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

`output/` has **three folders, two files in each** — one image and one zip with
the same base name, so nothing is mixed:

| Folder | Image | Zip |
|---|---|---|
| `main/` | `01-stock-boot.img` — untouched LineageOS image (rollback + repack template) | `01-stock-boot.zip` — sideload zip that restores it |
| `apatch/` | `02-apatch-boot.img` — our kernel, stock layout (**this is what APatch patches**) | `02-apatch-boot.zip` — sideload zip that writes it |
| `docker/` | `03-docker-boot.img` — Docker-enabled kernel (also APatch-patchable) | `03-docker-boot.zip` — sideload zip that writes it |

```
output/
├── main/     01-stock-boot.img   01-stock-boot.zip
├── apatch/   02-apatch-boot.img  02-apatch-boot.zip
├── docker/   03-docker-boot.img  03-docker-boot.zip
├── anykernel3/   optional kernel-only zips
└── SHA256SUMS.txt
```

`SHA256SUMS.txt` has the checksums. Every line starts with the full path, so it
is always clear which hash belongs to which file:

```
8d50dd35...  main/01-stock-boot.img
e0cff4b5...  apatch/02-apatch-boot.img
4d3b6f0e...  docker/03-docker-boot.img
```

Verify with:

```sh
cd output && sha256sum -c SHA256SUMS.txt
```

A file ending in `-PATCHED.img` is **your own APatch output**, not something the
build produces: `apatch/02-apatch-boot-PATCHED.img` /
`docker/03-docker-boot-PATCHED.img` are created when you patch the matching
image in the APatch app.

> The zip packages contain the **unpatched** image as `boot.img`. For a rooted
> phone, patch the `.img` in APatch first, then put the patched file back into
> the zip (same name `boot.img`) or flash it with fastboot.

`output/anykernel3/` holds an optional **kernel-only** AnyKernel3 package
(`02-apatch-...`, `03-docker-...`). It is only for a non-APatch setup: it
replaces just the kernel, so flashing it after APatch would erase the patch.

### 1. Patch the boot image with APatch

1. Copy the image to the phone: `apatch/02-apatch-boot.img` (normal kernel)
   or `docker/03-docker-boot.img` (Docker kernel).
2. Open **APatch** → *Patch Image* → select the image.
3. APatch writes a patched image (usually to `Download/`). Keep it.

Verified to work with KernelPatch **0.13.9** tools; any recent APatch that
reports a successful patch is fine.

### 2. Flash it

Fastboot (recommended, both slots):

```sh
# run from the repo root; use docker/03-docker-boot-PATCHED.img for Docker
fastboot flash boot_a output/apatch/02-apatch-boot-PATCHED.img
fastboot flash boot_b output/apatch/02-apatch-boot-PATCHED.img
fastboot reboot
```

or recovery sideload — put the patched image into the matching package as
`boot.img` (same file name), then:

```sh
adb reboot recovery
adb sideload output/apatch/02-apatch-boot.zip   # or output/docker/03-docker-boot.zip
```

The `update-binary` detects the active slot from `ro.boot.slot_suffix`
(with a `/proc/cmdline` fallback) and writes to `boot_a` / `boot_b`.

### 3. Rollback

Fastboot:

```sh
fastboot flash boot_a output/main/01-stock-boot.img
fastboot flash boot_b output/main/01-stock-boot.img
fastboot reboot
```

or from recovery:

```sh
adb reboot recovery
adb sideload output/main/01-stock-boot.zip
```

> **Never flash a file called `recovery.img`.** This device boots recovery from
> the `boot` partition; a separate recovery image does not exist.

> **Do not flash the AnyKernel3 zip after patching with APatch.** It replaces
> only the kernel and would erase the APatch patch. Use it only for
> kernel-only updates on a non-APatch setup.

### Publishing a release (maintainer)

After `scripts/finalize.sh` and `scripts/build-docker-variant.sh`, attach every
numbered file plus the checksum file to a GitHub release:

```
output/main/01-stock-boot.img
output/main/01-stock-boot.zip
output/apatch/02-apatch-boot.img
output/apatch/02-apatch-boot.zip
output/docker/03-docker-boot.img
output/docker/03-docker-boot.zip
output/SHA256SUMS.txt
```

`scripts/checksums.sh` regenerates `SHA256SUMS.txt` for whatever is present.
The optional kernel-only packages live in `output/anykernel3/` and can be
attached too. Suggested tag: the kernel version, e.g. `v4.19.325-cip136-st20`.

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

# 2. stock boot image (also the 01-stock rollback file)
cp /path/to/stock/boot.img output/main/01-stock-boot.img

# 3. build the Docker image once
./build.sh image

# 4. configure and build
./build.sh defconfig configs/apatch.fragment
./build.sh build Image.gz

# 5. verify APatch compatibility (requires kptools, see tools/README.md)
scripts/verify-patch.sh

# 6. package: 01-stock + 02-apatch img/zip, AnyKernel3, SHA256SUMS.txt
scripts/finalize.sh
```

`scripts/full-build.sh` runs steps 3-5 in one go.

A shallow clone (`git clone --depth 1`) is fine and much faster for the
initial download.

Build time is roughly 20-40 minutes on a modern desktop CPU; the first run
also builds the Docker image.

### Stock template

`apatch/02-apatch-boot.img` is produced by swapping only the kernel inside a known-good
boot image, so a stock `boot.img` for the exact ROM version is required as
`output/main/01-stock-boot.img`. It is not shipped in git (`output/` is ignored),
because the ramdisk belongs to the ROM. The same file is the `01-stock` rollback
image, which is why it carries the first number.

Get it from the LineageOS install package with
[payload-dumper-go](https://github.com/ssut/payload-dumper-go):

```sh
payload-dumper-go -p boot -o extracted lineage-24.0-*-earth.zip
cp extracted/boot.img output/main/01-stock-boot.img
```

or dump it from the device (root shell, before flashing anything):

```sh
adb shell su -c 'dd if=/dev/block/by-name/boot_a of=/sdcard/stock-boot.img'
adb pull /sdcard/stock-boot.img output/main/01-stock-boot.img
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

### Optional: Docker-enabled variant (native dockerd)

The normal kernel deliberately does not carry the container options. If you
want to run a native Docker daemon on the phone (Termux + root, no chroot),
build the second variant — same sources and toolchain, plus
`configs/docker.fragment`:

```sh
scripts/build-docker-variant.sh
```

It builds into `out-docker/` and produces the `03-docker` group, so the normal
build is never touched:

| File | What it is |
|---|---|
| `output/docker/03-docker-boot.img` | Docker-enabled kernel in the stock boot layout |
| `output/docker/03-docker-boot.zip` | sideload zip that writes `03-docker-boot.img` |
| `output/anykernel3/03-docker-anykernel3-<stamp>.zip` | optional kernel-only package |

`output/SHA256SUMS.txt` is regenerated after packaging. `SKIP_BUILD=1` repacks
an existing build, and `TEMPLATE=/path/to/stock.img` points at a different
stock boot image. Patch `docker/03-docker-boot.img` with APatch exactly like
`apatch/02-apatch-boot.img`.

The fragment enables namespaces, the cgroup controllers, overlayfs,
veth/bridge, VXLAN/MACVLAN/IPVLAN and the iptables NAT targets that dockerd
needs. It does not enable IPVS (absent from this tree) or the hugetlb cgroup
(`HUGETLB_PAGE` is off). Runtime notes: `NOTES.txt` section 13.

## Docker on the device (Termux + root)

With `docker/03-docker-boot.img` flashed, the phone runs a **real `dockerd`** — no proot,
no chroot, no PC. `scripts/termux-dockerd.sh` is the helper: it downloads the
static Docker binaries, starts/stops the daemon with a persistent data root,
and hands the normal `build.sh` a working `DOCKER_HOST`.

```
APatch-patched docker/03-docker-boot.img  ->  dockerd (root, Termux)  ->  docker run / ./build.sh
```

### Prerequisites

| | |
|---|---|
| Kernel | Docker-enabled variant (`output/docker/03-docker-boot.img`) on **both** slots |
| Root | APatch (or another root) with a working `su` |
| Termux | `pkg install curl tar` — `pkg install iproute2` for the `doctor` probes |
| Space | ~10 GB free on `/data` (Docker binaries ~70 MB + images + build tree) |
| RAM | 4 GB is enough for containers; a kernel build wants more (see below) |

The standard `boot.img` does **not** have the container options. If
`/proc/config.gz` shows `CONFIG_NAMESPACES` or `CONFIG_VETH` missing, the wrong
kernel is running — flash `docker/03-docker-boot.img` first.

### Quick start

```sh
pkg install curl tar iproute2
cd ~/earth-kernel-fix-apatch

bash scripts/termux-dockerd.sh doctor   # 1. is the kernel ready?
bash scripts/termux-dockerd.sh setup    # 2. static Docker 27.3.1 (aarch64)
bash scripts/termux-dockerd.sh start    # 3. dockerd via su
docker run --rm hello-world             # 4. it works
```

Step 4 is the real proof: pulling an image uses the daemon's own network, so it
works even when container NAT is unavailable.

### 1. Flash the Docker kernel

Patch `output/docker/03-docker-boot.img` with APatch exactly like the normal image, then
flash the **patched** file to both slots (same rules as
[Download and install](#download-and-install-no-build-required)):

```sh
fastboot flash boot_a apatch-patched-docker.img
fastboot flash boot_b apatch-patched-docker.img
fastboot reboot
```

Rollback is always the untouched `output/main/01-stock-boot.img`.

### 2. Set up Termux

```sh
pkg update
pkg install curl tar iproute2
```

`iproute2` is optional; without it `doctor` simply skips the veth/bridge probes.
Everything installed by the helper lives outside the repository:

```
~/.local/docker/                 docker, dockerd, containerd, runc
~/.local/share/docker-data/      images, containers, volumes (the "volume")
~/.local/share/dockerd.log       daemon log (scripts/termux-dockerd.sh logs)
$PREFIX/var/run/docker.sock      socket, chmod 666 for the Termux user
```

Because the data root is a normal directory on `/data`, **images and containers
survive reboots and daemon restarts**. Deleting that directory is the only way
to lose them; back it up with

```sh
tar -C ~/.local/share -czf docker-data-backup.tar.gz docker-data
```

### 3. Check, install, start

`doctor` reads `/proc/config.gz` (through `su` if needed) and probes the live
kernel:

```sh
bash scripts/termux-dockerd.sh doctor
```

Expected highlights:

```
ok      CONFIG_NAMESPACES
ok      CONFIG_MEMCG
ok      CONFIG_OVERLAY_FS
ok      CONFIG_VETH
ok      CONFIG_BRIDGE
ok      veth pairs can be created
ok      bridge devices can be created
```

Then:

```sh
bash scripts/termux-dockerd.sh setup    # once: static Docker tarball
bash scripts/termux-dockerd.sh start    # dockerd, persistent data root
bash scripts/termux-dockerd.sh status   # docker info + state paths
```

`start` prints the socket and the data directory, and is safe to run twice — if
the daemon is already up it just says so. To keep it running after Termux is
reopened, add one line to `~/.bashrc`:

```sh
bash ~/earth-kernel-fix-apatch/scripts/termux-dockerd.sh start >/dev/null 2>&1 || true
```

### 4. Run containers

The script exports `DOCKER_HOST` for itself, but your shell needs it too:

```sh
export DOCKER_HOST=unix://$PREFIX/var/run/docker.sock
```

Put that line in `~/.bashrc` next to the `start` line.

```sh
docker run --rm hello-world                       # smoke test
docker run --rm -it --network host alpine sh      # shell, host network
docker run --rm --network host ubuntu:24.04 uname -a
docker ps -a                                      # containers
docker images                                     # images
docker system df                                  # disk usage
docker logs <container>                           # output
docker rm <container>; docker rmi <image>         # cleanup
docker system prune -af                           # reclaim space
```

Two phone-specific rules:

- **Use `--network host`** for anything that needs the internet (package
  installs, `git clone`, registry-less builds). Without an `iptables` binary the
  daemon disables NAT, so the default bridge has no outbound route.
- **`-p 8080:80` needs iptables.** With NAT disabled, reach the service on
  `127.0.0.1:80` through `--network host` instead of publishing a port.

A bind mount is the usual way to share files with the phone:

```sh
docker run --rm -it --network host \
  -v "$HOME/storage/shared:/work" -w /work alpine sh
```

(`termux-setup-storage` once, so `~/storage/shared` points at internal storage.)

### 5. Build the kernel with it

```sh
bash scripts/termux-dockerd.sh image    # docker build, host network, once
bash scripts/termux-dockerd.sh build defconfig configs/apatch.fragment configs/docker.fragment
bash scripts/termux-dockerd.sh build build Image.gz
```

`image` uses `--network host`, so `apt-get` inside the Dockerfile works even
with NAT disabled. Anything else goes through the normal entry points:

```sh
export DOCKER_HOST=unix://$PREFIX/var/run/docker.sock
./build.sh defconfig configs/apatch.fragment
./build.sh build Image.gz
```

A full kernel build on the phone is slow (hours) and can exhaust RAM because
`build.sh` uses `-j$(nproc)`. Use fewer jobs on a 4 GB device:

```sh
docker run --rm -it --user "$(id -u):$(id -g)" -e HOME=/tmp -e JOBS=4 \
  -v "$PWD:/workspace" -w /workspace earth-kernel-abuild:latest \
  bash docker/kernel-build.sh build Image.gz
```

### 6. Stop

```sh
bash scripts/termux-dockerd.sh stop    # daemon only; images stay on disk
bash scripts/termux-dockerd.sh logs    # last 80 lines if something failed
```

Run `stop` before uninstalling Docker or flashing another kernel. Nothing is
deleted automatically — to start clean, remove `~/.local/share/docker-data`
(and optionally `~/.local/docker`).

### Docker troubleshooting

| Symptom | Fix |
|---|---|
| `permission denied` on `docker.sock` | `start` chmods it to 666; rerun `start`, or export the right `DOCKER_HOST` |
| `Cannot connect to the Docker daemon` | daemon not up: `scripts/termux-dockerd.sh start`, then `status` |
| `dockerd` exits immediately | `scripts/termux-dockerd.sh logs`; usually cgroup/SELinux or a missing kernel option — `doctor` tells you which |
| `operation not permitted` while creating a container | storage driver: keep the default `vfs`, or try `DOCKER_STORAGE=overlay2 ... start` only if the ROM allows xattrs |
| container has no internet | add `--network host` (NAT is off without iptables) |
| `-p` port not reachable | same reason — use `--network host` and connect to the container port |
| `no space left on device` | `docker system prune -af`, and remember `vfs` copies every layer in full |
| build killed (OOM) | rerun with `-e JOBS=4` as shown above |
| `doctor` reports missing `CONFIG_*` | the standard kernel is running; flash the APatch-patched `docker/03-docker-boot.img` |

Kernel-side details and the full option list are in `NOTES.txt` section 13.
`DOCKER_VERSION`, `DOCKER_STORAGE`, `DOCKER_DATA_ROOT`, `DOCKER_LOG`, `IMAGE`
can be overridden as environment variables.

### GitHub Actions

`.github/workflows/build.yml` builds **both variants automatically** in the
same Docker pipeline:

| Job | Config | Build tree | Artifact |
|---|---|---|---|
| `standard` | `configs/apatch.fragment` | `out/` | `earth-kernel-standard-<run>-<attempt>` |
| `docker` | + `configs/docker.fragment` | `out-docker/` | `earth-kernel-docker-<run>-<attempt>` |

- runs on every push to `master`/`main`, on `v*` tags, and manually
  (`workflow_dispatch`);
- inputs: `target` (default `Image.gz`), `clean_build` (from scratch),
  `stock_boot_url` (optional);
- reuses `build.sh`, `finalize.sh`, `make-zip.sh` and
  `build-docker-variant.sh`, so a CI build and a local build are identical;
- caches the Docker layers and the build trees, so a rerun continues instead
  of starting over — `clean_build` forces a fresh one;
- uploads `Image.gz`, `Image`, `kernel.config`, `kernel.release`, whatever
  boot images/zips were produced, and a single `SHA256SUMS.txt`.

`boot.img` needs the stock boot template, which is not in the repository. Set
the repository variable `STOCK_BOOT_URL` (Settings → Secrets and variables →
Actions → Variables) or pass `stock_boot_url` on a manual run, and CI will
download it and build the `02-apatch` and `03-docker` images plus all sideload zips.
Without it you only get `Image.gz`/`Image` and the AnyKernel3 zip.

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
configs/docker.fragment      optional Docker/containerd options (variant)
patches/0001-gcc-build-fixes.patch  same fixes, for upstream users
scripts/repack-boot.py       boot image v2 repacker (kernel swap only)
scripts/make-zip.sh          AnyKernel3 kernel-only zip -> output/anykernel3/
scripts/make-bootimg-zip.sh  full boot image sideload zip
scripts/finalize.sh          02-apatch img/zip + 01-stock zip + checksums
scripts/build-docker-variant.sh  Docker-enabled variant (03-docker, out-docker/)
scripts/checksums.sh         regenerate output/SHA256SUMS.txt
scripts/termux-dockerd.sh    native dockerd on the phone (Termux + root)
scripts/verify-patch.sh      KernelPatch patchability gate
scripts/full-build.sh        image + defconfig + build + verify
.github/workflows/build.yml  CI: both variants, cached (Docker)
anykernel3/                  AnyKernel3 (osm0sis) with an earth config
tools/                       place kptools-linux / kpimg-linux here
output/                      deliverables (git-ignored):
  main/01-stock-boot.img/.zip   stock image + rollback zip
  apatch/02-apatch-boot.img/.zip  standard kernel + sideload zip
  docker/03-docker-boot.img/.zip  Docker kernel + sideload zip
  anykernel3/                optional kernel-only zips
  SHA256SUMS.txt             one checksum file, full paths on every line
out/                         kernel build tree (git-ignored)
out-docker/                  Docker variant build tree (git-ignored)
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
| Device does not boot after flashing | flash `main/01-stock-boot.img` to both slots |

## Credits and license

- Kernel source: [LineageOS/android_kernel_xiaomi_earth](https://github.com/LineageOS/android_kernel_xiaomi_earth) (GPL-2.0)
- APatch / KernelPatch: [bmax121/KernelPatch](https://github.com/bmax121/KernelPatch) (GPL-2.0)
- AnyKernel3: [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) (BSD-3-Clause style, see `anykernel3/LICENSE`)
- Build scripts and boot-image tooling in this repository: **GPL-2.0**, see [`LICENSE`](LICENSE)

This project is unofficial and not affiliated with Xiaomi, LineageOS, APatch or
AnyKernel3. Flashing custom kernels can brick a device; you do it at your own
risk, and you need an unlocked bootloader.
