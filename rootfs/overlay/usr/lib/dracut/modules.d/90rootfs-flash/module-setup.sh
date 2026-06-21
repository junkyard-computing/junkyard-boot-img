#!/bin/bash
# rootfs-flash dracut module — installs a pre-mount hook that reflashes `super`
# from a staged image on `userdata` before root is mounted. This is the portable
# rootfs cutover/OTA primitive: the device only has to accept a boot-chain flash
# (which works over SSH), then the next boot self-installs the new rootfs.
# See flash-rootfs.sh for the trigger protocol.
#
# Included in the initramfs via `dracut --add rootfs-flash` (see Makefile
# .install_initramfs). This file ships in the rootfs overlay so it is present in
# the sysroot's modules.d when dracut runs inside the build nspawn.

# Always include when explicitly --add'ed.
check() {
    return 0
}

# No dependencies on other dracut modules.
depends() {
    echo ""
    return 0
}

install() {
    inst_hook pre-mount 50 "$moddir/flash-rootfs.sh"
    # The hook needs these in the initramfs. The base image's busybox/util set
    # lacks sync(1); pull it in so the hook can flush without relying on sysrq.
    inst_multiple cat mount umount mkdir rm sync
}
