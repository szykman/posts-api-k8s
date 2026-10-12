# shellcheck shell=bash
# Shared by the scripts that call the API through the ingress. Source it, do not run it.
#
# The ingress serves HTTPS only, with a self-signed certificate that `bootstrap.sh up` creates and keeps in the
# Secret posts-api-tls. The certificate is its own trust anchor: load_ca saves it, and icurl passes it to curl
# with --cacert, so the TLS chain and the host name are really verified (no -k).

HOST_HEADER="${HOST_HEADER:-posts.local}"
INGRESS_TLS_PORT="${INGRESS_TLS_PORT:-18443}"   # must match the 443 hostPort in kind/cluster.yaml
INGRESS_URL="${INGRESS_URL:-https://${HOST_HEADER}:${INGRESS_TLS_PORT}}"
TLS_SECRET="${TLS_SECRET:-posts-api-tls}"
CA_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/posts-api/ingress-ca.crt"

# load_ca <kube-context> <namespace>
load_ca() {
  mkdir -p "$(dirname "$CA_FILE")"
  kubectl --context "$1" -n "$2" get secret "$TLS_SECRET" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CA_FILE"
  if [ ! -s "$CA_FILE" ]; then
    echo "ERROR: could not read the certificate from the Secret ${TLS_SECRET}; run: scripts/bootstrap.sh up" >&2
    return 1
  fi
}

# curl that verifies the certificate and maps the host name to the local port of the kind cluster
icurl() {
  curl --cacert "$CA_FILE" --resolve "${HOST_HEADER}:${INGRESS_TLS_PORT}:127.0.0.1" "$@"
}
