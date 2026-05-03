# Thin orchestration layer; the Makefile owns the sentinel-tracked build
# pipeline so reruns skip already-finished stages. See Makefile for details.

# Config
[private]
_apt_packages_file := join("rootfs", "packages.txt")
[private]
_apt_packages := replace(read(_apt_packages_file), "\n", " ")

# Tools
[private]
_git := require("git")
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
_lz4 := require("lz4")
[private]
_extract_fs := join(justfile_directory(), "tools", "extract-partition-fs.sh")
[private]
_mkbootimg := join(justfile_directory(), "tools", "mkbootimg", "mkbootimg.py")

# Paths / variables
[private]
_kernel_build_dir := join(justfile_directory(), "kernel", "source", "out")
# shell() instead of read() so a missing kernel_version (fresh checkout, or
# post-`just clean_kernel`) doesn't abort justfile parsing. `.build_kernel`
# will write the real value; the two-invocation split in `all` re-reads it
# at recipe time.
[private]
_kernel_version := trim(shell("cat kernel/kernel_version 2>/dev/null || true"))
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
export MODULE_ORDER_PATH := _module_order_path

default:
    just --list

# Run the full pipeline. Takes a while on first run (kernel build dominates).
# Reruns skip already-finished stages thanks to the Makefile's sentinel files.
#
# Split into two make invocations so the second picks up the fresh
# KERNEL_VERSION written by .build_kernel. justfile exports are evaluated at
# parse time, so on a fresh checkout KERNEL_VERSION would be empty without
# this split.
all size="8100M" debootstrap_release="trixie" root_password="0000" hostname="fold" user_login="kalm" user_password="0000": clone_kernel_source
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

# Sync the kernel source submodule (github.com/junkyard-computing/linux, felix
# branch). The branch name is pinned in .gitmodules; update it there if you
# need to change branches.
[group('kernel')]
clone_kernel_source:
    {{ _git }} submodule update --init --recursive kernel/source

[group('kernel')]
clean_kernel:
    {{ _make }} -C {{ justfile_directory() }}/kernel/source mrproper O=out || true
    rm -rf {{ justfile_directory() }}/kernel/source/out
    rm -f {{ justfile_directory() }}/.build_kernel

# Drop into nconfig against the current kernel build tree so transitive deps
# resolve correctly.
[group('kernel')]
config_kernel: clone_kernel_source
    {{ _make }} -C {{ justfile_directory() }}/kernel/source ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=out nconfig

[group('kernel')]
build_kernel: clone_kernel_source
    {{ _make }} -C {{ justfile_directory() }} .build_kernel

# Create the empty ext4 rootfs image.
[group('rootfs')]
create_rootfs_image size="8100M": unmount_rootfs
    {{ _make }} -C {{ justfile_directory() }} .create_image SIZE={{ size }}

# Mount the ext4 rootfs image at rootfs/sysroot.
mount_rootfs size="8100M": (create_rootfs_image size)
    @mkdir -p {{ _sysroot_dir }}
    @if ! mountpoint -q {{ _sysroot_dir }}; then \
      echo "Mounting rootfs image at {{ _sysroot_dir }}"; \
      sudo mount {{ _sysroot_img }} {{ _sysroot_dir }}; \
    fi

# Unmount the ext4 rootfs image.
unmount_rootfs:
    @if mountpoint -q {{ _sysroot_dir }}; then \
      echo "Unmounting rootfs image from {{ _sysroot_dir }}"; \
      sudo umount {{ _sysroot_dir }}; \
    fi

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
