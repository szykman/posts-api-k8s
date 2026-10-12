#!/usr/bin/env bash
# Create (or update) the image pull Secret the chart references in `imagePullSecrets`, for a private registry.
#
# Usage: REGISTRY_USER=<user> REGISTRY_TOKEN=<token> scripts/create-pull-secret.sh [secret-name]
#   REGISTRY         registry host (default: ghcr.io)
#   REGISTRY_USER    registry user name
#   REGISTRY_TOKEN   a token that can only READ images (for ghcr.io: a token with the read:packages scope).
#                    If it is not set the script asks for it without echoing it.
#   NAMESPACE        namespace of the release (default: posts)
#
# The token never appears on a command line (where `ps` would show it): the Secret is built from a
# temporary file readable only by the owner. Use a read-only token, as short-lived as the registry allows.
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-kind-posts}"   # never act on the current context by accident
NAMESPACE="${NAMESPACE:-posts}"
REGISTRY="${REGISTRY:-ghcr.io}"
SECRET_NAME="${1:-regcred}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl is not installed"
command -v base64 >/dev/null 2>&1 || die "base64 is not installed"
[ -n "${REGISTRY_USER:-}" ] || die "set REGISTRY_USER"
if [ -z "${REGISTRY_TOKEN:-}" ]; then
  [ -t 0 ] || die "set REGISTRY_TOKEN (there is no terminal to ask on)"
  printf 'Token for %s (input hidden): ' "$REGISTRY"
  read -rs REGISTRY_TOKEN
  echo
fi
[ -n "$REGISTRY_TOKEN" ] || die "empty token"

# The values go into a JSON document, so refuse characters that would need escaping.
case "$REGISTRY$REGISTRY_USER$REGISTRY_TOKEN" in
  *[!A-Za-z0-9._~+/=:@-]*) die "unexpected characters in the registry, user or token" ;;
esac

umask 077
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
auth="$(printf '%s:%s' "$REGISTRY_USER" "$REGISTRY_TOKEN" | base64 | tr -d '\n')"
printf '{"auths":{"%s":{"username":"%s","password":"%s","auth":"%s"}}}' \
  "$REGISTRY" "$REGISTRY_USER" "$REGISTRY_TOKEN" "$auth" > "$tmp"

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson="$tmp" \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
echo "Secret ${SECRET_NAME} ready in namespace ${NAMESPACE}. Use it with: --set 'imagePullSecrets[0].name=${SECRET_NAME}'"
