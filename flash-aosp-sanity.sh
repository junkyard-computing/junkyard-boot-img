#!/bin/bash
# UFS hardware sanity test: flash stock felix boot/vendor_boot/vendor_kernel_boot/dtbo
# extracted from the OTA. Leaves `super` partition (our Debian rootfs) alone.
# Boot will fail at Android init (no /system on super), but UFS will probe
# during kernel init — look for "KIOXIA" / "Direct-Access" in UART log.
# Recovery: re-run ./flash.sh to restore mainline.
set -euo pipefail

cd "$(dirname "$0")/aosp-sanity"

fastboot oem disable-verification || true
fastboot oem disable-verity || true

fastboot erase boot
fastboot flash boot boot.img
fastboot erase vendor_boot
fastboot flash vendor_boot vendor_boot.img
fastboot erase vendor_kernel_boot
fastboot flash vendor_kernel_boot vendor_kernel_boot.img
fastboot erase dtbo
fastboot flash dtbo dtbo.img

# Deliberately do NOT touch `super` — preserves Debian rootfs.
# Android init will fail when it can't find /system, but UFS will have
# already probed by then. That's the signal we're looking for.

fastboot reboot
