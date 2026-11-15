#!/usr/bin/env bash
# One-shot reproducible build: image -> defconfig+fragment -> kernel -> verify.
# Every heavy step runs in Docker; the host only needs docker + bash.
#
#   scripts/full-build.sh            # default
#   SKIP_IMAGE=1 scripts/full-build.sh
#   TARGETS="Image.gz" IMAGE_WAIT=1800 scripts/full-build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-earth-kernel-abuild:latest}"
TARGETS="${TARGETS:-Image.gz}"
FRAGMENT="${FRAGMENT:-configs/apatch.fragment}"
IMAGE_WAIT="${IMAGE_WAIT:-1800}"

cd "$ROOT"

if [[ "${SKIP_IMAGE:-0}" != "1" ]]; then
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[full-build] waiting up to ${IMAGE_WAIT}s for $IMAGE"
    waited=0
    while ! docker image inspect "$IMAGE" >/dev/null 2>&1; do
      if (( waited >= IMAGE_WAIT )); then
        echo "[full-build] $IMAGE not ready; building it now" >&2
        ./build.sh image
        break
      fi
      sleep 10
      waited=$(( waited + 10 ))
    done
  fi
fi

echo "[full-build] defconfig"
./build.sh defconfig "$FRAGMENT"

echo "[full-build] build $TARGETS"
./build.sh build $TARGETS

echo "[full-build] patchability check"
scripts/verify-patch.sh

echo "[full-build] done"
