#!/usr/bin/env bash
# Build (and optionally publish) the application image.
#
# Usage: scripts/build.sh [--push]
#
# The tag is the chart's appVersion, so the chart and the image cannot drift apart: the chart
# defaults to the image tag it was released with. Publishing refuses to overwrite a tag that
# already exists in the registry, so a version always points at one image.
#
# Environment:
#   IMAGE_REPO   image repository (default: ghcr.io/szykman/posts-api)
#   PLATFORM     target platform (default: linux/amd64)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/szykman/posts-api}"
PLATFORM="${PLATFORM:-linux/amd64}"
CHART="$ROOT/helm/posts-api/Chart.yaml"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PUSH=false
case "${1:-}" in
  "") ;;
  --push) PUSH=true ;;
  *) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker info >/dev/null 2>&1 || die "the Docker daemon is not running"

VERSION="$(sed -n 's/^appVersion:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$CHART")"
[ -n "$VERSION" ] || die "could not read appVersion from ${CHART}"
IMAGE="${IMAGE_REPO}:${VERSION}"

REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  [ "$PUSH" = false ] || die "the working tree has uncommitted changes; commit them before publishing"
  REVISION="${REVISION}-dirty"
fi

if [ "$PUSH" = true ] && docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
  die "${IMAGE} already exists in the registry; bump appVersion in Chart.yaml instead of overwriting a tag"
fi

echo "==> Building ${IMAGE} (${PLATFORM}, revision ${REVISION})"
docker build --platform "$PLATFORM" \
  --label "org.opencontainers.image.version=${VERSION}" \
  --label "org.opencontainers.image.revision=${REVISION}" \
  --label "org.opencontainers.image.source=https://github.com/szykman/posts-api-k8s" \
  -t "$IMAGE" "$ROOT"

if [ "$PUSH" = true ]; then
  echo "==> Pushing ${IMAGE}"
  docker push "$IMAGE"
  docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE"
else
  echo "Built ${IMAGE}. Run with --push to publish it."
fi
