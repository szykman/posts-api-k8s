#!/usr/bin/env bash
# Observability on the local cluster: Prometheus, Grafana and the alerts and dashboard for the API.
#
# Usage: scripts/observability.sh up        install kube-prometheus-stack, then switch on the API's PodMonitor, alerts
#                                           and dashboard (an upgrade of the posts-api release)
#        scripts/observability.sh test      check that Prometheus scrapes every API pod, has the request metrics and
#                                           the alerts, and that /metrics is not reachable through the ingress
#        scripts/observability.sh grafana   print how to open Grafana (address, user, password)
#        scripts/observability.sh down      remove the stack and switch the API's monitor, alerts and dashboard off
#
# It needs the cluster from `scripts/bootstrap.sh up`. The stack adds roughly 1 GB of memory to the cluster.
# Every kubectl/helm call targets the kind-posts context explicitly, as in bootstrap.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT="${KUBE_CONTEXT:-kind-posts}"
NAMESPACE="${NAMESPACE:-posts}"
RELEASE="${RELEASE:-posts-api}"
MONITORING_NAMESPACE="monitoring"
STACK_RELEASE="kube-prometheus-stack"
# Pinned, as the Traefik chart is: an install today and one next month must not differ.
STACK_CHART_VERSION="${STACK_CHART_VERSION:-91.9.0}"
PROMETHEUS_LOCAL_PORT="${PROMETHEUS_LOCAL_PORT:-19090}"
GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT:-13000}"
# How long `test` waits for Prometheus to scrape and load the rules (the scrape interval is 30 s).
WAIT_SECONDS="${WAIT_SECONDS:-120}"

# shellcheck source=lib/ingress.sh
. "$ROOT/scripts/lib/ingress.sh"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
k() { kubectl --context "$CONTEXT" "$@"; }
h() { helm --kube-context "$CONTEXT" "$@"; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: ${tool} (kubectl and helm: scripts/install-tools.sh)"
  done
}

require_cluster() {
  k cluster-info >/dev/null 2>&1 || die "cluster '${CONTEXT}' is not reachable; run: scripts/bootstrap.sh up"
  h -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1 || die "release '${RELEASE}' not found in '${NAMESPACE}'; run: scripts/bootstrap.sh up"
}

# The API release with the monitoring objects switched on or off. The other values are the chart defaults, which is
# what bootstrap.sh installs, so nothing else changes. The pre-upgrade hook runs the (idempotent) migration again.
upgrade_api() {
  h upgrade "$RELEASE" "$ROOT/helm/posts-api" -n "$NAMESPACE" --wait --timeout 300s \
    --set "metrics.podMonitor.enabled=$1" --set "metrics.prometheusRule.enabled=$1" --set "metrics.grafanaDashboard.enabled=$1"
}

cmd_up() {
  require_tools kubectl helm
  require_cluster

  log "kube-prometheus-stack ${STACK_CHART_VERSION} in namespace ${MONITORING_NAMESPACE}"
  h repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  h repo update >/dev/null
  h upgrade --install "$STACK_RELEASE" prometheus-community/kube-prometheus-stack --version "$STACK_CHART_VERSION" \
    -n "$MONITORING_NAMESPACE" --create-namespace -f "$ROOT/k8s/observability-values.yaml" --wait --timeout 600s

  log "API: PodMonitor, alerts and dashboard on"
  upgrade_api true
  k -n "$MONITORING_NAMESPACE" get pods

  log "Ready"
  echo "Check it:   scripts/observability.sh test"
  echo "Grafana:    scripts/observability.sh grafana"
}

PF_PID=""
stop_port_forward() {
  if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; fi
}

# A Prometheus instant query. Prints the value of the first result, or nothing when the result is empty.
PROM_URL="http://127.0.0.1:${PROMETHEUS_LOCAL_PORT}"
query() {
  curl -fsS -G "${PROM_URL}/api/v1/query" --data-urlencode "query=$1" \
    | sed -n 's/.*"result":\[{.*"value":\[[^,]*,"\([^"]*\)"\]}.*/\1/p'
}

# wait_for <description> <command...>: run the command until it succeeds, for at most WAIT_SECONDS.
wait_for() {
  local description="$1" waited=0
  shift
  until "$@"; do
    waited=$((waited + 5))
    if [ "$waited" -gt "$WAIT_SECONDS" ]; then
      echo "FAIL  ${description} (waited ${WAIT_SECONDS}s)" >&2
      return 1
    fi
    sleep 5
  done
  echo "ok    ${description}"
}

prometheus_ready() { curl -fsS "${PROM_URL}/-/ready" >/dev/null 2>&1; }

has_requests() { [ "$(query "sum(http_requests_total{namespace=\"${NAMESPACE}\",route=\"/posts\"})")" != "" ]; }

targets_match_pods() {
  local up ready
  up="$(query "count(up{namespace=\"${NAMESPACE}\"} == 1)")"
  ready="$(k -n "$NAMESPACE" get deployment "$RELEASE" -o jsonpath='{.status.readyReplicas}')"
  [ -n "$up" ] && [ "${up%.*}" = "${ready:-0}" ] && [ "${ready:-0}" -gt 0 ]
}

rules_loaded() {
  local body name
  body="$(curl -fsS "${PROM_URL}/api/v1/rules" 2>/dev/null)" || return 1
  for name in PostsApiNoReplicasAvailable PostsApiReplicasUnavailable PostsApiHighErrorRate PostsApiSlowRequests PostsApiPodRestarting; do
    printf '%s' "$body" | grep -q "\"name\":\"${name}\"" || return 1
  done
}

cmd_test() {
  require_tools kubectl helm curl base64
  require_cluster
  load_ca "$CONTEXT" "$NAMESPACE"
  trap stop_port_forward EXIT

  log "Port-forward to Prometheus (${PROM_URL})"
  k -n "$MONITORING_NAMESPACE" port-forward "svc/${STACK_RELEASE}-prometheus" "${PROMETHEUS_LOCAL_PORT}:9090" >/dev/null 2>&1 &
  PF_PID=$!
  wait_for "Prometheus answers" prometheus_ready

  log "Traffic through the ingress (30 reads)"
  for _ in $(seq 1 30); do
    icurl -s -o /dev/null "${INGRESS_URL}/posts" || true
  done

  log "Checks"
  wait_for "every API pod is a Prometheus target and is up" targets_match_pods
  wait_for "http_requests_total has samples for GET /posts" has_requests
  wait_for "the five PostsApi alerts are loaded" rules_loaded

  local firing
  firing="$(query "count(ALERTS{alertname=~\"PostsApi.*\",alertstate=\"firing\"})")" || die "could not query Prometheus"
  [ -z "$firing" ] || die "${firing} PostsApi alert(s) are firing; open Prometheus > Alerts"
  echo "ok    no PostsApi alert is firing"

  local code
  code="$(icurl -s -o /dev/null -w '%{http_code}' "${INGRESS_URL}/metrics" || true)"
  [ "$code" = "404" ] || die "/metrics through the ingress answered ${code}, expected 404 (metrics must stay inside the cluster)"
  echo "ok    /metrics is not served through the ingress (404)"

  log "Observability checks passed"
}

cmd_grafana() {
  require_tools kubectl base64
  local password
  password="$(k -n "$MONITORING_NAMESPACE" get secret "${STACK_RELEASE}-grafana" -o jsonpath='{.data.admin-password}' | base64 -d)"
  echo "Open Grafana from the machine where the cluster runs:"
  echo "  kubectl --context ${CONTEXT} -n ${MONITORING_NAMESPACE} port-forward svc/${STACK_RELEASE}-grafana ${GRAFANA_LOCAL_PORT}:80"
  echo "  then http://127.0.0.1:${GRAFANA_LOCAL_PORT}   user: admin   password: ${password}"
  echo "Dashboards: 'posts-api' (this API) and the Kubernetes ones the stack ships."
  echo "From another machine: ssh -L ${GRAFANA_LOCAL_PORT}:127.0.0.1:${GRAFANA_LOCAL_PORT} <this host>, then the same address."
}

cmd_down() {
  require_tools kubectl helm
  if k cluster-info >/dev/null 2>&1 && h -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1; then
    log "API: PodMonitor, alerts and dashboard off"
    upgrade_api false
  fi
  if h -n "$MONITORING_NAMESPACE" status "$STACK_RELEASE" >/dev/null 2>&1; then
    log "Removing ${STACK_RELEASE}"
    h -n "$MONITORING_NAMESPACE" uninstall "$STACK_RELEASE"
    k delete namespace "$MONITORING_NAMESPACE" --ignore-not-found
    echo "The Prometheus Operator CRDs stay in the cluster (Helm does not remove CRDs). Deleting the cluster removes them:"
    echo "  scripts/bootstrap.sh down"
  else
    echo "${STACK_RELEASE} is not installed, nothing to remove"
  fi
}

usage() {
  sed -n '/^# Usage:/,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  up) cmd_up ;;
  test) cmd_test ;;
  grafana) cmd_grafana ;;
  down) cmd_down ;;
  *) usage; exit 2 ;;
esac
