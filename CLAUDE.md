# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo builds

An `android-boot.img` / `vendor_boot.img` / `rootfs.img` trio that replaces the Pixel Fold (codename **felix**, SoC gs201) stock userspace with a Debian rootfs, while keeping the stock Android kernel source + vendor blobs. `boot.img` carries the kernel, `vendor_boot.img` carries the dtb + dracut initramfs, and `rootfs.img` is an ext4 image flashed to the `super` slot as the real root fs. The trio reaches the device three ways — fastboot, SSH/OTA, or UART delta-flash (see **Flashing — three transports**).

This repo is the **substrate / dev platform**. A constellation of sibling repos under the `junkyard-computing` org drives bring-up, flashing, and fleet work against the images it produces — see **The bring-up tooling ecosystem**. The `main` branch here is the AOSP-GKI / Debian / ext4 track; the mainline gs201 kernel port lives on the `feature/linux-kernel` branch (checked out separately at `../jboot-mainline`).

## Build pipeline

The build is driven by a **Makefile with sentinel-tracked stages**; the justfile is a thin orchestration/env-setup layer that delegates to make. Reruns skip stages whose sentinels are already touched.

Sentinel chain (all live at repo root, dotfile-named): `.create_image` → `.debootstrap` → `.build_kernel` → `.install_vendor_firmware` → `.install_packages` → `.install_kernel` → `.install_initramfs` → `.build_boot`. `.sync_vendor_firmware` is a sibling sentinel that `.install_vendor_firmware` depends on. `.build_pixel_bootctl` and `.build_pixel_ota` are two more sibling sentinels that `.install_packages` depends on — they cross-compile the on-device A/B tools into the overlay (see **On-device A/B + OTA tools**).

First-time run:

```
just clone_kernel_source          # repo init + sync; ~1hr
just sync_vendor_firmware         # pull felix OTA, extract /vendor/firmware; ~2GB
just all                          # everything else
./flash-fastboot.sh
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

### Vendor firmware — required to boot at all
`sync_vendor_firmware` downloads the felix factory OTA (`_felix_ota_url`), extracts `payload.bin`, pulls only the `vendor` partition with `payload-dumper-go` (downloaded + pinned to `_payload_dumper_version`), and runs [tools/extract-partition-fs.sh](tools/extract-partition-fs.sh) to unpack it into `rootfs/vendor-firmware/extracted/`. The helper auto-detects EROFS vs ext4 and unwraps Android sparse framing via `simg2img` if needed — felix has shipped both formats across OTAs.

`.install_vendor_firmware` then rsyncs `extracted/firmware/` into `/vendor/firmware/` on the mounted sysroot. **This is mandatory**: the stock felix dtb's `/chosen/bootargs` carries `firmware_class.path=/vendor/firmware` (not something we set in boot.img's cmdline), and without `aoc.bin` the AOC coprocessor retry-loops indefinitely. The visible symptom is starved UART RX (login-prompt keystrokes get dropped). Empirically, the AOC failure also breaks the boot itself: `/dev/disk/by-partlabel/super` doesn't appear, dracut times out waiting for the rootfs, and the device drops to an emergency shell you can't type into. The exact mechanism isn't fully nailed down — plausible contributors include the firmware-loader uevent fallback tying up udev workers and AOC/GSA/ACPM sharing platform infrastructure that UFS leans on for FMP key handling (`fmp-id = <0>` in `gs201-ufs.dtsi`) — but the net "no `aoc.bin` → no boot" relationship is reproducible.

Because of that, `aoc.bin` has to be present in **both** the rootfs (where the running system finds it via `firmware_class.path`) **and** the dracut initramfs (where the same path applies during early boot, before rootfs is mounted). `.install_initramfs` declares `.install_vendor_firmware` as a prerequisite and passes `--install /vendor/firmware/aoc.bin` to dracut so the blob lands at the expected path inside the cpio. The 21M cost is bearable; without it the device won't reach login. None of the other firmware blobs (wifi, audio DSP, modem, etc.) appear to be needed in the initramfs — only AOC has been observed to block the boot path.

### Rootfs overlay
[rootfs/overlay/](rootfs/overlay/) is an `rsync -a`-ed tree applied at the end of `.install_packages`. Overlay files are Makefile dependencies of `.install_packages` (via `$(shell find rootfs/overlay -type f)`), so editing an overlay file re-triggers the package stage. Add new tracked sysroot files here rather than editing `rootfs/sysroot/` directly (the sysroot is wiped and rebuilt by `.debootstrap`). What it currently ships, by purpose:

- **Modules / kernel**: `etc/modprobe.d/blacklist.conf` (applied by running userspace — see module-loading section).
- **Console banner**: `etc/issue` (agetty `\4` → live IPv4) plus the kmscon drop-ins `kmsconvt@.service.d/override.conf` (agetty, **no autologin**) and `10-wait-network.conf` (wait for DHCP before the first `\4` render).
- **Login-time status generators** — small oneshots/timers that rewrite lines of `/etc/issue` so the console banner shows live state: `battery-issue.{service,timer}` + `usr/local/sbin/battery-issue`, `boot-slot-issue.service` + `usr/local/sbin/boot-slot-issue` (current A/B slot, via `pixel-bootctl`), and `dongle-mac-issue.service` + `99-dongle-mac-issue.rules` + `usr/local/sbin/dongle-mac-issue`.
- **A/B**: `mark-slot-successful.service` runs `pixel-bootctl mark-successful` post-boot so the bootloader's slot-retry counter never exhausts and drops to fastboot.
- **rootfs OTA hook**: `usr/lib/dracut/modules.d/90rootfs-flash/` (`module-setup.sh` + `flash-rootfs.sh`) — the in-place rootfs cutover primitive (see below).
- **Thermal**: `usr/local/sbin/thermal-thresholds` — runtime knob to raise the (AOSP-kernel) thermal-zone trip points via writable sysfs (`CONFIG_THERMAL_WRITABLE_TRIPS`), for the low felix skin backstop (56.5/58.5 °C). Volatile per boot; see [docs/thermal-thresholds.md](docs/thermal-thresholds.md). Not wired to a unit by default.
- **Misc**: `custom.service` + `usr/bin/customservice`, `usr/local/sbin/usb_gadget`, and the `10-ignore-lid.conf` logind drop-in.
- **Built binaries (gitignored)**: `usr/local/bin/pixel-bootctl` and `usr/local/bin/pixel-ota` are dropped here by the `.build_pixel_bootctl` / `.build_pixel_ota` stages, so they ride the same overlay rsync into the image.

### rootfs cutover — dracut pre-mount hook, not a shutdown pivot
The overlay's `90rootfs-flash` dracut module ([rootfs/overlay/usr/lib/dracut/modules.d/90rootfs-flash/](rootfs/overlay/usr/lib/dracut/modules.d/90rootfs-flash/)) installs a **pre-mount hook** that reflashes `super` from a staged image on `userdata` **before dracut mounts root** — at that point `super` is just a free block device, so it needs no live-root unmount and no working `dracut-shutdown.service` (which is `/bin/true` on these images). It is added to the initramfs via `dracut --add rootfs-flash` in `.install_initramfs`. Trigger protocol (set by the userspace updater, then `reboot`): stage `userdata:/pixel-ota/rootfs.img` and touch `userdata:/pixel-ota/flash-pending`; the flag is cleared before the write (write-once — a crash mid-write can't loop-flash). This dracut hook — **not** the systemd shutdown-pivot that pixel-ota's own README describes — is the mechanism that actually works on these images; the SSH flash path (below) depends on the `flash-pending` flag reaching this hook.

### Console and user accounts
Login lives on kmscon (pinned `kmscon_9.0.0-4_arm64.deb` from the Debian pool — trixie dropped the package, so `.install_packages` curls it onto the sysroot and `apt install`s it in-nspawn). The overlay's `kmsconvt@.service.d/override.conf` runs kmscon with a normal agetty (no autologin) on every VT. The unprivileged user is created in `.install_packages` via `useradd -G sudo $(USER_LOGIN)` with `USER_LOGIN`/`USER_PW` Makefile variables (defaults `kalm`/`0000`, overridable via `just all user_login=... user_password=...`). Passwordless sudo is dropped in at `/etc/sudoers.d/99-sudo-nopasswd` (mode 0440) — written inside nspawn, not via the overlay, because git can't track the 0440 mode bit. The login banner is `rootfs/overlay/etc/issue` with agetty's `\4` escape, so the prompt re-renders the current IPv4 address each time it draws. A second drop-in (`kmsconvt@.service.d/10-wait-network.conf`) pulls in `NetworkManager-wait-online.service` via `Wants=`/`After=` so the first render of `\4` actually sees a DHCP-assigned IP; on timeout (default 30s) the console comes up anyway. The same stage also masks `systemd-backlight@.service` (symlink to `/dev/null`) to keep `systemctl is-system-running` out of "degraded".

### Default network config
`.install_packages` disables `dhcpcd`, enables `NetworkManager`, and seeds `/etc/NetworkManager/system-connections/default_connection.nmconnection` via `nmcli --offline connection add` piped to a file, then chmod 600 so NM trusts it. Result: wired ethernet comes up on DHCP automatically.

### mkbootimg is a submodule
There are three git submodules (`.gitmodules`): [tools/mkbootimg](tools/mkbootimg) and the two on-device tools [tools/pixel-bootctl](tools/pixel-bootctl) + [tools/pixel-ota](tools/pixel-ota) (covered below). [tools/mkbootimg](tools/mkbootimg) is the upstream AOSP mkbootimg repo. `.build_boot` invokes its `mkbootimg.py` twice — once for `boot.img` (kernel + generic root= cmdline) and once for `vendor_boot.img` (dtb + vendor_ramdisk_fragment pointing at the dracut initramfs inside the mounted rootfs image). Header version 4, pagesize 2048.

### On-device A/B + OTA tools (built into the image)
Two Rust tools are cross-compiled to static `aarch64-unknown-linux-musl` and installed into the overlay at `/usr/local/bin/` by dedicated Makefile stages (`.build_pixel_bootctl`, `.build_pixel_ota`), so every image ships them. Source-of-truth is the two submodules above; the Makefile rebuilds when their `src/*.rs` / `Cargo.*` change. Together they are the keyless, host-PC-free, no-fastboot update path for a fleet of Debian-on-Pixel devices:

- **pixel-bootctl** — the `bootctl` / boot_control primitive for Tensor-under-Linux. Slot switching on Tensor is **keyless** (no fastboot / GSA / signing / Trusty): the real switch is the **UFS boot-LUN attribute**. Two backends, autodetected (force with `--aosp` / `--linux`): the **AOSP** backend writes the Pixel-kernel sysfs node `/sys/devices/platform/*.ufs/pixel/boot_lun_enabled` (`"1"`=A, `"2"`=B); the **mainline** backend — where that node is absent/read-only — issues a UFS `WRITE ATTRIBUTE` over `/dev/bsg/ufs-bsg0`. Subcommands: `status`; `set-active-slot <a|b>` (switch + mark target active, reboot to apply); `mark-successful` (devinfo-only, retry=7 — run from a post-boot unit so the bootloader retry counter never exhausts and drops to fastboot); `mark-unbootable` (write devinfo UNBOOTABLE + retry=0 → next reboot rolls back, the in-OS mainline→AOSP fallback used when the boot-LUN is read-only); plus `probe` / `send` Trusty-IPC diagnostics. Runs as root.
- **pixel-ota** — the `update_engine` analog. `update <dir>` flashes the **inactive** slot's boot chain (`boot, init_boot, vendor_boot, vendor_kernel_boot, dtbo, vbmeta, vbmeta_system, vbmeta_vendor, pvmfw`) from a directory of `*.img`, fits-checks each, **refuses to flash the active slot**, then calls pixel-bootctl to switch **rollback-safe** (target marked active but NOT successful — a slot that never boots burns its retry budget and the bootloader falls back). `confirm` commits after a good boot (→ `mark-successful`; a post-boot service does this automatically). `flash-rootfs <img>` arms an in-place reflash of the **single, non-slotted `super`** — **destructive and rollback-free** (the rollback-capable A/B-rootfs design is the follow-up in the submodule's `PLAN.md`). Note: pixel-ota's own README describes a systemd shutdown-pivot for this, but on these images the reflash is actually done by the overlay's `90rootfs-flash` dracut pre-mount hook keyed on a `userdata:/pixel-ota/flash-pending` flag (see "rootfs cutover" above) — the shutdown pivot is inert here.

### dtbo partition must be re-flashed — critical
The base `dtb.img` we pass to `vendor_boot.img` is only the SoC-level tree ([gs201.dtsi](kernel/source/private/devices/google/gs201/dts/gs201.dtsi)), where `serial_0`, the foldable panels, and most other felix-specific nodes are `status = "disabled"`. The felix variant overlays (`gs201-felix-*.dtbo`, packaged into `kernel/source/out/felix/dist/dtbo.img`) flip those to `status = "okay"` at boot time when the bootloader selects the variant matching the board ID. We don't bake the overlay into `vendor_boot.img`; the dtbo lives on its own `dtbo` partition.

Consequence: `fastboot flash dtbo kernel/source/out/felix/dist/dtbo.img` is mandatory, and [flash-fastboot.sh](flash-fastboot.sh) does it. Skipping it (or flashing a stock image afterward and only re-flashing our `boot`/`vendor_boot`/`super`) produces a half-configured DT where earlycon printk still reaches UART (MMIO poking, no driver needed) but `/dev/ttySAC0` never appears and the panel never lights up — the device boots to `graphical.target` but nothing interactive works.

## Flashing — three transports

The same build outputs (`boot/boot.img`, `boot/vendor_boot.img`, `boot/rootfs.img`, plus `kernel/source/out/felix/dist/dtbo.img`) reach the device three ways:

- **fastboot** — [flash-fastboot.sh](flash-fastboot.sh). Device sitting in the bootloader on USB-C. Full erase+flash of `boot` / `vendor_boot` / `dtbo` / `super` (+ `disable-verity`/`disable-verification`). The from-scratch and recovery path.
- **SSH / OTA** — [flash-ssh.sh](flash-ssh.sh). Device already booted and reachable on the network (the image ships `openssh-server`); the userspace analog of an OTA, non-interactive for fleet use. It scp+installs `pixel-bootctl`/`pixel-ota` if missing, stages `rootfs.img` onto `userdata` (`/dev/sda31` at `/userdata` — preflight FAILs if that isn't mounted, since staging must land off `super`), runs `pixel-ota update` to write+switch the inactive boot slot, then arms the rootfs reflash (stage image + `flash-pending` flag on userdata) so a single reboot's `90rootfs-flash` dracut hook writes `super`. Boot-chain half is A/B-safe; the rootfs half is destructive/rollback-free.
- **UART delta-flash** — `uartfs` (in the `uartd` sibling repo). For a mainline experiment slot with **no network**, where the serial console is the only persistent channel and fastboot would mean a human swapping the USB-C cable each cycle. Delta-flashes the boot partition in place over the console (a new `vendor_boot` is ~99% the last → KB, not MB), sha256-verified and resumable across a mid-flash reboot.

Note: **fastboot and UART share the one Type-C port** — never `reboot bootloader` mid-UART-session. Switch slots in-OS with `pixel-bootctl set-active-slot` + reboot instead.

## Sibling repos

This repo is the **substrate / dev platform**; related work lives in sibling repos under the `junkyard-computing` org, beside this one (`../<repo>`), not vendored. The ones relevant to *this* (android-GKI / Debian) track:

- **pixel-bootctl / pixel-ota** — submodules of this repo ([tools/pixel-bootctl](tools/pixel-bootctl), [tools/pixel-ota](tools/pixel-ota)); the on-device A/B + OTA tools built into every image. Covered under **On-device A/B + OTA tools** above.
- **[../tensor-tpu](../tensor-tpu)** (GitHub `pixel-finch`) — **finch**: drives the Pixel's on-SoC Edge TPU (the `janeiro` / darwinn-2.0 variant on gs201) directly from Debian, bypassing Android's closed TFLite Edge TPU runtime. It uses the **stock `edgetpu` kernel module + `gsa` firmware-auth**, so it targets *this* AOSP-kernel image; `finch load` / `version` / `timestamp` / `exec-probe` prove firmware auth, the KCI mailbox round-trip, live hardware reads, and the execution substrate.
- **[../tensor-usbdl](../tensor-usbdl)** — Go tool for Exynos **USB download (DNW)** mode: the low-level PBL/BL1 USB bootloader protocol for bricked-device recovery on Tensor. felix recoverability via this path is uncertain.
- **Home-base image stashes** — `../image`, `../new-image` are saved image trios + flash scripts (`PROVENANCE.txt` records the source commit, kernel version, and slot at capture). **[../panthor-mesa-artifacts](../panthor-mesa-artifacts)** holds the only off-phone copy of the built Panthor/Mesa G710 open-GPU userspace.

**The mainline gs201 kernel track lives on the `feature/linux-kernel` branch** (checked out separately at [../jboot-mainline](../jboot-mainline)) — a different kernel (plain-kbuild fork of mainline Linux, not AOSP Bazel) with its own diverged CLAUDE.md. Its bring-up inner loop is a UART-driven toolchain — **uartd/uartfs** (console daemon + delta-flash over the serial line), **felixprobe/hwdiff** (register-map-aware on-device probe + AOSP-oracle diff), **aospdiff** (static DT/defconfig differ), **benchctl** (unattended UART iteration harness) — used because the mainline experiment slot has no network. Those tools serve that track, not this one; they're documented in the `feature/linux-kernel` CLAUDE.md.

## Conventions

- Adding apt packages → one per line in [rootfs/packages.txt](rootfs/packages.txt) (read by the justfile at parse time and space-joined into the apt install invocation).
- Adding kconfig options → append to [kernel/custom_defconfig_mod/custom_defconfig](kernel/custom_defconfig_mod/custom_defconfig). Remember transitive deps.
- Adding sysroot files → put them under [rootfs/overlay/](rootfs/overlay/), not in `rootfs/sysroot/`.
- `kernel_version`, `rootfs/module_order.txt`, `rootfs/sysroot/`, `rootfs/unpack/`, `boot/*.img`, and all sentinel dotfiles (`.create_image`, `.debootstrap`, etc.) are gitignored build artifacts.
- `clone_kernel_source`'s `android_kernel_branch` argument is pinned to `android-gs-felix-6.1-android16` because the earlier android14 branch was deleted upstream. Changing the branch requires rebuilding kernel + rootfs modules in lockstep.
- `just clean_rootfs` removes the image and per-stage sentinels; `.build_kernel` and `.sync_vendor_firmware` sentinels are preserved because they're expensive (~1hr kernel build, ~2GB OTA download). `just clean_kernel` is a separate knob.

## Build-host prerequisites

Beyond the obvious `just`, `repo`, `qemu-user-static`: `make`, `e2fsprogs` (for `mkfs.ext4`), `rsync`, `debootstrap`, `systemd-container` (for `systemd-nspawn`), `curl`, `unzip`, `xxd`. `erofs-utils` and `android-sdk-libsparse-utils` are optional and only kick in if a future felix OTA ships the vendor partition in those formats.
