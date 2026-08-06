# Per-device build config for felix (Pixel Fold, Tensor G2 / gs201).
#
# Included by the Makefile via `include devices/$(DEVICE).mk`. These are the ONLY
# values that differ between gs201 Pixels — everything else in the tree is
# SoC-level or userspace and is shared. A command-line `make VAR=val` (and the
# justfile's size=/hostname= variables) still beats anything set here.

KERNEL_BRANCH := android-gs-felix-6.1-android16
BAZEL_CONFIG  := felix
BAZEL_TARGET  := //private/devices/google/felix:gs201_felix_dist

# felix full OTA (Android 16, cp1a). sync_vendor_firmware extracts /vendor/firmware
# (aoc.bin, ...) from this. Pinned by content hash so a rotated/corrupt OTA fails
# the sync loudly instead of silently changing the vendor firmware. The zip's
# content matches the `-7a13341e` prefix Google embeds in the URL.
OTA_URL    := https://dl.google.com/dl/android/aosp/felix-ota-cp1a.260405.005-7a13341e.zip
OTA_SHA256 := 7a13341eb090a7656e67e1244b832420ffe6c7c0f2530d544ab9e7e23c69ff56

# Rootfs image size — ONE HALF of `super`, not all of it.
#
# ⚠ This was 8100M before rootfs A/B landed, when one rootfs filled the whole
# partition. super is 8136 MiB split into two 4068 MiB slots that the initramfs
# maps one at a time (see the rootfs-slot dracut module); 4000M leaves a little
# slack inside a half. Raising it past 4068 silently produces an image that
# overruns slot A into slot B.
SIZE     := 4000M
HOSTNAME := fold

# The whole `super` partition, for the full-flash super.img. Must match the
# TARGET device, not the build host.
#
# MEASURED: `fastboot getvar partition-size:super` = 0x1FC800000 = 8136 MiB
# exactly. Confirmed identical on all three felixes.
SUPER_BYTES := 8531214336
