#!/bin/bash
#
# The felix dtbo carries the board-variant overrides that flip serial_0,
# the panels, and other felix-specific nodes from status="disabled" (as
# defined in gs201.dtsi) to status="okay". Without it UART login and the
# display silently go dead. Any prior "reflash to stock" wipes whatever
# stock dtbo was there, so always re-flash ours.
DTBO=../kernel/source/out/felix/dist/dtbo.img

pushd boot

fastboot oem disable-verification
fastboot oem disable-verity
fastboot erase init_boot
fastboot erase boot
fastboot flash boot boot.img
fastboot erase vendor_boot
fastboot flash vendor_boot vendor_boot.img
fastboot erase dtbo
fastboot flash dtbo "$DTBO"
fastboot erase super
fastboot flash super rootfs.img
fastboot erase vendor_kernel_boot
# fastboot oem uart disable
fastboot reboot

popd