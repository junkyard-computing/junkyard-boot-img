#!/bin/sh
# dracut pre-mount hook: reflash the root partition (`super`) from a staged image
# on `userdata`, BEFORE dracut mounts root. At this point `super` is just a free
# block device, so this needs no live-root unmount, no systemd shutdown-pivot,
# and no working dracut-shutdown.service (which is /bin/true on these images) —
# which makes it the portable rootfs cutover / OTA primitive.
#
# Trigger (set by the userspace updater, e.g. pixel-ota, then `reboot`):
#   userdata:/pixel-ota/rootfs.img         the raw rootfs image to write to super
#   userdata:/pixel-ota/rootfs.img.sha256  REQUIRED: lowercase hex sha256 of it
#   userdata:/pixel-ota/flash-pending      presence = "do it on next boot"
#
# The sha256 sidecar is MANDATORY and is checked before anything is written. The
# staging transfer is the fail-prone step (a ~GB image over the network), and an
# unverified write here destroys the live root with fastboot as the only recovery
# — which, on a fleet with no hands on the devices, is the worst outcome in the
# system. A missing or mismatched sidecar is therefore treated as "do not flash",
# NOT as "flash anyway": an image staged by an updater too old to write a sidecar
# will be refused. Failing to update is always recoverable; a destroyed root is not.
#
# Write-once semantics: the flag is cleared (and flushed) BEFORE the write, so a
# crash mid-write cannot loop-flash forever — a half-written super is recovered
# by re-staging + fastboot, an infinite reflash loop is not recoverable at all.
# Verification runs BEFORE the flag is cleared, though: a crash while hashing has
# written nothing, so retrying on the next boot is free. A verification FAILURE
# does clear the flag — re-reading the same bad image every boot cannot fix it,
# the updater has to re-stage.
command -v info >/dev/null 2>&1 || . /lib/dracut-lib.sh

SUPER=/dev/disk/by-partlabel/super
UD=/dev/disk/by-partlabel/userdata
MNT=/rootfs-flash
PENDING=pixel-ota/flash-pending
IMG=pixel-ota/rootfs.img
SHA=pixel-ota/rootfs.img.sha256

# Persist pending metadata changes. This initramfs may lack sync(1); sysrq is
# always-enabled via the kernel cmdline, and 's' syncs all filesystems.
# Both are best-effort. The sysrq write is wrapped so a failed *redirection* is
# swallowed too — `cmd > file 2>/dev/null` still lets the shell report that one.
flush() {
    sync 2>/dev/null
    { echo s > /proc/sysrq-trigger; } 2>/dev/null
}

# Disarm and give up without writing. Callers must `return 0` after this — we are
# inside a function, so `return` here would only leave the function, not the hook.
refuse() {  # <reason...>
    warn "rootfs-flash: $*"
    rm -f "$MNT/$PENDING"
    flush
    umount "$MNT" 2>/dev/null
}

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
    info "rootfs-flash: pending flash -> verifying $IMG"

    # --- verify (nothing written yet; safe to bail at any point) -------------
    expect=
    if [ -s "$MNT/$SHA" ]; then
        # Accepts a bare hex digest or `sha256sum` output ("<hex>  <name>").
        read -r expect _rest < "$MNT/$SHA" 2>/dev/null || expect=
    fi
    if [ -z "$expect" ]; then
        refuse "no sha256 sidecar ($SHA) -- REFUSING to write $SUPER"
        return 0
    fi
    actual=$(sha256sum < "$MNT/$IMG" 2>/dev/null) || actual=
    actual=${actual%% *}
    if [ "$actual" != "$expect" ]; then
        refuse "sha256 MISMATCH: want $expect, got ${actual:-<none>} -- REFUSING $SUPER"
        return 0
    fi
    info "rootfs-flash: sha256 ok ($actual)"

    # --- fit check: a short write would leave super truncated ----------------
    isz=$(stat -c %s "$MNT/$IMG" 2>/dev/null) || isz=
    dsz=$(blockdev --getsize64 "$SUPER" 2>/dev/null) || dsz=
    case "$isz:$dsz" in
        *[!0-9:]*|:*|*:)
            warn "rootfs-flash: could not size image/$SUPER -- skipping fit check" ;;
        *)
            if [ "$isz" -gt "$dsz" ]; then
                refuse "image $isz > $SUPER $dsz -- REFUSING to write"
                return 0
            fi ;;
    esac

    info "rootfs-flash: writing $IMG onto $SUPER"
    # Disarm before writing, and persist that first — see the write-once note above.
    rm -f "$MNT/$PENDING"
    flush
    if cat "$MNT/$IMG" > "$SUPER"; then
        info "rootfs-flash: write complete"
    else
        warn "rootfs-flash: write FAILED -- super may be inconsistent"
    fi
    flush
else
    info "rootfs-flash: no pending flash (looked for $MNT/$PENDING + $MNT/$IMG)"
fi

umount "$MNT" 2>/dev/null
return 0
