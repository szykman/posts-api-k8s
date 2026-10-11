#!/usr/bin/env bash
# Resilience test: drain one worker node while traffic flows through the ingress,
# then report how many requests failed.
#
# What it demonstrates (requirement 4, high availability):
#   - losing one node/zone does not interrupt the API (PodDisruptionBudget, probes,
#     preStop delay and graceful shutdown work together);
#   - with topologySpreadConstraints "DoNotSchedule", the evicted pod stays Pending
#     instead of doubling up in another zone, until the node comes back.
#
# Usage: scripts/resilience-test.sh [node-to-drain]
#   Without an argument it picks a node that hosts an API pod but not the database
#   (the scheduler decides where the database lands, so it cannot be hard-coded).
set -euo pipefail

NODE="${1:-}"   # empty: auto-select (see below)
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-posts}"   # never act on the current context by accident
NAMESPACE="${NAMESPACE:-posts}"
DEPLOYMENT="${DEPLOYMENT:-posts-api}"
INGRESS_URL="${INGRESS_URL:-http://localhost:18080}"
HOST_HEADER="${HOST_HEADER:-posts.local}"
BASELINE_SECONDS="${BASELINE_SECONDS:-5}"
SETTLE_SECONDS="${SETTLE_SECONDS:-15}"
API_SELECTOR="app.kubernetes.io/name=posts-api,app.kubernetes.io/component=api"
DB_SELECTOR="app.kubernetes.io/name=posts-api,app.kubernetes.io/component=db"

LOG="$(mktemp)"
LOAD_PID=""

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }

for tool in kubectl curl; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not found" >&2; exit 2; }
done

# Safety: the bundled database is a single instance with a node-bound volume.
# Draining its node would take the database (and therefore the API) down.
db_node="$(kc -n "$NAMESPACE" get pods -l "$DB_SELECTOR" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
if [ -z "$NODE" ]; then
  for candidate in $(kc -n "$NAMESPACE" get pods -l "$API_SELECTOR" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}'); do
    if [ "$candidate" != "$db_node" ]; then
      NODE="$candidate"
      break
    fi
  done
  [ -n "$NODE" ] || { echo "ERROR: no node with an API pod and without the database was found." >&2; exit 2; }
  echo "Auto-selected node: ${NODE} (hosts an API pod, not the database)"
fi
if [ -n "$db_node" ] && [ "$NODE" = "$db_node" ]; then
  echo "ERROR: $NODE hosts the single-instance database; pick another node." >&2
  exit 2
fi

cleanup() {
  if [ -n "$LOAD_PID" ]; then kill "$LOAD_PID" 2>/dev/null || true; fi
  if [ -n "$NODE" ]; then kc uncordon "$NODE" >/dev/null 2>&1 || true; fi
  rm -f "$LOG"
}
trap cleanup EXIT

generate_load() {
  while true; do
    code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' -H "Host: ${HOST_HEADER}" "${INGRESS_URL}/ready" || true)"
    echo "$(date +%s.%N) ${code}" >> "$LOG"
    sleep 0.2
  done
}

echo "== 1. Baseline: pods before the drain"
kc -n "$NAMESPACE" get pods -l "$API_SELECTOR" -o wide

echo
echo "== 2. Starting traffic through ${INGRESS_URL} (Host: ${HOST_HEADER})"
generate_load &
LOAD_PID=$!
sleep "$BASELINE_SECONDS"

echo
echo "== 3. Draining ${NODE}"
kc drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=120s \
  || echo "WARNING: drain did not complete within the timeout"

echo
echo "== 4. Letting the scheduler settle (${SETTLE_SECONDS}s)"
sleep "$SETTLE_SECONDS"
kc -n "$NAMESPACE" get pods -l "$API_SELECTOR" -o wide
echo "-- scheduling events:"
kc -n "$NAMESPACE" get events --sort-by=.lastTimestamp | grep -i FailedScheduling | tail -n 2 || true

echo
echo "== 5. Stopping traffic and counting results"
kill "$LOAD_PID" 2>/dev/null || true
LOAD_PID=""
total="$(wc -l < "$LOG" | tr -d ' ')"
ok="$(awk '$2 == 200' "$LOG" | wc -l | tr -d ' ')"
failed=$((total - ok))
echo "HTTP codes seen:"
awk '{print $2}' "$LOG" | sort | uniq -c

echo
echo "== 6. Recovery: uncordon ${NODE} and wait for the rollout"
kc uncordon "$NODE"
kc -n "$NAMESPACE" rollout status "deployment/${DEPLOYMENT}" --timeout=120s
kc -n "$NAMESPACE" get pods -l "$API_SELECTOR" -o wide

echo
echo "== Result: ${total} requests, ${ok} OK, ${failed} failed"
if [ "$failed" -eq 0 ]; then
  echo "PASS: no request failed while ${NODE} was drained."
else
  echo "FAIL: ${failed} request(s) failed during the drain." >&2
  exit 1
fi
