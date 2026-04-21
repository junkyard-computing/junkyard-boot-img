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
# fastboot oem uart disable
fastboot reboot

popd