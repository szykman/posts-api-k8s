#!/usr/bin/env bash
# Bootstrap: create the local cluster, install the ingress controller, create the
# database and API-token Secrets, deploy the application and run the tests.
#
# Usage: scripts/bootstrap.sh <command>
#   up                  create everything (safe to re-run: every step is idempotent)
#                       LOCAL_IMAGE=true builds the image from this checkout and loads it into the cluster
#                       instead of pulling the published one (used by CI, and to try unreleased changes)
#   test                run `helm test` and a functional smoke test through the ingress
#   test --resilience   also run the node-drain resilience test
#   test --upgrade      also run the upgrade/rollback test (changes the release revision)
#   token               print the API token (needed to POST /posts)
#   ca                  print the path of the ingress certificate, for curl --cacert
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
INGRESS_PORT="${INGRESS_PORT:-18080}"   # plain HTTP, must match hostPort in kind/cluster.yaml (the API is not served on it)
SECRET_NAME="posts-db-credentials"
TOKEN_SECRET="posts-api-token"

# HTTPS settings and the helpers that verify the ingress certificate (HOST_HEADER, INGRESS_URL, TLS_SECRET, icurl, load_ca)
# shellcheck source=lib/ingress.sh
. "$ROOT/scripts/lib/ingress.sh"
BASE_URL="$INGRESS_URL"
HTTP_URL="http://localhost:${INGRESS_PORT}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
k() { kubectl --context "$CONTEXT" "$@"; }
# The API token written by `up`; POST /posts needs it as "Authorization: Bearer <token>".
api_token() { k -n "$NAMESPACE" get secret "$TOKEN_SECRET" -o jsonpath='{.data.API_TOKEN}' | base64 -d; }
h() { helm --kube-context "$CONTEXT" "$@"; }

usage() {
  sed -n '/^# Usage:/,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

require_tools() {
  local missing=()
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "missing tools: ${missing[*]}. kubectl, kind and helm can be installed with scripts/install-tools.sh; Docker and the rest are listed in the README prerequisites"
  fi
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER"
}

port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

wait_for_ingress() {
  local code
  for _ in $(seq 1 30); do
    code="$(icurl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/ready" || true)"
    if [ "$code" = "200" ]; then
      return 0
    fi
    sleep 2
  done
  die "the API did not answer 200 on ${BASE_URL}/ready through the ingress"
}

# The API pods must sit in different zones (one per zone with 3 replicas). A fresh install gets this right;
# a rolling update is what can break it, so run this after an upgrade too (it is part of `test`).
check_zone_spread() {
  local nodes total distinct want
  nodes="$(k -n "$NAMESPACE" get pods -l app.kubernetes.io/name=posts-api,app.kubernetes.io/component=api \
    -o wide --no-headers | awk '$3=="Running"{print $7}')"
  [ -n "$nodes" ] || die "no running API pods found"
  total="$(printf '%s\n' "$nodes" | wc -l)"
  distinct="$(printf '%s\n' "$nodes" | while read -r node; do
    k get node "$node" -L topology.kubernetes.io/zone --no-headers | awk '{print $NF}'
  done | sort -u | wc -l)"
  total=$((total)); distinct=$((distinct))
  want=$((total < 3 ? total : 3))
  [ "$distinct" -ge "$want" ] || die "the ${total} API pods are spread over only ${distinct} zone(s), expected ${want}; see: kubectl -n ${NAMESPACE} get pods -o wide"
  echo "ok  ${total} API pods spread over ${distinct} zone(s)"
}

smoke_test() {
  local title out body id code token
  title="smoke-$(date +%s)"
  token="$(api_token)"
  [ -n "$token" ] || die "could not read the API token from the Secret ${TOKEN_SECRET}"

  wait_for_ingress
  echo "ok  HTTPS with the ingress certificate, verified (no -k)"
  check_zone_spread

  out="$(icurl -fsS "${BASE_URL}/ready")"
  case "$out" in *'"ready"'*) ;; *) die "unexpected /ready answer: ${out}" ;; esac
  echo "ok  GET /ready"

  # Authentication: a write without the token, or with a wrong one, must be refused.
  code="$(icurl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d '{"title":"no token","text":"x"}' "${BASE_URL}/posts" || true)"
  [ "$code" = "401" ] || die "POST /posts without a token answered ${code}, expected 401"
  echo "ok  POST without a token -> 401"

  code="$(icurl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -H 'Authorization: Bearer not-the-token' -d '{"title":"wrong token","text":"x"}' "${BASE_URL}/posts" || true)"
  [ "$code" = "401" ] || die "POST /posts with a wrong token answered ${code}, expected 401"
  echo "ok  POST with a wrong token -> 401"

  out="$(icurl -sS -X POST -H "Authorization: Bearer ${token}" -H 'content-type: application/json' \
    -d "{\"title\":\"${title}\",\"text\":\"created by the smoke test\"}" \
    -w $'\n%{http_code}' "${BASE_URL}/posts")"
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  [ "$code" = "201" ] || die "POST /posts answered ${code}, expected 201: ${body}"
  id="$(printf '%s' "$body" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')"
  [ -n "$id" ] || die "POST /posts did not return an id: ${body}"
  echo "ok  POST /posts with the token -> 201, id ${id}"

  out="$(icurl -fsS "${BASE_URL}/posts/${id}")"
  case "$out" in *"$title"*) ;; *) die "GET /posts/${id} did not return the created post: ${out}" ;; esac
  echo "ok  GET /posts/${id}"

  # Input validation (regression test for the mass-assignment fix): an id sent by the client
  # must be rejected, and the existing post must stay untouched.
  code="$(icurl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer ${token}" -H 'content-type: application/json' \
    -d "{\"id\":${id},\"title\":\"overwritten\",\"text\":\"x\"}" "${BASE_URL}/posts" || true)"
  [ "$code" = "400" ] || die "POST /posts with a client-supplied id answered ${code}, expected 400 (an existing post could be overwritten)"
  echo "ok  POST with a client-supplied id -> 400"

  out="$(icurl -fsS "${BASE_URL}/posts/${id}")"
  case "$out" in *"$title"*) ;; *) die "the post ${id} was overwritten: ${out}" ;; esac
  echo "ok  the existing post was not overwritten"

  code="$(icurl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/posts/${id}abc" || true)"
  [ "$code" = "400" ] || die "GET /posts/${id}abc answered ${code}, expected 400"
  echo "ok  malformed id -> 400"

  code="$(icurl -s -o /dev/null -w '%{http_code}' -H 'Host: unknown.example' "${BASE_URL}/posts" || true)"
  [ "$code" = "404" ] || die "a request for an unknown host returned ${code}, expected 404"
  echo "ok  unknown host -> 404"

  # The API is served over HTTPS only: on the plain HTTP port nothing answers for this host, so a client that
  # forgets https:// gets an error instead of a working (and unencrypted) API.
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${HOST_HEADER}" "${HTTP_URL}/ready" || true)"
  [ "$code" = "404" ] || die "plain HTTP answered ${code} for ${HOST_HEADER}, expected 404 (the API must be HTTPS only)"
  echo "ok  plain HTTP is not served -> 404"
}

# Self-signed certificate for the ingress, valid one year, with the host name as a subjectAltName (modern clients
# ignore the common name). The private key only exists in a temporary directory and in the Secret.
create_tls_secret() {
  local dir
  dir="$(mktemp -d)"
  cat > "$dir/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${HOST_HEADER}
[v3]
subjectAltName = DNS:${HOST_HEADER}
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
basicConstraints = critical, CA:FALSE
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout "$dir/tls.key" -out "$dir/tls.crt" -config "$dir/openssl.cnf" >/dev/null 2>&1 \
    || { rm -rf "$dir"; die "could not generate the TLS certificate with openssl"; }
  k -n "$NAMESPACE" create secret tls "$TLS_SECRET" --cert="$dir/tls.crt" --key="$dir/tls.key"
  rm -rf "$dir"
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
  k wait --for=condition=Ready node --all --timeout=180s
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

  if k -n "$NAMESPACE" get secret "$TLS_SECRET" >/dev/null 2>&1; then
    echo "Secret ${TLS_SECRET} already exists, keeping it"
  else
    create_tls_secret
  fi
  if k -n "$NAMESPACE" get secret "$TOKEN_SECRET" >/dev/null 2>&1; then
    echo "Secret ${TOKEN_SECRET} already exists, keeping it"
  else
    k -n "$NAMESPACE" create secret generic "$TOKEN_SECRET" --from-literal=API_TOKEN="$(openssl rand -hex 32)"
  fi

  if [ "${LOCAL_IMAGE:-false}" = "true" ]; then
    log "Image built from this checkout, loaded into the cluster (LOCAL_IMAGE=true)"
    "$ROOT/scripts/build.sh"
    kind load docker-image "$("$ROOT/scripts/build.sh" --print-image)" --name "$CLUSTER"
  fi

  log "Application (Helm release '${RELEASE}')"
  h lint "$ROOT/helm/posts-api"
  h upgrade --install "$RELEASE" "$ROOT/helm/posts-api" -n "$NAMESPACE" --wait --timeout 300s
  k -n "$NAMESPACE" get pods -o wide

  log "Ready"
  echo "Try it:   curl --cacert \"\$(scripts/bootstrap.sh ca)\" --resolve ${HOST_HEADER}:${INGRESS_TLS_PORT}:127.0.0.1 ${BASE_URL}/posts"
  echo "Write:    add -H \"Authorization: Bearer \$(scripts/bootstrap.sh token)\" -H 'content-type: application/json' -d '{\"title\":\"t\",\"text\":\"x\"}'"
  echo "HTTPS only, self-signed certificate: --cacert makes curl verify it."
  echo "Test it:  scripts/bootstrap.sh test"
  echo "Remove:   scripts/bootstrap.sh down"
}

cmd_test() {
  local resilience=0 upgrade=0 arg
  for arg in "$@"; do
    case "$arg" in
      --resilience) resilience=1 ;;
      --upgrade) upgrade=1 ;;
      *) die "unknown option for test: ${arg}" ;;
    esac
  done

  require_tools kubectl helm curl base64
  k cluster-info >/dev/null 2>&1 || die "cluster '${CLUSTER}' is not reachable; run: scripts/bootstrap.sh up"
  load_ca "$CONTEXT" "$NAMESPACE"

  log "helm test (readiness check from inside the cluster)"
  h -n "$NAMESPACE" test "$RELEASE"

  log "Functional smoke test through the ingress"
  smoke_test

  if [ "$upgrade" -eq 1 ]; then
    log "Upgrade and rollback test (under traffic)"
    "$ROOT/scripts/upgrade-test.sh"
  fi

  if [ "$resilience" -eq 1 ]; then
    log "Resilience test (drains a worker under traffic)"
    "$ROOT/scripts/resilience-test.sh"
  fi

  log "All tests passed"
}

cmd_token() {
  require_tools kubectl base64
  api_token
  echo
}

cmd_ca() {
  require_tools kubectl base64
  load_ca "$CONTEXT" "$NAMESPACE"
  echo "$CA_FILE"
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
  token) cmd_token ;;
  ca) cmd_ca ;;
  down) cmd_down ;;
  *) usage; exit 2 ;;
esac
