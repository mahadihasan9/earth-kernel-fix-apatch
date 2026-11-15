# earth-kernel-abuild

APatch-ready Linux 4.19 kernel build toolkit for the Xiaomi **earth**
(Redmi 12C / POCO C55, MediaTek MT6768), running LineageOS 24.0.

It builds the vendor kernel in a throw-away Docker container, verifies that
**APatch / KernelPatch** can patch the result, and repacks a stock-format
`boot.img` that keeps the original ramdisk, DTB and AVB tail. Flashable
packages are produced for `adb sideload` as well as for fastboot.

Prebuilt `boot.img` and zips are attached to the
[Releases](../../releases) page, so you do not need to build anything to use
this kernel.

---

## Device / ROM

| | |
|---|---|
| Device | Xiaomi `earth` — Redmi 12C, POCO C55 (alias `aether`) |
| SoC | MediaTek MT6768 (Helio G85), arm64 |
| Kernel | Linux 4.19.325-cip136-st20 (`android_kernel_xiaomi_earth`, branch `lineage-24.0`) |
| ROM | LineageOS 24.0 |
| Boot layout | Android boot header v2, 2048-byte pages, separate DTB field, 64 MiB `boot` partition |
| Slots | A/B, **recovery-as-boot** (no separate recovery partition) |

---

## Download and install (no build required)

Grab these from [Releases](../../releases):

| File | What it is |
|---|---|
| `boot.img` | Kernel packed in the stock boot layout. **This is the file you patch with APatch.** |
| `earth-apatch-bootimg-<date>.zip` | `adb sideload` package that writes a complete boot image to the active slot |
| `earth-apatch-<kernelver>-<date>.zip` | AnyKernel3 package, kernel only (for a non-APatch setup) |
| `boot-stock-lineage.img` | Untouched stock boot image — rollback |

### 1. Patch the boot image with APatch

1. Copy `boot.img` to the phone.
2. Open **APatch** → *Patch Image* → select `boot.img`.
3. APatch writes a patched image (usually to `Download/`). Keep it.

Verified to work with KernelPatch **0.13.9** tools; any recent APatch that
reports a successful patch is fine.

### 2. Flash it

Fastboot (recommended, both slots):

```sh
fastboot flash boot_a apatch-patched.img
fastboot flash boot_b apatch-patched.img
fastboot reboot
```

or recovery sideload — put the patched image into the package as `boot.img`
(same file name), then:

```sh
adb reboot recovery
adb sideload earth-apatch-bootimg-<date>.zip
```

The `update-binary` detects the active slot from `ro.boot.slot_suffix`
(with a `/proc/cmdline` fallback) and writes to `boot_a` / `boot_b`.

### 3. Rollback

```sh
fastboot flash boot_a boot-stock-lineage.img
fastboot flash boot_b boot-stock-lineage.img
fastboot reboot
```

> **Never flash a file called `recovery.img`.** This device boots recovery from
> the `boot` partition; a separate recovery image does not exist.

> **Do not flash the AnyKernel3 zip after patching with APatch.** It replaces
> only the kernel and would erase the APatch patch. Use it only for
> kernel-only updates on a non-APatch setup.

### Publishing a release (maintainer)

After `scripts/finalize.sh` and `scripts/make-bootimg-zip.sh`, attach these to
a GitHub release:

```
output/boot.img
output/earth-apatch-bootimg-<date>.zip
output/earth-apatch-<kernelver>-<date>.zip
output/boot-stock-lineage.img
output/sha256sums.txt
```

with

```sh
sha256sum output/*.img output/*.zip > output/sha256sums.txt
```

Suggested tag: the kernel version, e.g. `v4.19.325-cip136-st20`.

---

## Why this kernel is APatch-patchable

APatch patches the kernel image itself and needs the kernel's symbol table.
Two things are easy to get wrong on this vendor tree:

1. **`CONFIG_KALLSYMS_ALL`** must be enabled. With only function symbols,
   kptools cannot find its anchor symbols and aborts with

   ```
   analyze_kallsym_info error
   can't locate vectors
   ```

   Note that `KALLSYMS_ALL` depends on `CONFIG_DEBUG_KERNEL`, which this
   defconfig does not enable — without it `olddefconfig` silently drops
   `KALLSYMS_ALL` again. Both are set in `configs/apatch.fragment`.

2. **No PIE link.** On arm64 `CONFIG_RANDOMIZE_BASE` selects
   `CONFIG_RELOCATABLE`, which makes the linker emit
   `-shared -Bsymbolic -z notext --no-apply-dynamic-relocs`. GNU ld then leaves
   every relocated site at zero in the image and keeps the real values in
   `.rela.dyn`. `kallsyms_addresses` is one of those arrays, so the shipped
   `Image` contains zeros where kptools expects addresses:

   ```
   find approximate kallsyms_addresses error
   ```

   The stock kernel is not PIE, so the fragment disables
   `CONFIG_RANDOMIZE_BASE` and the build links like the stock kernel.
   KASLR is not available as a result; on this device the bootloader always
   loads the kernel at its link address anyway.

Also disabled: `LTO_CLANG`, `CFI_CLANG`, `SHADOW_CALL_STACK`, `DEBUG_INFO`
(clang-only or useless without debug info). There is **no KernelSU/SukiSU**
code in the tree — APatch brings its own hook engine.

`scripts/verify-patch.sh` re-checks all of this and runs the same patch
operation APatch performs, so a broken config fails the build pipeline
instead of the phone.

---

## Build from source

### Requirements

- Linux host with Docker (Engine 20+)
- ~12 GB free disk space (kernel source in this repo 1.4 GB, plus ~600 MB
  build output and the Docker image)
- 4 GB RAM or more (`make -j$(nproc)`)
- `git`, `bash`

Nothing is installed on the host: every tool lives in the build image.

### Steps

The vendor kernel source is **inside this repository** at
`android_kernel_xiaomi_earth/`, already carrying the GCC compatibility fixes.
No separate clone, checkout or patch step is needed.

```sh
# 1. this repository (~1.4 GB, the kernel source is included)
git clone <this-repo-url> earth-kernel-abuild
cd earth-kernel-abuild

# 2. stock boot image used as the repack template
cp /path/to/stock/boot.img output/boot-stock-lineage.img

# 3. build the Docker image once
./build.sh image

# 4. configure and build
./build.sh defconfig configs/apatch.fragment
./build.sh build Image.gz

# 5. verify APatch compatibility (requires kptools, see tools/README.md)
scripts/verify-patch.sh

# 6. package
scripts/finalize.sh                          # output/boot.img + AnyKernel3 zip
scripts/make-bootimg-zip.sh output/boot.img  # full-image sideload zip
```

`scripts/full-build.sh` runs steps 3-5 in one go.

A shallow clone (`git clone --depth 1`) is fine and much faster for the
initial download.

Build time is roughly 20-40 minutes on a modern desktop CPU; the first run
also builds the Docker image.

### Stock template

`output/boot.img` is produced by swapping only the kernel inside a known-good
boot image, so a stock `boot.img` for the exact ROM version is required as
`output/boot-stock-lineage.img`. It is not shipped in git (`output/` is
ignored), because the ramdisk belongs to the ROM.

Get it from the LineageOS install package with
[payload-dumper-go](https://github.com/ssut/payload-dumper-go):

```sh
payload-dumper-go -p boot -o extracted lineage-24.0-*-earth.zip
cp extracted/boot.img output/boot-stock-lineage.img
```

or dump it from the device (root shell, before flashing anything):

```sh
adb shell su -c 'dd if=/dev/block/by-name/boot_a of=/sdcard/stock-boot.img'
adb pull /sdcard/stock-boot.img output/boot-stock-lineage.img
```

Reusing a boot image from a different LineageOS build is not supported: the
ramdisk must match the ROM.

### Host commands

```sh
./build.sh image                 # build the toolchain image (once)
./build.sh defconfig [fragment]  # earth_defconfig + config fragment
./build.sh build [target ...]    # default target: Image.gz
./build.sh shell                 # interactive shell inside the container
```

Useful overrides: `IMAGE=`, `KERNEL_SRC=`, `OUT=`, `JOBS=`, `KCFLAGS=`.

### Source changes

The tree in `android_kernel_xiaomi_earth/` is the LineageOS
`android_kernel_xiaomi_earth` branch `lineage-24.0` at commit `5aea3a23c`,
with six minimal changes on top because the vendor tree is normally built with
AOSP clang while this toolkit uses GCC 11. They are already applied here; the
same changes are exported as `patches/0001-gcc-build-fixes.patch` so the build
can be reproduced from the pristine upstream tree:

```sh
git clone https://github.com/LineageOS/android_kernel_xiaomi_earth.git
git -C android_kernel_xiaomi_earth checkout 5aea3a23c
git -C android_kernel_xiaomi_earth apply ../patches/0001-gcc-build-fixes.patch
```

| File | Change |
|---|---|
| `include/linux/keyslot-manager.h`, `block/keyslot-manager.c` | drop bogus `inline` from `ksm_flock()` (always_inline with no body visible) |
| `include/linux/blk-crypto.h`, `block/blk-crypto.c` | same for `blk_crypto_flock()` |
| `.../mali-r32p1/.../midgard/Kbuild` | add `.NOTPARALLEL:` — a `modversions` `.ver` race in that subtree |
| `.../gen4m/chips/common/fw_dl.c` | `strncpy(dst, src, sizeof(src))` → `memcpy` (GCC false positive on `-Werror=sizeof-pointer-memaccess`) |

Because the kernel version string embeds the git hash, a rebuild from the
pristine tree produces a different `-g<hash>` suffix. That is cosmetic.

---

## Repository layout

```
android_kernel_xiaomi_earth/ vendor kernel source (GPL-2.0, no nested .git)
build.sh                     host entry point (docker wrapper)
Dockerfile                   Ubuntu 22.04 + aarch64 GCC toolchain
docker/kernel-build.sh       in-container make wrapper + KCFLAGS
configs/apatch.fragment      APatch-required kernel config
patches/0001-gcc-build-fixes.patch  same fixes, for upstream users
scripts/repack-boot.py       boot image v2 repacker (kernel swap only)
scripts/make-zip.sh          AnyKernel3 kernel-only zip
scripts/make-bootimg-zip.sh  full boot image sideload zip
scripts/finalize.sh          repack + zip + sha256
scripts/verify-patch.sh      KernelPatch patchability gate
scripts/full-build.sh        image + defconfig + build + verify
anykernel3/                  AnyKernel3 (osm0sis) with an earth config
tools/                       place kptools-linux / kpimg-linux here
output/                      build artifacts (git-ignored)
out/                         kernel build tree (git-ignored)
```

The kernel tree is committed as plain files (it has no `.git` of its own), so
this repository has exactly one remote — no submodule and no nested repository
to push separately.

Two small things keep the tree intact when it is committed from a GUI:

- the toplevel `.gitattributes` sets `* -text` so git does not rewrite CRLF
  line endings (54 vendor files use CRLF) under `core.autocrlf`;
- three `.gitignore` files inside the kernel tree got one-line negations
  (`!.gitattributes`, `!vmlinux.scr`, `!tools/...`) for files that upstream
  tracks but this tree's ignore rules would otherwise drop.

## Boot image handling

`scripts/repack-boot.py` replaces **only** the kernel in the stock image:

- header page copied verbatim (`header v2`, page size, load addresses, cmdline)
- new `kernel_size` written, legacy SHA-1 `id` recomputed like `mkbootimg`
- ramdisk, second stage, recovery DTBO and the separate DTB copied unchanged
- AVB `vbmeta` + footer preserved verbatim when the new kernel still fits in
  front of them (they are already invalid by definition because the signing
  key is not public, and the bootloader is unlocked)
- output is exactly 64 MiB

Repacking the stock image with the stock kernel reproduces the stock file
byte-for-byte, which is used as a self-test for the script.

## Components

| Component | Used for |
|---|---|
| Docker / Ubuntu 22.04 | isolated build environment |
| `gcc-aarch64-linux-gnu` 11.4.0, `binutils` 2.38 | kernel cross-compiler |
| Linux 4.19.325-cip136 vendor tree (LineageOS) | kernel source |
| Python 3 (stdlib only) | boot image repacker |
| [KernelPatch](https://github.com/bmax121/KernelPatch) 0.13.9 | `kptools` / `kpimg` — patchability verification and the hook engine APatch uses |
| [AnyKernel3](https://github.com/osm0sis/AnyKernel3) | kernel-only zip backend |
| AOSP boot image format (header v2) | boot image layout |
| toybox / `ziptool` (`unzip`) from the stock recovery ramdisk | what the sideload `update-binary` relies on |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| APatch: `Patch kernel error`, `analyze_kallsym_info error` | `CONFIG_KALLSYMS_ALL` (and `DEBUG_KERNEL`) missing — rebuild with `configs/apatch.fragment` |
| APatch: `find approximate kallsyms_addresses error` | kernel is PIE — `CONFIG_RANDOMIZE_BASE` must be off (see above) |
| `kptools` not found | download it into `tools/`, see `tools/README.md` |
| Sideload fails to run `update-binary` | the script uses `#!/system/bin/sh` on purpose; this recovery ramdisk has no `/sbin` |
| Device does not boot after flashing | flash `boot-stock-lineage.img` to both slots |

## Credits and license

- Kernel source: [LineageOS/android_kernel_xiaomi_earth](https://github.com/LineageOS/android_kernel_xiaomi_earth) (GPL-2.0)
- APatch / KernelPatch: [bmax121/KernelPatch](https://github.com/bmax121/KernelPatch) (GPL-2.0)
- AnyKernel3: [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) (BSD-3-Clause style, see `anykernel3/LICENSE`)
- Build scripts and boot-image tooling in this repository: **GPL-2.0**, see [`LICENSE`](LICENSE)

This project is unofficial and not affiliated with Xiaomi, LineageOS, APatch or
AnyKernel3. Flashing custom kernels can brick a device; you do it at your own
risk, and you need an unlocked bootloader.
