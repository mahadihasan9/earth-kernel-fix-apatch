#!/usr/bin/env bash
# Create a recovery-sideload zip that flashes a *complete* boot image.
#
# Usage:
#   scripts/make-bootimg-zip.sh [boot.img] [output-name.zip]
#
# With no boot.img argument, output/apatch/02-apatch-boot.img is used and the
# zip is named output/apatch/02-apatch-boot.zip.  The zip always contains the image as
# "boot.img".  This is the package to use after APatch has patched an image:
# replace boot.img inside the zip with the APatch-patched file (same name), or
# flash the unpatched image as-is to get a clean boot with our kernel.
#
# AnyKernel3 is not involved here: the whole boot partition (kernel + the
# stock LineageOS ramdisk) is written verbatim.
#
# Device specifics (verified against the stock boot ramdisk of LineageOS 24):
#   - there is no /sbin in the ramdisk, so the update-binary shebang must be
#     /system/bin/sh (AnyKernel3's /sbin/sh only works under TWRP)
#   - toybox provides sh, unzip, dd, getprop, tr, grep, cut, wc, mkdir, rm
#   - recovery-as-boot: this same boot image boots recovery, so the ramdisk is
#     present while sideloading
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT="${1:-$ROOT/output/apatch/02-apatch-boot.img}"
STAMP="$(date +%Y%m%d-%H%M)"
ZIP="${2:-$ROOT/output/apatch/02-apatch-boot.zip}"

# The zip command runs inside $WORK, so the destination must be absolute.
case "$ZIP" in
    /*) ;;
    *)  ZIP="$PWD/$ZIP" ;;
esac
mkdir -p "$(dirname "$ZIP")"

[[ -f "$BOOT" ]] || { echo "no such boot image: $BOOT" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/META-INF/com/google/android"
cp -f "$BOOT" "$WORK/boot.img"

cat > "$WORK/META-INF/com/google/android/update-binary" <<'EOS'
#!/system/bin/sh
# Flash the bundled boot.img onto the active A/B boot slot.
#
# Runs inside LineageOS recovery.  This device's recovery ramdisk has no /sbin,
# so the interpreter must be /system/bin/sh; toybox provides dd/tr/grep/cut/wc/
# mkdir/rm/sync and ziptool provides unzip.  Absolute paths are used because
# the recovery PATH is not to be trusted.
#
# Recovery passes: $1 = api version, $2 = status fd, $3 = package path.
OUTFD="$2"
ZIPFILE="$3"

ui_print() {
    if [ -n "$OUTFD" ] && [ -w "/proc/self/fd/$OUTFD" ]; then
        echo "ui_print $1" >> "/proc/self/fd/$OUTFD"
        echo "ui_print" >> "/proc/self/fd/$OUTFD"
    else
        echo "$1"
    fi
}

WORK="/tmp/bootimg.$$"
rm -rf "$WORK"
mkdir -p "$WORK" || { ui_print "cannot create $WORK"; exit 1; }
cd "$WORK" || exit 1

# --- get the boot image out of the package --------------------------------
IMG="$WORK/boot.img"
HAVE_IMG=0
if [ -n "$ZIPFILE" ] && [ -f "$ZIPFILE" ]; then
    /system/bin/unzip -o -d "$WORK" "$ZIPFILE" boot.img >/dev/null 2>&1
    [ -s "$IMG" ] && HAVE_IMG=1
fi
if [ "$HAVE_IMG" = 0 ] && [ -s /tmp/boot.img ]; then
    cp -f /tmp/boot.img "$IMG" 2>/dev/null
    [ -s "$IMG" ] && HAVE_IMG=1
fi
if [ "$HAVE_IMG" = 0 ]; then
    ui_print "Cannot extract boot.img from the package"
    exit 1
fi

# --- sanity check the image ----------------------------------------------
MAGIC="$(/system/bin/dd if="$IMG" bs=8 count=1 2>/dev/null)"
if [ "$MAGIC" != "ANDROID!" ]; then
    ui_print "boot.img does not start with ANDROID!"
    exit 1
fi
SIZE="$(/system/bin/wc -c < "$IMG" | /system/bin/tr -d ' ')"
ui_print "Package boot image: $SIZE bytes"

# --- active slot ---------------------------------------------------------
SLOT=""
if [ -x /system/bin/getprop ]; then
    SLOT="$(/system/bin/getprop ro.boot.slot_suffix 2>/dev/null)"
    [ -n "$SLOT" ] || SLOT="$(/system/bin/getprop ro.boot.slot 2>/dev/null)"
fi
if [ -z "$SLOT" ] && [ -r /proc/cmdline ]; then
    SLOT="$(/system/bin/tr ' ' '\n' < /proc/cmdline | /system/bin/grep -m1 '^androidboot.slot_suffix=' | /system/bin/cut -d= -f2)"
    [ -n "$SLOT" ] || SLOT="$(/system/bin/tr ' ' '\n' < /proc/cmdline | /system/bin/grep -m1 '^androidboot.slot=' | /system/bin/cut -d= -f2)"
fi
case "$SLOT" in
    a|_a) SLOT="_a" ;;
    b|_b) SLOT="_b" ;;
    *)    SLOT="" ;;
esac
[ "$SLOT" = "normal" ] && SLOT=""

# --- locate the boot partition ------------------------------------------
BOOTDEV=""
for d in /dev/block/by-name /dev/block/bootdevice/by-name \
         /dev/block/platform/bootdevice/by-name /dev/block/platform/*/by-name; do
    if [ -e "$d/boot${SLOT}" ]; then BOOTDEV="$d/boot${SLOT}"; break; fi
    if [ -z "$SLOT" ] && [ -e "$d/boot" ]; then BOOTDEV="$d/boot"; break; fi
done
if [ -z "$BOOTDEV" ]; then
    for d in /dev/block/by-name /dev/block/bootdevice/by-name; do
        if [ -e "$d/boot" ]; then BOOTDEV="$d/boot"; break; fi
    done
fi
if [ -z "$BOOTDEV" ]; then
    ui_print "Cannot find the boot partition"
    exit 1
fi

ui_print "Target: ${BOOTDEV} (slot '${SLOT:-default}')"
ui_print "Writing boot image..."
/system/bin/dd if="$IMG" of="$BOOTDEV" bs=4096 2>/dev/null
if [ $? -ne 0 ]; then
    ui_print "Write failed"
    exit 1
fi
/system/bin/sync
ui_print "Done."
rm -rf "$WORK"
exit 0
EOS
chmod 755 "$WORK/META-INF/com/google/android/update-binary"

# AOSP recovery expects this file next to update-binary; the shell script above
# does the actual work, so the edify script is only a placeholder.
echo '# placeholder: work is done by update-binary' \
    > "$WORK/META-INF/com/google/android/updater-script"

mkdir -p "$ROOT/output"
rm -f "$ZIP"
( cd "$WORK" && zip -r9 "$ZIP" . >/dev/null )

echo "[zip] $ZIP"
sha256sum "$ZIP"
