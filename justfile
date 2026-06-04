# Thin orchestration layer; the Makefile owns the sentinel-tracked build
# pipeline so reruns skip already-finished stages. See Makefile for details.

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
_extract_fs := join(justfile_directory(), "tools", "extract-partition-fs.sh")
[private]
_mkbootimg := join(justfile_directory(), "tools", "mkbootimg", "mkbootimg.py")
[private]
_bazel := join(justfile_directory(), "kernel", "source", "tools", "bazel")

# Paths / variables
[private]
_kernel_build_dir := join(justfile_directory(), "kernel", "source", "out", "felix", "dist")
[private]
_kernel_version := trim(read(join("kernel", "kernel_version")))
[private]
_sysroot_img := join(justfile_directory(), "boot", "rootfs.img")
[private]
_sysroot_dir := join(justfile_directory(), "rootfs", "sysroot")
[private]
_module_order_path := join(justfile_directory(), "rootfs", "module_order.txt")
[private]
_initramfs_path := join(_sysroot_dir, "boot", "initrd.img-" + _kernel_version)

# Vendor firmware extraction (Pixel Fold / felix OTA).
[private]
_felix_ota_url := "https://dl.google.com/dl/android/aosp/felix-ota-cp1a.260405.005-7a13341e.zip"
# We can't redistribute the OTA, but we pin it by content hash: sync_vendor_firmware
# verifies the downloaded zip against this, so a rotated/corrupt OTA fails loudly
# instead of silently changing the vendor firmware. (The zip's content matches the
# `-7a13341e` prefix Google embeds in the URL.)
[private]
_felix_ota_sha256 := "7a13341eb090a7656e67e1244b832420ffe6c7c0f2530d544ab9e7e23c69ff56"
[private]
_vendor_firmware_workdir := join(justfile_directory(), "rootfs", "vendor-firmware")
[private]
_vendor_firmware_stage := join(_vendor_firmware_workdir, "extracted")
[private]
_payload_dumper_version := "1.2.2"
[private]
_payload_dumper_dir := join(justfile_directory(), "tools", "payload-dumper-go")
[private]
_payload_dumper_bin := join(_payload_dumper_dir, "payload-dumper-go")

# Env vars consumed by Makefile
[private]
export APT_PACKAGES := _apt_packages
[private]
export INITRAMFS_PATH := _initramfs_path
[private]
export KERNEL_BUILD_DIR := _kernel_build_dir
[private]
export KERNEL_SOURCE_DIR := join("kernel", "source")
[private]
export KERNEL_VERSION := _kernel_version
[private]
export MKBOOTIMG := _mkbootimg
[private]
export SYSROOT_DIR := _sysroot_dir
[private]
export BAZEL := _bazel
[private]
export MODULE_ORDER_PATH := _module_order_path

default:
    just --list

# Run the full pipeline. Takes ~1hr on first run (kernel build dominates).
# Reruns skip already-finished stages thanks to the Makefile's sentinel files.
#
# Split into two make invocations so the second picks up the fresh
# KERNEL_VERSION written by .build_kernel. justfile exports are evaluated at
# parse time, so on a fresh checkout KERNEL_VERSION would be empty without
# this split.
all android_kernel_branch="android-gs-felix-6.1-android16" size="8100M" debootstrap_release="trixie" root_password="0000" hostname="fold" user_login="kalm" user_password="0000": (clone_kernel_source android_kernel_branch)
    {{ _make }} -C {{ justfile_directory() }} .build_kernel
    KVER=$(cat {{ justfile_directory() }}/kernel/kernel_version); \
    {{ _make }} -C {{ justfile_directory() }} .build_boot \
        SIZE={{ size }} \
        RELEASE={{ debootstrap_release }} \
        ROOT_PW={{ root_password }} \
        USER_LOGIN={{ user_login }} \
        USER_PW={{ user_password }} \
        HOSTNAME={{ hostname }} \
        KERNEL_VERSION=$KVER \
        INITRAMFS_PATH={{ _sysroot_dir }}/boot/initrd.img-$KVER
    # Always-run provenance stamp (PHONY, recomputed every build) — writes the
    # kernel-bound IMAGE_VERSION into the rootfs so two phones can be told apart
    # by what they actually run. KERNEL_VERSION must be passed so the +k<ver>
    # suffix reflects this build's kernel, not a stale one.
    KVER=$(cat {{ justfile_directory() }}/kernel/kernel_version); \
    {{ _make }} -C {{ justfile_directory() }} stamp_version KERNEL_VERSION=$KVER
    # Return blocks freed during the build (apt cache, pruned kernel trees) to
    # the sparse backing file so boot/rootfs.img doesn't bloat over time.
    just trim_rootfs

[group('kernel')]
[working-directory: 'kernel/source']
clone_kernel_source android_kernel_branch="android-gs-felix-6.1-android16":
    @echo "Cloning Android kernel from branch: {{ android_kernel_branch }}"
    # `< /dev/null` on every `repo init`: its interactive color prompt otherwise
    # writes color.ui to the global git config — on NixOS (home-manager) that's a
    # read-only /nix/store symlink, so the write fails "Read-only file system".
    # Non-interactive stdin makes repo default the prompt to "no" (no write).
    #
    # Reproducibility: if a pinned manifest exists (kernel/kernel-manifest.xml,
    # produced by `just pin_kernel_source`), select it so sync checks out the exact
    # recorded per-project SHAs instead of whatever the branch tips are today. The
    # pinned path is a FULL (non-shallow) init — a --depth=1 clone can only fetch
    # current branch tips, so it can't reach a pinned SHA once the branch advances.
    # With no pin, stay shallow for a fast first sync, then run pin_kernel_source.
    if [ -f {{ justfile_directory() }}/kernel/kernel-manifest.xml ]; then \
        echo "Pinned manifest found — full sync against recorded SHAs"; \
        {{ _repo }} init \
          -u https://android.googlesource.com/kernel/manifest \
          -b {{ android_kernel_branch }} \
          < /dev/null; \
        cp {{ justfile_directory() }}/kernel/kernel-manifest.xml .repo/manifests/; \
        {{ _repo }} init -m kernel-manifest.xml < /dev/null; \
    else \
        echo "No pinned manifest — shallow init (run 'just pin_kernel_source' to lock)"; \
        {{ _repo }} init \
          --depth=1 \
          -u https://android.googlesource.com/kernel/manifest \
          -b {{ android_kernel_branch }} \
          < /dev/null; \
    fi
    {{ _repo }} sync -j {{ num_cpus() }}
    if [ ! -e custom_defconfig_mod ]; then \
        ln -s ../custom_defconfig_mod ./; \
    fi

# Lock the kernel source to its current per-project SHAs by regenerating
# kernel/kernel-manifest.xml from the synced tree. Commit the result; thereafter
# clone_kernel_source does a full sync against these exact revisions. Re-run
# after an intentional kernel branch/version bump, then rebuild kernel + rootfs
# modules in lockstep.
[group('kernel')]
[working-directory: 'kernel/source']
pin_kernel_source:
    {{ _repo }} manifest -r -o {{ justfile_directory() }}/kernel/kernel-manifest.xml
    @echo "Wrote kernel/kernel-manifest.xml — commit it to lock the kernel source."

[group('kernel')]
[working-directory: 'kernel/source']
clean_kernel: clone_kernel_source
    {{ _bazel }} clean --expunge
    rm -f {{ justfile_directory() }}/.build_kernel

# Print a diff showing what the custom fragment would change vs. gki_defconfig.
[group('kernel')]
[working-directory: 'kernel/source']
config_kernel: clone_kernel_source
    cp ./aosp/arch/arm64/configs/gki_defconfig ./gki_defconfig_original
    {{ _bazel }} run //private/devices/google/felix:kernel_config -- nconfig
    diff -up ./gki_defconfig_original aosp/arch/arm64/configs/gki_defconfig; [ $? -eq 0 ] || [ $? -eq 1 ]
    rm ./gki_defconfig_original
    cd aosp; git checkout arch/arm64/configs/gki_defconfig

[group('kernel')]
build_kernel: clone_kernel_source
    {{ _make }} -C {{ justfile_directory() }} .build_kernel

# Create the empty ext4 rootfs image.
[group('rootfs')]
create_rootfs_image size="8100M": unmount_rootfs
    {{ _make }} -C {{ justfile_directory() }} .create_image SIZE={{ size }}

# Mount the ext4 rootfs image at rootfs/sysroot. The --make-rprivate is required:
# / is mounted shared, so without it systemd-nspawn's container /dev mounts propagate
# back to the host and nspawn (systemd >= 260) then trips over its own propagated mounts
# with "/dev is pre-mounted and pre-populated" / "Failed to create /dev/pts: File exists".
# Apply --make-rprivate unconditionally so a sysroot reused across runs (e.g. when a
# prior nspawn failed mid-recipe) still becomes private even though we skip the mount.
mount_rootfs size="8100M": (create_rootfs_image size)
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
# `just all` runs this automatically at the end; run it standalone any time to
# shrink boot/rootfs.img on disk.
[group('rootfs')]
trim_rootfs: mount_rootfs
    sudo fstrim -v {{ _sysroot_dir }}
    just unmount_rootfs

# Delete the rootfs image and associated sentinels.
[group('rootfs')]
clean_rootfs: unmount_rootfs
    {{ _make }} -C {{ justfile_directory() }} clean_image

# Delete the rootfs image, boot images, kernel-staging unpack dir, and all
# image-pipeline sentinels. Preserves the cached kernel build (`just
# clean_kernel` for that) and the cached felix OTA under rootfs/vendor-firmware/
# so the next `just all` skips the ~1hr kernel build and ~2GB OTA download.
clean: unmount_rootfs
    {{ _make }} -C {{ justfile_directory() }} clean

# Refresh the snapshot.debian.org pins: the Debian archive timestamp
# (rootfs/debian_snapshot, read via the Makefile's SNAPSHOT/MIRROR) and the
# kmscon .deb URL+hash (rootfs/kmscon.env, -include'd by the Makefile). With no
# args, pins the latest snapshot and refreshes kmscon; pass through tool flags
# otherwise, e.g. `just update_snapshot --date 2026-05-01`,
# `just update_snapshot --no-kmscon`, or `just update_snapshot --dry-run`.
[group('rootfs')]
update_snapshot *args:
    {{ justfile_directory() }}/tools/update-snapshot.sh {{ args }}

[group('rootfs')]
build_rootfs debootstrap_release="trixie" root_password="0000" hostname="fold" size="8100M":
    {{ _make }} -C {{ justfile_directory() }} .debootstrap \
        RELEASE={{ debootstrap_release }} \
        ROOT_PW={{ root_password }} \
        HOSTNAME={{ hostname }} \
        SIZE={{ size }}

[group('rootfs')]
install_apt_packages user_login="kalm" user_password="0000":
    {{ _make }} -C {{ justfile_directory() }} .install_packages \
        USER_LOGIN={{ user_login }} \
        USER_PW={{ user_password }}

# Pull /vendor/firmware out of the Pixel Fold (felix) factory OTA and stage it
# under rootfs/vendor-firmware/extracted/. The Makefile's
# .install_vendor_firmware step rsyncs this into /vendor/firmware/ on the
# target image. Cached intermediates let re-runs skip already-completed work.
[group('rootfs')]
sync_vendor_firmware:
    mkdir -p {{ _vendor_firmware_workdir }} {{ _payload_dumper_dir }}

    # One-time download of payload-dumper-go (pinned) so OTA payloads can be opened.
    [ -x {{ _payload_dumper_bin }} ] || ( \
      {{ _curl }} -L --fail -o {{ _vendor_firmware_workdir }}/payload-dumper-go.tgz \
        "https://github.com/ssut/payload-dumper-go/releases/download/{{ _payload_dumper_version }}/payload-dumper-go_{{ _payload_dumper_version }}_linux_amd64.tar.gz" \
      && tar -xzf {{ _vendor_firmware_workdir }}/payload-dumper-go.tgz -C {{ _payload_dumper_dir }} \
      && chmod +x {{ _payload_dumper_bin }} \
    )

    # Download the OTA zip once. ~2GB; subsequent runs are cheap.
    [ -f {{ _vendor_firmware_workdir }}/felix-ota.zip ] || \
      {{ _curl }} -L --fail -o {{ _vendor_firmware_workdir }}/felix-ota.zip "{{ _felix_ota_url }}"

    # Verify the OTA against its pinned hash — runs for cached downloads too, so a
    # stale or tampered zip is caught before we extract vendor firmware from it.
    echo "{{ _felix_ota_sha256 }}  {{ _vendor_firmware_workdir }}/felix-ota.zip" | sha256sum -c -

    # Pull payload.bin out of the zip.
    [ -f {{ _vendor_firmware_workdir }}/payload.bin ] || \
      {{ _unzip }} -o {{ _vendor_firmware_workdir }}/felix-ota.zip payload.bin -d {{ _vendor_firmware_workdir }}

    # Extract only the vendor partition image from the A/B OTA payload.
    [ -f {{ _vendor_firmware_workdir }}/vendor.img ] || \
      (cd {{ _vendor_firmware_workdir }} && {{ _payload_dumper_bin }} -partitions vendor -output . payload.bin)

    # Extract the vendor partition into extracted/; filesystem type on felix
    # has changed over the years (ext4 on Android 14 builds, EROFS on some
    # others) and may also be wrapped in Android sparse framing, so the helper
    # auto-detects and handles both.
    {{ _extract_fs }} {{ _vendor_firmware_workdir }}/vendor.img {{ _vendor_firmware_stage }}

# Each target below re-reads kernel/kernel_version at recipe time so it works
# immediately after `just build_kernel`, even though justfile-level exports
# were evaluated at parse time (before the file existed).
update_kernel_modules_and_source:
    KVER=$(cat {{ justfile_directory() }}/kernel/kernel_version); \
    {{ _make }} -C {{ justfile_directory() }} .install_kernel KERNEL_VERSION=$KVER

update_initramfs:
    KVER=$(cat {{ justfile_directory() }}/kernel/kernel_version); \
    {{ _make }} -C {{ justfile_directory() }} .install_initramfs KERNEL_VERSION=$KVER

[group('boot')]
build_boot_images:
    KVER=$(cat {{ justfile_directory() }}/kernel/kernel_version); \
    {{ _make }} -C {{ justfile_directory() }} .build_boot \
        KERNEL_VERSION=$KVER \
        INITRAMFS_PATH={{ _sysroot_dir }}/boot/initrd.img-$KVER
