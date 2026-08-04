#!/bin/sh
# dracut pre-mount hook: reflash the root partition (`super`) from a staged image
# on `userdata`, BEFORE dracut mounts root. At this point `super` is just a free
# block device, so this needs no live-root unmount, no systemd shutdown-pivot,
# and no working dracut-shutdown.service (which is /bin/true on these images) —
# which makes it the portable rootfs cutover / OTA primitive.
#
# Trigger (set by the userspace updater, e.g. pixel-ota, then `reboot`):
#   userdata:/pixel-ota/rootfs.img      the raw rootfs image to write to super
#   userdata:/pixel-ota/flash-pending   presence = "do it on next boot"
#
# Write-once semantics: the flag is cleared (and flushed) BEFORE the write, so a
# crash mid-write cannot loop-flash forever — a half-written super is recovered
# by re-staging + fastboot, an infinite reflash loop is not recoverable at all.
command -v info >/dev/null 2>&1 || . /lib/dracut-lib.sh

SUPER=/dev/disk/by-partlabel/super
UD=/dev/disk/by-partlabel/userdata
MNT=/rootfs-flash
PENDING=pixel-ota/flash-pending
IMG=pixel-ota/rootfs.img

info "rootfs-flash: hook invoked"
# Make sure the partition symlinks exist this early in boot.
udevadm settle --timeout=10 2>/dev/null
[ -b "$SUPER" ] || { info "rootfs-flash: $SUPER not present, skip"; return 0; }
[ -b "$UD" ]    || { info "rootfs-flash: $UD not present, skip"; return 0; }

mkdir -p "$MNT"
if ! mount -t ext4 "$UD" "$MNT" 2>/dev/null; then
    info "rootfs-flash: mount $UD failed, skip"
    return 0
fi

if [ -e "$MNT/$PENDING" ] && [ -s "$MNT/$IMG" ]; then
    # INTEGRITY GATE — `[ -s ]` above only proves the file is non-empty, which is
    # nowhere near enough to bet the rootfs on. Staging is a long network
    # transfer and is interruptible; setting the flag is a SEPARATE action, so a
    # partial image plus a flag is an entirely reachable state. Observed for real
    # on 2026-08-03: a 1.06 GB fragment of a 7.9 GiB image sat in the staging dir
    # from an interrupted transfer days earlier. Writing that over `super`
    # produces a truncated filesystem and a device that cannot boot — and since
    # `super` is NOT slotted there is no rollback, so recovery means fastboot and
    # physical access to a unit whose whole point is that it has neither.
    #
    # Protocol: the updater SHOULD stage `<img>.sha256` next to the image (the
    # bare hex digest, as produced by `sha256sum <img> | cut -d' ' -f1`). If that
    # file is present the digest MUST match or the flash is refused. If it is
    # absent we proceed, so older updaters keep working — but we say so loudly,
    # because an unverified write is exactly the failure mode above.
    if [ -s "$MNT/$IMG.sha256" ]; then
        want=$(cat "$MNT/$IMG.sha256" 2>/dev/null | tr -d ' \t\n\r')
        info "rootfs-flash: verifying $IMG against staged digest"
        got=$(sha256sum "$MNT/$IMG" 2>/dev/null | cut -d' ' -f1)
        if [ -z "$got" ]; then
            warn "rootfs-flash: sha256sum unavailable -- REFUSING to flash"
            rm -f "$MNT/$PENDING"; sync 2>/dev/null
            umount "$MNT" 2>/dev/null
            return 0
        fi
        if [ "$got" != "$want" ]; then
            warn "rootfs-flash: DIGEST MISMATCH -- refusing to flash $SUPER"
            warn "rootfs-flash:   staged: $want"
            warn "rootfs-flash:   actual: $got"
            # Clear the flag: a corrupt image will not become correct on retry,
            # and leaving it armed would re-attempt this every single boot.
            rm -f "$MNT/$PENDING"; sync 2>/dev/null
            umount "$MNT" 2>/dev/null
            return 0
        fi
        info "rootfs-flash: digest OK"
    else
        warn "rootfs-flash: no $IMG.sha256 staged -- writing UNVERIFIED image"
    fi

    info "rootfs-flash: pending flash -> writing $IMG onto $SUPER"
    rm -f "$MNT/$PENDING"
    # Persist the flag removal first. This initramfs may lack sync(1); sysrq is
    # always-enabled via the kernel cmdline, and 's' syncs all filesystems.
    sync 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null
    if cat "$MNT/$IMG" > "$SUPER"; then
        info "rootfs-flash: write complete"
    else
        warn "rootfs-flash: write FAILED -- super may be inconsistent"
    fi
    sync 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null
else
    info "rootfs-flash: no pending flash (looked for $MNT/$PENDING + $MNT/$IMG)"
fi

umount "$MNT" 2>/dev/null
return 0
