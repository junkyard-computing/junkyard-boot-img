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
    # Protocol: the updater stages `<img>.sha256` (bare hex digest) and
    # `<img>.size` (decimal byte count) next to the image.
    #
    # ★ TWO-TIER, because "cannot verify" MUST NOT mean "silently do nothing".
    #
    # The first version treated empty sha256sum output as "tool unavailable" and
    # REFUSED. On 35041FDHS0032G (2026-08-04) that turned a perfectly good OTA
    # into a no-op: the hook ran, printed "sha256sum unavailable -- REFUSING",
    # cleared the flag, and left the unit with a NEW AOSP kernel on the OLD
    # mainline rootfs — no matching /lib/modules, so no NIC, reachable only over
    # the USB gadget with a physical cable. The binary was demonstrably PRESENT
    # in that initramfs (usr/bin/sha256sum); it just produced nothing, and it
    # did so in ~7s, far too fast to have hashed 8 GiB. So it ran and FAILED
    # (most likely an unresolved library), and an empty result cannot be read as
    # "missing".
    #
    # Now: self-test sha256sum against a known vector, keep its stderr, and fall
    # back to a SIZE check when it is unusable. Size is weaker than a digest but
    # it catches the failure that has actually happened twice here — a truncated
    # staging transfer (a 1.06 GB fragment, and a 457 MB one) — and it is far
    # better than either refusing a good image or writing an unchecked one.
    #
    # ★ The "unresolved library" guess above was WRONG, and the way it was wrong
    # is the lesson. On 35071FDHS0017C (2026-08-04) this hook again reported
    # "PRESENT but BROKEN" and fell through to the size check — but sha256sum was
    # fine. `cut` was simply NOT in the initramfs, so `... | cut -d' ' -f1`
    # produced nothing and the self-test could never match. `tr` *was* present,
    # which is why the size branch worked and hid the real cause. The self-test
    # was measuring its own pipeline, not sha256sum.
    #
    # So parse with shell parameter expansion instead: no external command, no
    # second tool that can silently be absent. Anything the integrity gate itself
    # depends on has to be as close to zero-dependency as possible, because when
    # it fails it fails toward "cannot verify" — and that is the branch that
    # decides whether an unverified image gets written over the only rootfs.
    verified=""

    # Known vector: sha256 of the empty string.
    _sha_empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    _sha_err=$(printf '' | sha256sum 2>&1 >/dev/null)
    _sha_probe=$(printf '' | sha256sum 2>/dev/null)
    _sha_probe=${_sha_probe%% *}
    if [ "$_sha_probe" = "$_sha_empty" ]; then
        _sha_ok=1
    else
        _sha_ok=0
        if [ -x /usr/bin/sha256sum ] || [ -x /bin/sha256sum ]; then
            warn "rootfs-flash: sha256sum is PRESENT but BROKEN (self-test failed)"
        else
            warn "rootfs-flash: sha256sum is NOT INSTALLED in the initramfs"
        fi
        [ -n "$_sha_err" ] && warn "rootfs-flash:   error: $_sha_err"
    fi

    if [ -s "$MNT/$IMG.sha256" ] && [ "$_sha_ok" = 1 ]; then
        want=$(cat "$MNT/$IMG.sha256" 2>/dev/null | tr -d ' \t\n\r')
        info "rootfs-flash: verifying $IMG against staged digest"
        got=$(sha256sum "$MNT/$IMG" 2>/dev/null)
        got=${got%% *}
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
        verified=digest
    fi

    if [ -z "$verified" ] && [ -s "$MNT/$IMG.size" ]; then
        want_sz=$(cat "$MNT/$IMG.size" 2>/dev/null | tr -d ' \t\n\r')
        got_sz=$(stat -c%s "$MNT/$IMG" 2>/dev/null)
        if [ -z "$got_sz" ]; then
            warn "rootfs-flash: cannot stat $IMG -- REFUSING to flash"
            rm -f "$MNT/$PENDING"; sync 2>/dev/null
            umount "$MNT" 2>/dev/null
            return 0
        fi
        if [ "$got_sz" != "$want_sz" ]; then
            warn "rootfs-flash: SIZE MISMATCH -- refusing to flash $SUPER"
            warn "rootfs-flash:   staged: $want_sz bytes"
            warn "rootfs-flash:   actual: $got_sz bytes"
            rm -f "$MNT/$PENDING"; sync 2>/dev/null
            umount "$MNT" 2>/dev/null
            return 0
        fi
        warn "rootfs-flash: digest unusable; SIZE check passed ($got_sz bytes) -- proceeding"
        verified=size
    fi

    if [ -z "$verified" ]; then
        if [ -s "$MNT/$IMG.sha256" ] || [ -s "$MNT/$IMG.size" ]; then
            # The updater intended verification and we could not do any of it.
            warn "rootfs-flash: verification requested but IMPOSSIBLE -- REFUSING to flash"
            rm -f "$MNT/$PENDING"; sync 2>/dev/null
            umount "$MNT" 2>/dev/null
            return 0
        fi
        warn "rootfs-flash: no $IMG.sha256 / .size staged -- writing UNVERIFIED image"
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
