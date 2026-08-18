# Per-device build config for lynx (Pixel 7a, Tensor G2 / gs201).
#
# Same SoC as felix — only these board values differ. Included by the Makefile
# via `include devices/$(DEVICE).mk`; a command-line `make VAR=val` overrides.

KERNEL_BRANCH := android-gs-lynx-6.1-android16
BAZEL_CONFIG  := lynx
BAZEL_TARGET  := //private/devices/google/lynx:gs201_lynx_dist

# lynx full OTA (Android 16, cp1a) — the direct parallel to felix's cp1a image:
# same Android major => same vendor-firmware ABI expectations. Newer Android-17
# cp2a images exist (lynx-ota-cp2a.260705.006-f4d6d546.zip,
# sha256 f4d6d546e812da1ebbc9d4028025aa2d3da0e162935e95693e8185d6477e0f27) — swap
# URL+hash to track those. Pinned by content hash.
OTA_URL    := https://dl.google.com/dl/android/aosp/lynx-ota-cp1a.260505.005-fd391772.zip
OTA_SHA256 := fd391772de040173a19d97bc080cccb6785ac91d3b2b6b770bcef0fb4ea4018f

# ★ lynx's `super` is BYTE-IDENTICAL to felix's — this is measured, not assumed.
#
#   39271JEHN00059 (lynx, MP1.0, bootloader lynx-16.4-14540572), 2026-08-05:
#     fastboot getvar partition-size:super    -> 0x1fc800000 = 8531214336 = 8136 MiB
#     fastboot getvar partition-size:userdata -> 0x1b7a615000 = 109.9 GiB
#
# So the A/B half, and therefore SIZE, are the same as felix. userdata DOES
# differ (felix is 229 GiB, this is a 128 GB 7a) but nothing here keys on its
# size — flash-ssh.sh finds the staging partition by GPT label, not by node or
# capacity, which is why there is deliberately no USERDATA_DEV here. Set that in
# the environment if a specific device ever needs the override.
SIZE        := 4000M
SUPER_BYTES := 8531214336
HOSTNAME    := lynx

# ⚠ NOT YET BUILT OR BOOTED. The values above are read off real hardware, but no
# image built from this fragment has been flashed yet — the lynx kernel branch
# has never been synced or built here, so treat the first `just device=lynx all`
# as bring-up, not a rebuild.
#
# The bench unit 39271JEHN00059 (MP1.0, bootloader lynx-16.4-14540572) reports
# `unlocked: yes`, so the fastboot path is open. Note that
# `secure-boot: PRODUCTION` still holds: our repacked boot chain is unsigned, so
# it needs the same per-slot `fastboot oem disable-verity` / `disable-verification`
# treatment felix does, and the same vbmeta flag normalisation on the INACTIVE
# slot before an OTA (see flash-ssh.sh) — that per-slot trap is not felix-specific.
#
# The boot-chain partition set is confirmed identical to felix — boot, init_boot,
# vendor_boot, vendor_kernel_boot, dtbo, vbmeta, vbmeta_system, vbmeta_vendor and
# pvmfw all report has-slot:yes — so pixel-ota's flash list needs no change.

# Human-facing model name, used in the operator-facing provisioning README.
DEVICE_MODEL := Pixel 7a
