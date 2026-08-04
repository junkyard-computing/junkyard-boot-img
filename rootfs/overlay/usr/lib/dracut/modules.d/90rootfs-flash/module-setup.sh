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
    #
    # sha256sum: primary integrity check in flash-rootfs.sh.
    # stat: the SIZE fallback, used when sha256sum turns out to be unusable at
    # runtime. That is not hypothetical — on 35041FDHS0032G sha256sum was
    # installed here and still produced nothing, which made the hook refuse a
    # good image and leave the unit on a mismatched kernel/rootfs pair. The
    # fallback needs a tool that is NOT the one that just failed.
    #
    # cut/tr: the hook no longer parses digests with `cut` (it uses shell
    # parameter expansion, because `cut` turned out to be absent here and that
    # made the sha256sum self-test fail against its own pipeline rather than
    # against sha256sum). `tr` is still used to strip whitespace from the staged
    # .sha256/.size files. Install both anyway — a missing helper in the
    # integrity gate degrades it silently, which is the one failure mode this
    # whole hook exists to avoid.
    inst_multiple cat mount umount mkdir rm sync sha256sum stat cut tr blockdev
}
