#!/bin/sh
# dracut initqueue/settled hook: map the active rootfs slot out of `super`.
#
# `super` is one 8136 MiB partition with no A/B twin (the GPT has no free space
# to carve one from — see docs). We split it in software instead: two equal
# halves, each holding a complete rootfs image, mapped one at a time by dm-linear
# as /dev/mapper/rootfs. boot.img's cmdline says root=/dev/mapper/rootfs, so the
# half this hook maps is the one that gets mounted.
#
# Which half is NOT our decision: the bootloader already picked a boot slot, and
# it tells us which in `androidboot.slot_suffix`. Following that means the rootfs
# slot rides the boot chain's existing A/B machinery — same active-slot choice,
# same retry counter, same automatic rollback when a slot fails to boot — instead
# of needing a selector and a rollback policy of its own. Note slot_suffix is in
# /proc/bootconfig, NOT /proc/cmdline: felix's cmdline is mostly the stock dtb's
# /chosen/bootargs and carries no slot information at all.
#
# WHY initqueue/settled AND NOT pre-mount: dracut waits for the root= device to
# appear before it runs pre-mount hooks. Creating /dev/mapper/rootfs from there
# would deadlock — dracut would be waiting for the device that only the hook it
# has not run yet can create. initqueue/settled runs inside that wait loop, so
# the device shows up and the wait resolves. (90rootfs-flash stays in pre-mount:
# it writes raw offsets in `super` and needs no mapping.)
command -v info >/dev/null 2>&1 || . /lib/dracut-lib.sh

SUPER=/dev/disk/by-partlabel/super
NAME=rootfs
# Refuse to map a half smaller than this — a plausible-looking but tiny mapping
# would fail later as a confusing mount error instead of an obvious one here.
MIN_HALF_SECTORS=1048576   # 512 MiB in 512-byte sectors

# Idempotent: the initqueue re-runs settled hooks until the root device shows up.
[ -e "/dev/mapper/$NAME" ] && return 0
# Not settled yet — say nothing and let the next iteration try again.
[ -b "$SUPER" ] || return 0

# Parse slot_suffix out of bootconfig ("androidboot.slot_suffix = "_a"") without
# needing sed/grep in the initramfs.
slot=
while read -r key _eq val _rest; do
    if [ "$key" = "androidboot.slot_suffix" ]; then
        val=${val#\"}
        slot=${val%\"}
        break
    fi
done < /proc/bootconfig 2>/dev/null

case "$slot" in
    _a) idx=0 ;;
    _b) idx=1 ;;
    *)
        # Default to A rather than failing: A is at offset 0, which is also where
        # a bare `fastboot flash super` lands, so it is the half most likely to
        # hold something bootable on a device in an odd state.
        warn "rootfs-slot: no usable androidboot.slot_suffix (got '${slot:-<none>}'), assuming _a"
        slot=_a
        idx=0 ;;
esac

sz=$(blockdev --getsz "$SUPER" 2>/dev/null) || sz=
case "$sz" in
    ''|*[!0-9]*) warn "rootfs-slot: cannot size $SUPER -- not mapping"; return 0 ;;
esac

# Halve at runtime rather than baking a constant: the initramfs and the image
# builder would otherwise have to agree on a magic number forever, and this also
# just works on a device whose super is a different size.
half=$(( sz / 2 ))
half=$(( half - half % 8 ))   # 4K-align, so the fs never starts mid-block
if [ "$half" -lt "$MIN_HALF_SECTORS" ]; then
    warn "rootfs-slot: half of $SUPER is only $half sectors -- not mapping"
    return 0
fi
off=$(( idx * half ))

info "rootfs-slot: slot ${slot:-_a} -> $NAME = $half sectors of $SUPER at $off"
if ! dmsetup create "$NAME" --table "0 $half linear $SUPER $off"; then
    warn "rootfs-slot: dmsetup create failed -- root will not appear"
fi
return 0
