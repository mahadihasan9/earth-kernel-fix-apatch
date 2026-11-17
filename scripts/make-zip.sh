#!/usr/bin/env bash
# Packs the built kernel into an AnyKernel3 zip (kernel only, no boot image).
#
# This is the *optional* package for non-APatch setups and lives in
# output/anykernel3/ so the variant folders (main/, apatch/, docker/) stay
# the simple "image + zip" sets.
#
#   PREFIX=02-apatch scripts/make-zip.sh  -> output/anykernel3/02-apatch-anykernel3.zip
#   PREFIX=03-docker scripts/make-zip.sh  -> output/anykernel3/03-docker-anykernel3.zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out"
AK="$ROOT/anykernel3"
PREFIX="${PREFIX:-02-apatch}"

IMG="$OUT/arch/arm64/boot/Image.gz"
[[ -f "$IMG" ]] || { echo "kernel image not found: $IMG" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M)"
ZIP="$ROOT/output/anykernel3/${PREFIX}-anykernel3-${STAMP}.zip"

mkdir -p "$ROOT/output/anykernel3"
# keep only the newest kernel-only zip for this variant
rm -f "$ROOT/output/anykernel3/${PREFIX}-anykernel3-"*.zip

rm -f "$AK"/Image "$AK"/Image.gz "$AK"/Image.gz-dtb "$AK"/dtb "$AK"/dtbo.img
cp -f "$IMG" "$AK/Image.gz"

# The stock earth boot image keeps the DTB in a separate boot-image field, so
# AnyKernel3 must only swap the compressed kernel and keep that DTB.
rm -f "$ZIP"
( cd "$AK" && zip -r9 "$ZIP" . -x '*.git*' >/dev/null )

echo "[zip] $ZIP"
ls -lh "$ZIP"
