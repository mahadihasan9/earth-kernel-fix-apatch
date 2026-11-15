#!/usr/bin/env bash
# Build the deliverables from the freshly compiled kernel:
#   output/boot.img  - stock layout + new kernel, ready for APatch to patch
#   output/*.zip     - AnyKernel3 package for `adb sideload` (kernel only)
#   output/*-bootimg.zip - sideload package that flashes a full boot image
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="$ROOT/out/arch/arm64/boot/Image.gz"
TEMPLATE="${TEMPLATE:-$ROOT/output/boot-stock-lineage.img}"

[[ -f "$IMG" ]] || { echo "missing $IMG (run ./build.sh build Image.gz)" >&2; exit 1; }
if [[ ! -f "$TEMPLATE" ]]; then
  cat >&2 <<EOF
missing stock boot image: $TEMPLATE

The output boot.img is built by swapping only the kernel inside a stock boot
image of the same ROM build.  Extract boot.img from the LineageOS package
(payload-dumper-go) or dump it from the device, then either place it at
$TEMPLATE or set TEMPLATE=/path/to/boot.img.

See "Stock template" in README.md.
EOF
  exit 1
fi

python3 "$ROOT/scripts/repack-boot.py" \
  --template "$TEMPLATE" \
  --kernel "$IMG" \
  --output "$ROOT/output/boot.img"

bash "$ROOT/scripts/make-zip.sh"

echo
sha256sum "$ROOT/output/boot.img" "$ROOT"/output/earth-apatch-*.zip | sed "s#$ROOT/##"
