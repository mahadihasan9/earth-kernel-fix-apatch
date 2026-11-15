#!/usr/bin/env python3
"""Repack an Android boot image, replacing only the kernel.

The Xiaomi earth boot image uses header v2 with a *separate* DTB region:

    header page | kernel | ramdisk | second | recovery_dtbo | dtb | [vbmeta] | [AVB footer]

so the kernel must be a plain ``Image.gz``; the DTB is preserved from the
template.  Ramdisk, second stage, recovery DTBO, DTB, load addresses, cmdline
and the header version are kept byte-for-byte.  The legacy ``id`` SHA-1 is
recomputed the same way mkbootimg does.

The stock image also carries an AVB footer (64-byte variant used by the
vendor avbtool) plus the vbmeta blob it points at.  We cannot re-sign it --
the signing key is not public -- and the bootloader is unlocked, so AVB is
not enforced for boot.  The footer/vbmeta are therefore copied verbatim as
long as the new kernel still fits in front of them, which keeps the output
identical to stock except for the kernel bytes.  If the kernel grows past the
vbmeta offset the AVB tail is dropped and the image is zero-padded instead.

For APatch, patch the resulting boot image afterwards with the APatch app or
with a matching kptools.
"""

import argparse
import hashlib
import struct
import sys

AVB_MAGIC = b"AVBf"
AVB_FOOTER_SIZES = (64, 192)  # vendor avbtool variant, then current libavb


def align(n, page):
    return (n + page - 1) // page * page


def find_avb(image, page):
    """Return (vbmeta_offset, tail_offset) or None.

    ``tail_offset`` is where the footer starts; everything from vbmeta_offset
    to the end of the file belongs to the AVB tail.
    """
    for footer_size in AVB_FOOTER_SIZES:
        start = len(image) - footer_size
        if start < 0 or image[start:start + 4] != AVB_MAGIC:
            continue
        (ver_major, ver_minor, orig_size, vbmeta_off, vbmeta_size) = \
            struct.unpack_from(">IIQQQ", image, start + 4)
        if vbmeta_off + vbmeta_size > start or vbmeta_off % page:
            continue
        print("[avb] footer@0x%x v%d.%d original_image_size=%d "
              "vbmeta@0x%x size=%d"
              % (start, ver_major, ver_minor, orig_size,
                 vbmeta_off, vbmeta_size))
        return vbmeta_off, start, orig_size
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True, help="known-good boot.img")
    ap.add_argument("--kernel", required=True, help="new Image.gz")
    ap.add_argument("--output", required=True)
    ap.add_argument("--partition-size", type=int, default=64 * 1024 * 1024)
    ap.add_argument("--strip-avb", action="store_true",
                    help="drop the AVB vbmeta/footer even if it would fit")
    args = ap.parse_args()

    tpl = open(args.template, "rb").read()
    if tpl[:8] != b"ANDROID!":
        sys.exit("template is not an Android boot image")

    ks, kaddr, rs, raddr, ss, saddr, tags, page = struct.unpack_from("<8I", tpl, 8)
    hdrver, = struct.unpack_from("<I", tpl, 40)
    header_size, dtb_size = struct.unpack_from("<II", tpl, 1644)
    rdtbo_size, = struct.unpack_from("<I", tpl, 1632)
    if hdrver < 2 or header_size < 1660:
        sys.exit("unsupported boot image header (need v2)")

    off = page
    kernel = tpl[off:off + ks]
    off += align(ks, page)
    ramdisk = tpl[off:off + rs]
    off += align(rs, page)
    second = tpl[off:off + ss]
    off += align(ss, page)
    rdtbo = tpl[off:off + rdtbo_size]
    off += align(rdtbo_size, page)
    dtb = tpl[off:off + dtb_size]
    off += align(dtb_size, page)

    avb = None if args.strip_avb else find_avb(tpl, page)

    new_kernel = open(args.kernel, "rb").read()
    if new_kernel[:2] != b"\x1f\x8b":
        sys.exit("kernel is not gzip compressed; earth needs Image.gz")

    body = bytearray()
    for blob in (new_kernel, ramdisk, second, rdtbo, dtb):
        body += blob
        body += b"\x00" * (align(len(blob), page) - len(blob))
    body_end = page + len(body)

    hdr = bytearray(tpl[:page])
    struct.pack_into("<I", hdr, 8, len(new_kernel))

    sha = hashlib.sha1()
    for blob in (new_kernel, ramdisk, second, rdtbo, dtb):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))
    hdr[576:608] = sha.digest() + b"\x00" * 12

    out = bytearray(hdr) + body

    if avb is not None:
        vbmeta_off, footer_off, orig_size = avb
        if body_end > vbmeta_off:
            print("[avb] new kernel overflows vbmeta@0x%x -> dropping AVB tail"
                  % vbmeta_off)
            avb = None
        else:
            out += b"\x00" * (vbmeta_off - body_end)
            out += tpl[vbmeta_off:]
            if body_end != orig_size:
                print("[avb] note: original_image_size stays %d, real body is "
                      "%d; vbmeta hash is stale by definition (we cannot "
                      "re-sign). Harmless with an unlocked bootloader."
                      % (orig_size, body_end))

    if avb is None:
        if len(out) > args.partition_size:
            sys.exit("new image does not fit the partition")
        out += b"\x00" * (args.partition_size - len(out))

    if len(out) != args.partition_size:
        sys.exit("internal error: output is %d bytes, expected %d"
                 % (len(out), args.partition_size))

    open(args.output, "wb").write(out)
    print("[boot] %s  kernel=%d bytes  ramdisk=%d  dtb=%d  avb=%s  total=%d"
          % (args.output, len(new_kernel), len(ramdisk), len(dtb),
             "kept" if avb else "stripped", len(out)))


if __name__ == "__main__":
    main()
