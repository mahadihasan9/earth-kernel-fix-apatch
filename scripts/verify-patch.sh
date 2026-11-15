#!/usr/bin/env bash
# Verify that the built kernel image can be patched by APatch/KernelPatch.
#
# KernelPatch's kptools parses the kernel's kallsyms tables at patch time.  If
# CONFIG_KALLSYMS_ALL is missing you get:
#
#   analyze_kallsym_info error
#   can't locate vectors
#   Patch kernel error: 1
#
# Usage:
#   scripts/verify-patch.sh [Image] [kptools]
#
# Defaults: out/arch/arm64/boot/Image and ./tools/kptools-linux (or
# $KPTOOLS, or /tmp/opencode/kp/kptools-linux).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-$ROOT/out/arch/arm64/boot/Image}"
KPTOOLS="${2:-${KPTOOLS:-}}"

if [[ -z "$KPTOOLS" ]]; then
  for cand in "$ROOT/tools/kptools-linux" /tmp/opencode/kp/kptools-linux; do
    [[ -x "$cand" ]] && { KPTOOLS="$cand"; break; }
  done
fi

[[ -f "$IMG" ]] || { echo "missing kernel image: $IMG" >&2; exit 1; }
[[ -x "$KPTOOLS" ]] || { echo "kptools not found; pass it as the 2nd argument" >&2; exit 1; }

KPIMG="${KPIMG:-$(dirname "$KPTOOLS")/kpimg-linux}"
[[ -f "$KPIMG" ]] || { echo "kpimg not found next to kptools: $KPIMG" >&2; exit 1; }

CONFIG="$ROOT/out/.config"
if [[ -f "$CONFIG" ]]; then
  echo "== config"
  grep -E '^CONFIG_(DEBUG_KERNEL|KALLSYMS|KALLSYMS_ALL|KALLSYMS_BASE_RELATIVE|LTO_CLANG|CFI_CLANG|SHADOW_CALL_STACK|KSU)=' "$CONFIG" || true
  for sym in DEBUG_KERNEL KALLSYMS KALLSYMS_ALL; do
    if ! grep -qx "CONFIG_$sym=y" "$CONFIG"; then
      echo "FAIL: CONFIG_$sym is not enabled" >&2
      exit 1
    fi
  done
  # A PIE link (CONFIG_RELOCATABLE, selected by RANDOMIZE_BASE on arm64)
  # zero-fills the kallsyms address table in the Image and kptools cannot read
  # it.  See NOTES.txt section 6.
  if grep -qx 'CONFIG_RANDOMIZE_BASE=y' "$CONFIG"; then
    echo "FAIL: CONFIG_RANDOMIZE_BASE=y makes the kernel PIE; kptools cannot" >&2
    echo "      parse kallsyms_addresses from the resulting Image" >&2
    exit 1
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== kptools patch test"
set +e
"$KPTOOLS" -p -i "$IMG" -k "$KPIMG" -o "$TMP/Image.patched" 2>&1 | tee "$TMP/patch.log"
rc="${PIPESTATUS[0]}"
set -e

echo "== result"
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: kptools exited $rc" >&2
  exit "$rc"
fi
if grep -qE 'analyze_kallsym_info error|can.t locate vectors' "$TMP/patch.log"; then
  echo "FAIL: kallsyms tables are not parseable" >&2
  exit 1
fi
if [[ ! -s "$TMP/Image.patched" ]]; then
  echo "FAIL: kptools produced no output image" >&2
  exit 1
fi

echo "OK: kernel is APatch/KernelPatch patchable"
echo "     $(sha256sum "$TMP/Image.patched" | cut -d' ' -f1)  (patched test image, not shipped)"
