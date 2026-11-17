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
#   out-docker/                                       variant build tree
#   output/boot-docker.img                            variant boot image
#   output/earth-apatch-docker-<ver>-<stamp>.zip      AnyKernel3 (kernel only)
#   output/earth-apatch-docker-bootimg-<stamp>.zip    full-image sideload zip
#
# so out/, output/boot.img and the release files of the normal kernel are
# never modified.  Removing out-docker/ only discards the variant's build
# cache; it does not touch the main build.
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
TEMPLATE="${TEMPLATE:-$ROOT/output/boot-stock-lineage.img}"
IMG="$OUT_DIR/arch/arm64/boot/${TARGET}"
STAMP="$(date +%Y%m%d-%H%M)"

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
mkdir -p "$ROOT/output"

BOOT="$ROOT/output/boot-docker.img"
if [[ -f "$TEMPLATE" ]]; then
	log "repack $BOOT from $(basename "$TEMPLATE")"
	python3 "$ROOT/scripts/repack-boot.py" \
		--template "$TEMPLATE" \
		--kernel "$IMG" \
		--output "$BOOT"
else
	cat >&2 <<EOF

[docker-variant] stock boot image not found: $TEMPLATE
  boot-docker.img and the full-image sideload zip are skipped.
  Extract boot.img from the LineageOS package (payload-dumper-go) or dump
  boot_a from the device, then rerun with:
    TEMPLATE=/path/to/stock-boot.img scripts/build-docker-variant.sh

EOF
	BOOT=""
fi

# AnyKernel3: kernel only, distinct file name so it can never be confused
# with the normal release zip.
AK="$ROOT/anykernel3"
ZIP="$ROOT/output/earth-apatch-docker-${KREL}-${STAMP}.zip"
log "pack AnyKernel3 zip $(basename "$ZIP")"
rm -f "$AK"/Image "$AK"/Image.gz "$AK"/Image.gz-dtb "$AK"/dtb "$AK"/dtbo.img
cp -f "$IMG" "$AK/Image.gz"
rm -f "$ZIP"
( cd "$AK" && zip -r9 "$ZIP" . -x '*.git*' >/dev/null )

if [[ -n "$BOOT" ]]; then
	log "pack full-image sideload zip"
	bash "$ROOT/scripts/make-bootimg-zip.sh" \
		"$BOOT" \
		"$ROOT/output/earth-apatch-docker-bootimg-${STAMP}.zip"
fi

# ---------------------------------------------------------------------------
# 4. summary
# ---------------------------------------------------------------------------
log "done"
{
	echo
	echo "kernel release : $KREL"
	echo "build tree     : out-docker/"
	[[ -n "$BOOT" ]] && echo "boot image     : ${BOOT#$ROOT/}"
	echo "AnyKernel3 zip : ${ZIP#$ROOT/}"
	echo
	echo "APatch order: patch boot-docker.img in APatch, then flash the patched"
	echo "image (fastboot) or put it into the full-image sideload zip as boot.img."
	echo "Do not flash the AnyKernel3 zip after patching with APatch."
	echo
} >&2

FILES=("$ZIP")
[[ -n "$BOOT" ]] && FILES+=("$BOOT")
BOOTZIP="$ROOT/output/earth-apatch-docker-bootimg-${STAMP}.zip"
[[ -f "$BOOTZIP" ]] && FILES+=("$BOOTZIP")
sha256sum "${FILES[@]}" | sed "s#$ROOT/##" | tee "$ROOT/output/sha256sums-docker.txt"
