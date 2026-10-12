#!/usr/bin/env bash
# Upgrade and rollback test: upgrade the Helm release, roll it back, then upgrade again,
# all while requests flow through the ingress.
#
# What it demonstrates:
#   - the pre-upgrade hook runs the migration Job before the new pods roll out;
#   - the rolling update (maxUnavailable 0, readiness probe, preStop delay) keeps serving traffic;
#   - `helm rollback` returns to the previous revision without interrupting traffic.
#     A rollback does not run the migration hook and does not revert the schema, so it is only
#     safe while schema changes stay backward compatible.
#
# The release ends on the target version (the last step upgrades again).
#
# Usage: scripts/upgrade-test.sh [extra helm upgrade arguments]    e.g. --set image.tag=0.1.1
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-posts}"   # never act on the current context by accident
NAMESPACE="${NAMESPACE:-posts}"
RELEASE="${RELEASE:-posts-api}"
DEPLOYMENT="${DEPLOYMENT:-posts-api}"
MIGRATION_JOB="${MIGRATION_JOB:-posts-api-migrate}"
BASELINE_SECONDS="${BASELINE_SECONDS:-5}"
MIN_REQUESTS="${MIN_REQUESTS:-20}"   # a pass without traffic would prove nothing

LOG="$(mktemp)"
LOAD_PID=""

kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }
hc() { helm --kube-context "$KUBE_CONTEXT" "$@"; }

# shellcheck source=lib/ingress.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/ingress.sh"

for tool in kubectl helm curl; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not found" >&2; exit 2; }
done
load_ca "$KUBE_CONTEXT" "$NAMESPACE" || exit 2

cleanup() {
  if [ -n "$LOAD_PID" ]; then kill "$LOAD_PID" 2>/dev/null || true; fi
  rm -f "$LOG"
}
trap cleanup EXIT

# Helm keeps one Secret per revision; the label "version" is the revision number.
current_revision() {
  kc -n "$NAMESPACE" get secret -l "owner=helm,name=${RELEASE},status=deployed" \
    -o jsonpath='{.items[0].metadata.labels.version}'
}
current_image() {
  kc -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}'
}
migration_job_uid() {
  kc -n "$NAMESPACE" get job "$MIGRATION_JOB" -o jsonpath='{.metadata.uid}' 2>/dev/null || true
}
lines() { wc -l < "$LOG" | tr -d ' '; }
failures_between() {   # failed requests recorded after line $1 up to line $2
  sed -n "$(( $1 + 1 )),${2}p" "$LOG" | awk '$2 != 200' | wc -l | tr -d ' '
}
requests_between() { echo $(( $2 - $1 )); }

generate_load() {
  while true; do
    code="$(icurl -s -o /dev/null -m 2 -w '%{http_code}' "${INGRESS_URL}/ready" || true)"
    echo "$(date +%s.%N) ${code}" >> "$LOG"
    sleep 0.2
  done
}

upgrade() {
  hc upgrade --install "$RELEASE" "$ROOT/helm/posts-api" -n "$NAMESPACE" --wait --timeout 300s "$@"
}

rev0="$(current_revision)"; img0="$(current_image)"; uid0="$(migration_job_uid)"
echo "== Start: revision ${rev0}, image ${img0}"

echo
echo "== Starting traffic through ${INGRESS_URL}"
generate_load &
LOAD_PID=$!
sleep "$BASELINE_SECONDS"
m0="$(lines)"

echo
echo "== 1. Upgrade"
upgrade "$@" >/dev/null
rev1="$(current_revision)"; img1="$(current_image)"; uid1="$(migration_job_uid)"
m1="$(lines)"
echo "revision ${rev0} -> ${rev1}; image ${img0} -> ${img1}"
if [ "$img0" = "$img1" ]; then
  echo "WARNING: the image did not change, so no pod was replaced; pick a different target to exercise the rolling update."
fi
if [ "$uid1" != "$uid0" ]; then
  echo "pre-upgrade hook: ran (a new migration Job was created)"
else
  echo "WARNING: the migration Job is unchanged; the hook may not have run"
fi

echo
echo "== 2. Rollback to revision ${rev0}"
hc rollback "$RELEASE" "$rev0" -n "$NAMESPACE" --wait --timeout 300s >/dev/null
rev2="$(current_revision)"; img2="$(current_image)"; uid2="$(migration_job_uid)"
m2="$(lines)"
echo "now at revision ${rev2}; image ${img2}"
if [ "$uid2" = "$uid1" ]; then
  echo "migration hook: not run on rollback (as expected; the schema is not reverted)"
else
  echo "WARNING: a rollback created a new migration Job"
fi
if [ "$img2" != "$img0" ]; then
  echo "WARNING: the image after the rollback (${img2}) is not the original one (${img0})"
fi

echo
echo "== 3. Upgrade again (leaves the release on the target version)"
upgrade "$@" >/dev/null
rev3="$(current_revision)"; img3="$(current_image)"
m3="$(lines)"
echo "now at revision ${rev3}; image ${img3}"
kc -n "$NAMESPACE" get pods -l app.kubernetes.io/component=api -o wide

echo
echo "== Stopping traffic and counting results"
kill "$LOAD_PID" 2>/dev/null || true
LOAD_PID=""

printf '%-22s %10s %8s\n' "phase" "requests" "failed"
f1="$(failures_between "$m0" "$m1")"; f2="$(failures_between "$m1" "$m2")"; f3="$(failures_between "$m2" "$m3")"
printf '%-22s %10s %8s\n' "1. upgrade" "$(requests_between "$m0" "$m1")" "$f1"
printf '%-22s %10s %8s\n' "2. rollback" "$(requests_between "$m1" "$m2")" "$f2"
printf '%-22s %10s %8s\n' "3. upgrade again" "$(requests_between "$m2" "$m3")" "$f3"
failed=$(( f1 + f2 + f3 ))
total=$(( m3 - m0 ))

echo
echo "== Result: ${total} requests during the three operations, ${failed} failed"
if [ "$total" -lt "$MIN_REQUESTS" ]; then
  echo "FAIL: only ${total} requests were recorded (minimum ${MIN_REQUESTS}); the traffic generator did not run, so a pass would mean nothing." >&2
  exit 1
fi
if [ "$failed" -eq 0 ]; then
  echo "PASS: no request failed during the upgrade, the rollback and the second upgrade."
else
  echo "FAIL: ${failed} request(s) failed." >&2
  exit 1
fi
