# Junkyard Slurm Setup

Automated flow for building a Pixel Fold (felix) boot image trio — `boot.img`, `vendor_boot.img`, and an ext4 `rootfs.img` — that replaces stock Android userspace with Debian while keeping the stock kernel source and vendor firmware.

* Clones and builds the AOSP felix kernel with a custom defconfig fragment
* Creates a Debian trixie rootfs via debootstrap + systemd-nspawn
* Pulls `/vendor/firmware` out of the felix factory OTA (required for working UART)
* Assembles a dracut initramfs and mkbootimg artifacts

## Requirements

* [just](https://github.com/casey/just)
* [repo](https://source.android.com/docs/setup/download/source-control-tools)
* `make`, `rsync`, `curl`, `unzip`, `xxd`, `debootstrap`, `e2fsprogs` (for `mkfs.ext4`)
* `systemd-container` (for `systemd-nspawn`)
* `qemu-user-static` (arm64 chroot on x86)

## Customizing

* **Kernel config** — add/remove options in [kernel/custom_defconfig_mod/custom_defconfig](kernel/custom_defconfig_mod/custom_defconfig). Use `just config_kernel` to discover transitive deps via `nconfig`.
* **Apt packages** — one per line in [rootfs/packages.txt](rootfs/packages.txt).
* **Rootfs files** — drop under [rootfs/overlay/](rootfs/overlay/); the overlay is rsynced into the sysroot at the end of `.install_packages`.

## Building

The pipeline is Makefile-driven with sentinel files per stage, so reruns skip completed work.

```shell
just clone_kernel_source          # once; ~1hr
just sync_vendor_firmware         # once; ~2GB OTA download
just all                          # full pipeline; produces boot/{boot,vendor_boot,rootfs}.img
```

`just all` takes optional args: `android_kernel_branch`, `size`, `debootstrap_release`, `root_password`, `hostname`. Defaults: `android-gs-felix-6.1-android16`, `8100M`, `trixie`, `0000`, `fold`.

### What `just all` runs

It drives the Makefile's sentinel chain. Each stage writes a dotfile on success, so reruns skip finished work.

| Stage | Does |
| --- | --- |
| `.create_image` | `fallocate` + `mkfs.ext4 -F -L rootfs` a fresh `boot/rootfs.img` |
| `.debootstrap` | Two-stage debootstrap of `trixie` into the mounted image; sets root password and hostname |
| `.build_kernel` | Bazel-builds the felix kernel with the custom defconfig fragment; writes `kernel/kernel_version` |
| `.install_vendor_firmware` | Rsyncs `rootfs/vendor-firmware/extracted/firmware/` (from `sync_vendor_firmware`) into `/vendor/firmware/` on the mounted image — required for UART input |
| `.install_packages` | `apt-get install` everything in [rootfs/packages.txt](rootfs/packages.txt); disables `dhcpcd`, enables `NetworkManager`, seeds a DHCP ethernet profile; rsyncs [rootfs/overlay/](rootfs/overlay/) into the sysroot |
| `.install_kernel` | Copies modules from the kernel build's staging archives, runs `depmod`, installs kernel headers, composes `rootfs/module_order.txt` for dracut's force-drivers list (with `bcmdhd4389`/`exynos_mfc` stripped) |
| `.install_initramfs` | Runs `dracut` inside `systemd-nspawn` with `--force-drivers` from `module_order.txt` |
| `.build_boot` | `mkbootimg` twice — `boot.img` (kernel + `root=` cmdline) and `vendor_boot.img` (dtb + vendor_ramdisk_fragment pointing at the dracut initramfs) |

`just all` invokes make twice in sequence: first to build `.build_kernel`, then everything else with a freshly-read `KERNEL_VERSION`. That's because justfile's `read()` of `kernel/kernel_version` happens at parse time, before the kernel has been built on a fresh checkout.

Individual stages are also exposed: `just build_kernel`, `just build_rootfs`, `just install_apt_packages`, `just update_kernel_modules_and_source`, `just update_initramfs`, `just build_boot_images`. See `just --list`.

## Flashing

```shell
fastboot oem disable-verity
fastboot oem disable-verification
./flash.sh
```

`flash.sh` wraps flashing `boot.img` + `vendor_boot.img` + `rootfs.img` (to the `super` slot).

## TODO

* Proper fstab
* Dedicated build machine
* Mount additional partitions by label
* Suppress sleep when lid closed
