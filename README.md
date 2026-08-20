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
just all       # build every device
just felix     # or just one
just lynx
```

Each of those runs the whole pipeline for its device, including the first-time `repo` sync (~1hr) and the ~2GB vendor-firmware OTA download. Reruns are cheap.

**Everything is per-device.** Both devices are gs201, but they need different kernel branches and different vendor firmware, so each gets its own artifact tree and its own kernel checkout:

```
build/<device>/       sentinels, rootfs.img, super.img, boot.img, vendor_boot.img,
                      module_order.txt, unpack/, vendor-firmware/
kernel/source-<device>/       its own `repo` checkout, on its own manifest branch
kernel/kernel_version.<device>
devices/<device>.mk           kernel branch, Bazel target, OTA url+sha, SIZE, SUPER_BYTES, hostname
```

Adding a third gs201 Pixel is a new `devices/<name>.mk` plus a one-line recipe.

### Migrating an existing checkout

A checkout from before the split has its artifacts at the old paths. Move them into place — mtimes are preserved, so the next build is a no-op instead of a from-scratch rebuild:

```shell
just migrate
```

Idempotent, and safe to run on a fresh checkout with nothing to move.

### Overrides

`device`, `size`, `hostname`, `root_password`, `user_login`, `user_password`, `fleet_id` and `debootstrap_release` are just **variables**, so they go *before* the recipe name, make-style:

```shell
just user_login=bob felix        # correct
just felix user_login=bob        # WRONG — a positional argument to `felix`
```

Leave `size`/`hostname` unset to take the device fragment's values. `size` in particular is one half of `super` and must not exceed 4068 MiB.

### What a device build runs

It drives the Makefile's sentinel chain. Each stage writes a dotfile on success, so reruns skip finished work.

| Stage | Does |
| --- | --- |
| `.create_image` | `truncate` + `mkfs.ext4 -F -L rootfs` a fresh `build/<device>/rootfs.img` |
| `.debootstrap` | Two-stage debootstrap of `trixie` into the mounted image; sets root password and hostname |
| `.build_kernel` | Bazel-builds the device's kernel (`BAZEL_TARGET` from its fragment) with the custom defconfig fragment; writes `kernel/kernel_version.<device>` |
| `.install_vendor_firmware` | Rsyncs `build/<device>/vendor-firmware/extracted/firmware/` (from `sync_vendor_firmware`) into `/vendor/firmware/` on the mounted image — required for UART input |
| `.install_packages` | `apt-get install` everything in [rootfs/packages.txt](rootfs/packages.txt); installs kmscon from a pinned Debian-pool `.deb` (trixie dropped it); creates `$(USER_LOGIN)` with passwordless sudo; masks `systemd-backlight@.service`; disables `dhcpcd`, enables `NetworkManager`, seeds a DHCP ethernet profile; rsyncs [rootfs/overlay/](rootfs/overlay/) into the sysroot |
| `.install_kernel` | Copies modules from the kernel build's staging archives, runs `depmod`, installs kernel headers, composes `build/<device>/module_order.txt` for dracut's force-drivers list (with `bcmdhd4389`/`exynos_mfc` stripped) |
| `.install_initramfs` | Runs `dracut` inside `systemd-nspawn` with `--force-drivers` from `module_order.txt` |
| `.build_boot` | `mkbootimg` twice — `boot.img` (kernel + `root=` cmdline) and `vendor_boot.img` (dtb + vendor_ramdisk_fragment pointing at the dracut initramfs) |

A device build invokes make twice in sequence: first to build `.build_kernel`, then everything else with a freshly-read `KERNEL_VERSION`. That's because the justfile reads `kernel/kernel_version.<device>` at parse time, before the kernel has been built on a fresh checkout.

Individual stages are also exposed, and take `device=` like everything else: `just build_kernel`, `just build_rootfs`, `just install_apt_packages`, `just update_kernel_modules_and_source`, `just update_initramfs`, `just build_boot_images`, `just device=lynx build_kernel`. See `just --list`.

`just clean` removes built images and sentinels for **every** device, pairing with `just all`; `just device=lynx clean` narrows it to one. It preserves the expensive kernel-build and OTA caches. `just clean_rootfs` and `just clean_kernel` follow the same rule, the latter being the separate knob for the Bazel output.

## Flashing

```shell
./flash-fastboot.sh <serial>              # device inferred from the bootloader
DEVICE=lynx ./flash-fastboot.sh <serial>  # or asserted
```

`flash-fastboot.sh` wraps flashing `boot.img` + `vendor_boot.img` + `super.img` over fastboot, with the device in the bootloader on USB. It requires an explicit serial (`$1` or `FASTBOOT_SERIAL`) because it erases `super`, and it flashes `super.img` — the full-flash image with **both** rootfs halves seeded — not `rootfs.img`, which is only one half.

It reads `build/<device>/`. With no `DEVICE=` it **asks the hardware** — `fastboot getvar product` — and uses that, so the plain form is correct for either device; set `DEVICE=` to assert an expectation instead and a mismatch aborts. felix and lynx are both gs201 and both accept these commands happily, but the images are incompatible, and this is the path that erases `super` and writes both slots. `DEVICE_CHECK=0` overrides.

**No command in this repo has a default device.** felix and lynx are equal citizens, and a default is a preference — it silently decides which device a bare command acts on. `just felix` / `just lynx` / `just all` say it for you; the whole-fleet recipes (`clean`, `clean_rootfs`, `clean_kernel`) read "unset" as *every* device, pairing with `just all`; `flash-fastboot.sh` asks the bootloader; and the single-device recipes require it, listing the known devices if you forget. The one enforcement point is the Makefile, which errors on an empty or unknown `DEVICE`.

For a device that is **already running and reachable over the network**, `flash-ssh.sh [user@]host` updates it in place over SSH instead — no fastboot, no USB. It flashes the inactive boot slot with `pixel-ota` and switches to it, then arms a rootfs reflash that the initramfs' `90rootfs-flash` **pre-mount hook** performs on the way back up — before root is mounted, and after verifying the staged image against its `sha256`/`size` sidecars. (Not a systemd shutdown pivot: `dracut-shutdown.service` is `/bin/true` on these images.) It checks the device for the `pixel-ota`/`pixel-bootctl` binaries and copies any that are missing, and stages the image on the `userdata` partition — mounting it if it isn't mounted.

On a **rootfs-A/B** image the hook writes only the active slot's half of `super`, so the other half keeps the previous rootfs and a bad image rolls back with the boot slot. On a single-rootfs image it overwrites the whole partition, which is destructive and rollback-free. Which one happens is decided by the image size, not a flag — see [rootfs A/B](#rootfs-ab) below.

For a **fleet**, `flash-nmap.sh` finds the devices first: it nmaps the given subnets for SSH, fingerprints every host that answers (board, arch, serial, image version, A/B slot, `userdata`), writes an inventory CSV, and reports which ones are really ours.

```shell
./flash-nmap.sh 10.0.0.0/24                            # survey only — the default
./flash-nmap.sh --from-version 'v7.1*' --flash 10.0.0.0/24
```

It flashes **nothing** without `--flash`. A device is a target only if it (1) authorizes our SSH key and grants it passwordless root, (2) runs our rootfs — gs201/felix device tree plus overlay-only markers — and (3) reports an `IMAGE_VERSION` matching `--from-version`. That last one is the gate that scales: you know what image the devices were built with even when you don't know their serials. `--fleet ID` additionally requires the build-time stamp in `/etc/junkyard-fleet` (`just fleet_id=… felix`). Exclusions are by serial (`--exclude-serial-file`), which is the list that stays small.

Both SSH paths **require** `DEVICE=`, and the device's own `/etc/image-device` stamp is checked against the image being shipped — the gate that stops a felix image reaching lynx hardware, which every other check would pass since lynx is also gs201.

Because the rootfs half is not rollback-safe, a run is **canaried and waved**: `--canary 3` units go first and must come back on the new version or the run stops with the rest untouched, then `--wave 25` batches, each verified by re-scanning and matching serials (a reflashed device may take a new DHCP lease). `--max-fail 10` trips a circuit breaker. Devices already on the target version are skipped, so re-running the same command converges the fleet. Logs and the inventory land in `out/flash-nmap/<timestamp>/`.

## rootfs A/B

`super` is a single 8136 MiB partition with no A/B twin — the GPT has no free space to carve one from. So it is split in software: two 4068 MiB halves, each holding a complete rootfs, with the initramfs' `90rootfs-slot` module mapping one at a time as `/dev/mapper/rootfs` via dm-linear. `boot.img`'s cmdline is `root=/dev/mapper/rootfs`, so the half that gets mapped is the one that gets mounted.

**Which half is not our decision.** The bootloader has already chosen a boot slot and reports it in `androidboot.slot_suffix`, so the rootfs slot simply follows it. That means rootfs A/B inherits the boot chain's existing machinery — same active-slot choice, same retry counter, same automatic rollback when a slot fails to boot — instead of needing a selector and a rollback policy of its own. `pixel-bootctl` is unchanged.

Two image artifacts fall out of this:

| | size | used for |
| --- | --- | --- |
| `rootfs.img` | 4000 MiB, one rootfs | an in-layout **upgrade**: write the inactive half, switch the boot slot, reboot |
| `super.img` | 8136 MiB, **both halves seeded** | the initial fastboot flash, and a network **migration** of a device still on the old single-rootfs layout |

Build the second with `just build_super_image` (it is not part of `just all` — another 8 GiB of output that only those two paths use).

Both halves are seeded rather than just slot A because the invariant worth holding is *both halves always contain something bootable*. Seeding only the half being booted leaves the other holding a fragment of the old filesystem — an ext4 superblock claiming 8100 MiB inside a 4068 MiB mapping. Nothing looks wrong: the device boots and is reachable. The damage surfaces only when an update fails its retries and the bootloader rolls back into an unmountable half, on a unit with no screen, no buttons and no physical access.

The `90rootfs-flash` hook serves both layouts and picks its target by **image size**, not by a flag: an image that fits the mapped half is an upgrade and goes to that half; anything larger is a whole-partition image and goes to `super`. Keying on "is a half mapped?" alone would get migration backwards, since the migrating device is already running the new initramfs and has a half mapped.

> ⚠ **Not yet validated on hardware.** The slot mapping, the halved write and rollback are implemented and unit-tested but have not booted a device.

## TODO

* Proper fstab
* Dedicated build machine
* Mount additional partitions by label
