#!/usr/bin/env bash
# Bootstrap: create the local cluster, install the ingress controller, create the
# database Secret, deploy the application and run the tests.
#
# Usage: scripts/bootstrap.sh <command>
#   up                  create everything (safe to re-run: every step is idempotent)
#   test                run `helm test` and a functional smoke test through the ingress
#   test --resilience   same, plus the node-drain resilience test
#   down                delete the cluster and everything in it
#
# Every kubectl/helm call targets the kind-posts context explicitly, so this script can
# never act on whatever cluster happens to be your current context.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="posts"
CONTEXT="kind-${CLUSTER}"
NAMESPACE="${NAMESPACE:-posts}"
RELEASE="${RELEASE:-posts-api}"
TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-41.7.1}"
INGRESS_PORT="${INGRESS_PORT:-18080}"   # must match hostPort in kind/cluster.yaml
HOST_HEADER="${HOST_HEADER:-posts.local}"
SECRET_NAME="posts-db-credentials"
BASE_URL="http://localhost:${INGRESS_PORT}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
k() { kubectl --context "$CONTEXT" "$@"; }
h() { helm --kube-context "$CONTEXT" "$@"; }

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

require_tools() {
  local missing=()
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "missing tools: ${missing[*]} (see the prerequisites in the README)"
  fi
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER"
}

port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

wait_for_ingress() {
  local code attempt
  for attempt in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${HOST_HEADER}" "${BASE_URL}/ready" || true)"
    if [ "$code" = "200" ]; then
      return 0
    fi
    sleep 2
  done
  die "the API did not answer 200 on ${BASE_URL}/ready through the ingress"
}

smoke_test() {
  local title body id code out
  title="smoke-$(date +%s)"

  wait_for_ingress

  out="$(curl -fsS -H "Host: ${HOST_HEADER}" "${BASE_URL}/ready")"
  case "$out" in *'"ready"'*) ;; *) die "unexpected /ready answer: ${out}" ;; esac
  echo "ok  GET /ready"

  body="$(curl -fsS -X POST -H "Host: ${HOST_HEADER}" -H 'content-type: application/json' \
    -d "{\"title\":\"${title}\",\"text\":\"created by the smoke test\"}" "${BASE_URL}/posts")"
  id="$(printf '%s' "$body" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')"
  [ -n "$id" ] || die "POST /posts did not return an id: ${body}"
  echo "ok  POST /posts -> id ${id}"

  out="$(curl -fsS -H "Host: ${HOST_HEADER}" "${BASE_URL}/posts/${id}")"
  case "$out" in *"$title"*) ;; *) die "GET /posts/${id} did not return the created post: ${out}" ;; esac
  echo "ok  GET /posts/${id}"

  code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/posts" || true)"
  [ "$code" = "404" ] || die "a request without the expected Host header returned ${code}, expected 404"
  echo "ok  unknown host -> 404"
}

cmd_up() {
  require_tools docker kind kubectl helm openssl curl
  docker info >/dev/null 2>&1 || die "the Docker daemon is not running"

  log "Cluster '${CLUSTER}' (1 control-plane + 3 workers, one per simulated zone)"
  if cluster_exists; then
    echo "cluster already exists, reusing it"
  else
    local port
    for port in 18080 18443; do
      if port_in_use "$port"; then
        die "host port ${port} is already in use (change it in kind/cluster.yaml and set INGRESS_PORT)"
      fi
    done
    kind create cluster --config "$ROOT/kind/cluster.yaml"
  fi
  k get nodes -L topology.kubernetes.io/zone

  log "Ingress controller (Traefik chart ${TRAEFIK_CHART_VERSION})"
  h repo add traefik https://traefik.github.io/charts --force-update >/dev/null
  h repo update >/dev/null
  h upgrade --install traefik traefik/traefik --version "$TRAEFIK_CHART_VERSION" \
    -n traefik --create-namespace -f "$ROOT/k8s/traefik-values.yaml" --wait --timeout 300s

  log "Namespace and database credentials"
  if k get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "namespace ${NAMESPACE} already exists"
  else
    k create namespace "$NAMESPACE"
  fi
  if k -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    echo "Secret ${SECRET_NAME} already exists, keeping it (rotating it would not change the database password)"
  else
    k -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
      --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)" \
      --from-literal=MYSQL_PASSWORD="$(openssl rand -hex 16)" \
      --from-literal=MYSQL_USER=posts \
      --from-literal=MYSQL_DATABASE=posts
  fi

  log "Application (Helm release '${RELEASE}')"
  h lint "$ROOT/helm/posts-api"
  h upgrade --install "$RELEASE" "$ROOT/helm/posts-api" -n "$NAMESPACE" --wait --timeout 300s
  k -n "$NAMESPACE" get pods -o wide

  log "Ready"
  echo "Try it:   curl -H 'Host: ${HOST_HEADER}' ${BASE_URL}/posts"
  echo "Test it:  scripts/bootstrap.sh test"
  echo "Remove:   scripts/bootstrap.sh down"
}

cmd_test() {
  require_tools kubectl helm curl
  k cluster-info >/dev/null 2>&1 || die "cluster '${CLUSTER}' is not reachable; run: scripts/bootstrap.sh up"

  log "helm test (readiness check from inside the cluster)"
  h -n "$NAMESPACE" test "$RELEASE"

  log "Functional smoke test through the ingress"
  smoke_test

  if [ "${1:-}" = "--resilience" ]; then
    log "Resilience test (drains a worker under traffic)"
    "$ROOT/scripts/resilience-test.sh"
  fi

  log "All tests passed"
}

cmd_down() {
  require_tools kind
  if cluster_exists; then
    log "Deleting cluster '${CLUSTER}' and everything in it"
    kind delete cluster --name "$CLUSTER"
  else
    echo "cluster '${CLUSTER}' does not exist, nothing to do"
  fi
}

case "${1:-}" in
  up) cmd_up ;;
  test) shift; cmd_test "$@" ;;
  down) cmd_down ;;
  *) usage; exit 2 ;;
esac
