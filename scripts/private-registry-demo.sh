#!/usr/bin/env bash
# Shows, on the local cluster, that a private image can only be pulled with the pull Secret.
#
# Usage: PRIVATE_IMAGE=ghcr.io/<you>/<private-package>:<tag> REGISTRY_USER=<user> REGISTRY_TOKEN=<token> \
#        scripts/private-registry-demo.sh
#
# PRIVATE_IMAGE must be an image that is really private (see "Private registry" in the README). The script starts
# a throw-away pod twice: without the Secret it must fail with an image pull error, with it the pod must run.
# Nothing else in the cluster is touched; the pods and the Secret are removed at the end.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-posts}"   # never act on the current context by accident
NAMESPACE="${NAMESPACE:-posts}"
SECRET="demo-regcred"
IMAGE="${PRIVATE_IMAGE:-}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
kc() { kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }

[ -n "$IMAGE" ] || die "set PRIVATE_IMAGE to a private image reference"

cleanup() {
  kc delete pod demo-without-secret demo-with-secret --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kc delete secret "$SECRET" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# wait_state <pod> <seconds>: prints "running" or the waiting reason (ErrImagePull, ImagePullBackOff, ...)
wait_state() {
  local pod="$1" deadline=$((SECONDS + $2)) phase reason
  while [ "$SECONDS" -lt "$deadline" ]; do
    phase="$(kc get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    reason="$(kc get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    if [ "$phase" = "Running" ]; then echo running; return 0; fi
    case "$reason" in ErrImagePull|ImagePullBackOff) echo "$reason"; return 0 ;; esac
    sleep 2
  done
  echo timeout
}

echo "== 1. Without the pull Secret the image must not be pullable"
kc run demo-without-secret --image="$IMAGE" --restart=Never --command -- sleep 120 >/dev/null
state="$(wait_state demo-without-secret 90)"
echo "pod state: ${state}"
case "$state" in
  ErrImagePull|ImagePullBackOff) echo "ok  the private image was refused" ;;
  running) die "the pod ran without credentials: ${IMAGE} is not private" ;;
  *) die "unexpected state: ${state}" ;;
esac
kc get events --field-selector involvedObject.name=demo-without-secret 2>/dev/null | grep -i -m1 -E 'unauthorized|denied|authentication' || true

echo "== 2. With the pull Secret the same image runs"
"$ROOT/scripts/create-pull-secret.sh" "$SECRET"
kc run demo-with-secret --image="$IMAGE" --restart=Never \
  --overrides="{\"spec\":{\"imagePullSecrets\":[{\"name\":\"${SECRET}\"}]}}" --command -- sleep 120 >/dev/null
state="$(wait_state demo-with-secret 90)"
echo "pod state: ${state}"
[ "$state" = "running" ] || die "the pod did not run with the pull Secret (state: ${state})"
echo "ok  the pod pulled the private image with the Secret"
echo "== Private registry demo passed"
