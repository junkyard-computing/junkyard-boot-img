# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo builds

An `android-boot.img` / `vendor_boot.img` / `rootfs.img` trio that replaces the Pixel Fold (codename **felix**, SoC gs201) stock userspace with a Debian rootfs, while keeping the stock Android kernel source + vendor blobs. The output gets flashed via fastboot (`flash.sh`) — `boot.img` carries the kernel, `vendor_boot.img` carries the dtb + dracut initramfs, and `rootfs.img` is an ext4 image flashed to the `super` slot as the real root fs.

## Build pipeline

The build is driven by a **Makefile with sentinel-tracked stages**; the justfile is a thin orchestration/env-setup layer that delegates to make. Reruns skip stages whose sentinels are already touched.

Sentinel chain (all live at repo root, dotfile-named): `.create_image` → `.debootstrap` → `.build_kernel` → `.install_vendor_firmware` → `.install_packages` → `.install_kernel` → `.install_initramfs` → `.build_boot`. `.sync_vendor_firmware` is a sibling sentinel that `.install_vendor_firmware` depends on.

First-time run:

```
just clone_kernel_source          # repo init + sync; ~1hr
just sync_vendor_firmware         # pull felix OTA, extract /vendor/firmware; ~2GB
just all                          # everything else
./flash.sh
```

Individual stages are also exposed as justfile targets (`build_kernel`, `build_rootfs`, `install_apt_packages`, `update_kernel_modules_and_source`, `update_initramfs`, `build_boot_images`, `create_rootfs_image`, `mount_rootfs`, `unmount_rootfs`, `clean_rootfs`, `clean_kernel`). They all call `make` under the hood.

Why the split: `just all` runs two make invocations in sequence so the second picks up the fresh `KERNEL_VERSION` written by `.build_kernel` (justfile `read()` is parse-time; an empty `kernel/kernel_version` at parse would otherwise propagate). Individual `update_*` / `build_boot_images` targets also re-read `kernel/kernel_version` at recipe time for the same reason.

Targets are grouped (`[group('kernel')]`, `[group('rootfs')]`, `[group('boot')]`) — `just --list` shows them grouped.

## Architectural pieces that require reading multiple files

### Kernel build is AOSP's Bazel, not plain Make
`kernel/source/` is a `repo`-managed AOSP kernel manifest checkout, driven by `kernel/source/tools/bazel` (the `BAZEL` env var). Custom kconfig options live in [kernel/custom_defconfig_mod/custom_defconfig](kernel/custom_defconfig_mod/custom_defconfig) — it's a **defconfig *fragment*** loaded via `--defconfig_fragment=//custom_defconfig_mod:custom_defconfig`, not a full defconfig. [BUILD.bazel](kernel/custom_defconfig_mod/BUILD.bazel) just `exports_files` it. `clone_kernel_source` symlinks `kernel/custom_defconfig_mod/` into the kernel source tree so bazel picks it up. When adding new CONFIG_* options you may need to run `nconfig` inside the kernel tree first to discover transitive dependencies — `just config_kernel` wraps that.

The kernel version string is extracted from the built `Image` and written to [kernel/kernel_version](kernel/kernel_version). That file drives all the `/lib/modules/<ver>/` paths, so the kernel must be rebuilt whenever the branch or version changes and every downstream rootfs target depends on that value being current.

### Rootfs is an ext4 image, mounted during each build stage
The rootfs starts life as `boot/rootfs.img`, created empty by `.create_image` (`fallocate` + `mkfs.ext4 -F -L rootfs`). Every subsequent stage mounts it at `rootfs/sysroot/` via `just mount_rootfs` (`sudo mount`), does its work, and unmounts via `just unmount_rootfs`. Contents are owned by root throughout — no ownership-flipping dance.

Why ext4 and not btrfs/squashfs: the GKI-built kernel silently strips `CONFIG_BTRFS_FS` and `CONFIG_SQUASHFS` from the final `.config` even when the custom fragment sets them `=y` — GKI enforces a locked filesystem allowlist. `ext4`, `f2fs`, and `erofs` are the allowlisted ones. Adding a new in-tree filesystem to GKI would require a different kernel build profile.

Debootstrap runs two-stage (foreign arch; qemu-user-static binfmt required on the build host). Second-stage debootstrap and all in-sysroot shell work runs under `systemd-nspawn -D rootfs/sysroot` (not `chroot`) so systemd-aware scriptlets, `depmod`, `dracut`, and `nmcli --offline` behave correctly. Debian release is `trixie` by default, resolved against the live mirror (no snapshot pin).

The helper [rootfs/_enter](rootfs/_enter) exists for manually entering the sysroot with fakeroot (non-nspawn path, rarely used).

### Module loading — three stages, one force-list
Kernel modules come from two staging archives the kernel build produces: `vendor_dlkm_staging_archive.tar.gz` and `system_dlkm_staging_archive.tar.gz`. `.install_kernel` unpacks both into `rootfs/unpack/`, rsyncs only `*.ko` into the sysroot, concatenates their `modules.order` files, runs `depmod` inside nspawn, and installs kernel headers under `/usr/src/linux-headers-<ver>` with a symlink from `/lib/modules/<ver>/build`.

It then composes [rootfs/module_order.txt](rootfs/module_order.txt) from three `modules.load` lists (`vendor_kernel_boot` + `vendor_dlkm` + `system_dlkm`), resolved through `modinfo -F name`, with `bcmdhd4389` and `exynos_mfc` sed'd out (so they're not loaded before `/etc/modprobe.d/blacklist.conf` takes effect). `.install_initramfs` passes that list as dracut's `--force-drivers` so the initramfs force-loads them at boot.

`rootfs/overlay/etc/modprobe.d/blacklist.conf` exists but is applied by the running userspace, not the initramfs — that's why the module_order.txt sed step matters.

### Vendor firmware — required for UART input
`sync_vendor_firmware` downloads the felix factory OTA (`_felix_ota_url`), extracts `payload.bin`, pulls only the `vendor` partition with `payload-dumper-go` (downloaded + pinned to `_payload_dumper_version`), and runs [tools/extract-partition-fs.sh](tools/extract-partition-fs.sh) to unpack it into `rootfs/vendor-firmware/extracted/`. The helper auto-detects EROFS vs ext4 and unwraps Android sparse framing via `simg2img` if needed — felix has shipped both formats across OTAs.

`.install_vendor_firmware` then rsyncs `extracted/firmware/` into `/vendor/firmware/` on the mounted sysroot. **This is mandatory**: the stock felix dtb's `/chosen/bootargs` carries `firmware_class.path=/vendor/firmware` (not something we set in boot.img's cmdline), and without the blobs the AOC coprocessor retry-loops and starves UART RX, dropping login-prompt keystrokes.

### Rootfs overlay
[rootfs/overlay/](rootfs/overlay/) is an `rsync -a`-ed tree applied at the end of `.install_packages`. Currently contains `etc/modprobe.d/blacklist.conf`, a systemd unit (`etc/systemd/system/custom.service` + `usr/bin/customservice`), a `usr/local/sbin/usb_gadget` script, etc. Overlay files are Makefile dependencies of `.install_packages` (via `$(shell find rootfs/overlay -type f)`), so editing an overlay file re-triggers the package stage. Add new tracked sysroot files here rather than editing `rootfs/sysroot/` directly (the sysroot is wiped and rebuilt by `.debootstrap`).

### Default network config
`.install_packages` disables `dhcpcd`, enables `NetworkManager`, and seeds `/etc/NetworkManager/system-connections/default_connection.nmconnection` via `nmcli --offline connection add` piped to a file, then chmod 600 so NM trusts it. Result: wired ethernet comes up on DHCP automatically.

### mkbootimg is a submodule
[tools/mkbootimg](tools/mkbootimg) is the upstream AOSP mkbootimg repo pulled in via `.gitmodules`. `.build_boot` invokes its `mkbootimg.py` twice — once for `boot.img` (kernel + generic root= cmdline) and once for `vendor_boot.img` (dtb + vendor_ramdisk_fragment pointing at the dracut initramfs inside the mounted rootfs image). Header version 4, pagesize 2048.

## Conventions

- Adding apt packages → one per line in [rootfs/packages.txt](rootfs/packages.txt) (read by the justfile at parse time and space-joined into the apt install invocation).
- Adding kconfig options → append to [kernel/custom_defconfig_mod/custom_defconfig](kernel/custom_defconfig_mod/custom_defconfig). Remember transitive deps.
- Adding sysroot files → put them under [rootfs/overlay/](rootfs/overlay/), not in `rootfs/sysroot/`.
- `kernel_version`, `rootfs/module_order.txt`, `rootfs/sysroot/`, `rootfs/unpack/`, `boot/*.img`, and all sentinel dotfiles (`.create_image`, `.debootstrap`, etc.) are gitignored build artifacts.
- `clone_kernel_source`'s `android_kernel_branch` argument is pinned to `android-gs-felix-6.1-android16` because the earlier android14 branch was deleted upstream. Changing the branch requires rebuilding kernel + rootfs modules in lockstep.
- `just clean_rootfs` removes the image and per-stage sentinels; `.build_kernel` and `.sync_vendor_firmware` sentinels are preserved because they're expensive (~1hr kernel build, ~2GB OTA download). `just clean_kernel` is a separate knob.

## Build-host prerequisites

Beyond the obvious `just`, `repo`, `qemu-user-static`: `make`, `e2fsprogs` (for `mkfs.ext4`), `rsync`, `debootstrap`, `systemd-container` (for `systemd-nspawn`), `curl`, `unzip`, `xxd`. `erofs-utils` and `android-sdk-libsparse-utils` are optional and only kick in if a future felix OTA ships the vendor partition in those formats.
