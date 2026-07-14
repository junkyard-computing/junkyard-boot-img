# Building the kernel and images

How to build the felix (Pixel Fold, gs201) mainline boot trio — `boot.img`,
`vendor_boot.img`, `rootfs.img` — from a clean checkout.

The build is a **Makefile with sentinel-tracked stages**; the `justfile` is a
thin wrapper that sets up env and delegates to `make`. Each stage touches a
dotfile sentinel at the repo root on success, so reruns skip finished work.
See [../CLAUDE.md](../CLAUDE.md) for the architecture behind each stage.

> **Run everything through `./tools/dockershell`.** The wrapper supplies the
> aarch64 cross-compiler, passwordless sudo (the rootfs stages loop-mount the
> image and run `systemd-nspawn`), and USB passthrough for fastboot. Direct host
> `just all` hits a sudo password prompt at `mount_rootfs`. Prefix any command
> below with `./tools/dockershell` — e.g. `./tools/dockershell just all`. See
> the "Docker build environment" section of [../CLAUDE.md](../CLAUDE.md) for the
> rationale. If you have all the host prerequisites installed and passwordless
> sudo, you can drop the prefix.

## Prerequisites

If you use `./tools/dockershell` the image ([../tools/Dockerfile](../tools/Dockerfile))
packages all of this — you only need Docker and a one-time binfmt setup:

```shell
./tools/dockershell setup      # installs qemu arm64 binfmt (host-global, once)
```

To build directly on the host instead, install:

- **Orchestration:** `just`, `git`, `make`
- **Kernel toolchain:** an aarch64 cross-compiler (`gcc-aarch64-linux-gnu`),
  plus `flex`, `bison`, `bc`, `libelf-dev`, `libssl-dev`, `dwarves` (pahole, for
  BTF), `cpio`, `kmod`, `lz4`
- **Rootfs:** `debootstrap`, `qemu-user-static` (arm64 binfmt), `systemd-container`
  (for `systemd-nspawn`), `e2fsprogs` (for `mkfs.ext4`), `rsync`, `curl`,
  `unzip`, `xxd`
- **On-device tools:** a Rust toolchain with the `aarch64-unknown-linux-musl`
  target (`rustup target add aarch64-unknown-linux-musl`), for the
  `pixel-bootctl` / `pixel-ota` cross-builds baked into the image

`erofs-utils` and `android-sdk-libsparse-utils` are optional — only needed if a
future felix OTA ships its vendor partition in those formats.

## First-time setup (two one-time steps)

```shell
./tools/dockershell just clone_kernel_source   # git submodule init/update; several GB of Linux history
./tools/dockershell just sync_vendor_firmware  # pull felix factory OTA, extract /vendor/firmware; ~2GB
```

- `clone_kernel_source` fetches the kernel submodule at [kernel/source](../kernel/source)
  (github.com/junkyard-computing/linux, `felix` branch, pinned in
  [../.gitmodules](../.gitmodules)) plus the `mkbootimg` / `pixel-bootctl` /
  `pixel-ota` submodules.
- `sync_vendor_firmware` downloads the felix OTA, pulls the `vendor` partition,
  and stages `/vendor/firmware` under `rootfs/vendor-firmware/extracted/`. This
  is **mandatory** — without the AOC firmware blob the coprocessor retry-loops
  and starves UART RX, dropping console keystrokes. The download is cached, so
  it's paid once.

Both sentinels are preserved across `just clean_rootfs`, so you don't repeat the
expensive kernel checkout / OTA download on a routine rebuild.

## Full build

```shell
./tools/dockershell just all
```

`just all` drives the whole sentinel chain in dependency order:

```
.create_image → .debootstrap → .build_kernel → .install_vendor_firmware
  → .install_packages → .install_kernel → .install_initramfs → .build_boot
```

(`.build_pixel_bootctl`, `.build_pixel_ota`, and `.build_mesa` feed into
`.install_packages` / `.install_boot` as siblings.)

It runs `make` **twice**: first to build `.build_kernel`, then the rest with a
freshly-read `KERNEL_VERSION`. The kernel version string is only known *after*
the kernel builds, and the justfile reads `kernel/kernel_version` at parse time,
so the split lets the second invocation pick up the real value (all the
`/lib/modules/<ver>/` paths depend on it).

Optional args (with defaults):

```shell
./tools/dockershell just all \
    size=8100M \
    debootstrap_release=trixie \
    root_password=0000 \
    hostname=fold \
    user_login=kalm \
    user_password=0000
```

`size=8100M` leaves a margin under felix's 8136.9 MiB `super` partition so
fastboot doesn't reject a slightly-oversized image.

### Outputs

| File | Contents |
| --- | --- |
| [../boot/boot.img](../boot) | kernel (`Image.lz4`) + `root=` / `firmware_class.path=` cmdline |
| [../boot/vendor_boot.img](../boot) | `gs201-felix.dtb` + dracut initramfs (as a vendor ramdisk fragment) |
| [../boot/rootfs.img](../boot) | ext4 Debian rootfs, flashed to the `super` slot |

The `dtbo.img` used at flash time comes from the kernel build tree, not this
pipeline — see the flashing section below.

## Building just the kernel

```shell
./tools/dockershell just build_kernel
```

This runs the `.build_kernel` stage ([../Makefile](../Makefile)), which does
plain out-of-tree kbuild against the submodule (no AOSP Bazel):

1. `make ... O=out defconfig` — the mainline base defconfig.
2. Merges the felix fragment [../kernel/custom_defconfig_mod/felix.config](../kernel/custom_defconfig_mod/felix.config)
   on top via `merge_config.sh`. The fragment forces `VA_BITS=48` / no-LPA2 and
   disables ARMv8.5+ extensions the gs201 cores don't implement — **without it
   the kernel hangs silently in `head.S` MMU setup** (before earlycon) and the
   watchdog reboots.
3. `make ... olddefconfig`.
4. `make -j$(nproc) DTC_FLAGS=-@ Image modules dtbs` — the `DTC_FLAGS=-@` emits
   the `__symbols__` node into the dtbs, **required** or the felix bootloader
   refuses to boot (its factory dtbo phandle fixups can't resolve against a
   symbol-less dtb).
5. `lz4 -9` compresses `Image` → `Image.lz4`.
6. Writes the kernel version string (`include/config/kernel.release`) to
   [../kernel/kernel_version](../kernel/kernel_version).

Everything lands under `kernel/source/out/` (gitignored):
`arch/arm64/boot/Image{,​.lz4}`, `arch/arm64/boot/dts/exynos/google/gs201-felix.dtb`,
`System.map`, and the module tree.

The raw underlying make invocation (what `KMAKE` expands to), if you want to
build a single target by hand:

```shell
./tools/dockershell sh -c \
  'make -C kernel/source ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=out \
     exynos/google/gs201-felix.dtb'
```

### Changing kernel config

Edit the felix defconfig fragment
[../kernel/custom_defconfig_mod/felix.config](../kernel/custom_defconfig_mod/felix.config)
(or the submodule's own `arch/arm64/configs/defconfig` and commit there). To
discover transitive dependencies for a new `CONFIG_*`, drop into menuconfig
against the current build tree:

```shell
./tools/dockershell just config_kernel      # make nconfig against kernel/source/out
```

### When to rebuild the kernel

The kernel must be rebuilt whenever the submodule pointer or version string
changes, because every downstream rootfs stage keys off `kernel/kernel_version`
and the `/lib/modules/<ver>/` layout. The `.build_kernel` sentinel is expensive,
so it's **preserved** by `just clean_rootfs`. To force a from-scratch kernel
rebuild:

```shell
./tools/dockershell just clean_kernel        # make mrproper + rm kernel/source/out + rm .build_kernel
```

> **Submodule bump gotcha:** if you move the `kernel/source` pointer, `git add`
> the gitlink and `rm .build_kernel` — otherwise the Makefile's
> `git submodule update` can leave you silently compiling the old SHA.

## Rebuilding parts of the image (iterating)

The individual stages are exposed as targets so you don't rerun the whole chain.
Each re-reads `kernel/kernel_version` at recipe time, so they work right after
`just build_kernel`:

| Target | Rebuilds |
| --- | --- |
| `just build_rootfs` | debootstrap the base Debian rootfs |
| `just install_apt_packages` | apt packages + overlay + user/network setup |
| `just update_kernel_modules_and_source` | copy modules, `depmod`, headers, `module_order.txt` |
| `just update_initramfs` | re-run `dracut` in nspawn |
| `just build_boot_images` | re-`mkbootimg` `boot.img` + `vendor_boot.img` |
| `just build_mesa` / `just install_mesa` | open-GPU Mesa userland (optional, ~1hr first run) |

Because overlay files are Makefile dependencies of `.install_packages`, editing
anything under [../rootfs/overlay/](../rootfs/overlay) re-triggers that stage on
the next `just all`.

### Clean targets

- `just clean_rootfs` — remove `rootfs.img`, boot images, and image-pipeline
  sentinels; **preserves** the cached kernel build and OTA download.
- `just clean` — same as above (image pipeline only).
- `just clean_kernel` — `make mrproper` + drop `kernel/source/out` + `.build_kernel`.
- `just clean_mesa` — drop the cached Mesa build.

## Flashing

Once built, flash over fastboot with the device in the bootloader on USB-C:

```shell
./tools/dockershell ./flash-fastboot.sh      # boot + vendor_boot + rootfs (super) + mandatory dtbo
```

- [../flash.sh](../flash.sh) — default restore of the mainline boot chain to `super`.
- [../flash-fastboot.sh](../flash-fastboot.sh) — adds the **mandatory** `dtbo`
  re-flash (from the kernel build tree). Skipping the dtbo leaves the device
  half-configured (no `/dev/ttySAC0`, panel dark).
- [../flash-ssh.sh](../flash-ssh.sh) — in-place OTA over the network via
  `pixel-ota`, for a slot that already boots with working networking.
- **UART delta-flash** (`uartfs`, in the `../uartd` repo) — the primary
  iteration path for a no-network experiment slot.

Note: fastboot and UART share the one Type-C port — never `reboot bootloader`
mid-UART-session; switch slots in-OS with `pixel-bootctl set-active-slot` +
reboot. See the "Flashing" section of [../CLAUDE.md](../CLAUDE.md) for the full
transport story.
</content>
</invoke>
