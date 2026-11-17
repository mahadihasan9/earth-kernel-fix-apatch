#!/usr/bin/env bash
# Builds the standard (APatch) deliverables from the freshly compiled kernel.
#
#   output/apatch/02-apatch-boot.img   our kernel in the stock boot layout
#                                      -> this is the file APatch patches
#   output/apatch/02-apatch-boot.zip   sideload zip that writes that image
#   output/main/01-stock-boot.zip      sideload zip that restores the stock image
#   output/anykernel3/02-apatch-anykernel3-<stamp>.zip
#                                      optional kernel-only (non-APatch)
#   output/SHA256SUMS.txt              checksums of everything above
#
# output/main/01-stock-boot.img is the stock template and must already be there
# (README "Stock template"); it is also the rollback image, which is why it
# carries the 01- prefix.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="$ROOT/out/arch/arm64/boot/Image.gz"
TEMPLATE="${TEMPLATE:-$ROOT/output/main/01-stock-boot.img}"
OUTIMG="$ROOT/output/apatch/02-apatch-boot.img"

[[ -f "$IMG" ]] || { echo "missing $IMG (run ./build.sh build Image.gz)" >&2; exit 1; }
mkdir -p "$ROOT/output/main" "$ROOT/output/apatch"
if [[ ! -f "$TEMPLATE" ]]; then
  cat >&2 <<EOF
missing stock boot image: $TEMPLATE

The APatch image is built by swapping only the kernel inside a stock boot image
of the same ROM build.  Extract boot.img from the LineageOS package
(payload-dumper-go) or dump it from the device, then either place it at
$TEMPLATE or set TEMPLATE=/path/to/boot.img.

See "Stock template" in README.md.
EOF
  exit 1
fi

python3 "$ROOT/scripts/repack-boot.py" \
  --template "$TEMPLATE" \
  --kernel "$IMG" \
  --output "$OUTIMG"

bash "$ROOT/scripts/make-bootimg-zip.sh" \
  "$OUTIMG" "$ROOT/output/apatch/02-apatch-boot.zip"

bash "$ROOT/scripts/make-bootimg-zip.sh" \
  "$TEMPLATE" "$ROOT/output/main/01-stock-boot.zip"

PREFIX=02-apatch bash "$ROOT/scripts/make-zip.sh"

bash "$ROOT/scripts/checksums.sh"
