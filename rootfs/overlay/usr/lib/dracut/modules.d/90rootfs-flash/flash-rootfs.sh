#!/bin/sh
# dracut pre-mount hook: reflash the root filesystem from a staged image on
# `userdata`, BEFORE dracut mounts root. At that point the target is just a free
# block device, so this needs no live-root unmount, no systemd shutdown-pivot,
# and no working dracut-shutdown.service (which is /bin/true on these images) —
# which makes it the portable rootfs cutover / OTA primitive.
#
# Handles BOTH rootfs layouts, deciding by observation rather than configuration:
# the whole `super` partition on a single-rootfs image, or just the active slot's
# half on a rootfs-A/B image. See "WHERE THE IMAGE GOES" below.
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
SLOTDEV=/dev/mapper/rootfs
UD=/dev/disk/by-partlabel/userdata
MNT=/rootfs-flash
PENDING=pixel-ota/flash-pending
IMG=pixel-ota/rootfs.img

info "rootfs-flash: hook invoked"
# Make sure the partition symlinks exist this early in boot.
udevadm settle --timeout=10 2>/dev/null
[ -b "$SUPER" ] || { info "rootfs-flash: $SUPER not present, skip"; return 0; }
[ -b "$UD" ]    || { info "rootfs-flash: $UD not present, skip"; return 0; }

# ═══ WHERE THE IMAGE GOES: whole `super`, or this slot's half ════════════════
#
# Both layouts have to work from one hook, because the same tooling updates
# devices running either. The choice is made by looking, not by a flag:
#
#   90rootfs-slot   initqueue/settled 30   maps the active half as $SLOTDEV
#   90rootfs-flash  pre-mount        50    (this hook)
#
# dracut runs initqueue/settled while it waits for root= to appear, and pre-mount
# only once it has. So by the time we run, $SLOTDEV exists if and only if THIS
# initramfs does rootfs A/B. That makes the two modules impossible to disagree:
# an initramfs that maps halves also writes halves, one that does not, does not.
# A build flag or an image marker could drift out of sync with the initramfs
# actually running; this cannot.
#
# Writing through the mapper is also what makes the bound real. dm-linear only
# maps `half` sectors, so an oversized image fails AT THE DEVICE instead of
# running past the end of slot A and into slot B — i.e. into the copy that
# rollback depends on. The fit check below then becomes an early, legible error
# rather than the only thing standing between a too-big image and a destroyed
# rollback target.
#
# Slot semantics come out right for free: the bootloader has already selected the
# boot slot, 90rootfs-slot mapped THAT slot's half, so we write the half we are
# about to boot from and leave the other one holding the previous rootfs. If this
# boot fails, the bootloader's existing retry/rollback lands on the other slot and
# finds it intact — which is the whole point, and needs nothing from pixel-bootctl.
# ...and the choice is made by SIZE, not just by whether a half is mapped, because
# there are two different operations sharing this one hook:
#
#   an UPGRADE stages a half-sized rootfs.img  -> write the mapped half
#   a MIGRATION or RESTRUCTURE stages super.img,
#   the whole partition with both halves seeded -> write the whole partition
#
# Keying only on "is a half mapped?" gets migration exactly backwards. On a
# migrating device the NEW initramfs is already running, so rootfs-slot HAS mapped
# a half — and super.img is twice the size of that half, so the fit check would
# refuse the very image whose job is to establish the layout. The device would
# come back on the old rootfs with the flag cleared, reporting success.
#
# So: take the half only if the image actually fits in it. Anything larger is by
# definition not a single-slot image, and belongs to the whole partition.
# Deciding this needs the image size, which is why it happens here rather than
# before the mount.
select_target() {
    _isz=$(stat -c %s "$MNT/$IMG" 2>/dev/null) || _isz=
    case "$_isz" in ''|*[!0-9]*) _isz= ;; esac

    if [ -b "$SLOTDEV" ] && [ -n "$_isz" ]; then
        _hsz=$(blockdev --getsize64 "$SLOTDEV" 2>/dev/null) || _hsz=
        case "$_hsz" in ''|*[!0-9]*) _hsz= ;; esac
        if [ -n "$_hsz" ] && [ "$_isz" -le "$_hsz" ]; then
            TARGET=$SLOTDEV
            info "rootfs-flash: image fits this slot's half -- upgrading in place ($TARGET)"
            return 0
        fi
        TARGET=$SUPER
        info "rootfs-flash: image ($_isz) exceeds the mapped half (${_hsz:-?}) -- treating as a"
        info "rootfs-flash: whole-partition image (migration/restructure) -> $TARGET"
        WHOLE_UNDER_MAPPING=1
        return 0
    fi

    TARGET=$SUPER
    info "rootfs-flash: no slot mapping -- target is the whole partition ($TARGET)"
}
WHOLE_UNDER_MAPPING=0

mkdir -p "$MNT"
if ! mount -t ext4 "$UD" "$MNT" 2>/dev/null; then
    info "rootfs-flash: mount $UD failed, skip"
    return 0
fi

if [ -e "$MNT/$PENDING" ] && [ -s "$MNT/$IMG" ]; then
    select_target
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
            warn "rootfs-flash: DIGEST MISMATCH -- refusing to flash $TARGET"
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
            warn "rootfs-flash: SIZE MISMATCH -- refusing to flash $TARGET"
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

    # FIT CHECK — the image must not be larger than what we are writing it onto.
    # Distinct from the integrity gate above: a digest proves the image is intact,
    # not that it lands somewhere big enough to hold it. `cat img > $TARGET` stops
    # at ENOSPC having already overwritten the start of the partition, which
    # leaves a truncated filesystem — the same unbootable, no-rollback outcome
    # the digest gate exists to prevent, reached a different way.
    #
    # This matters more under rootfs A/B than it did before it: the write target
    # becomes one HALF of `super`, so an image that comfortably fitted the whole
    # partition can overflow its half. Sizing the target at runtime (rather than
    # assuming the partition size) is what makes the check keep working once
    # 90rootfs-slot maps a half.
    isz=$(stat -c %s "$MNT/$IMG" 2>/dev/null) || isz=
    dsz=$(blockdev --getsize64 "$TARGET" 2>/dev/null) || dsz=
    case "$isz:$dsz" in
        *[!0-9:]*|:*|*:)
            warn "rootfs-flash: could not size image or $TARGET -- skipping fit check" ;;
        *)
            if [ "$isz" -gt "$dsz" ]; then
                warn "rootfs-flash: image $isz > $TARGET $dsz -- REFUSING to write"
                rm -f "$MNT/$PENDING"; sync 2>/dev/null
                umount "$MNT" 2>/dev/null
                return 0
            fi
            info "rootfs-flash: fit ok ($isz <= $dsz)" ;;
    esac

    # Whole-partition write with a half currently mapped over it: drop the mapping
    # first. Device-mapper holds the underlying device open, and whether a raw
    # write through it is permitted is not something to find out during a fleet
    # migration — a refused write here leaves the flag already cleared and the
    # device booting a half that was never seeded.
    #
    # Removed rather than rewritten afterwards: recreating the table would mean
    # duplicating rootfs-slot's halving arithmetic in a second place, and two
    # copies of that maths drifting apart is exactly the failure this hook was
    # designed to avoid. Reboot instead and let rootfs-slot map it cleanly over
    # the freshly seeded partition. The flag is already cleared, so the next boot
    # does not reflash — it just boots.
    if [ "$WHOLE_UNDER_MAPPING" = 1 ]; then
        if command -v dmsetup >/dev/null 2>&1; then
            if dmsetup remove "$(basename "$SLOTDEV")" 2>/dev/null; then
                info "rootfs-flash: dropped the slot mapping for a whole-partition write"
            else
                warn "rootfs-flash: could not drop the slot mapping -- attempting the write anyway"
            fi
        else
            warn "rootfs-flash: dmsetup unavailable -- attempting the write under a live mapping"
        fi
    fi

    info "rootfs-flash: pending flash -> writing $IMG onto $TARGET"
    rm -f "$MNT/$PENDING"
    # Persist the flag removal first. This initramfs may lack sync(1); sysrq is
    # always-enabled via the kernel cmdline, and 's' syncs all filesystems.
    sync 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null
    _wrote=0
    if cat "$MNT/$IMG" > "$TARGET"; then
        info "rootfs-flash: write complete"
        _wrote=1
    else
        warn "rootfs-flash: write FAILED -- $TARGET may be inconsistent"
    fi
    sync 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null

    # After re-laying the whole partition we have no slot mapping and this
    # initramfs's view of the layout is stale by definition. Reboot into it rather
    # than continuing a boot whose root device we just removed.
    if [ "$WHOLE_UNDER_MAPPING" = 1 ] && [ "$_wrote" = 1 ]; then
        info "rootfs-flash: layout re-established -- rebooting so the slot is mapped fresh"
        umount "$MNT" 2>/dev/null
        sync 2>/dev/null
        echo s > /proc/sysrq-trigger 2>/dev/null
        echo b > /proc/sysrq-trigger 2>/dev/null
        # If sysrq is unavailable, fall through: dracut will fail to find root and
        # rd.emergency=reboot takes us round anyway.
    fi
else
    info "rootfs-flash: no pending flash (looked for $MNT/$PENDING + $MNT/$IMG)"
fi

umount "$MNT" 2>/dev/null
return 0
