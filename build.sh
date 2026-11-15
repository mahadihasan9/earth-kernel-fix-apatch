#!/usr/bin/env bash
# Host-side entry point. Everything heavy runs inside the Docker image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-earth-kernel-abuild:latest}"
KERNEL_SRC="${KERNEL_SRC:-android_kernel_xiaomi_earth}"
OUT="${OUT:-out}"

case "${1:-help}" in
  image)
    docker build -t "$IMAGE" "$ROOT"
    ;;

  defconfig)
    shift || true
    docker run --rm -i \
      --user "$(id -u):$(id -g)" \
      -e HOME=/tmp \
      -e JOBS= \
      -e KERNEL_SRC="/workspace/$KERNEL_SRC" \
      -e OUT="/workspace/$OUT" \
      -v "$ROOT:/workspace" \
      -w /workspace \
      "$IMAGE" bash docker/kernel-build.sh defconfig "$@"
    ;;

  build)
    shift || true
    docker run --rm -i \
      --user "$(id -u):$(id -g)" \
      -e HOME=/tmp \
      -e JOBS= \
      -e KERNEL_SRC="/workspace/$KERNEL_SRC" \
      -e OUT="/workspace/$OUT" \
      -v "$ROOT:/workspace" \
      -w /workspace \
      "$IMAGE" bash docker/kernel-build.sh build "$@"
    ;;

  shell)
    docker run --rm -it \
      --user "$(id -u):$(id -g)" \
      -e HOME=/tmp \
      -e KERNEL_SRC="/workspace/$KERNEL_SRC" \
      -e OUT="/workspace/$OUT" \
      -v "$ROOT:/workspace" \
      -w /workspace \
      "$IMAGE" bash
    ;;

  *)
    cat <<EOF
usage: ./build.sh <command>

  image                 build the Docker image ($IMAGE)
  defconfig [fragment]  generate earth_defconfig + merge config fragments
  build [target ...]    compile inside the container (default: Image.gz)
  shell                 interactive shell in the build container
EOF
    ;;
esac
