.PHONY: all clean clean_image stamp_version install_arm_blobs print-%

# This Makefile is driven by the justfile; most variables come in via env.
# Targets with a leading "." are sentinel files that track whether a stage has
# completed successfully, so reruns skip already-finished work.

# ═══ DEVICE SELECTION ════════════════════════════════════════════════════════
#
# Which gs201 Pixel this build targets. Selects the per-device config fragment
# (kernel branch, Bazel target/config, vendor-firmware OTA, super size, hostname).
# Default felix, so a bare `make` / `just all` behaves exactly as it did before
# the multi-device split. `make ... DEVICE=lynx` (or `just device=lynx all`)
# builds the other one.
#
# DEVICE is also STAMPED INTO THE IMAGE (/etc/image-device, and IMAGE_DEVICE in
# os-release) by stamp_version, and flash-nmap.sh refuses to write an image to a
# device whose stamp disagrees. That gate matters specifically because lynx is
# ALSO gs201 — `//private/devices/google/lynx:gs201_lynx_dist` — so flash-nmap's
# device-tree match (default 'felix|gs201') accepts a lynx device just as happily
# as a felix one, and IMAGE_VERSION is derived from the commit and kernel, so two
# images built from ONE commit for TWO devices are byte-identical in every other
# field the tool compares. The images are genuinely incompatible (different
# kernel branch, different vendor firmware), and a MIGRATION writes the whole
# partition and destroys both halves before anything can reject it. See the
# IMAGE_DEVICE stamp in stamp_version.
# ★ NO DEFAULT, deliberately. felix and lynx are equal citizens, and a default is
# a preference: it silently decides which device a bare command acts on. An
# unnoticed default costs an hour of rebuild at best, and writes the wrong
# device's image to real hardware at worst. `just felix` / `just lynx` / `just
# all` supply it; anything else must say so.
#
# This is the single enforcement point — the justfile passes DEVICE= through on
# every make call, so a `just mount_rootfs` with no device stops here rather than
# quietly operating on build//.
ifeq ($(strip $(DEVICE)),)
$(error DEVICE is not set. Use `just felix` / `just lynx` / `just all`, or pass DEVICE=<device> (known: $(patsubst devices/%.mk,%,$(wildcard devices/*.mk))))
endif
ifeq ($(wildcard devices/$(DEVICE).mk),)
$(error unknown DEVICE '$(DEVICE)' — no devices/$(DEVICE).mk (known: $(patsubst devices/%.mk,%,$(wildcard devices/*.mk))))
endif
include devices/$(DEVICE).mk

# All per-device build artifacts — sentinels, rootfs.img, super.img, boot images,
# the extracted vendor firmware, the module-order list and the kernel-staging
# unpack tree — live under here, so felix and lynx never clobber each other and
# switching between them is incremental. The expensive caches are per-device too:
# the ~1hr kernel build lands in out/$(BAZEL_CONFIG)/dist and the ~2GB OTA under
# $(BUILD_DIR)/vendor-firmware/. `build/` is gitignored.
BUILD_DIR := build/$(DEVICE)

# Per-device sentinel paths. .build_pixel_bootctl / .build_pixel_ota stay at the
# repo root (see below) because they are device-agnostic gs201 binaries — one
# build feeds both devices' overlay.
S_PATCH  := $(BUILD_DIR)/.apply_kernel_patches
S_CREATE := $(BUILD_DIR)/.create_image
S_DEBOOT := $(BUILD_DIR)/.debootstrap
S_KERNEL := $(BUILD_DIR)/.build_kernel
S_SYNCFW := $(BUILD_DIR)/.sync_vendor_firmware
S_INSTFW := $(BUILD_DIR)/.install_vendor_firmware
S_PKGS   := $(BUILD_DIR)/.install_packages
S_INSTK  := $(BUILD_DIR)/.install_kernel
S_INITRD := $(BUILD_DIR)/.install_initramfs
S_BOOT   := $(BUILD_DIR)/.build_boot

RELEASE ?= trixie
ROOT_PW ?= 0000
USER_LOGIN ?= kalm
USER_PW ?= 0000
# HOSTNAME, SIZE and SUPER_BYTES come from devices/$(DEVICE).mk — see the fragment
# for each. The justfile passes them on the command line only when overridden.
# Public SSH keys baked into the image for $(USER_LOGIN), one per line.
#
# ★ This is not a convenience — without it the OTA path destroys its own access.
# The rootfs cutover replaces the WHOLE filesystem, so any key added by hand on a
# running device is gone the moment that device is updated. Observed on
# 35071FDHS0017C (2026-08-04): the OTA succeeded and the unit came back rejecting
# our key ("Permission denied (publickey,password)"), leaving it password-only.
# flash-ssh.sh authenticates with BatchMode key auth, so such a device can be
# updated exactly ONCE and never again over the network. On fielded units — no
# screen, no buttons, no battery, network-only — that is unrecoverable remotely.
#
# Keys must therefore come from the IMAGE, not from the device. Deliberately an
# explicit file rather than a scrape of the builder's ~/.ssh/*.pub: which key can
# log into a fleet is not something a build should infer from whoever ran it.
SSH_AUTHORIZED_KEYS ?= rootfs/authorized_keys
# kmscon isn't in trixie, so we fetch the arm64 .deb out of the Debian archive.
# The plain pool path (ftp.*/debian/pool/...) gets purged once a package is
# superseded, so we use snapshot.debian.org's permanent content-addressed
# /file/<sha1> URL and verify the download against KMSCON_SHA256, so a
# wrong/corrupt fetch fails the build instead of installing a surprise kmscon.
# The pin is (re)generated by `just update_snapshot` into rootfs/kmscon.env,
# included here; the ?= values are the committed fallback so a fresh checkout
# still builds if that file is absent.
-include rootfs/kmscon.env
KMSCON_URL ?= https://snapshot.debian.org/file/19dae225043718dfcbf02b50a7fcbedbfe4ab262
KMSCON_SHA256 ?= 5a200898513a82cac4f9262f7c20fe4b2bfc6d1d57045ab5f7d9ee0b9ca07a4f
# SYSROOT_DIR is the MOUNTPOINT, not content, so it is deliberately shared
# between devices: only one device's $(ROOTFS_IMG) is ever mounted there at a
# time, and the content all lives in that per-device image.
SYSROOT_DIR ?= rootfs/sysroot

# One `repo` checkout PER DEVICE, each pinned to its own manifest branch
# ($(KERNEL_BRANCH) from the device fragment).
#
# ★ Why not one shared tree: `repo init -b <branch>` + `repo sync` is how the
# branch is selected, and a sync reverts EVERYTHING under the tree — including
# the kernel/patches/ content, which is the whole reason .apply_kernel_patches
# exists. A shared tree would therefore have to re-init and re-sync on every
# switch between devices, so building both could never be a cheap no-op rerun,
# and any uncommitted kernel work would be reverted twice per `just all`.
# Separate trees cost ~22 GB each and make each device's kernel independent.
KERNEL_SOURCE_DIR := kernel/source-$(DEVICE)
# Bazel builds into out/<config>/dist; BAZEL_CONFIG comes from the device
# fragment. `:=` rather than `?=` so it always tracks $(DEVICE) even if the
# justfile leaves a stale KERNEL_BUILD_DIR in the environment.
KERNEL_BUILD_DIR := $(KERNEL_SOURCE_DIR)/out/$(BAZEL_CONFIG)/dist
# Per-device, because the two devices build different kernel branches and every
# /lib/modules/<ver>/ path downstream keys on this value. Kept under kernel/
# rather than $(BUILD_DIR) because the justfile reads it at PARSE time, before
# any recipe (and therefore before $(BUILD_DIR)) exists. Gitignored.
KERNEL_VERSION_FILE := kernel/kernel_version.$(DEVICE)
APT_PACKAGES_FILE ?= rootfs/packages.txt

# Sysroot-relative paths retired from rootfs/overlay/. See the rm -f in
# .install_packages for why deleting an overlay file is not enough on its own.
RETIRED_OVERLAY_PATHS ?= \
	usr/local/sbin/slot-autocommit \
	etc/systemd/system/slot-autocommit.service \
	etc/systemd/system/multi-user.target.wants/slot-autocommit.service \
	etc/systemd/system/multi-user.target.wants/netcheck-recover.service \
	etc/systemd/system/multi-user.target.wants/mark-slot-successful.service
# Per-device: this list is composed from THIS device's kernel staging archives
# and is consumed by dracut --force-drivers. Sharing one path between devices
# lets a lynx build leave a lynx module list behind that a later felix
# .install_initramfs (re-triggered by, say, an overlay edit, without
# .install_kernel re-running) would force-load into a felix initramfs.
MODULE_ORDER_PATH := $(BUILD_DIR)/module_order.txt
# Kernel module/header staging is unpacked here. Per-device for the same reason:
# tar overlays and never deletes, so a shared tree mixes two kernels' modules.
UNPACK_DIR := $(BUILD_DIR)/unpack
ROOTFS_IMG := $(BUILD_DIR)/rootfs.img
BOOT_IMG := $(BUILD_DIR)/boot.img
VENDOR_BOOT_IMG := $(BUILD_DIR)/vendor_boot.img

# ═══ FULL-FLASH IMAGE (`super.img`) ══════════════════════════════════════════
#
# `rootfs.img` is ONE rootfs, sized to fit one half of `super`. `super.img` is the
# whole partition with BOTH halves seeded from it.
#
# Two artifacts because there are two different operations:
#
#   rootfs.img  ->  an in-layout upgrade: write the INACTIVE half while running,
#                   switch the boot slot, reboot. Nothing is mounted on that half,
#                   so this needs no initramfs involvement at all.
#   super.img   ->  establishing or re-establishing the layout: the initial
#                   fastboot flash, and a network MIGRATION of a device that is
#                   still on the old single-rootfs `super`. Both rewrite the whole
#                   partition, which for a running device means the pre-mount hook,
#                   because the live root is inside what is being overwritten.
#
# ★ Why both halves are seeded rather than just half A: the invariant that makes
# rootfs A/B worth having is "both halves always contain something bootable". If a
# migration seeded only the half it boots into, the OTHER half would still hold a
# fragment of the old 8100 MiB filesystem — an ext4 superblock claiming 8100 MiB
# inside a 4068 MiB mapping. The device comes up fine, so nothing looks wrong,
# and the damage only surfaces when the new image fails its retries and the
# bootloader rolls back into an unmountable half. That is a brick on a unit whose
# defining property is that nobody can reach it. Seeding both costs one extra
# 4068 MiB write, once, and makes the first real upgrade rollback-safe.
#
# ⚠ SUPER_BYTES must match the TARGET device, not the build host. It comes from
# devices/$(DEVICE).mk. The initramfs halves the REAL device at runtime, so a
# wrong value here does not corrupt anything — it produces an image that does not
# line up with the mapping, which the hook's fit check then rejects.
#
# Measured on both devices so far: felix and lynx are byte-identical at
# 0x1FC800000 = 8136 MiB exactly. That coincidence is NOT a licence to hardcode
# it — it stays per-device because a third gs201 Pixel need not match.
SUPER_IMG := $(BUILD_DIR)/super.img
# Half, 4K-aligned exactly as rootfs-slot.sh computes it (sectors/2, minus %8).
SUPER_HALF_BYTES := $(shell echo $$(( ( ($(SUPER_BYTES)/512/2) - ($(SUPER_BYTES)/512/2) % 8 ) * 512 )))
MKBOOTIMG ?= tools/mkbootimg/mkbootimg.py
# ABSOLUTE, deliberately: .build_kernel does `cd $(KERNEL_SOURCE_DIR); $(BAZEL)`,
# so a path relative to the repo root stops resolving the moment we cd into the
# tree. This used to work by accident — the justfile exported BAZEL as an
# absolute path, overriding the Makefile's relative `?=` default. That export is
# gone (the layout is derived from $(DEVICE) here now), so the absoluteness has
# to be stated rather than inherited.
BAZEL := $(abspath $(KERNEL_SOURCE_DIR))/tools/bazel
OVERLAY_DIR ?= rootfs/overlay
# Per-device: each device's OTA supplies its own /vendor/firmware. Also keeps the
# ~2GB download cached per-device, so switching back and forth doesn't re-fetch.
VENDOR_FIRMWARE_STAGE := $(BUILD_DIR)/vendor-firmware/extracted

# ARM NDA GPU userland blobs (Mali Vulkan + OpenCL). Committed only as an
# age-encrypted, rootfs-rooted overlay tarball, encrypted to every pubkey in
# $(ARM_RECIPIENTS); tools/arm-blobs.sh decrypts (with the builder's own SSH
# key) and installs it. Not a recipient / no key / blob absent => warning, not a
# build failure. See secrets/README.md. ARM_NDA_KEY optionally pins a specific
# identity (private key) file; empty => fall back to the builder's ~/.ssh keys.
SECRETS_DIR ?= secrets
ARM_BLOBS_ENC ?= $(SECRETS_DIR)/arm-mali-blobs.tar.age
ARM_RECIPIENTS ?= $(SECRETS_DIR)/recipients.txt
ARM_NDA_KEY ?=
ARM_BLOBS_SCRIPT ?= tools/arm-blobs.sh

OVERLAY_FILES := $(shell find $(OVERLAY_DIR) -type f 2>/dev/null)

# Pre-built static aarch64-musl binary copied into the overlay tree by
# .build_pixel_bootctl. Source-of-truth lives in the tools/pixel-bootctl
# submodule (github.com/junkyard-computing/pixel-bootctl, the rescoped
# pixel-devinfo). Used by the mark-slot-successful systemd unit (via
# `pixel-bootctl mark-successful`) to clear the bootloader's slot retry
# counter so the device doesn't fall into fastboot after a few boots.
# Static musl => no dynamic loader / glibc dependency, so the binary runs
# unchanged on the Debian rootfs (a glibc cross-build baked a build-host
# ld-linux path and failed to exec on-device with 203/EXEC).
PIXEL_BOOTCTL_DIR ?= tools/pixel-bootctl
PIXEL_BOOTCTL_TARGET ?= aarch64-unknown-linux-musl
PIXEL_BOOTCTL_BIN ?= $(PIXEL_BOOTCTL_DIR)/target/$(PIXEL_BOOTCTL_TARGET)/release/pixel-bootctl
PIXEL_BOOTCTL_OVERLAY ?= $(OVERLAY_DIR)/usr/local/bin/pixel-bootctl
PIXEL_BOOTCTL_SOURCES := $(wildcard $(PIXEL_BOOTCTL_DIR)/Cargo.toml $(PIXEL_BOOTCTL_DIR)/Cargo.lock $(PIXEL_BOOTCTL_DIR)/src/*.rs)

# pixel-ota: same static aarch64-musl cross-build as pixel-bootctl (shares
# PIXEL_BOOTCTL_TARGET), installed into the overlay so every built image ships
# it. It used to be source-only — flash-ssh.sh required a manual cross-build —
# but it is an on-device tool (`pixel-ota update` / `flash-rootfs` run over SSH),
# so baking it into the rootfs is the same treatment pixel-bootctl gets. Source-
# of-truth is the tools/pixel-ota submodule.
PIXEL_OTA_DIR ?= tools/pixel-ota
PIXEL_OTA_BIN ?= $(PIXEL_OTA_DIR)/target/$(PIXEL_BOOTCTL_TARGET)/release/pixel-ota
PIXEL_OTA_OVERLAY ?= $(OVERLAY_DIR)/usr/local/bin/pixel-ota
PIXEL_OTA_SOURCES := $(wildcard $(PIXEL_OTA_DIR)/Cargo.toml $(PIXEL_OTA_DIR)/Cargo.lock $(PIXEL_OTA_DIR)/src/*.rs)

# Debian archive pin. rootfs/debian_snapshot holds a snapshot.debian.org
# timestamp (managed by `just update_snapshot`); pinning the mirror is what
# makes a given IMAGE_VERSION reproducible. An empty pin leaves MIRROR empty,
# so debootstrap falls back to its default (live) mirror — a fresh checkout
# without a pin still builds.
SNAPSHOT ?= $(shell cat rootfs/debian_snapshot 2>/dev/null)
MIRROR ?= $(if $(SNAPSHOT),https://snapshot.debian.org/archive/debian/$(SNAPSHOT)/,)

# Image version string for /etc/os-release + the login banner. version.txt holds
# the human-bumped number (managed by release-please); the git short hash (and
# -dirty marker) pin it to a build. BUILD_DATE is informational — the snapshot
# pin above is the actual reproducibility anchor, not the build date.
#
# The kernel version is folded in (+k<ver>) because experiments here vary the
# KERNEL, and the stamp's whole job is to let two phones be told apart by what
# they actually run. A commit-only stamp can't distinguish two kernel variants
# built from the same tree state; binding the kernel string closes that.
#
# Provenance is RECOMPUTED, NEVER CACHED: the stamp is a *description of the
# result*, not a build stage. It is written by the PHONY `stamp_version` target
# (no sentinel; `just all` runs it after .build_boot) so it re-runs on every
# build and can never go stale relative to the kernel/commit/tree — the failure
# that previously let kernel changes ship under an old version string.
IMAGE_BASE_VERSION := $(shell cat version.txt 2>/dev/null || echo 0.0.0)
GIT_REV := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
GIT_DIRTY := $(shell test -n "$$(git status --porcelain 2>/dev/null)" && echo -dirty)
IMAGE_VERSION ?= $(IMAGE_BASE_VERSION)-g$(GIT_REV)$(GIT_DIRTY)$(if $(KERNEL_VERSION),+k$(KERNEL_VERSION),)
BUILD_DATE ?= $(shell date -u +%Y-%m-%d)

# Fleet stamp: an explicit, build-time answer to "is this device one of ours?".
# IMAGE_VERSION already identifies WHAT a device runs, which is what flash-nmap.sh
# keys on by default (`--from-version`), but that string necessarily changes with
# every build — so it cannot also say WHOSE the device is. FLEET_ID is the stable
# half: set it (e.g. `just all fleet_id=krg-lab`) and every image carries
# /etc/junkyard-fleet, which `flash-nmap.sh --fleet krg-lab` requires before it
# will write to a device. Matters when two fleets of our own images share a
# network — the version filter alone cannot separate those. Empty by default: no
# variable set, no file, and the marker-count identity check still applies.
FLEET_ID ?=

# NOTE: DEVICE is defined at the top of this file, where it also selects
# devices/$(DEVICE).mk. It is stamped into the image by stamp_version — see the
# DEVICE SELECTION block for why that stamp is what stops a felix image being
# written to lynx hardware.

# Wrap nspawn invocations through tools/nspawn-wrap.sh so each one starts
# from a known-good sysroot/dev (no leftover mounts, no stale /dev/pts).
# See the script header for the systemd >= 260 specifics that motivate it.
# Trailing `--` separates the wrapper's sysroot arg from the nspawn argv.
NSPAWN_WRAP := sudo tools/nspawn-wrap.sh $(SYSROOT_DIR) --
# --resolv-conf=bind-host overrides the container's /etc/resolv.conf for the
# lifetime of the nspawn session. Packages.txt installs systemd-resolved,
# whose postinst points /etc/resolv.conf at a stub that only resolves when
# systemd-resolved is running (it isn't, under nspawn). Without this flag,
# any nspawn call after that postinst loses DNS, including reruns.
NSPAWN := $(NSPAWN_WRAP) --resolv-conf=bind-host

# Running `make` directly bypasses the env vars set by the justfile (notably
# KERNEL_VERSION, which is read from kernel/kernel_version). Always go through
# `just all` so those are in scope.
all:
	@echo "Use 'just all' instead so KERNEL_VERSION and friends are exported."
	@just --list

# Report a variable's resolved value, e.g. `make print-ROOTFS_IMG DEVICE=lynx`.
# The justfile uses this so it never has to re-derive the build layout.
print-%:
	@echo "$($*)"

# Friendly stage names. The REAL targets are the per-device sentinel paths
# ($(BUILD_DIR)/.build_boot and friends), but `make .build_boot DEVICE=lynx` is
# what the justfile invokes and what everyone types by hand, so keep the short
# names working as phony aliases.
#
# .PHONY matters here beyond the usual reason: a pre-split checkout still has
# real, empty `.build_boot`-style files sitting in the repo root. Without PHONY,
# make would see those as up-to-date targets and do nothing at all — silently
# skipping the entire build, which is precisely the class of failure the sentinel
# comments elsewhere in this file keep warning about. (`just migrate` relocates
# them, but this must not depend on that having been run.)
.PHONY: .create_image .debootstrap .apply_kernel_patches .build_kernel \
        .sync_vendor_firmware .install_vendor_firmware .install_packages \
        .install_kernel .install_initramfs .build_boot
.create_image:            $(S_CREATE)
.debootstrap:             $(S_DEBOOT)
.apply_kernel_patches:    $(S_PATCH)
.build_kernel:            $(S_KERNEL)
.sync_vendor_firmware:    $(S_SYNCFW)
.install_vendor_firmware: $(S_INSTFW)
.install_packages:        $(S_PKGS)
.install_kernel:          $(S_INSTK)
.install_initramfs:       $(S_INITRD)
.build_boot:              $(S_BOOT)

# The per-device artifact directory, an ORDER-ONLY prerequisite (the `|`) of
# every sentinel below.
#
# Order-only, not normal: a directory's mtime changes every time a file is added
# to it, so a normal prerequisite would make each finished stage look older than
# its own output directory and re-trigger the whole chain on the next run.
#
# And on EVERY sentinel, not just the first. `mkdir -p` used to live in the
# .create_image recipe alone, but .apply_kernel_patches does not depend on
# .create_image — the kernel and rootfs halves of the graph are independent — so
# on a device with no build/<device>/ yet, the first thing to run was
#     touch: cannot touch 'build/lynx/.apply_kernel_patches': No such file or directory
# felix never hit it because `just migrate` had already created build/felix/.
$(BUILD_DIR):
	mkdir -p $@

$(S_CREATE): | $(BUILD_DIR)
	mkdir -p $(SYSROOT_DIR)
	# Use truncate, not fallocate: truncate makes a sparse file (8100M nominal but
	# only the written blocks occupy host disk; `just trim_rootfs` keeps it that
	# way), whereas fallocate would reserve the full size upfront. Sparse is fine
	# for mkfs.ext4 + fastboot.
	sudo truncate -s $(SIZE) $(ROOTFS_IMG)
	sudo mkfs.ext4 -F -L rootfs $(ROOTFS_IMG)
	touch $@

$(S_DEBOOT): $(S_CREATE) | $(BUILD_DIR)
	# ★ START FROM AN EMPTY FILESYSTEM, ALWAYS.
	#
	# debootstrap's first stage unpacks each .deb with plain `tar`, which does
	# NOT overwrite. Run it over a sysroot that already has content and it dies:
	#     tar: ./etc/apt/apt.conf.d/01autoremove: Cannot open: File exists
	#     E: Tried to extract package, but tar failed.
	#
	# So ANY interrupted debootstrap — a dropped connection to the (slow,
	# rate-limited) snapshot mirror, a Ctrl-C, a failure in this recipe after the
	# unpack — leaves the image populated but the sentinel unwritten. Every retry
	# then fails on the FIRST package, with an error naming tar rather than the
	# actual problem, and the only cure was `just clean_rootfs` — which nothing
	# told you about. Measured on the first lynx bring-up.
	#
	# mkfs is cheap here (the image is sparse and nothing but debootstrap owns
	# this filesystem), and it makes the stage genuinely re-runnable. Unmount
	# first: mkfs on a mounted image would corrupt it.
	just device=$(DEVICE) unmount_rootfs
	sudo mkfs.ext4 -F -L rootfs $(ROOTFS_IMG)
	just device=$(DEVICE) mount_rootfs
	# Trailing $(MIRROR) pins the archive to the snapshot.debian.org timestamp
	# in rootfs/debian_snapshot; empty MIRROR => debootstrap's default mirror.
	# --components: debootstrap defaults to `main` only, and writes the
	# components it actually fetched into the sysroot's /etc/apt/sources.list.
	# firmware-realtek (the r8152 dongle's errata patch — mandatory, see the
	# network section of CLAUDE.md) ships in non-free-firmware, so it has to be
	# enabled here or apt reports "no installation candidate".
	sudo debootstrap --variant=minbase --components=main,non-free-firmware --include=symlinks --arch=arm64 --foreign $(RELEASE) $(SYSROOT_DIR) $(MIRROR)
	# nixpkgs heavily patches debootstrap: both the shebang AND in-script
	# references to dpkg/chroot/unshare are rewritten to absolute /nix/store
	# paths. --foreign copies the host script verbatim into sysroot, so
	# inside the nspawn container those paths don't exist and the script
	# either fails to exec or silently dies on `set -e` when the first
	# nix-store binary is invoked. Rewrite both:
	#   - line 1 (shebang): /nix/store/<hash>/bin/bash → /bin/bash
	#   - lines 2..: strip /nix/store/<hash>/bin/ entirely so PATH lookup
	#     resolves the (container's own) dpkg, chroot (/usr/sbin), unshare.
	# No-op on non-Nix hosts (the upstream debootstrap has no /nix/store
	# references at all).
	sudo sed -i \
		-e '1s|^#!/nix/store/[^/]*/bin/|#!/bin/|' \
		-e '2,$$s|/nix/store/[^/]*/bin/||g' \
		$(SYSROOT_DIR)/debootstrap/debootstrap
	$(NSPAWN_WRAP) -D $(SYSROOT_DIR) debootstrap/debootstrap --second-stage
	$(NSPAWN_WRAP) -D $(SYSROOT_DIR) symlinks -cr .
	$(NSPAWN_WRAP) -D $(SYSROOT_DIR) sh -c "echo root:$(ROOT_PW) | chpasswd"
	$(NSPAWN_WRAP) -D $(SYSROOT_DIR) sh -c "echo $(HOSTNAME) > /etc/hostname"
	just device=$(DEVICE) unmount_rootfs
	touch $@

# Must build inside the flake's FHS shell so kleaf's host tools (python3, perl, bash,
# rsync) resolve and Bazel's server starts in the FHS mount namespace:
#   nix run .#bazel-fhs -- -c 'just build_kernel'
# --config=local is kleaf's "reduce sandboxes" mode (build/kernel/kleaf/docs/sandbox.md):
# it runs the in-tree kernel_build/kernel_config actions locally (per-target cache dirs)
# while keeping modules_install/dtbo/uapi/abi actions sandboxed. This is what makes
# --config=use_source_tree_aosp (in-tree GKI build) work on NixOS. Do NOT replace it with
# a blanket --spawn_strategy=local: that forces the sandbox-required actions to run local
# and they abort with "FATAL: this action must be executed in a sandbox!".
# NOTE: per the kleaf docs, run `tools/bazel clean` if you change --strategy/--config,
# else stale cached action outputs cause confusing failures.
# Apply the tree patches under kernel/patches/ to the repo-managed checkout.
#
# WHY THIS STAGE EXISTS: `kernel/source/` is a `repo` checkout whose .gitignore
# ignores everything, so nothing edited in there is tracked by this repo. A
# `repo sync` / fresh `clone_kernel_source` silently reverts local kernel edits
# and the build then succeeds against the UNPATCHED tree with no error at all —
# the same silent-degradation shape as the sentinel and gitlink traps elsewhere
# in this file. Kconfig already survives syncs via custom_defconfig_mod; device
# tree and source changes had no such mechanism, so they live here as patches.
#
# LAYOUT: kernel/patches/<repo-project-path>/NNNN-*.patch, e.g.
#   kernel/patches/private/devices/google/gs201/0001-....patch
# `repo` makes each project its own git, so a single `git apply` cannot span
# them; the directory under kernel/patches/ names the project the patch applies
# inside, and each patch is -p1 relative to that project root.
#
# IDEMPOTENT + FAIL-LOUD: already-applied patches are detected with
# `git apply --check --reverse` and skipped, so re-running is safe. A patch that
# neither applies nor is already applied ABORTS the build — a kernel patch that
# silently no-ops is exactly what this stage exists to prevent.
# NOTE the -path prune: kernel/patches/rejected/ holds patches that were built,
# flashed and MEASURED not to work. They are kept as documentation so nobody
# re-derives them, and they must NOT be applied. Without this exclusion the
# stage derives a project path of "kernel/source/rejected", which does not
# exist, and aborts the whole build.
PATCH_FILES := $(shell find kernel/patches -path kernel/patches/rejected -prune -o -name '*.patch' -print 2>/dev/null | sort)

$(S_PATCH): $(PATCH_FILES) | $(BUILD_DIR)
	# Decide whether the patched files may be hidden from git's dirty check.
	#
	# `-dirty` should mean "there is uncommitted work in this kernel", NOT "a patch
	# was applied". The patches under kernel/patches/ are tracked, reviewed content
	# that every build applies, so a tree that differs from HEAD by exactly the
	# patch set is not drifting and should keep a clean version string. That
	# matters beyond tidiness: `-dirty` renames every /lib/modules/<ver>/ path, so
	# a boot-only flash against an existing rootfs finds no modules at all — no
	# dongle, no network, which is how slot B was bricked once already.
	#
	# The previous version of this stanza hid the patched files UNCONDITIONALLY,
	# which bought that stability by making the kernel lie: real uncommitted work
	# was hidden right alongside the patches. tools/kernel-drift.sh tells the two
	# apart (see that file for why each test is needed and why the check must clear
	# --assume-unchanged itself before measuring anything).
	#
	#   clean (0) — tree == HEAD + our patches. Hide them; version stays clean.
	#   dirty (1) — extra uncommitted work in the kernel project. Leave them
	#               visible so setlocalversion stamps an honest -dirty.
	#   fatal (2) — drift that CANNOT reach the version string: another project
	#               (they feed modules, not the version) or an untracked file
	#               (setlocalversion's check is -uno). Refuse to build rather than
	#               emit an image whose contents no version identifies.
	#
	# Nothing here writes .scmversion: kleaf supplies "-android14-11-g8769cc47188c"
	# by its own mechanism and APPENDS .scmversion on top, producing a string that
	# blows the 64-character limit. A local commit is no good either — it moves the
	# SHA, which is the thing being kept stable.
	@set -e; \
	verdict=$$(tools/kernel-drift.sh $(KERNEL_SOURCE_DIR) $(PATCH_FILES)) || true; \
	case "$$verdict" in \
	clean) \
		for p in $(PATCH_FILES); do \
			rel=$${p#kernel/patches/}; proj=$$(dirname "$$rel"); \
			tgt="$(KERNEL_SOURCE_DIR)/$$proj"; \
			[ -d "$$tgt" ] || continue; \
			grep -oE '^\+\+\+ b/[^[:space:]]+' "$$p" | sed 's|^+++ b/||' | while read -r f; do \
				( cd "$$tgt" && git update-index --assume-unchanged "$$f" 2>/dev/null ) || true; \
			done; \
		done; \
		echo "kernel tree == HEAD + patches: version string stays clean"; \
		;; \
	dirty) \
		echo "kernel tree has uncommitted work beyond our patches — building -dirty."; \
		echo "  /lib/modules/<ver> will change, so a boot-only flash is NOT valid:"; \
		echo "  rebuild modules + initramfs and do a full rootfs cutover."; \
		;; \
	*) \
		echo "ERROR: kernel drift cannot be recorded in the version string (see above)."; \
		exit 1; \
		;; \
	esac
	@set -e; \
	if [ -z "$(PATCH_FILES)" ]; then \
		echo "No kernel patches to apply."; \
	fi; \
	for p in $(PATCH_FILES); do \
		abs=$$(readlink -f "$$p"); \
		rel=$${p#kernel/patches/}; \
		proj=$$(dirname "$$rel"); \
		tgt="$(KERNEL_SOURCE_DIR)/$$proj"; \
		if [ ! -d "$$tgt" ]; then \
			echo "ERROR: patch target project missing: $$tgt"; \
			echo "       (run 'just clone_kernel_source' first)"; \
			exit 1; \
		fi; \
		if (cd "$$tgt" && git apply --check --reverse "$$abs" >/dev/null 2>&1); then \
			echo "already applied: $$rel"; \
		elif (cd "$$tgt" && git apply --check "$$abs" >/dev/null 2>&1); then \
			(cd "$$tgt" && git apply "$$abs"); \
			echo "APPLIED: $$rel"; \
		else \
			echo "ERROR: $$rel does not apply to $$tgt and is not already applied."; \
			echo "       The kernel tree may have moved; refresh the patch."; \
			exit 1; \
		fi; \
	done
	touch $@

$(S_KERNEL): $(S_PATCH) kernel/custom_defconfig_mod/BUILD.bazel kernel/custom_defconfig_mod/custom_defconfig | $(BUILD_DIR)
	cd $(KERNEL_SOURCE_DIR); $(BAZEL) run \
		--config=use_source_tree_aosp \
		--config=stamp \
		--config=$(BAZEL_CONFIG) \
		--config=local \
		--defconfig_fragment=//custom_defconfig_mod:custom_defconfig \
		$(BAZEL_TARGET)
	@echo "Updating kernel version string"
	# Derive KERNEL_VERSION from the module staging archive, NOT from `strings Image`.
	#
	# The old form was:
	#     strings $(KERNEL_BUILD_DIR)/Image | grep "Linux version" | head -n1 | awk '{print $$3}' > kernel/kernel_version
	# and it BLANKS the file silently:
	#     `strings` (binutils) is not present in every build environment used
	#     here. In a pipeline a missing `strings` still leaves the exit status
	#     of `awk` (0), so make sees SUCCESS while `>` truncates the file.
	#
	# CORRECTION (2026-08-04): an earlier version of this comment also blamed
	# `Image` being "an arm64 EFI zboot (compressed) image with no Linux
	# version banner". THAT WAS WRONG. Every arm64 Image carries an MZ header
	# for the EFI stub — MZ magic does NOT imply zboot compression. This Image
	# is uncompressed and greppable:
	#     grep -ac 'Linux version' Image   -> 2
	#     grep -ao 'Linux version [^ ]*'   -> Linux version 6.1.124-...-dirty
	# The missing binutils was the whole cause. Keep the archive-based method
	# anyway: it has no binutils dependency and cannot disagree with the
	# directory the modules actually install into.
	# Either way kernel/kernel_version becomes EMPTY, every downstream path
	# becomes `lib/modules//...`, and the build dies two stages later in
	# .install_kernel with a confusing "modules.order: No such file" — after
	# `find $(SYSROOT_DIR)/lib/modules/ -name '*.ko' -delete` has already run
	# against the whole module tree.
	#
	# The staging archive is the right source: it is the same artifact
	# .install_kernel unpacks, so the version can never disagree with the
	# directory the modules actually land in. No binutils dependency.
	@KVER=$$(tar tzf $(KERNEL_BUILD_DIR)/vendor_dlkm_staging_archive.tar.gz 2>/dev/null \
	           | grep -oE 'lib/modules/[^/]+' | head -n 1 | cut -d/ -f3); \
	if [ -z "$$KVER" ]; then \
		echo "ERROR: could not determine kernel version from vendor_dlkm_staging_archive.tar.gz"; \
		echo "       REFUSING to blank $(KERNEL_VERSION_FILE) (an empty value breaks"; \
		echo "       every /lib/modules/<ver>/ path and wipes the module tree)."; \
		exit 1; \
	fi; \
	echo "  kernel version: $$KVER"; \
	printf '%s\n' "$$KVER" > $(KERNEL_VERSION_FILE)
	touch $@

$(S_SYNCFW): | $(BUILD_DIR)
	just device=$(DEVICE) sync_vendor_firmware
	touch $@

$(S_INSTFW): $(S_DEBOOT) $(S_SYNCFW) | $(BUILD_DIR)
	just device=$(DEVICE) mount_rootfs
	sudo mkdir -p $(SYSROOT_DIR)/vendor/firmware
	# --chown=root:root for the same reason as the overlay rsync: the extracted
	# staging tree is owned by the build user (uid 1000 = $(USER_LOGIN) on the
	# device), and `rsync -a` preserves that. Without it the unprivileged user
	# owns /vendor/firmware and everything in it — including aoc.bin, which the
	# firmware loader reads and without which the device does not boot.
	sudo rsync -a --chown=root:root $(VENDOR_FIRMWARE_STAGE)/firmware/ $(SYSROOT_DIR)/vendor/firmware/
	just device=$(DEVICE) unmount_rootfs
	touch $@

# WHY A PREFLIGHT: the toolchains are split across environments — the rootfs
# stages need sudo (tools/dockershell, a Debian container), the kernel needs the
# bazel FHS env, and these two stages need cargo. Nothing here can install cargo
# (Nix lives only in flake.nix so this Makefile stays portable), but it can say
# so. Without the check the failure is a bare "sh: line 2: cargo: not found"
# several stages into a build, with nothing naming the missing toolchain, which
# shell wanted it, or why a build that worked yesterday suddenly needs it —
# these sentinels only re-trigger when a pixel-* submodule gitlink moves, so the
# stage is usually already satisfied and invisible.
define require_cargo
	@command -v cargo >/dev/null 2>&1 || { \
		printf '%s\n' \
		  "ERROR: cargo not found, so $@ cannot cross-build." \
		  "       These two stages build the on-device A/B tools for" \
		  "       $(PIXEL_BOOTCTL_TARGET); they re-run whenever a pixel-*" \
		  "       submodule gitlink moves. Build them where cargo lives, then" \
		  "       re-run this build — the sentinels are picked up as-is:" \
		  "" \
		  "         NixOS:  nix develop -c make .build_pixel_bootctl .build_pixel_ota" \
		  "         other:  rustup target add $(PIXEL_BOOTCTL_TARGET)" \
		  "" \
		  "       (tools/dockershell's container has no Rust toolchain by design.)" >&2; \
		exit 1; }
endef

# Cross-compile pixel-bootctl to a fully static aarch64-musl binary and copy it
# into the overlay tree. Links with the Rust toolchain's bundled rust-lld and
# strips via rustc (-C strip), so no external aarch64 gcc/strip is needed — the
# same recipe works in the flake's devShell and on any non-Nix host that has
# rustup's aarch64-unknown-linux-musl target installed. Static => no dynamic
# loader, so it runs unchanged on the Debian rootfs.
.build_pixel_bootctl: $(PIXEL_BOOTCTL_SOURCES)
	$(require_cargo)
	cd $(PIXEL_BOOTCTL_DIR) && \
		RUSTFLAGS="-C linker=rust-lld -C strip=symbols" \
		cargo build --release --target $(PIXEL_BOOTCTL_TARGET)
	mkdir -p $(dir $(PIXEL_BOOTCTL_OVERLAY))
	install -m 0755 $(PIXEL_BOOTCTL_BIN) $(PIXEL_BOOTCTL_OVERLAY)
	touch $@

# pixel-ota: identical cross-build recipe to pixel-bootctl (see the comment
# above .build_pixel_bootctl for the static-musl rationale).
.build_pixel_ota: $(PIXEL_OTA_SOURCES)
	$(require_cargo)
	cd $(PIXEL_OTA_DIR) && \
		RUSTFLAGS="-C linker=rust-lld -C strip=symbols" \
		cargo build --release --target $(PIXEL_BOOTCTL_TARGET)
	mkdir -p $(dir $(PIXEL_OTA_OVERLAY))
	install -m 0755 $(PIXEL_OTA_BIN) $(PIXEL_OTA_OVERLAY)
	touch $@

# $(wildcard ...) on the key file: it is a real dependency when present (editing
# the fleet's keys must rebuild the image) but must not be a hard prerequisite
# when absent, or a fresh checkout without one would fail with "No rule to make
# target". The absent case is handled with a loud warning in the recipe instead.
$(S_PKGS): $(S_DEBOOT) .build_pixel_bootctl .build_pixel_ota $(APT_PACKAGES_FILE) $(OVERLAY_FILES) version.txt $(wildcard $(SSH_AUTHORIZED_KEYS)) | $(BUILD_DIR)
	just device=$(DEVICE) mount_rootfs
	# apt tuning for the snapshot.debian.org mirror (all harmless on the live
	# mirror, so written unconditionally):
	#   Check-Valid-Until false  - snapshot Release files carry an old
	#                              Valid-Until; apt rejects them as expired.
	#   Retries 5                - snapshot intermittently freezes a connection
	#     + *::Timeout 60          mid-transfer; without a timeout apt hangs
	#                              forever, so cap it and retry instead.
	#   Pipeline-Depth 0         - snapshot throttles/stalls under apt's default
	#                              HTTP pipelining; disable it.
	# Regular file, no symlink — safe to write host-side into the mounted sysroot.
	sudo sh -c "printf '%s\n' \
		'Acquire::Check-Valid-Until \"false\";' \
		'Acquire::Retries \"5\";' \
		'Acquire::http::Timeout \"60\";' \
		'Acquire::https::Timeout \"60\";' \
		'Acquire::http::Pipeline-Depth \"0\";' \
		> $(SYSROOT_DIR)/etc/apt/apt.conf.d/99snapshot"
	# Ensure the non-free-firmware component is enabled before `apt-get update`,
	# so firmware-realtek resolves. .debootstrap now passes --components for
	# this, but editing that recipe does NOT invalidate its sentinel — an
	# already-debootstrapped sysroot would still carry a main-only sources.list
	# and fail here. Idempotent, so it is a no-op once the component is present.
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"grep -q non-free-firmware /etc/apt/sources.list \
		|| sed -i '/^deb .* main/ s/$$/ non-free-firmware/' /etc/apt/sources.list"
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c "apt-get update"
	# Locale setup.
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"DEBIAN_FRONTEND=noninteractive apt-get -y install locales apt-utils"
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"export DEBIAN_FRONTEND=noninteractive; \
		sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
		&& dpkg-reconfigure locales \
		&& update-locale en_US.UTF-8"
	# Pre-stage the pinned kmscon .deb (trixie dropped the package) so the
	# single apt-get install below resolves its deps alongside packages.txt.
	sudo curl -L --fail -o $(SYSROOT_DIR)/var/cache/apt/archives/kmscon.deb "$(KMSCON_URL)"
	# Fail loudly if the fetched .deb isn't the pinned one.
	echo "$(KMSCON_SHA256)  $(SYSROOT_DIR)/var/cache/apt/archives/kmscon.deb" | sha256sum -c -
	# Packages from rootfs/packages.txt plus the staged kmscon .deb.
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"DEBIAN_FRONTEND=noninteractive apt-get -y install $(APT_PACKAGES) /var/cache/apt/archives/kmscon.deb"
	# Drop the downloaded .deb cache so it doesn't accumulate in the image across
	# rebuilds — it otherwise grows every time the snapshot pin / package set
	# changes (new versions fetched, old ones never purged).
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c "apt-get clean"
	# Unprivileged user with passwordless sudo. Paired with the autologin
	# override in rootfs/overlay/etc/systemd/system/kmsconvt@.service.d/.
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"id -u $(USER_LOGIN) >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo $(USER_LOGIN)"
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"echo $(USER_LOGIN):$(USER_PW) | chpasswd"
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"echo '%sudo ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-sudo-nopasswd \
		&& chmod 0440 /etc/sudoers.d/99-sudo-nopasswd"
	# Bake in the fleet's SSH public keys. Must live in the image: the rootfs
	# cutover wipes anything added on a running device, so a hand-copied key
	# survives exactly until that device's first OTA (see SSH_AUTHORIZED_KEYS).
	# Written here rather than via the overlay because git cannot track the 0600
	# mode bit or the non-root ownership, same reason as 99-sudo-nopasswd above.
	@if [ -s "$(SSH_AUTHORIZED_KEYS)" ]; then \
		echo "  installing SSH keys from $(SSH_AUTHORIZED_KEYS)"; \
		sudo mkdir -p "$(SYSROOT_DIR)/home/$(USER_LOGIN)/.ssh"; \
		sudo cp "$(SSH_AUTHORIZED_KEYS)" \
			"$(SYSROOT_DIR)/home/$(USER_LOGIN)/.ssh/authorized_keys"; \
		$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
			"chown -R $(USER_LOGIN):$(USER_LOGIN) /home/$(USER_LOGIN)/.ssh \
			&& chmod 0700 /home/$(USER_LOGIN)/.ssh \
			&& chmod 0600 /home/$(USER_LOGIN)/.ssh/authorized_keys"; \
		echo "  $$(grep -cvE '^[[:space:]]*(#|$$)' "$(SSH_AUTHORIZED_KEYS)") key(s) installed for $(USER_LOGIN)"; \
	else \
		echo "  ****************************************************************"; \
		echo "  WARNING: no $(SSH_AUTHORIZED_KEYS) — image ships with NO SSH keys."; \
		echo "  This image is PASSWORD-ONLY, so flash-ssh.sh (BatchMode key auth)"; \
		echo "  cannot update a device built from it. Fine for bench work; for"; \
		echo "  fielded units it means the FIRST OTA is also the LAST one."; \
		echo "  ****************************************************************"; \
	fi
	# Explicitly enable a getty on felix's UART console. The compiled-in
	# `console=ttynull` in CONFIG_CMDLINE masks ttySAC0 from /sys/class/tty/
	# console/active, so systemd-getty-generator won't spawn one on its own.
	$(NSPAWN) -D $(SYSROOT_DIR) systemctl enable serial-getty@ttySAC0.service
	# systemd-backlight@.service pulls felix into systemd "degraded" on every
	# boot; mask it (symlink to /dev/null) to keep `systemctl is-system-running`
	# green.
	$(NSPAWN) -D $(SYSROOT_DIR) \
		ln -sf /dev/null /etc/systemd/system/systemd-backlight@.service
	# Prefer NetworkManager over dhcpcd and pre-seed a DHCP ethernet profile.
	$(NSPAWN) -D $(SYSROOT_DIR) systemctl disable dhcpcd
	$(NSPAWN) -D $(SYSROOT_DIR) systemctl enable NetworkManager
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"nmcli --offline connection add type ethernet con-name default_connection ipv4.method auto autoconnect true \
		> /etc/NetworkManager/system-connections/default_connection.nmconnection"
	$(NSPAWN) -D $(SYSROOT_DIR) chmod 600 /etc/NetworkManager/system-connections/default_connection.nmconnection
	# Apply tracked overlay (usb_gadget, blacklist.conf, custom service, ...).
	# Units are enabled by the .wants symlinks committed under the overlay's
	# etc/systemd/system/, not by `systemctl enable` here.
	# --chown=root:root is REQUIRED. `rsync -a` preserves SOURCE ownership, and
	# rootfs/overlay/ is owned by the build user (uid 1000 here) — which is the
	# same uid as $(USER_LOGIN) on the device. Without this, every directory the
	# overlay touches lands owned by that unprivileged user, including `/`,
	# /etc, /usr, /etc/systemd/system, /etc/udev/rules.d and /usr/local/sbin.
	#
	# That is a privilege hole on its own, and it also silently breaks
	# systemd-tmpfiles: it refuses to traverse an unprivileged-owned directory
	# into a root-owned one ("Detected unsafe path transition / (owned by kalm)
	# → /sys ..."), so tmpfiles.d entries under /sys are skipped with no error.
	# That is how the USB-autosuspend fix appeared to apply and did nothing.
	sudo rsync -a --chown=root:root $(OVERLAY_DIR)/ $(SYSROOT_DIR)/
	# ...and repair the ancestors. --chown only takes effect on entries rsync
	# actually rewrites, so leaf dirs whose contents changed get fixed while
	# untouched parents keep whatever ownership a previous (pre---chown) build
	# gave them. Measured: /etc/systemd/system and /usr/local/sbin came out
	# uid=0 while `/`, /etc and /usr stayed uid=1000 — and `/` is exactly the
	# one that makes systemd-tmpfiles refuse to work. Chown every directory the
	# overlay contains, plus the sysroot root itself. Scoped to overlay dirs on
	# purpose: a blanket chown -R would clobber /home/$(USER_LOGIN).
	# Built with -printf rather than `-exec chown ... {} +`: GNU find requires a
	# lone {} in the + form, so embedding it in a longer path is a hard error
	# ("the '{}' must appear by itself"). abspath also keeps this correct
	# whether SYSROOT_DIR arrives relative or already absolute — the justfile
	# passes it absolute, so an added $(CURDIR)/ prefix yielded /work//work/...
	sudo chown root:root $(SYSROOT_DIR)
	cd $(OVERLAY_DIR) && find . -type d -printf '$(abspath $(SYSROOT_DIR))/%P\0' \
		| sudo xargs -0 --no-run-if-empty chown root:root
	# RETIRED_OVERLAY_PATHS — files that USED to ship in the overlay and must be
	# actively removed from the sysroot.
	#
	# The rsync above is deliberately NOT --delete: the overlay is a sparse graft
	# onto a full Debian install, so --delete would try to remove the entire
	# distro. The consequence is that `git rm`-ing an overlay file does NOT
	# remove it from the image — .debootstrap's sentinel means the sysroot is
	# never wiped between builds, so the stale copy survives every rebuild and
	# keeps shipping. A deleted unit therefore stays ENABLED on device.
	#
	# So retiring an overlay file is two steps: delete it from the overlay AND
	# list it here. Entries can be dropped once .debootstrap has been rerun for
	# other reasons (a wiped sysroot never had them).
	sudo rm -f $(addprefix $(SYSROOT_DIR)/,$(RETIRED_OVERLAY_PATHS))
	# pstore-beacon (overlay) surfaces the PREVIOUS boot's panic dmesg on UART —
	# felix has one USB-C port, so we usually can't be UART-attached for the boot
	# that crashes. systemd-pstore.service would race it for the records, so mask
	# it: the beacon is the single owner of /sys/fs/pstore consumption.
	$(NSPAWN) -D $(SYSROOT_DIR) \
		ln -sf /dev/null /etc/systemd/system/systemd-pstore.service
	# dnsmasq is installed ONLY to serve DHCP on the USB gadget link, started
	# ad-hoc by usr/local/sbin/usb_gadget bound to usb0. Debian enables
	# dnsmasq.service on install, and that system-wide instance binds the
	# wildcard address — on a lab/fleet LAN that is a rogue DHCP server handing
	# leases to everything on the wire. Disable it; the gadget script's
	# --bind-interfaces instance is the only one that should ever run.
	$(NSPAWN) -D $(SYSROOT_DIR) systemctl disable dnsmasq.service || true
	# NOTE: the image-version stamp used to live here — moved to the PHONY
	# `stamp_version` target (run by `just all` after .build_boot) so it is
	# recomputed every build and reflects the actual kernel, not whatever was
	# stamped the first time this (sentinel-gated) stage ran. See IMAGE_VERSION.
	just device=$(DEVICE) unmount_rootfs
	touch $@

$(S_INSTK): $(S_KERNEL) $(S_PKGS) | $(BUILD_DIR)
	just device=$(DEVICE) mount_rootfs
	sudo mkdir -p $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)
	sudo cp $(KERNEL_BUILD_DIR)/modules.builtin $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/
	sudo cp $(KERNEL_BUILD_DIR)/modules.builtin.modinfo $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/
	sudo rm -f $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/modules.order
	sudo touch $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/modules.order
	@echo "Copying modules"
	# Wipe stale .ko files from a previous kernel build before resyncing.
	# rsync below must overwrite, not skip — a previous build's modules have
	# __versions CRCs computed against the old vmlinux, so leaving them in
	# place causes every module to fail MODVERSIONS check against a freshly
	# rebuilt kernel and kicks the device into a watchdog reboot loop.
	sudo find $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION) -name '*.ko' -delete 2>/dev/null || true
	# ...and wipe the UNPACK tree too, not just the sysroot. tar overlays, it never
	# deletes, so a module dropped from the kernel build survives in
	# rootfs/unpack/<staging>/ indefinitely and the rsync below copies it straight
	# back into the sysroot the sweep above just cleaned. Net effect: removing a
	# module from the build does not remove it from the image, and nothing says so.
	#
	# Measured 2026-08-04: clk-acpm-gpu.ko was reverted out of the kernel and the
	# rebuilt staging archive contained 0 copies of it, yet it still shipped in
	# rootfs.img (13240 bytes, live inode) because the stale copy in
	# rootfs/unpack/vendor_dlkm/ was rsynced over the top. The archive was clean,
	# the sysroot sweep ran, and the module shipped anyway.
	for staging in vendor_dlkm system_dlkm; \
	do \
		sudo rm -rf $(UNPACK_DIR)/"$$staging"; \
		sudo mkdir -p $(UNPACK_DIR)/"$$staging" && \
		sudo tar \
			-xvzf $(KERNEL_BUILD_DIR)/"$$staging"_staging_archive.tar.gz \
			-C $(UNPACK_DIR)/"$$staging"; \
		sudo rsync -avK --include='*/' --include='*.ko' --exclude='*' $(UNPACK_DIR)/"$$staging"/ $(SYSROOT_DIR)/; \
		sudo sh -c "cat $(UNPACK_DIR)/\"$$staging\"/lib/modules/$(KERNEL_VERSION)/modules.order \
			>> $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/modules.order"; \
	done
	@echo "Updating System.map"
	sudo cp $(KERNEL_BUILD_DIR)/System.map $(SYSROOT_DIR)/boot/System.map-$(KERNEL_VERSION)
	@echo "Updating module dependencies"
	$(NSPAWN_WRAP) -D $(SYSROOT_DIR) depmod \
		--errsyms \
		--all \
		--filesyms /boot/System.map-$(KERNEL_VERSION) \
		$(KERNEL_VERSION)
	@echo "Copying kernel headers"
	sudo mkdir -p $(UNPACK_DIR)/kernel_headers
	sudo tar \
		-xvzf $(KERNEL_BUILD_DIR)/kernel-headers.tar.gz \
		-C $(UNPACK_DIR)/kernel_headers
	sudo cp -r $(UNPACK_DIR)/kernel_headers $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION)
	sudo ln -rsf $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION) $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/build
	sudo cp $(KERNEL_BUILD_DIR)/kernel_aarch64_Module.symvers $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION)/
	sudo cp $(KERNEL_BUILD_DIR)/vmlinux.symvers $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION)/
	@echo "Writing dracut force-drivers list"
	sudo rm -f $(MODULE_ORDER_PATH)
	sudo sh -c "cat $(KERNEL_BUILD_DIR)/vendor_kernel_boot.modules.load | xargs -I {} \
		modinfo -b $(SYSROOT_DIR) -k $(KERNEL_VERSION) -F name \"$(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/{}\" \
		> $(MODULE_ORDER_PATH)"
	sudo sh -c "cat $(KERNEL_BUILD_DIR)/vendor_dlkm.modules.load | xargs -I {} \
		modinfo -b $(SYSROOT_DIR) -k $(KERNEL_VERSION) -F name \"$(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/{}\" \
		>> $(MODULE_ORDER_PATH)"
	sudo sh -c "cat $(KERNEL_BUILD_DIR)/system_dlkm.modules.load | xargs -I {} \
		modinfo -b $(SYSROOT_DIR) -k $(KERNEL_VERSION) -F name \"$(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/{}\" \
		>> $(MODULE_ORDER_PATH)"
	# Strip blacklisted modules so dracut --force-drivers doesn't pull them
	# into the initramfs despite /etc/modprobe.d/blacklist.conf.
	#
	# NOTE: exynos_seclog was excluded here for a while on the theory that it
	# caused the boot-time add_uevent_var panic — 3 of 8 boots logged
	# "exynos-seclog: probe of seclog failed with error -22" and exactly those
	# 3 panicked. That correlation was FALSE. With seclog excluded from this
	# list AND blacklisted (verified not loaded, and its only trace in the
	# panicking boot was the reserved-memory node at t=0.000000), the identical
	# panic recurred — same call path, same faulting address
	# ffffffc00e1e3568. Do not re-add it on that reasoning; the panic is
	# something else. See the uevent-panic notes for the live state.
	#
	# st21nfc: the NFC controller driver, dropped because on some units the chip
	# does not answer cleanly on i2c and its probe wedges a udev worker — inside
	# the INITRAMFS, where dracut-initqueue then loops "Timed out while waiting
	# for udev queue to empty" at ~60s a round.
	#
	# Measured over UART on 34291FDHS000WV (2026-08-04): 500+ seconds of boot,
	# stalls of 60/117/46/58/50s each ending in either an st21nfc
	# "Switched from IDLE to IDLE" error or another initqueue timeout. The same
	# image on 35041FDHS0032G boots in 13.0s total. The two units differ in
	# st21nfc lines (7 vs 1) and IDLE-to-IDLE errors (7 vs 0); every other
	# candidate was identical across both — same cs40l26 i2c NO-ACKs (11), same
	# deferred probes (9), same missing-firmware -2 loads (17), healthy UFS, AOC
	# up. So the NFC chip is the variable, not the image.
	#
	# The user-visible symptom is a device that sits on the bootloader splash for
	# ten minutes and looks bricked, which is how this started: three separate
	# wrong diagnoses (bad dongle, netcheck bricking both slots, an unclean
	# sysrq reboot) before the console showed it was simply still in the initramfs.
	#
	# These devices have no use for NFC at all, so dropping the driver costs
	# nothing and removes a boot-blocking dependency on a peripheral we never
	# touch. Paired with a blacklist entry so udev cannot autoload it later by
	# modalias — the sed only stops dracut force-loading it.
	sudo sed -i '/^bcmdhd4389$$/d; /^exynos_mfc$$/d; /^st21nfc$$/d' $(MODULE_ORDER_PATH)
	# Prune module/header/boot trees from other kernel versions so a
	# KERNEL_VERSION bump doesn't accumulate stale ones in the image. (The new
	# version's initrd is (re)created later in .install_initramfs.)
	sudo find $(SYSROOT_DIR)/lib/modules -mindepth 1 -maxdepth 1 -type d \
		! -name '$(KERNEL_VERSION)' -exec rm -rf {} +
	sudo find $(SYSROOT_DIR)/usr/src -mindepth 1 -maxdepth 1 -type d \
		-name 'linux-headers-*' ! -name 'linux-headers-$(KERNEL_VERSION)' -exec rm -rf {} +
	sudo find $(SYSROOT_DIR)/boot -mindepth 1 -maxdepth 1 \
		\( -name 'initrd.img-*' -o -name 'System.map-*' \) \
		! -name '*-$(KERNEL_VERSION)' -exec rm -f {} +
	just device=$(DEVICE) unmount_rootfs
	touch $@

$(S_INITRD): $(S_INSTK) $(S_PKGS) $(S_INSTFW) | $(BUILD_DIR)
	just device=$(DEVICE) mount_rootfs
	# Bundle aoc.bin into the initramfs at the path firmware_class.path
	# (/vendor/firmware, set by the dtb's /chosen/bootargs) points at.
	# Without it, the AOC coprocessor retry-loops in dracut and starves
	# UART RX, so emergency-shell keystrokes are dropped.
	#
	# rd.udev.children-max=4 is an EXPERIMENT against the add_uevent_var panic,
	# not a settled fix. That panic fires on ~40% of boots (measured: 5 of 12 in
	# one reboot campaign, including three consecutive), always at t~6-7s, always
	# Comm: udevadm, always the same path:
	#   uevent_store -> kobject_synth_uevent -> kobject_uevent_env
	#     -> add_uevent_var -> vsnprintf -> string()
	# dereferencing an UNMAPPED address while formatting SUBSYSTEM=%s.
	#
	# Two things point at a coldplug race rather than one bad device:
	#   * it is NOT reproducible at runtime — writing add AND change to all 3286
	#     /sys/.../uevent files never faults on a settled system
	#   * it only happens inside the initramfs, where dracut force-loads 324
	#     modules WHILE udev processes events concurrently
	# The faulting address (0xffffffc00e1e3568) is constant across boots and days
	# and lies in the general vmalloc area — NOT in module memory (modules live
	# at 0xffffffd1e4xxxxxx here), so "a module unloaded and left a dangling
	# name pointer" is ruled out.
	#
	# Limiting udev workers reduces that concurrency. If the panic rate collapses
	# the race is confirmed and this is a usable mitigation; if it does not, the
	# race hypothesis is wrong, which is equally worth knowing.
	#
	# 4, not 1, deliberately: rd.udev.children-max=1 previously serialized ~9,700
	# coldplug events and took the initrd from 4.6s to 2m14s
	# (see the "random boot hang" investigation). Measure boot time alongside the
	# panic rate — a fix that trades a 40% panic for a 2-minute boot is not a fix.
	#
	# rd.shell=0 rd.emergency=reboot: a dracut failure must REBOOT, never wait
	# at an interactive shell. The shipped configuration has no screen, no
	# volume keys and no power button, and the initramfs has no networking, so
	# an emergency shell is reachable only by someone physically attaching a
	# UART adapter — which on a fielded unit is nobody. Worse, it is reachable
	# only in theory even on the bench: the one time dracut actually did fail
	# here (missing aoc.bin, no /dev/disk/by-partlabel/super) it dropped to an
	# emergency shell that could not be typed into, because the AOC retry loop
	# was starving UART RX. So the shell buys nothing and costs everything: a
	# hang is permanent, whereas a reboot burns a slot-retry and lets the
	# bootloader roll back to the other slot. Panics already self-recover
	# (CONFIG_PANIC_TIMEOUT=-1, CONFIG_PANIC_ON_OOPS=y); this closes the
	# non-panic hang path.
	$(NSPAWN_WRAP) -D $(SYSROOT_DIR) dracut \
		--kver $(KERNEL_VERSION) \
		--lz4 \
		--show-modules \
		--force \
		--add "rescue bash rootfs-flash rootfs-slot" \
		--install /vendor/firmware/aoc.bin \
		--kernel-cmdline "rd.shell=0 rd.emergency=reboot" \
		--force-drivers "$$(tr '\n' ' ' < $(MODULE_ORDER_PATH))"
	just device=$(DEVICE) unmount_rootfs
	touch $@

# Always-run provenance stamp (PHONY, no sentinel) — see IMAGE_VERSION comment.
# Writes /etc/os-release IMAGE_VERSION/IMAGE_BUILD_DATE + /etc/image-version into
# the (already-built) rootfs. Runs inside nspawn because /etc/os-release is a
# symlink into /usr/lib that only resolves in the container. Idempotent: strips
# prior IMAGE_* lines before re-appending, so re-stamping never accumulates.
# Depends only on the rootfs existing (.install_packages), but is itself PHONY so
# it re-executes on every build regardless of sentinels.
stamp_version: $(S_PKGS)
	just device=$(DEVICE) mount_rootfs
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"sed -i --follow-symlinks '/^IMAGE_VERSION=/d; /^IMAGE_BUILD_DATE=/d; /^IMAGE_DEVICE=/d' /etc/os-release; \
		echo 'IMAGE_VERSION=\"$(IMAGE_VERSION)\"' >> /etc/os-release; \
		echo 'IMAGE_BUILD_DATE=\"$(BUILD_DATE)\"' >> /etc/os-release; \
		printf '%s\n' '$(IMAGE_VERSION)' > /etc/image-version; \
		echo 'IMAGE_DEVICE=\"$(DEVICE)\"' >> /etc/os-release; \
		printf '%s\n' '$(DEVICE)' > /etc/image-device"
	# Fleet stamp — see FLEET_ID. Removed when unset, so an image never keeps a
	# stale claim to a fleet it was rebuilt out of (this stage is PHONY and reruns
	# on every build, so the file always reflects THIS build's variables).
ifneq ($(strip $(FLEET_ID)),)
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c "printf '%s\n' '$(FLEET_ID)' > /etc/junkyard-fleet"
	@echo "stamped FLEET_ID=$(FLEET_ID)"
else
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c "rm -f /etc/junkyard-fleet"
endif
	just device=$(DEVICE) unmount_rootfs
	@echo "stamped IMAGE_VERSION=$(IMAGE_VERSION)"

# Decrypt + install the ARM NDA GPU userland blobs into the rootfs. PHONY (no
# sentinel), like stamp_version: it re-runs every build so a builder who fixes
# their key (or gets added as a recipient + re-pulls the blob) picks the drivers
# up on the next `just all` with nothing to remember. tools/arm-blobs.sh exits 0
# when the blob/key is absent or the builder isn't a recipient, so this NEVER
# fails the build — it just warns and skips. Decoupled from .build_boot because
# the blobs land in rootfs.img (flashed to super), not in boot/vendor_boot.img;
# `just all` runs this after .build_boot. ldconfig refreshes the loader cache so
# a freshly-installed .so is found at runtime.
install_arm_blobs: $(S_PKGS)
	just device=$(DEVICE) mount_rootfs
	SECRETS_DIR=$(SECRETS_DIR) ARM_BLOBS_ENC=$(ARM_BLOBS_ENC) \
		ARM_RECIPIENTS=$(ARM_RECIPIENTS) ARM_NDA_KEY=$(ARM_NDA_KEY) \
		$(ARM_BLOBS_SCRIPT) install $(SYSROOT_DIR)
	$(NSPAWN_WRAP) -D $(SYSROOT_DIR) ldconfig || true
	just device=$(DEVICE) unmount_rootfs

# NO usbcore.quirks here — see below.
#
# RETIRED 2026-08-03: `usbcore.quirks=0bda:8153:k` (USB_QUIRK_NO_LPM) was added
# believing the wedge was a failed U1/U2 low-power link-state exit on the
# RTL8153. That premise is dead, twice over:
#
#  1. The host controller disables USB2 LPM on its own regardless — the boot log
#     says `usb usb2: We don't know the algorithms for LPM for this host,
#     disabling LPM` — and the AOSP DT already sets snps,dis-u1-entry-quirk and
#     snps,dis-u2-entry-quirk, so U1/U2 ENTRY was never happening either.
#  2. 8 GiB transferred cleanly with quirks=[] , and the wedge still reproduced
#     with the quirk in place.
#
# ★ THE SS.Inactive EVIDENCE WAS RIGHT; ONLY THE FIX WAS WRONG.
# Tracepoints captured 2026-08-03 across a real failure show the SuperSpeed LINK
# dying FIRST, and the controller trouble following 140ms later:
#     329.981  xhci_handle_port_status: port-0: Powered Connected Disabled
#                                       Link:Inactive PortSpeed:4 Change: PLC
#     330.121  xhci_urb_dequeue: ep3in-intr
#     330.121  xhci_handle_command: Stop Ring Command  <- this one COMPLETED
#     330.123  xhci_urb_dequeue: ep2out-bulk
#              ... a later Stop Ring never retires -> 5s -> xhci_halt + hc_died
# So the order is: SS link fails recovery (SS.Inactive) -> URBs cancelled ->
# Stop Endpoint issued against a dead port -> command hangs -> "HC died", with
# `r8152: Tx status -2` last of all. The xHCI messages name the VICTIM.
#
# NO_LPM is still correctly removed: U1/U2 ENTRY is already disabled in the DT
# (snps,dis-u1-entry-quirk / snps,dis-u2-entry-quirk) so there was no LPM
# transition for the quirk to prevent. The real question is why SuperSpeed link
# RECOVERY fails, which is a PHY/signal-integrity matter, not an LPM one.
# (snps,parkmode-disable-ss-quirk is also NOT a fix — failures recur with it.)
# udev.event_timeout=20 BOUNDS THE INTERMITTENT MULTI-MINUTE BOOT.
#
# On some boots a udev worker wedges while holding the display `atc` uevent and
# systemd-udevd SIGKILLs it at its default timeout — measured at 130s, twice per
# affected boot, which is the whole of the ~6min42s initrd (dracut-initqueue
# meanwhile loops "Timed out while waiting for udev queue to empty"). Same image,
# same hour, three units: 12.8s / 25.2s / 6min38s.
#
# ★ The worker is killed either way. NOTHING depends on it finishing, so the
# 130s is pure waiting for a foregone conclusion. Killing it at 20s instead
# turns a ~6min50s worst case into roughly 50s, without needing to know what it
# is blocked on. This BOUNDS the symptom; it is not a root-cause fix, and the
# underlying wedge is still worth chasing at the pd_dpu/coldplug level.
#
# ★★ Why bounding it matters more than the seconds saved: with no screen and no
# console, a 6min50s boot and a HANG are indistinguishable from the outside.
# "Wait seven minutes and see" is not a procedure a contractor can follow across
# hundreds of units, so the unpredictability was the real defect, not the delay.
#
# 20s is ~1000x the duration of a normal udev event (they finish in ms), so it
# should never truncate legitimate work. It is read by systemd-udevd straight
# from /proc/cmdline, which is why it goes HERE in boot.img's cmdline and not in
# dracut's --kernel-cmdline: the latter only lands in the initramfs's
# /etc/cmdline.d for dracut's own parsing, where systemd-udevd never sees it.
# Being on the real cmdline also means it applies in the real root too, where
# the same wedge otherwise burns 130s post-boot.
$(S_BOOT): $(S_INITRD) $(S_INSTFW) | $(BUILD_DIR)
	$(MKBOOTIMG) \
		--kernel $(KERNEL_BUILD_DIR)/Image.lz4 \
		--cmdline "root=/dev/mapper/rootfs udev.event_timeout=20" \
		--header_version 4 \
		-o $(BOOT_IMG) \
		--pagesize 2048 \
		--os_version 15.0.0 \
		--os_patch_level 2025-02
	just device=$(DEVICE) mount_rootfs
	sudo $(MKBOOTIMG) \
		--ramdisk_name "" \
		--vendor_ramdisk_fragment $(INITRAMFS_PATH) \
		--dtb $(KERNEL_BUILD_DIR)/dtb.img \
		--header_version 4 \
		--vendor_boot $(VENDOR_BOOT_IMG) \
		--pagesize 2048 \
		--os_version 15.0.0 \
		--os_patch_level 2025-02
	just device=$(DEVICE) unmount_rootfs
	touch $@

# Scoped to $(DEVICE): `make clean DEVICE=lynx` leaves the felix build alone.
# The kernel-build and OTA-sync sentinels are deliberately NOT removed — they
# guard the ~1hr kernel build and ~2GB download, and both are already per-device.
clean_image:
	just device=$(DEVICE) unmount_rootfs
	rm -f $(ROOTFS_IMG)
	rm -f $(S_CREATE) $(S_DEBOOT) $(S_INSTFW) $(S_PKGS) $(S_INSTK) $(S_INITRD) $(S_BOOT)

clean: clean_image
	# ★ super.img MUST be removed here, and `all` rebuilds it (both changed
	# 2026-08-05). It was previously excluded from `all` (another 8 GiB,
	# only fastboot and a layout migration need it), so a `clean` that leaves it
	# behind produces the worst possible outcome: fresh boot.img/vendor_boot.img
	# beside a STALE rootfs inside super.img, with nothing to warn you. It is
	# gitignored, so `git clean` does not catch it either, and `git status` stays
	# clean throughout.
	#
	# That is not hypothetical — measured 2026-08-05: a `just clean && just all`
	# after a version bump produced rootfs.img at 1.5.0-ge0559d7 while super.img
	# still held 1.4.0-gdaa33e3. flash-fastboot.sh flashes super.img, and
	# package-provisioning.sh reads the version FROM super.img, so the contractor
	# kit would have told an operator to expect 1.4.0 on screen while shipping a
	# 1.5.0 boot chain.
	rm -f $(BOOT_IMG) $(VENDOR_BOOT_IMG) $(SUPER_IMG)
	sudo rm -rf $(UNPACK_DIR)

# Build the full-flash `super.img`: the whole partition with both halves seeded
# from $(ROOTFS_IMG). See the SUPER_IMG block near the top for why both.
#
# Not part of .build_boot, but `just all` does invoke it — see the justfile. It is
# needed for a fastboot flash or a layout
# migration, and it is another 8 GiB of build output. `just build_super_image`.
# Depends on the BUILD SENTINEL, not on $(ROOTFS_IMG) as a bare file. Two
# reasons: a bare file prerequisite has no rule, so a missing rootfs.img fails
# with "No rule to make target" instead of building it; and more importantly it
# would happily seed super.img from a STALE rootfs, which is exactly the
# half-updated-boot/ failure documented in `clean` above.
.PHONY: super_image
super_image: $(S_BOOT)
	@set -e; \
	half=$(SUPER_HALF_BYTES); \
	isz=$$(stat -c%s "$(ROOTFS_IMG)"); \
	if [ "$$isz" -gt "$$half" ]; then \
		echo "ERROR: $(ROOTFS_IMG) is $$isz bytes but a half of super is only $$half."; \
		echo "       Lower SIZE in devices/$(DEVICE).mk — an image that does not fit a"; \
		echo "       half cannot be used for A/B at all, and seeding it here would just"; \
		echo "       overwrite the start of the other half."; \
		exit 1; \
	fi; \
	echo "super.img ($(DEVICE)): $(SUPER_BYTES) bytes, two halves of $$half, seeded from a $$isz-byte rootfs"; \
	rm -f "$(SUPER_IMG)"; \
	truncate -s $(SUPER_BYTES) "$(SUPER_IMG)"; \
	dd if="$(ROOTFS_IMG)" of="$(SUPER_IMG)" bs=4M conv=notrunc status=none; \
	: 'seek_bytes, NOT seek in bs units: half/4194304 truncates to 0 whenever the'; \
	: 'half is not a whole number of blocks, which would stack both copies at'; \
	: 'offset 0 and leave slot B empty — silently, since the image still builds.'; \
	: 'It happens to be exact for felix and lynx alike (both 8136 MiB -> 1017 x 4M),'; \
	: 'but SUPER_BYTES is per-device and a third gs201 Pixel need not divide evenly.'; \
	dd if="$(ROOTFS_IMG)" of="$(SUPER_IMG)" bs=4M oflag=seek_bytes seek=$$half conv=notrunc status=none; \
	echo "  wrote $(SUPER_IMG) (apparent $$(stat -c%s "$(SUPER_IMG)"), on disk $$(du -h --apparent-size=never "$(SUPER_IMG)" 2>/dev/null | cut -f1 || du -h "$(SUPER_IMG)" | cut -f1))"
