#!/usr/bin/env bash
# Build the *optional* Docker-enabled kernel variant.
#
# Same sources, same toolchain, same APatch requirements as the normal build.
# The only difference is the extra config fragment configs/docker.fragment,
# which enables the namespaces, cgroup controllers, overlayfs, veth/bridge and
# iptables NAT that a native dockerd needs on the device (Termux + root, no
# chroot).
#
# Everything is kept apart from the normal build:
#
#   out-docker/                                  variant build tree
#   output/docker/03-docker-boot.img             variant boot image
#   output/docker/03-docker-boot.zip             sideload zip (full image)
#   output/anykernel3/03-docker-anykernel3-<stamp>.zip   kernel-only (optional)
#   output/SHA256SUMS.txt                        regenerated for all files
#
# so out/, output/apatch/02-apatch-boot.img and the other normal files are never
# modified.  Removing out-docker/ only discards the variant's build cache; it
# does not touch the main build.
#
# Usage:
#   scripts/build-docker-variant.sh                    configure + build + package
#   SKIP_BUILD=1 scripts/build-docker-variant.sh       repack/zip an existing build
#   TEMPLATE=/path/to/stock.img scripts/build-docker-variant.sh
#   TARGET=Image.gz scripts/build-docker-variant.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/out-docker"
TARGET="${TARGET:-Image.gz}"
TEMPLATE="${TEMPLATE:-$ROOT/output/main/01-stock-boot.img}"
IMG="$OUT_DIR/arch/arm64/boot/${TARGET}"

log() { printf '\n\033[1;32m[docker-variant]\033[0m %s\n' "$*"; }
die() { echo "[docker-variant] $*" >&2; exit 1; }

command -v zip >/dev/null || die "zip is required (install it with your package manager)"
[[ -d "$ROOT/android_kernel_xiaomi_earth" ]] || die "kernel source tree is missing"

# ---------------------------------------------------------------------------
# 1. build (inside the same Docker image as the normal kernel)
# ---------------------------------------------------------------------------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
	log "configure: earth_defconfig + apatch.fragment + docker.fragment"
	OUT="$(basename "$OUT_DIR")" "$ROOT/build.sh" defconfig \
		configs/apatch.fragment configs/docker.fragment

	log "build: $TARGET (tree: $(basename "$OUT_DIR"))"
	OUT="$(basename "$OUT_DIR")" "$ROOT/build.sh" build "$TARGET"
else
	log "SKIP_BUILD=1: reusing $IMG"
fi

[[ -f "$IMG" ]] || die "missing $IMG (run without SKIP_BUILD=1)"
[[ -f "$OUT_DIR/.config" ]] || die "missing $OUT_DIR/.config"

# ---------------------------------------------------------------------------
# 2. the Docker options must really be on, and APatch must still work
# ---------------------------------------------------------------------------
log "checking the merged config"
missing=0
while read -r sym; do
	if ! grep -qx "CONFIG_${sym}=y" "$OUT_DIR/.config"; then
		echo "  MISSING: CONFIG_${sym}=y" >&2
		missing=$((missing + 1))
	fi
done < <(grep -oP '^CONFIG_\K[A-Z0-9_]+(?==y)' "$ROOT/configs/docker.fragment")

for sym in KALLSYMS KALLSYMS_ALL DEBUG_KERNEL; do
	grep -qx "CONFIG_${sym}=y" "$OUT_DIR/.config" \
		|| { echo "  MISSING: CONFIG_${sym}=y" >&2; missing=$((missing + 1)); }
done
if grep -qx 'CONFIG_RANDOMIZE_BASE=y' "$OUT_DIR/.config"; then
	echo "  CONFIG_RANDOMIZE_BASE=y: the image would be PIE and kptools could not patch it" >&2
	missing=$((missing + 1))
fi
(( missing == 0 )) || die "config check failed ($missing problem(s)); see configs/docker.fragment"
log "config OK: Docker options on, APatch patchability intact"

# ---------------------------------------------------------------------------
# 3. boot image + zips
# ---------------------------------------------------------------------------
KREL="$(cat "$OUT_DIR/include/config/kernel.release" 2>/dev/null || echo unknown)"
mkdir -p "$ROOT/output/docker"

BOOT="$ROOT/output/docker/03-docker-boot.img"
if [[ -f "$TEMPLATE" ]]; then
	log "repack $BOOT from $(basename "$TEMPLATE")"
	python3 "$ROOT/scripts/repack-boot.py" \
		--template "$TEMPLATE" \
		--kernel "$IMG" \
		--output "$BOOT"
else
	cat >&2 <<EOF

[docker-variant] stock boot image not found: $TEMPLATE
  output/docker/03-docker-boot.img and .zip are skipped.
  Extract boot.img from the LineageOS package (payload-dumper-go) or dump
  boot_a from the device, then rerun with:
    TEMPLATE=/path/to/stock-boot.img scripts/build-docker-variant.sh

EOF
	BOOT=""
fi

# AnyKernel3 (kernel only) goes to output/anykernel3/ so it never mixes with
# the simple image + zip set in output/.
log "pack AnyKernel3 zip"
PREFIX=03-docker bash "$ROOT/scripts/make-zip.sh"

if [[ -n "$BOOT" ]]; then
	log "pack full-image sideload zip"
	bash "$ROOT/scripts/make-bootimg-zip.sh" \
		"$BOOT" \
		"$ROOT/output/docker/03-docker-boot.zip"
fi

# ---------------------------------------------------------------------------
# 4. summary
# ---------------------------------------------------------------------------
log "done"
{
	echo
	echo "kernel release : $KREL"
	echo "build tree     : out-docker/"
	[[ -n "$BOOT" ]] && echo "boot image     : ${BOOT#$ROOT/}  (patch this with APatch)"
	[[ -n "$BOOT" ]] && echo "sideload zip   : output/docker/03-docker-boot.zip"
	echo "kernel-only zip: output/anykernel3/ (optional, non-APatch)"
	echo
	echo "APatch order: patch output/docker/03-docker-boot.img in APatch, then flash the patched"
	echo "image (fastboot) or put it into output/docker/03-docker-boot.zip as boot.img."
	echo "Do not flash the AnyKernel3 zip after patching with APatch."
	echo
} >&2

bash "$ROOT/scripts/checksums.sh"
