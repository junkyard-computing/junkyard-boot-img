#!/bin/bash
# rootfs-slot dracut module — maps the active half of `super` as /dev/mapper/rootfs
# so boot.img's `root=/dev/mapper/rootfs` resolves. See rootfs-slot.sh for the
# layout and for why the hook is initqueue/settled rather than pre-mount.
#
# Included in the initramfs via `dracut --add rootfs-slot` (see Makefile
# .install_initramfs). This file ships in the rootfs overlay so it is present in
# the sysroot's modules.d when dracut runs inside the build nspawn.

# Always include when explicitly --add'ed.
check() {
    return 0
}

# dm brings in dmsetup plus the device-mapper udev rules, so the /dev/mapper node
# and its symlinks are created the way the rest of dracut expects.
depends() {
    echo "dm"
    return 0
}

install() {
    inst_hook initqueue/settled 30 "$moddir/rootfs-slot.sh"
    # dmsetup arrives via the dm dependency; blockdev is ours (sizing `super`).
    inst_multiple blockdev
    # pixel-bootctl gives rootfs-slot the boot slot on mainline, where there is no
    # /proc/bootconfig to read androidboot.slot_suffix from. It is a static musl
    # binary, so there are no shared libraries to pull in alongside it. Guarded so
    # a build without it (e.g. the Rust cross-build skipped) still produces an
    # initramfs — rootfs-slot then falls back to _a.
    if [ -x "${dracutsysrootdir}/usr/local/bin/pixel-bootctl" ]; then
        inst_multiple /usr/local/bin/pixel-bootctl
    else
        dwarn "rootfs-slot: pixel-bootctl not found; mainline slot detection falls back to _a"
    fi
}
