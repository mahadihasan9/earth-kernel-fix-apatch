#!/usr/bin/env bash
# Packs the built kernel into an AnyKernel3 zip that can be flashed from a
# custom recovery or via `adb sideload`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out"
AK="$ROOT/anykernel3"

IMG="$OUT/arch/arm64/boot/Image.gz"
[[ -f "$IMG" ]] || { echo "kernel image not found: $IMG" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M)"
KREL="$(cat "$OUT/include/config/kernel.release" 2>/dev/null || echo unknown)"
NAME="earth-apatch-${KREL}-${STAMP}"
ZIP="$ROOT/output/$NAME.zip"

mkdir -p "$ROOT/output"

rm -f "$AK"/Image "$AK"/Image.gz "$AK"/Image.gz-dtb "$AK"/dtb "$AK"/dtbo.img
cp -f "$IMG" "$AK/Image.gz"

# The stock earth boot image keeps the DTB in a separate boot-image field, so
# AnyKernel3 must only swap the compressed kernel and keep that DTB.
rm -f "$ZIP"
( cd "$AK" && zip -r9 "$ZIP" . -x '*.git*' >/dev/null )

echo "[zip] $ZIP"
ls -lh "$ZIP"
