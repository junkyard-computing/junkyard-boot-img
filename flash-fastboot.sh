#!/bin/bash
#
# The felix dtbo carries the board-variant overrides that flip serial_0,
# the panels, and other felix-specific nodes from status="disabled" (as
# defined in gs201.dtsi) to status="okay". Without it UART login and the
# display silently go dead. Any prior "reflash to stock" wipes whatever
# stock dtbo was there, so always re-flash ours.
DTBO=../kernel/source/out/felix/dist/dtbo.img

# Which device to flash. REQUIRED — bare `fastboot` commands target "the single
# attached device", and this script runs `erase super` (the rootfs) among others,
# so with more than one felix on the bus an unscoped run destroys whichever one
# fastboot happened to pick. There is routinely more than one attached here, and
# at least one of them is a reference unit that must not be touched, so refusing
# to guess is the only safe default.
#
#   ./flash-fastboot.sh <serial>      or      FASTBOOT_SERIAL=<serial> ./flash-fastboot.sh
#
# `fastboot devices` lists candidates.
SERIAL="${FASTBOOT_SERIAL:-${1:-}}"
if [ -z "$SERIAL" ]; then
	echo "refusing to flash: no serial given (this script erases super)." >&2
	echo "pass one as \$1 or FASTBOOT_SERIAL. attached devices:" >&2
	fastboot devices >&2
	exit 2
fi
# Confirm the named device is actually in fastboot, so a typo'd serial fails here
# rather than after the first few commands have already run against nothing.
if ! fastboot devices | grep -q "^${SERIAL}[[:space:]]"; then
	echo "refusing to flash: '$SERIAL' is not in fastboot. attached devices:" >&2
	fastboot devices >&2
	exit 2
fi
echo ">>> flashing $SERIAL ($(fastboot -s "$SERIAL" getvar product 2>&1 | head -1))"

# Every command below goes through this, so none of them can pick a device.
fb() { fastboot -s "$SERIAL" "$@"; }

pushd boot

# ★★ FLASH THE BOOT CHAIN TO BOTH SLOTS, and disable AVB on both.
#
# The old script flashed unsuffixed partitions, which target whichever slot is
# active, so only ONE slot got our boot chain. `super` is not slotted and
# super.img seeds both halves with our rootfs, so the other slot ended up
# pairing a stock/stale kernel with our Debian rootfs half — provably different
# chains on a live unit (boot_a cd09c736… vs boot_b 130f3a93…).
#
# That is the rollback target. A unit that rolls back — because its slot was
# never committed and the bootloader's retry counter hit zero — lands on a
# chain that cannot bring our system up, on hardware with no screen and no
# buttons. Flashing both slots makes a rollback survivable instead of terminal.
#
# ⚠ The set-active dance is REQUIRED, not decoration: `oem disable-verification`
# and `oem disable-verity` apply ONLY to the slot that is active when they run.
# Flashing our unsigned repacked chain into a slot whose AVB is still enforcing
# produces the silent-rollback failure documented for the OTA path — the flash
# reports success, the hashes match, and the slot simply never boots.
for slot in a b; do
	echo ">>> preparing slot $slot (set-active, then disable AVB for THAT slot)"
	fb --set-active=$slot
	fb oem disable-verification
	fb oem disable-verity
	fb erase init_boot_$slot   || true
	fb erase boot_$slot        || true
	fb flash boot_$slot boot.img
	fb erase vendor_boot_$slot || true
	fb flash vendor_boot_$slot vendor_boot.img
	fb erase dtbo_$slot        || true
	fb flash dtbo_$slot "$DTBO"
	fb erase vendor_kernel_boot_$slot || true
done

# Leave slot A active. Both slots now carry an identical, AVB-permissive chain,
# so this is a choice of starting point rather than a fallback arrangement.
fb --set-active=a

fb erase super
# ★ super.img, NOT rootfs.img — this is the FULL FLASH, and it is what leaves the
# device in a valid A/B state.
#
# rootfs.img is one rootfs sized to fit ONE HALF of super. Flashing it here would
# land it at offset 0 (slot A) and leave slot B holding whatever was there before,
# so the very first OTA would switch into a half that has never contained a
# filesystem. super.img is the whole partition with BOTH halves seeded from the
# same rootfs, which establishes the invariant the design depends on: both halves
# always contain something bootable.
#
# That matters most for the case with no recovery path. A device whose fallback
# half is garbage looks completely healthy — it boots, it is reachable, nothing
# reports a problem — right up until an update fails its retries and the
# bootloader rolls back into an unmountable half. On a unit with no screen, no
# buttons and no physical access, that is the difference between a failed update
# and a dead device.
if [ ! -f super.img ]; then
	echo "missing super.img — build it with: just build_super_image" >&2
	echo "(rootfs.img alone is only half of super; flashing it would leave slot B" >&2
	echo " unseeded and the first OTA would have no valid rollback target.)" >&2
	exit 1
fi
fb flash super super.img
# fb oem uart disable
fb reboot

popd

# ★★ COMMIT THE FLASHED SLOT.
#
# fastboot leaves slot metadata alone, and `--set-active` above marks the slot
# active but NOT successful. Nothing on the device commits a slot until
# netcheck proves a network — so a factory-flashed unit that never sees one
# spends its 7 bootloader retries and rolls back, silently, having looked
# healthy the whole time. That is the same invisible-rollback shape as the
# vbmeta bug: the unit is up and reachable, it is just not running the image
# you shipped.
#
# The device is already cabled to this host — that is how we just flashed it —
# so after reboot it comes up as a CDC-NCM gadget serving DHCP on 10.42.0.1,
# and we commit over that. No wired network required, which is the whole point.
#
# Best effort by design: if it cannot be reached, SAY SO LOUDLY rather than
# exiting 0 on a unit whose slot is uncommitted. The in-image `--mark-only`
# path also commits when no wired NIC is present, so this is belt-and-braces
# for a unit that has a dongle attached but no DHCP behind it — the one case
# neither mechanism can prove on its own.
[ "${COMMIT_SLOT:-1}" = 1 ] || { echo ">>> COMMIT_SLOT=0, leaving the slot uncommitted"; exit 0; }

GADGET=${GADGET:-10.42.0.1}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/junkyard-fleet}
SSH_OPTS="-i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6"

echo ">>> waiting for $SERIAL to come back on the USB gadget to commit its slot"
committed=0
for _ in $(seq 1 40); do
	sleep 15
	s=$(timeout 20 ssh $SSH_OPTS "kalm@$GADGET" \
		'grep -o "androidboot.serialno = \"[^\"]*\"" /proc/bootconfig | cut -d\" -f2' 2>/dev/null)
	# Confirm it is the unit we just flashed — the gadget address is fixed, so a
	# different phone on the same bench would answer to it just as readily.
	[ "$s" = "$SERIAL" ] || continue
	if timeout 30 ssh $SSH_OPTS "kalm@$GADGET" \
		'sudo /usr/local/bin/pixel-bootctl mark-successful' >/dev/null 2>&1; then
		echo ">>> slot committed on $SERIAL"
		timeout 30 ssh $SSH_OPTS "kalm@$GADGET" \
			'sudo /usr/local/bin/pixel-bootctl status' 2>/dev/null | sed 's/^/    /'
		committed=1
	fi
	break
done

if [ "$committed" != 1 ]; then
	echo "" >&2
	echo "!!! WARNING: could not commit the slot on $SERIAL over the USB gadget." >&2
	echo "!!! The slot is ACTIVE but NOT SUCCESSFUL. If this unit reboots ~7 times" >&2
	echo "!!! before something proves a network, the bootloader will roll it back." >&2
	echo "!!! Both slots now carry the same chain, so a rollback is survivable —" >&2
	echo "!!! but the unit would be running the other slot, not the one you flashed." >&2
	echo "!!! Fix: boot it, confirm reachability, and run:" >&2
	echo "!!!     sudo pixel-bootctl mark-successful" >&2
fi
