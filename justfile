# Thin orchestration layer; the Makefile owns the sentinel-tracked build
# pipeline so reruns skip already-finished stages. See Makefile for details.

# ═══ BUILDING ════════════════════════════════════════════════════════════════
#
#     just felix      build the Pixel Fold image
#     just lynx       build the Pixel 7a image
#     just all        build both
#
# Everything else is per-device via the `device` variable below, which the two
# named recipes just set for you.
#
# ⚠ The settings below are just VARIABLES, so they go BEFORE the recipe name,
# make-style:
#
#     just user_login=bob felix       <- correct
#     just felix user_login=bob       <- WRONG: a positional argument to `felix`
#
# They used to be recipe PARAMETERS, which is why the second form appeared in the
# docs. It never worked: `just all hostname=x` passed the literal string
# "hostname=x" as the first positional parameter (android_kernel_branch), so the
# override was silently ignored and a bogus kernel branch was used instead.

# Which gs201 Pixel to build for. Selects devices/<device>.mk in the Makefile and
# namespaces every artifact under build/<device>/, so felix and lynx never clobber
# each other. Prefer `just felix` / `just lynx`; set this directly only for the
# lower-level recipes (mount_rootfs, clean, sync_vendor_firmware, ...).
device := "felix"

# Empty means "use the device fragment's value" (devices/<device>.mk), which is
# the right answer almost always — SIZE in particular is one half of `super` and
# must not be raised past 4068 MiB. Set these only to deliberately override.
size := ""
hostname := ""
root_password := "0000"
user_login := "kalm"
user_password := "0000"
fleet_id := ""
debootstrap_release := "trixie"

# Config
[private]
_apt_packages_file := join("rootfs", "packages.txt")
[private]
_apt_packages := replace(read(_apt_packages_file), "\n", " ")

# Tools
[private]
_repo := require("repo")
[private]
_debootstrap := require("debootstrap")
[private]
_rsync := require("rsync")
[private]
_fallocate := require("fallocate")
[private]
_mkfs_ext4 := require("mkfs.ext4")
[private]
_curl := require("curl")
[private]
_unzip := require("unzip")
[private]
_make := require("make")
[private]
_age := require("age")
[private]
_arm_blobs_script := join(justfile_directory(), "tools", "arm-blobs.sh")
[private]
_extract_fs := join(justfile_directory(), "tools", "extract-partition-fs.sh")
[private]
_mkbootimg := join(justfile_directory(), "tools", "mkbootimg", "mkbootimg.py")
# One repo checkout per device, each pinned to its own manifest branch — see the
# KERNEL_SOURCE_DIR comment in the Makefile for why they are not shared.
[private]
_kernel_source_dir := join(justfile_directory(), "kernel", "source-" + device)
[private]
_bazel := join(_kernel_source_dir, "tools", "bazel")

# Paths / variables
#
# Per-device artifact root, mirroring the Makefile's BUILD_DIR. The Makefile is
# the source of truth for the layout; these exist because `just` needs a few of
# the paths at parse time, before any recipe can ask make.
[private]
_build_dir := join(justfile_directory(), "build", device)
# `read()` would abort the whole justfile if the file is missing, and this one is
# a gitignored per-device build artifact that does not exist on a fresh checkout.
# shell() with a `|| true` degrades to empty instead, which is fine: every recipe
# that actually needs the version re-reads it at RECIPE time (see the
# update_*/build_boot_images targets), because parse-time is before .build_kernel
# has written it anyway.
[private]
_kernel_version := trim(shell("cat kernel/kernel_version." + device + " 2>/dev/null || true"))
[private]
_sysroot_img := join(_build_dir, "rootfs.img")
# The MOUNTPOINT is shared between devices — only one device's rootfs.img is ever
# mounted there at a time, and all the content lives in that per-device image.
[private]
_sysroot_dir := join(justfile_directory(), "rootfs", "sysroot")
[private]
_initramfs_path := join(_sysroot_dir, "boot", "initrd.img-" + _kernel_version)

# Vendor firmware extraction. The OTA URL + pinned hash now live in
# devices/<device>.mk (each device needs its OWN vendor firmware), and are read
# back out of make at recipe time so the fragment stays the single source of
# truth. We can't redistribute the OTA, but it is pinned by content hash:
# sync_vendor_firmware verifies the downloaded zip, so a rotated or corrupt OTA
# fails loudly instead of silently changing the vendor firmware.
#
# Per-device workdir, so the ~2GB download is cached separately and switching
# devices back and forth never re-fetches.
[private]
_vendor_firmware_workdir := join(_build_dir, "vendor-firmware")
[private]
_vendor_firmware_stage := join(_vendor_firmware_workdir, "extracted")
[private]
_payload_dumper_version := "1.2.2"
[private]
_payload_dumper_dir := join(justfile_directory(), "tools", "payload-dumper-go")
[private]
_payload_dumper_bin := join(_payload_dumper_dir, "payload-dumper-go")

# Env vars consumed by Makefile.
#
# KERNEL_BUILD_DIR, KERNEL_SOURCE_DIR, BAZEL and MODULE_ORDER_PATH are NOT
# exported any more: the Makefile derives all four from $(DEVICE) with `:=`, and
# a simple assignment in a makefile beats the environment. Exporting them here
# would just be a second, silently-ignored copy of the layout that could drift.
[private]
export APT_PACKAGES := _apt_packages
[private]
export INITRAMFS_PATH := _initramfs_path
[private]
export KERNEL_VERSION := _kernel_version
[private]
export MKBOOTIMG := _mkbootimg
[private]
export SYSROOT_DIR := _sysroot_dir

default:
    just --list

# Build EVERY device. `all` means all, in both senses: every device, and every
# artifact for each of them (super.img included — see the note at the end of
# _build).
#
# Each device is a separate `just` process so its parse-time variables (build
# dir, kernel source dir, kernel version) resolve for that device. They are
# sequential, not parallel: the stages mount one shared sysroot at
# rootfs/sysroot, so two concurrent device builds would fight over the mount.
[doc('Build EVERY device (felix + lynx)')]
all:
    just device=felix _build
    just device=lynx _build

# Build the felix (Pixel Fold) image.
felix:
    just device=felix _build

# Build the lynx (Pixel 7a) image.
lynx:
    just device=lynx _build

# The actual per-device pipeline; `device` selects which. Takes ~1hr on the first
# run for a device (kernel build dominates). Reruns skip already-finished stages
# thanks to the Makefile's sentinel files, which are per-device.
#
# Split into two make invocations so the second picks up the fresh
# KERNEL_VERSION written by .build_kernel. justfile exports are evaluated at
# parse time, so on a fresh checkout KERNEL_VERSION would be empty without
# this split.
[private]
_build: clone_kernel_source
    @echo "═══ building {{ device }} ═══"
    {{ _make }} -C {{ justfile_directory() }} .build_kernel DEVICE={{ device }}
    KVER=$(cat {{ justfile_directory() }}/kernel/kernel_version.{{ device }}); \
    {{ _make }} -C {{ justfile_directory() }} .build_boot \
        DEVICE={{ device }} \
        {{ if size == "" { "" } else { "SIZE=" + size } }} \
        {{ if hostname == "" { "" } else { "HOSTNAME=" + hostname } }} \
        RELEASE={{ debootstrap_release }} \
        ROOT_PW={{ root_password }} \
        USER_LOGIN={{ user_login }} \
        USER_PW={{ user_password }} \
        KERNEL_VERSION=$KVER \
        INITRAMFS_PATH={{ _sysroot_dir }}/boot/initrd.img-$KVER
    # Always-run provenance stamp (PHONY, recomputed every build) — writes the
    # kernel-bound IMAGE_VERSION into the rootfs so two phones can be told apart
    # by what they actually run. KERNEL_VERSION must be passed so the +k<ver>
    # suffix reflects this build's kernel, not a stale one. FLEET_ID (optional)
    # additionally stamps /etc/junkyard-fleet, which flash-nmap.sh --fleet checks
    # before it will write to a device.
    KVER=$(cat {{ justfile_directory() }}/kernel/kernel_version.{{ device }}); \
    {{ _make }} -C {{ justfile_directory() }} stamp_version \
        DEVICE={{ device }} KERNEL_VERSION=$KVER FLEET_ID={{ fleet_id }}
    # Decrypt + install the ARM NDA GPU blobs (Mali Vulkan/OpenCL). PHONY, so it
    # runs every build; warns and skips (never fails) if this builder can't
    # decrypt the blob. See secrets/README.md.
    {{ _make }} -C {{ justfile_directory() }} install_arm_blobs DEVICE={{ device }}
    # Return blocks freed during the build (apt cache, pruned kernel trees) to
    # the sparse backing file so build/<device>/rootfs.img doesn't bloat over time.
    just device={{ device }} trim_rootfs
    # ★ super.img is part of a build, because `all` must mean ALL.
    #
    # It used to be excluded to save 8 GiB and a minute, on the reasoning that
    # only fastboot and a layout migration need it. That reasoning was wrong in
    # the way that matters: it left boot/ HALF UPDATED. A rebuild produced fresh
    # boot.img, vendor_boot.img and rootfs.img next to a super.img containing the
    # PREVIOUS rootfs — and nothing said so, because super.img is gitignored, so
    # `git status` stays clean and the build reports success.
    #
    # Measured 2026-08-05: `just clean && just all` after a version bump left
    # rootfs.img at 1.5.0-ge0559d7 and super.img at 1.4.0-gdaa33e3.
    # flash-fastboot.sh flashes super.img, and package-provisioning.sh reads the
    # shipped version FROM super.img — so the contractor kit would have told an
    # operator to expect 1.4.0 on screen while shipping a 1.5.0 boot chain, and
    # the screen check would have "passed" against the wrong expectation.
    #
    # A minute of dd is worth less than that failure mode. `just clean` now
    # removes it too, so clean+all really does recreate every artifact.
    just device={{ device }} build_super_image
    @echo "═══ {{ device }} done: $(ls -1 {{ _build_dir }}/*.img 2>/dev/null | tr '\n' ' ') ═══"

# Sync THIS device's kernel checkout (kernel/source-<device>) to its own manifest
# branch, taken from devices/<device>.mk. Each device gets its own tree, so this
# never re-points another device's source — see KERNEL_SOURCE_DIR in the Makefile.
#
# The [working-directory] attribute can't be used any more: it takes a string
# literal, and the path now depends on `device`. Each command therefore cds
# explicitly (just runs every recipe line in its own shell).
[group('kernel')]
[doc("Sync this device's kernel checkout to its manifest branch")]
clone_kernel_source:
    #!/usr/bin/env bash
    set -euo pipefail
    branch=$({{ _make }} -C {{ justfile_directory() }} print-KERNEL_BRANCH DEVICE={{ device }} | tail -1)
    src={{ _kernel_source_dir }}
    manifest={{ justfile_directory() }}/kernel/kernel-manifest.{{ device }}.xml

    # ★ Catch an un-migrated checkout BEFORE starting an hour-long sync.
    #
    # A pre-split tree has kernel/source/ but no kernel/source-<device>/, so the
    # sync below would happily start from nothing and re-fetch ~22 GB that is
    # already sitting on this disk under the old name. Nothing would look wrong —
    # it just takes an hour and burns the bandwidth.
    if [ ! -d "$src" ] && [ -d {{ justfile_directory() }}/kernel/source ]; then
        echo "REFUSING to sync: kernel/source/ exists but $src does not." >&2
        echo "" >&2
        echo "  This checkout predates the multi-device split. Syncing now would" >&2
        echo "  re-download ~22 GB you already have. Move it into place first:" >&2
        echo "" >&2
        echo "      just migrate" >&2
        echo "" >&2
        echo "  (or set KERNEL_SYNC_ANYWAY=1 to sync a genuinely new tree)" >&2
        [ "${KERNEL_SYNC_ANYWAY:-0}" = 1 ] || exit 1
    fi

    echo "Cloning {{ device }} kernel from branch: $branch into $src"
    mkdir -p "$src"
    cd "$src"
    # `< /dev/null` on every `repo init`: its interactive color prompt otherwise
    # writes color.ui to the global git config — on NixOS (home-manager) that's a
    # read-only /nix/store symlink, so the write fails "Read-only file system".
    # Non-interactive stdin makes repo default the prompt to "no" (no write).
    #
    # Reproducibility: if a pinned manifest exists (kernel/kernel-manifest.<device>.xml,
    # produced by `just pin_kernel_source`), select it so sync checks out the exact
    # recorded per-project SHAs instead of whatever the branch tips are today. The
    # pinned path is a FULL (non-shallow) init — a --depth=1 clone can only fetch
    # current branch tips, so it can't reach a pinned SHA once the branch advances.
    # With no pin, stay shallow for a fast first sync, then run pin_kernel_source.
    if [ -f "$manifest" ]; then
        echo "Pinned manifest found — full sync against recorded SHAs"
        {{ _repo }} init \
          -u https://android.googlesource.com/kernel/manifest \
          -b "$branch" \
          < /dev/null
        cp "$manifest" .repo/manifests/
        {{ _repo }} init -m "$(basename "$manifest")" < /dev/null
    else
        echo "No pinned manifest — shallow init (run 'just pin_kernel_source' to lock)"
        {{ _repo }} init \
          --depth=1 \
          -u https://android.googlesource.com/kernel/manifest \
          -b "$branch" \
          < /dev/null
    fi
    {{ _repo }} sync -j {{ num_cpus() }}
    if [ ! -e custom_defconfig_mod ]; then
        ln -s ../custom_defconfig_mod ./
    fi
    # A sync reverts everything under the tree, including the patches in
    # kernel/patches/. Drop their sentinel so the next build re-applies them
    # instead of trusting a stale "already done" marker and quietly building an
    # unpatched kernel.
    #
    # Deliberately NOT removing .build_kernel here. .build_kernel depends on
    # .apply_kernel_patches, so re-applying patches already makes the kernel
    # out of date and it rebuilds on its own. Deleting it outright forced a
    # full kernel rebuild on EVERY build (which always depends on this recipe) —
    # expensive, and it is how the kernel_version blanking bug got triggered.
    rm -f {{ justfile_directory() }}/build/{{ device }}/.apply_kernel_patches

# Lock this device's kernel source to its current per-project SHAs by
# regenerating kernel/kernel-manifest.<device>.xml. Commit the result; thereafter
# clone_kernel_source does a full sync against these exact revisions. Re-run
# after an intentional kernel branch/version bump, then rebuild kernel + rootfs
# modules in lockstep.
[group('kernel')]
pin_kernel_source:
    cd {{ _kernel_source_dir }} && {{ _repo }} manifest -r \
        -o {{ justfile_directory() }}/kernel/kernel-manifest.{{ device }}.xml
    @echo "Wrote kernel/kernel-manifest.{{ device }}.xml — commit it to lock the kernel source."

[group('kernel')]
clean_kernel: clone_kernel_source
    cd {{ _kernel_source_dir }} && {{ _bazel }} clean --expunge
    rm -f {{ justfile_directory() }}/build/{{ device }}/.build_kernel \
          {{ justfile_directory() }}/build/{{ device }}/.apply_kernel_patches

# Print a diff showing what the custom fragment would change vs. gki_defconfig.
[group('kernel')]
config_kernel: clone_kernel_source
    #!/usr/bin/env bash
    set -euo pipefail
    target=$({{ _make }} -C {{ justfile_directory() }} print-BAZEL_TARGET DEVICE={{ device }} | tail -1)
    cd {{ _kernel_source_dir }}
    cp ./aosp/arch/arm64/configs/gki_defconfig ./gki_defconfig_original
    # Same package as BAZEL_TARGET, but the :kernel_config rule rather than :dist.
    {{ _bazel }} run "${target%:*}:kernel_config" -- nconfig
    diff -up ./gki_defconfig_original aosp/arch/arm64/configs/gki_defconfig || [ $? -eq 1 ]
    rm ./gki_defconfig_original
    cd aosp && git checkout arch/arm64/configs/gki_defconfig

[group('kernel')]
build_kernel: clone_kernel_source
    {{ _make }} -C {{ justfile_directory() }} .build_kernel DEVICE={{ device }}

# Idempotent; .build_kernel already depends on this, so a normal build is
# patched automatically. Use this to re-apply by hand after a `repo sync`.
# A patch that neither applies nor is already applied aborts loudly.
[group('kernel')]
apply_kernel_patches:
    {{ _make }} -C {{ justfile_directory() }} .apply_kernel_patches DEVICE={{ device }}

# Create the empty ext4 rootfs image.
[group('rootfs')]
create_rootfs_image: unmount_rootfs
    {{ _make }} -C {{ justfile_directory() }} .create_image DEVICE={{ device }} \
        {{ if size == "" { "" } else { "SIZE=" + size } }}

# Mount the ext4 rootfs image at rootfs/sysroot. The --make-rprivate is required:
# / is mounted shared, so without it systemd-nspawn's container /dev mounts propagate
# back to the host and nspawn (systemd >= 260) then trips over its own propagated mounts
# with "/dev is pre-mounted and pre-populated" / "Failed to create /dev/pts: File exists".
# Apply --make-rprivate unconditionally so a sysroot reused across runs (e.g. when a
# prior nspawn failed mid-recipe) still becomes private even though we skip the mount.
[doc("Mount this device's rootfs.img at rootfs/sysroot")]
mount_rootfs: create_rootfs_image
    @mkdir -p {{ _sysroot_dir }}
    @if ! mountpoint -q {{ _sysroot_dir }}; then \
      echo "Mounting rootfs image at {{ _sysroot_dir }}"; \
      sudo mount {{ _sysroot_img }} {{ _sysroot_dir }}; \
    fi
    @sudo mount --make-rprivate {{ _sysroot_dir }}

# Unmount the ext4 rootfs image.  -R is recursive: a previous nspawn failure
# (e.g. binfmt missing) can leave /dev tmpfs + bind mounts inside sysroot, and
# the next nspawn then trips "/dev is pre-mounted and pre-populated".  Fall
# back to a lazy unmount if any child is still busy so we never stall here.
[doc('Unmount rootfs/sysroot')]
unmount_rootfs:
    @if mountpoint -q {{ _sysroot_dir }}; then \
      echo "Unmounting rootfs image from {{ _sysroot_dir }}"; \
      sudo umount -R {{ _sysroot_dir }} 2>/dev/null \
        || sudo umount -lR {{ _sysroot_dir }}; \
    fi

# Reclaim host disk space without rebuilding: return blocks freed inside the
# rootfs image back to its sparse backing file. The image is a fixed-size ext4
# file reused across builds, and neither ext4 nor the loop device hand freed
# blocks back without an explicit fstrim, so the backing file only ever grows.
# A build runs this automatically at the end; run it standalone any time to
# shrink build/<device>/rootfs.img on disk.
[group('rootfs')]
[doc('Shrink build/<device>/rootfs.img on disk (fstrim)')]
trim_rootfs: mount_rootfs
    sudo fstrim -v {{ _sysroot_dir }}
    just device={{ device }} unmount_rootfs

# Delete the rootfs image and associated sentinels.
[group('rootfs')]
clean_rootfs: unmount_rootfs
    {{ _make }} -C {{ justfile_directory() }} clean_image DEVICE={{ device }}

# Delete THIS device's rootfs image, boot images, super.img, kernel-staging
# unpack dir and image-pipeline sentinels. Scoped to `device` (default felix) on
# purpose: `just clean` should not silently destroy the other device's ~8 GiB of
# build output. Use `just clean_all` for both.
#
# Preserves the cached kernel build (`just clean_kernel` for that) and the cached
# OTA under build/<device>/vendor-firmware/, so the next build skips the ~1hr
# kernel build and ~2GB OTA download.
[doc("Delete one device's images + sentinels (device=felix by default)")]
clean: unmount_rootfs
    {{ _make }} -C {{ justfile_directory() }} clean DEVICE={{ device }}

# Clean every device, mirroring `all`.
clean_all:
    just device=felix clean
    just device=lynx clean

# ═══ ONE-TIME MIGRATION INTO THE PER-DEVICE LAYOUT ═══════════════════════════
#
# Relocate a pre-split checkout's artifacts to where the multi-device build now
# expects them, so the next `just felix` is a NO-OP rather than a from-scratch
# rebuild. Without this, the ~1hr kernel build, the ~2GB OTA download and the
# whole debootstrap+apt stage all run again, because their sentinels are gone.
#
#   boot/{rootfs,super,boot,vendor_boot}.img  ->  build/felix/
#   ./.<stage> sentinels                      ->  build/felix/
#   rootfs/{unpack,vendor-firmware}           ->  build/felix/
#   rootfs/module_order.txt                   ->  build/felix/
#   kernel/kernel_version                     ->  kernel/kernel_version.felix
#   kernel/kernel-manifest.xml                ->  kernel/kernel-manifest.felix.xml
#   kernel/source                             ->  kernel/source-felix
#
# `mv` throughout, so mtimes are preserved — sentinel freshness is entirely an
# mtime comparison, and copying would make every stage look newer than its
# inputs (or older, depending on direction) and re-trigger it.
#
# Idempotent: every step is skipped if the source is already gone. Safe to run on
# a fresh checkout with nothing to move. Left in the tree rather than run once and
# deleted, because other clones of this repo still need it.
[doc('One-time: move a pre-split checkout into build/<device>/ (no rebuild)')]
migrate:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{ justfile_directory() }}

    # ★ REFUSE to merge into a pre-existing build/felix/.
    #
    # Every move below is "skip if the destination already exists", which is what
    # makes this idempotent — but it is exactly wrong against a build/felix/ that
    # some EARLIER attempt at the multi-device split left behind. There, the skip
    # preserves the stale copy and discards the live one, silently, producing a
    # tree with old sentinels next to new images and no indication anything is off.
    #
    # This is not hypothetical: the first checkout migrated here had a build/felix/
    # from the abandoned branch holding an 8493465600-byte rootfs.img — the old
    # WHOLE-super size from before rootfs A/B. Under A/B that image overruns slot A
    # into slot B. Shipping it would have looked like a successful build.
    #
    # So: stop, and make the human decide. MIGRATE_FORCE=1 moves the old tree aside
    # to build/<device>.stale rather than deleting it — 8 GiB is worth a look before
    # it goes.
    if [ -d build/felix ] && [ -n "$(ls -A build/felix 2>/dev/null)" ]; then
        if [ "${MIGRATE_FORCE:-0}" = 1 ]; then
            echo "moving stale build/felix -> build/felix.stale"
            [ ! -e build/felix.stale ] || { echo "build/felix.stale exists too — resolve by hand" >&2; exit 1; }
            sudo mv build/felix build/felix.stale
        else
            echo "REFUSING to migrate: build/felix/ already exists and is not empty." >&2
            echo "" >&2
            echo "  It is almost certainly output from an earlier multi-device attempt." >&2
            echo "  Merging into it would keep the STALE files and drop the live ones," >&2
            echo "  because every move here skips when the destination exists." >&2
            echo "" >&2
            ls -la build/felix >&2
            echo "" >&2
            echo "  Re-run with MIGRATE_FORCE=1 to move it to build/felix.stale first," >&2
            echo "  then delete that once you have looked at it." >&2
            exit 1
        fi
    fi

    mkdir -p build/felix

    # rootfs.img and vendor_boot.img are root-owned (created under sudo), so the
    # moves need sudo even though the destination is ours.
    for f in rootfs.img super.img boot.img vendor_boot.img; do
        if [ -e "boot/$f" ] && [ ! -e "build/felix/$f" ]; then
            echo "  boot/$f -> build/felix/$f"
            sudo mv "boot/$f" "build/felix/$f"
        fi
    done

    for s in .apply_kernel_patches .create_image .debootstrap .build_kernel \
             .sync_vendor_firmware .install_vendor_firmware .install_packages \
             .install_kernel .install_initramfs .build_boot; do
        if [ -e "$s" ] && [ ! -e "build/felix/$s" ]; then
            echo "  $s -> build/felix/$s"
            sudo mv "$s" "build/felix/$s"
        fi
    done

    for d in unpack vendor-firmware; do
        if [ -e "rootfs/$d" ] && [ ! -e "build/felix/$d" ]; then
            echo "  rootfs/$d -> build/felix/$d"
            sudo mv "rootfs/$d" "build/felix/$d"
        fi
    done

    if [ -e rootfs/module_order.txt ] && [ ! -e build/felix/module_order.txt ]; then
        echo "  rootfs/module_order.txt -> build/felix/module_order.txt"
        sudo mv rootfs/module_order.txt build/felix/module_order.txt
    fi

    if [ -e kernel/kernel_version ] && [ ! -e kernel/kernel_version.felix ]; then
        echo "  kernel/kernel_version -> kernel/kernel_version.felix"
        mv kernel/kernel_version kernel/kernel_version.felix
    fi

    # Tracked file, so move it in git's index too — it is felix's pinned manifest
    # and a lynx sync must not be handed felix's SHAs.
    if [ -e kernel/kernel-manifest.xml ] && [ ! -e kernel/kernel-manifest.felix.xml ]; then
        echo "  kernel/kernel-manifest.xml -> kernel/kernel-manifest.felix.xml"
        git mv kernel/kernel-manifest.xml kernel/kernel-manifest.felix.xml 2>/dev/null \
          || mv kernel/kernel-manifest.xml kernel/kernel-manifest.felix.xml
    fi

    # The big one: 22 GB. A move is instant (same filesystem); re-syncing it from
    # scratch is an hour and ~22 GB of network.
    if [ -d kernel/source ] && [ ! -d kernel/source-felix ]; then
        echo "  kernel/source -> kernel/source-felix (22 GB, instant same-fs move)"
        mv kernel/source kernel/source-felix
    fi

    # The symlink inside the tree points at ../custom_defconfig_mod, which still
    # resolves after the rename (same depth), but recreate it if it went missing.
    if [ -d kernel/source-felix ] && [ ! -e kernel/source-felix/custom_defconfig_mod ]; then
        ln -s ../custom_defconfig_mod kernel/source-felix/
    fi

    echo "migration complete — 'just felix' should now be a no-op"

# Refresh the snapshot.debian.org pins: the Debian archive timestamp
# (rootfs/debian_snapshot, read via the Makefile's SNAPSHOT/MIRROR) and the
# kmscon .deb URL+hash (rootfs/kmscon.env, -include'd by the Makefile). With no
# args, pins the latest snapshot and refreshes kmscon; pass through tool flags
# otherwise, e.g. `just update_snapshot --date 2026-05-01`,
# `just update_snapshot --no-kmscon`, or `just update_snapshot --dry-run`.
[group('rootfs')]
update_snapshot *args:
    {{ justfile_directory() }}/tools/update-snapshot.sh {{ args }}

# --- ARM NDA GPU blobs (Mali Vulkan/OpenCL) -------------------------------
# These libs ship under an ARM NDA; the repo carries only an age-encrypted
# tarball, encrypted to every pubkey in secrets/recipients.txt. Each builder
# decrypts with their OWN SSH private key — no private key is ever shared. A
# builder who isn't a recipient gets a warning + skipped GPU drivers, not a
# build failure. See secrets/README.md.

# Encrypt a rootfs-rooted tree of blobs into secrets/arm-mali-blobs.tar.age,
# readable by every recipient in secrets/recipients.txt. srcdir must mirror the
# on-device layout (e.g. src/usr/lib/aarch64-linux-gnu/...).
[group('rootfs')]
pack_arm_blobs srcdir:
    {{ _arm_blobs_script }} pack {{ srcdir }}

# Decrypt + install the blobs into the mounted rootfs (warn-only; never fails).
# Normally runs automatically as part of `just all` via the Makefile.
[group('rootfs')]
install_arm_blobs:
    {{ _make }} -C {{ justfile_directory() }} install_arm_blobs DEVICE={{ device }}

[group('rootfs')]
build_rootfs:
    {{ _make }} -C {{ justfile_directory() }} .debootstrap \
        DEVICE={{ device }} \
        RELEASE={{ debootstrap_release }} \
        ROOT_PW={{ root_password }} \
        {{ if hostname == "" { "" } else { "HOSTNAME=" + hostname } }} \
        {{ if size == "" { "" } else { "SIZE=" + size } }}

[group('rootfs')]
install_apt_packages:
    {{ _make }} -C {{ justfile_directory() }} .install_packages \
        DEVICE={{ device }} \
        USER_LOGIN={{ user_login }} \
        USER_PW={{ user_password }}

# Pull /vendor/firmware out of THIS device's factory OTA and stage it under
# build/<device>/vendor-firmware/extracted/. The Makefile's
# .install_vendor_firmware step rsyncs this into /vendor/firmware/ on the
# target image. Cached intermediates let re-runs skip already-completed work.
#
# The OTA URL and its pinned sha256 come from devices/<device>.mk — each device
# needs its own vendor firmware, and mixing them is not a subtle failure: without
# a matching aoc.bin the device does not boot at all (see CLAUDE.md).
[group('rootfs')]
[doc("Extract /vendor/firmware from this device's factory OTA")]
sync_vendor_firmware:
    #!/usr/bin/env bash
    set -euo pipefail
    ota_url=$({{ _make }} -C {{ justfile_directory() }} print-OTA_URL DEVICE={{ device }} | tail -1)
    ota_sha=$({{ _make }} -C {{ justfile_directory() }} print-OTA_SHA256 DEVICE={{ device }} | tail -1)
    work={{ _vendor_firmware_workdir }}
    zip="$work/{{ device }}-ota.zip"
    mkdir -p "$work" {{ _payload_dumper_dir }}

    # One-time download of payload-dumper-go (pinned) so OTA payloads can be opened.
    # Shared between devices — it is a host tool, not a device artifact.
    [ -x {{ _payload_dumper_bin }} ] || ( \
      {{ _curl }} -L --fail -o "$work/payload-dumper-go.tgz" \
        "https://github.com/ssut/payload-dumper-go/releases/download/{{ _payload_dumper_version }}/payload-dumper-go_{{ _payload_dumper_version }}_linux_amd64.tar.gz" \
      && tar -xzf "$work/payload-dumper-go.tgz" -C {{ _payload_dumper_dir }} \
      && chmod +x {{ _payload_dumper_bin }} \
    )

    # Download the OTA zip once. ~2GB; subsequent runs are cheap.
    [ -f "$zip" ] || {{ _curl }} -L --fail -o "$zip" "$ota_url"

    # Verify the OTA against its pinned hash — runs for cached downloads too, so a
    # stale or tampered zip is caught before we extract vendor firmware from it.
    echo "$ota_sha  $zip" | sha256sum -c -

    # Pull payload.bin out of the zip.
    [ -f "$work/payload.bin" ] || {{ _unzip }} -o "$zip" payload.bin -d "$work"

    # Extract only the vendor partition image from the A/B OTA payload.
    [ -f "$work/vendor.img" ] || \
      (cd "$work" && {{ _payload_dumper_bin }} -partitions vendor -output . payload.bin)

    # Extract the vendor partition into extracted/; the filesystem type has
    # changed over the years (ext4 on Android 14 builds, EROFS on some others)
    # and may also be wrapped in Android sparse framing, so the helper
    # auto-detects and handles both.
    {{ _extract_fs }} "$work/vendor.img" {{ _vendor_firmware_stage }}

# Each target below re-reads kernel/kernel_version.<device> at recipe time so it
# works immediately after `just build_kernel`, even though justfile-level exports
# were evaluated at parse time (before the file existed).
[doc('Reinstall kernel modules + headers into the rootfs')]
update_kernel_modules_and_source:
    KVER=$(cat {{ justfile_directory() }}/kernel/kernel_version.{{ device }}); \
    {{ _make }} -C {{ justfile_directory() }} .install_kernel DEVICE={{ device }} KERNEL_VERSION=$KVER

[doc('Rebuild the dracut initramfs')]
update_initramfs:
    KVER=$(cat {{ justfile_directory() }}/kernel/kernel_version.{{ device }}); \
    {{ _make }} -C {{ justfile_directory() }} .install_initramfs DEVICE={{ device }} KERNEL_VERSION=$KVER

[group('boot')]
build_boot_images:
    KVER=$(cat {{ justfile_directory() }}/kernel/kernel_version.{{ device }}); \
    {{ _make }} -C {{ justfile_directory() }} .build_boot \
        DEVICE={{ device }} \
        KERNEL_VERSION=$KVER \
        INITRAMFS_PATH={{ _sysroot_dir }}/boot/initrd.img-$KVER

# Built by `all` (since 2026-08-05) AND removed by `clean`, so clean+all really
# recreates every artifact. Kept as its own target too, for regenerating just this
# one. It used to be excluded to save 8 GiB, which left boot/ half-updated: a
# fresh boot chain beside a super.img holding the PREVIOUS rootfs, silently,
# because it is gitignored. Formerly: only the fastboot flash and a
# layout migration use it. See the SUPER_IMG block in the Makefile for why BOTH
# halves are seeded rather than just slot A.
#
# Build the full-flash super.img (whole partition, both halves seeded).
[group('boot')]
build_super_image:
    {{ _make }} -C {{ justfile_directory() }} super_image DEVICE={{ device }}
