#!/bin/bash
#
pushd boot

fastboot oem disable-verification
fastboot oem disable-verity
fastboot erase init_boot
fastboot erase boot
fastboot flash boot boot.img
fastboot erase vendor_boot
fastboot flash vendor_boot vendor_boot.img
fastboot erase super
fastboot flash super rootfs.img
fastboot erase vendor_kernel_boot
# Erase dtbo so the bootloader skips the factory device-tree overlay. Our dtb
# (built from the junkyard-computing felix branch) carries the full board
# description; the factory dtbo's phandle fixups target a __symbols__ node
# that a standard kbuild dtb doesn't emit, and the bootloader refuses to boot
# when the merge fails.
fastboot erase dtbo
# fastboot oem uart disable
# fastboot reboot

popd