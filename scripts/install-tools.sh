#!/usr/bin/env bash
# Install kubectl, kind and Helm (pinned versions) into ~/.local/bin, without root.
#
# Usage: scripts/install-tools.sh
#
# Linux and macOS, amd64 and arm64. Docker is NOT installed here: it needs root and changes
# the system, so install it yourself (https://docs.docker.com/engine/install/).
# Each download is verified against the SHA-256 file the project publishes next to it.
# Already-installed tools are left alone; override the versions through the environment.
set -euo pipefail

KUBECTL_VERSION="${KUBECTL_VERSION:-v1.37.1}"
KIND_VERSION="${KIND_VERSION:-v0.33.0}"
HELM_VERSION="${HELM_VERSION:-v3.22.0}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=darwin ;;
  *) die "unsupported OS $(uname -s); install kubectl, kind and helm manually" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required"
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "sha256sum or shasum is required"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$BIN_DIR"

# fetch <url> <file>: download, then verify against <url>.sha256 or <url>.sha256sum
fetch() {
  local url="$1" file="$2" suffix expected
  curl -fsSL "$url" -o "$file"
  for suffix in .sha256 .sha256sum; do
    if curl -fsSL "${url}${suffix}" -o "${file}.sum" 2>/dev/null; then
      expected="$(cut -d' ' -f1 "${file}.sum")"
      [ "$(sha256 "$file")" = "$expected" ] || die "checksum mismatch for ${url}"
      return 0
    fi
  done
  die "no checksum published for ${url}; refusing to install an unverified file"
}

have() { command -v "$1" >/dev/null 2>&1 || [ -x "$BIN_DIR/$1" ]; }

if have kubectl; then echo "kubectl already installed, skipping"; else
  echo "==> kubectl ${KUBECTL_VERSION}"
  fetch "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl" "$TMP/kubectl"
  install -m 0755 "$TMP/kubectl" "$BIN_DIR/kubectl"
fi

if have kind; then echo "kind already installed, skipping"; else
  echo "==> kind ${KIND_VERSION}"
  fetch "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" "$TMP/kind"
  install -m 0755 "$TMP/kind" "$BIN_DIR/kind"
fi

if have helm; then echo "helm already installed, skipping"; else
  echo "==> helm ${HELM_VERSION}"
  fetch "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz" "$TMP/helm.tgz"
  tar -xzf "$TMP/helm.tgz" -C "$TMP" "${OS}-${ARCH}/helm"
  install -m 0755 "$TMP/${OS}-${ARCH}/helm" "$BIN_DIR/helm"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Add ${BIN_DIR} to your PATH:  export PATH=\"${BIN_DIR}:\$PATH\"" ;;
esac
command -v docker >/dev/null 2>&1 || echo "Docker is not installed: https://docs.docker.com/engine/install/"
echo "Done."
