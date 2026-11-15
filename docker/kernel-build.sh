#!/usr/bin/env bash
# Runs inside the Docker container. Never executes on the host.
set -euo pipefail

KERNEL_SRC="${KERNEL_SRC:-/workspace/android_kernel_xiaomi_earth}"
OUT="${OUT:-/workspace/out}"
JOBS="${JOBS:-$(nproc)}"
DEFCONFIG="${DEFCONFIG:-earth_defconfig}"

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# This vendor tree is normally built with AOSP clang. GCC 11 flags several
# patterns that clang accepts, and the tree builds with -Werror. Only known
# false positives are silenced; -Werror itself stays on.
KCFLAGS="${KCFLAGS:--Wno-memset-elt-size -Wno-stringop-truncation -Wno-stringop-overflow -Wno-array-bounds -Wno-address-of-packed-member -Wno-format-overflow -Wno-maybe-uninitialized -Wno-unused-but-set-variable -Wno-misleading-indentation -Wno-format-truncation}"

MAKE=(make -C "$KERNEL_SRC" O="$OUT" ARCH=arm64
      CROSS_COMPILE="$CROSS_COMPILE" KCFLAGS="$KCFLAGS" -j"$JOBS")

log() { printf '\n\033[1;32m[kbuild]\033[0m %s\n' "$*"; }

apply_fragment() {
	local frag="$1"
	[[ -f "$frag" ]] || { log "config fragment not found: $frag"; exit 1; }
	log "merging config fragment $(basename "$frag")"
	"$KERNEL_SRC/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$frag" >/dev/null
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  defconfig)
    log "generating $DEFCONFIG ($(aarch64-linux-gnu-gcc --version | head -n1))"
    mkdir -p "$OUT"
    "${MAKE[@]}" "$DEFCONFIG"
    for frag in "$@"; do apply_fragment "$frag"; done
    "${MAKE[@]}" olddefconfig
    log "config written to $OUT/.config"
    ;;

  build)
    [[ -f "$OUT/.config" ]] || { log "no $OUT/.config, run: ./build.sh defconfig"; exit 1; }
    log "building: targets=${*:-Image.gz}"
    "${MAKE[@]}" "${@:-Image.gz}"
    ;;

  *)
    log "unknown command: $cmd"
    exit 1
    ;;
esac
