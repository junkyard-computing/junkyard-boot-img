# Junkyard felix mainline boot image

Automated flow for building a Pixel Fold (codename **felix**, SoC gs201) boot
image trio — `boot.img`, `vendor_boot.img`, and an ext4 `rootfs.img` — that
replaces stock Android userspace with Debian.

This is the **mainline kernel track**. The kernel is a fork of the mainline
Linux tree ([github.com/junkyard-computing/linux](https://github.com/junkyard-computing/linux),
`felix` branch), pulled in as a git submodule at [kernel/source](kernel/source)
and built with standard out-of-tree kbuild (no AOSP Bazel). The separate
android-GKI track lives on the repo's `main` branch.

* Builds the junkyard-computing/linux `felix` kernel with a mainline defconfig
  plus the [kernel/custom_defconfig_mod/felix.config](kernel/custom_defconfig_mod/felix.config) fragment
* Creates a Debian trixie rootfs via debootstrap + systemd-nspawn
* Pulls `/vendor/firmware` out of the felix factory OTA (required for working UART)
* Assembles a dracut initramfs and mkbootimg artifacts
* Cross-compiles the on-device `pixel-bootctl` / `pixel-ota` A/B tools into the image

## Requirements

Easiest path is the container wrapper [tools/dockershell](tools/dockershell),
which bundles everything below — see **Building**. To build directly on the
host instead:

* [just](https://github.com/casey/just), `git`, `make`
* Kernel toolchain: an aarch64 cross-compiler (`gcc-aarch64-linux-gnu`), plus
  `flex`, `bison`, `bc`, `libelf-dev`, `libssl-dev`, `dwarves` (pahole), `cpio`,
  `kmod`, `lz4`
* Rootfs: `debootstrap`, `qemu-user-static` (arm64 binfmt), `systemd-container`
  (for `systemd-nspawn`), `e2fsprogs` (for `mkfs.ext4`), `rsync`, `curl`,
  `unzip`, `xxd`
* On-device tools: a Rust toolchain with the `aarch64-unknown-linux-musl` target

## Building

See **[docs/building.md](docs/building.md)** for the full guide. The short
version — run everything through [tools/dockershell](tools/dockershell), which
supplies the cross-compiler, passwordless sudo (the rootfs stages loop-mount the
image and run `systemd-nspawn`), and USB passthrough for fastboot:

```shell
./tools/dockershell just clone_kernel_source   # once; git submodule init/update
./tools/dockershell just sync_vendor_firmware  # once; ~2GB felix OTA download
./tools/dockershell just all                   # full pipeline; produces boot/{boot,vendor_boot,rootfs}.img
```

`just all` takes optional args (defaults shown): `size=8100M`,
`debootstrap_release=trixie`, `root_password=0000`, `hostname=fold`,
`user_login=kalm`, `user_password=0000`.

### What `just all` runs

The build is Makefile-driven with a sentinel file per stage, so reruns skip
completed work. `just all` invokes make twice: first to build `.build_kernel`,
then everything else with a freshly-read `KERNEL_VERSION` (the justfile reads
`kernel/kernel_version` at parse time, before the kernel exists on a fresh
checkout).

| Stage | Does |
| --- | --- |
| `.create_image` | `fallocate` + `mkfs.ext4 -F -L rootfs` a fresh `boot/rootfs.img` |
| `.debootstrap` | Two-stage debootstrap of `trixie` into the mounted image; sets root password and hostname |
| `.build_kernel` | Plain-kbuild the `felix` kernel: base defconfig + the `felix.config` fragment, `Image modules dtbs` (with `DTC_FLAGS=-@`), `lz4`-compress the Image, write `kernel/kernel_version` |
| `.install_vendor_firmware` | Rsyncs `rootfs/vendor-firmware/extracted/firmware/` (from `sync_vendor_firmware`) into `/vendor/firmware/` on the mounted image — required for UART input |
| `.install_packages` | `apt-get install` everything in [rootfs/packages.txt](rootfs/packages.txt); installs kmscon from a pinned Debian-pool `.deb`; creates `$(USER_LOGIN)` with passwordless sudo; masks `systemd-backlight@.service`; disables `dhcpcd`, enables `NetworkManager`, seeds a DHCP ethernet profile; rsyncs [rootfs/overlay/](rootfs/overlay/) into the sysroot |
| `.install_kernel` | `make modules_install` into the sysroot, reruns `depmod`, installs kernel headers, composes `rootfs/module_order.txt` for dracut's force-drivers list (with `bcmdhd4389`/`exynos_mfc` stripped) |
| `.install_initramfs` | Runs `dracut` inside `systemd-nspawn` with `--force-drivers` from `module_order.txt` |
| `.build_boot` | `mkbootimg` twice — `boot.img` (kernel + `root=` / `firmware_class.path=` cmdline) and `vendor_boot.img` (dtb + vendor_ramdisk_fragment pointing at the dracut initramfs) |

The Rust `pixel-bootctl` / `pixel-ota` tools (`.build_pixel_bootctl` /
`.build_pixel_ota`) and the optional open-GPU Mesa userland (`.build_mesa`) feed
into the image as sibling stages.

Individual stages are also exposed: `just build_kernel`, `just build_rootfs`,
`just install_apt_packages`, `just update_kernel_modules_and_source`,
`just update_initramfs`, `just build_boot_images`. See `just --list` and
[docs/building.md](docs/building.md).

### Customizing

* **Kernel config** — edit [kernel/custom_defconfig_mod/felix.config](kernel/custom_defconfig_mod/felix.config)
  (or the submodule's own `arch/arm64/configs/defconfig`). Use
  `just config_kernel` to discover transitive deps via `nconfig`.
* **Apt packages** — one per line in [rootfs/packages.txt](rootfs/packages.txt).
* **Rootfs files** — drop under [rootfs/overlay/](rootfs/overlay/); the overlay
  is rsynced into the sysroot at the end of `.install_packages`.

## Flashing

With the device in the bootloader on USB-C:

```shell
./tools/dockershell ./flash-fastboot.sh
```

`flash-fastboot.sh` flashes `boot.img` + `vendor_boot.img` + `rootfs.img` (to
the `super` slot) plus the **mandatory** `dtbo` re-flash. [flash.sh](flash.sh)
is the boot-chain-only restore; [flash-aosp-sanity.sh](flash-aosp-sanity.sh)
flashes stock felix for a UFS hardware sanity check.

For a device **already running and reachable over the network**,
[flash-ssh.sh](flash-ssh.sh) `[user@]host` updates it in place over SSH — it
flashes the inactive boot slot with `pixel-ota` and switches to it, then arms an
in-place rootfs reflash via the `90rootfs-flash` dracut pre-mount hook (keyed on
a `flash-pending` flag on `userdata`). It copies any missing `pixel-ota` /
`pixel-bootctl` binaries and requires a persistent staging partition mounted at
`/userdata` (the rootfs reflash is destructive and rollback-free).

**fastboot and UART share the one Type-C port** — never `reboot bootloader`
mid-UART-session; switch slots in-OS with `pixel-bootctl set-active-slot` +
reboot. See [CLAUDE.md](CLAUDE.md) for the full transport story and architecture.

## TODO

* Proper fstab
* Dedicated build machine
* Mount additional partitions by label
</content>
