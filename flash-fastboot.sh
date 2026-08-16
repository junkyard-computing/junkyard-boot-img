#!/bin/bash
#
# Run from the script's own directory throughout, so every relative path below
# (IMAGE_DIR, DTBO, the kit's images/) means the same thing regardless of where
# the caller invoked this from.
cd "$(dirname "$0")" || exit 1
#
# The felix dtbo carries the board-variant overrides that flip serial_0,
# the panels, and other felix-specific nodes from status="disabled" (as
# defined in gs201.dtsi) to status="okay". Without it UART login and the
# display silently go dead. Any prior "reflash to stock" wipes whatever
# stock dtbo was there, so always re-flash ours.
# Which DEVICE's build to flash (felix | lynx). Selects the per-device artifact
# directory; see devices/<device>.mk and the DEVICE SELECTION block in the
# Makefile. Env-only, because $1 is already the fastboot serial.
#
# ★ NO DEFAULT. It is ASKED OF THE HARDWARE (`getvar product`, below) when unset.
# A default here would be a preference between equal devices, and the wrong one
# writes a felix image over a lynx — this script erases `super` and flashes both
# slots, so that is not recoverable by rolling back. Asking the bootloader what
# it is beats guessing, and means the plain `./flash-fastboot.sh <serial>` form
# is correct for either device with nothing to remember.
#
# Set DEVICE explicitly to assert an expectation instead; a mismatch then aborts.
DEVICE="${DEVICE:-}"

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
# How many phones are attached, recorded BEFORE we flash — the slot commit below
# needs to know, and by the time it runs this phone has rebooted out of fastboot.
ATTACHED=$(fastboot devices | awk 'NF' | wc -l)

if ! fastboot devices | grep -q "^${SERIAL}[[:space:]]"; then
	echo "refusing to flash: '$SERIAL' is not in fastboot. attached devices:" >&2
	fastboot devices >&2
	exit 2
fi
# ★ Ask the hardware what it is, then either adopt that (DEVICE unset) or check
# the caller's expectation against it (DEVICE set).
#
# This matters more here than anywhere else: felix and lynx are both gs201 and
# both accept these fastboot commands happily, but the images are genuinely
# incompatible (different kernel branch, different vendor firmware — and without
# a matching aoc.bin the device does not boot at all). Meanwhile this script
# erases `super` and flashes BOTH slots, so a wrong-device run destroys the
# rootfs and both boot chains before anything gets a chance to reject it. The
# SSH/OTA path gates on the /etc/image-device stamp; this is the equivalent for
# the path that has no rootfs to read a stamp from yet.
#
# ★★ IN THE PROVISIONING KIT, THE KIT ITSELF IS THE AUTHORITY.
#
# Deriving DEVICE from `getvar product` is right in a repo checkout, where both
# devices are built and we simply pick the matching one. It is WRONG in the kit,
# where images/ holds exactly ONE device's images: derived-from-hardware would
# make DEVICE equal PRODUCT by construction, so the mismatch test below could
# never fire — and the kit is precisely where the risk is highest (a contractor,
# unfamiliar hardware, a batch of phones, and `erase super` in the script).
#
# So package-provisioning.sh stamps images/DEVICE with the device the kit was
# built for, and that wins over the hardware's answer. Plugging a lynx into a
# felix kit now aborts instead of flashing felix images onto it.
KIT_DEVICE=""
if [ -z "$DEVICE" ] && [ -r "${IMAGE_DIR:-images}/DEVICE" ]; then
	KIT_DEVICE=$(tr -d " \t\r\n" < "${IMAGE_DIR:-images}/DEVICE")
	[ -z "$KIT_DEVICE" ] || DEVICE="$KIT_DEVICE"
fi

# DEVICE_CHECK=0 skips the comparison, for the rare deliberate case.
PRODUCT=$(fastboot -s "$SERIAL" getvar product 2>&1 | sed -n 's/^product: *//p' | head -1)
if [ -z "$DEVICE" ]; then
	[ -n "$PRODUCT" ] || {
		echo "refusing to flash: '$SERIAL' did not report a product, and no DEVICE was set." >&2
		echo "pass DEVICE=<device> explicitly." >&2
		exit 2
	}
	DEVICE="$PRODUCT"
	echo ">>> device not specified; adopting the bootloader's answer: $DEVICE"
elif [ "${DEVICE_CHECK:-1}" = 1 ] && [ -n "$PRODUCT" ] && [ "$PRODUCT" != "$DEVICE" ]; then
	if [ -n "$KIT_DEVICE" ]; then
		echo "refusing to flash: '$SERIAL' is a '$PRODUCT', but this kit was built" >&2
		echo "for '$KIT_DEVICE' (images/DEVICE). Use the $PRODUCT kit for this phone." >&2
	else
		echo "refusing to flash: '$SERIAL' reports product '$PRODUCT', but DEVICE=$DEVICE." >&2
		echo "  build the right one:  just $PRODUCT" >&2
		echo "  then flash it:        DEVICE=$PRODUCT $0 $SERIAL" >&2
	fi
	echo "  (override with DEVICE_CHECK=0 if you really mean it)" >&2
	exit 2
fi

# Image locations. Resolved AFTER the device is known. Overridable so the SAME
# script works from a repo checkout and from the standalone provisioning kit,
# which lays them out differently: the kit sets IMAGE_DIR=images
# DTBO=images/dtbo.img. One tested flashing path, two layouts, instead of a
# second copy that drifts.
IMAGE_DIR="${IMAGE_DIR:-build/$DEVICE}"
DTBO="${DTBO:-kernel/source-$DEVICE/out/$DEVICE/dist/dtbo.img}"
echo ">>> flashing $SERIAL (product: ${PRODUCT:-unknown}, images: $IMAGE_DIR)"

# Every command below goes through this, so none of them can pick a device.
#
# ★★ AND IT ABORTS ON FAILURE. There is no `set -e` here (the slot-commit poll
# at the end depends on non-zero returns being survivable), so for a long time a
# failed `fb flash boot_a` simply carried on to the next command and the script
# still exited 0 — which flash-batch.sh reports as `OK`. A phone that never
# received its boot chain would ship looking flashed. Anything that must succeed
# goes through fb; anything allowed to fail goes through fb_try.
fb() {
	local rc
	fastboot -s "$SERIAL" "$@"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "" >&2
		echo "FAILED on $SERIAL: fastboot $* (exit $rc)" >&2
		echo "The phone has NOT been left in a known state. Put it back into" >&2
		echo "fastboot and re-run this script for that serial." >&2
		exit 1
	fi
}

# Best-effort: erasing a partition that does not exist on this device is fine,
# and was previously written as `fb ... || true` — which stops working the
# moment fb itself exits on failure.
fb_try() { fastboot -s "$SERIAL" "$@" || true; }

# ★★ CHECK EVERY IMAGE BEFORE TOUCHING THE PHONE.
#
# These checks used to sit further down, next to the partition each one feeds —
# which put the super.img test AFTER `fb erase super`. A checkout missing
# super.img therefore wiped the rootfs and only then refused to flash, leaving
# the phone worse off than when it arrived. Nothing here writes to the device,
# so all of it belongs before the first fastboot command.
for _img in "$IMAGE_DIR/boot.img" "$IMAGE_DIR/vendor_boot.img" "$DTBO"; do
	[ -f "$_img" ] || { echo "missing $_img — build it first: just $DEVICE" >&2; exit 1; }
done

if [ ! -f "$IMAGE_DIR/super.img" ]; then
	echo "missing super.img — build it with: just $DEVICE" >&2
	echo "(rootfs.img alone is only half of super; flashing it would leave slot B" >&2
	echo " unseeded and the first OTA would have no valid rollback target.)" >&2
	exit 1
fi

# ★ REFUSE A STALE super.img.
#
# super.img IS built by `just <device>` now (and removed by `just clean`), but
# that was not always so: it used to be skipped as another 8 GiB that only
# fastboot and a layout migration need. An ordinary rebuild then left fresh boot.img and
# vendor_boot.img beside a super.img containing the PREVIOUS rootfs, with
# nothing to warn you: it is gitignored, so `git status` stays clean throughout.
#
# Measured 2026-08-05: after a version bump, `just clean && just all` produced
# rootfs.img at 1.5.0-ge0559d7 while super.img still held 1.4.0-gdaa33e3. This
# script flashes super.img, so that would have paired a 1.5.0 boot chain with a
# 1.4.0 rootfs on every phone in the batch.
#
# Only checkable when rootfs.img is present (a repo checkout). The provisioning
# kit ships super.img alone, and package-provisioning.sh does this comparison at
# packaging time instead.
if [ -f "$IMAGE_DIR/rootfs.img" ]; then
	_dbg=$(command -v debugfs || ls -d /nix/store/*e2fsprogs*/bin/debugfs 2>/dev/null | head -1)
	if [ -n "$_dbg" ]; then
		_sv=$("$_dbg" -R 'cat /etc/image-version' "$IMAGE_DIR/super.img" 2>/dev/null | tr -d '\0\n')
		_rv=$("$_dbg" -R 'cat /etc/image-version' "$IMAGE_DIR/rootfs.img" 2>/dev/null | tr -d '\0\n')
		if [ -n "$_sv" ] && [ -n "$_rv" ] && [ "$_sv" != "$_rv" ]; then
			echo "refusing to flash: super.img is STALE." >&2
			echo "  super.img  : $_sv" >&2
			echo "  rootfs.img : $_rv" >&2
			echo "Regenerate super.img:" >&2
			echo "    just device=$DEVICE build_super_image" >&2
			exit 1
		fi
	fi
fi

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
	fb_try erase init_boot_$slot
	fb_try erase boot_$slot
	fb      flash boot_$slot "$IMAGE_DIR/boot.img"
	fb_try erase vendor_boot_$slot
	fb      flash vendor_boot_$slot "$IMAGE_DIR/vendor_boot.img"
	fb_try erase dtbo_$slot
	fb      flash dtbo_$slot "$DTBO"
	fb_try erase vendor_kernel_boot_$slot
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
# (super.img presence and staleness are checked in the preflight above, before
# `fb erase super` has had a chance to wipe anything.)
fb flash super "$IMAGE_DIR/super.img"
# fb oem uart disable
fb reboot


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
# exiting 0 on a unit whose slot is uncommitted.
#
# ★★ OPT-IN (COMMIT_SLOT=1), AND ONLY WITH ONE PHONE ATTACHED.
#
# EVERY phone serves the gadget on the SAME address, 10.42.0.1. With a hub full
# of them the host ends up with several 10.42.0.x interfaces all routing to that
# one address, and the connection lands on whichever route wins — not on the
# phone we just flashed. The serial check below stops us committing the WRONG
# phone, but it cannot make the right one reachable, so on a hub this just burns
# 40 x 15s of pointless polling per device.
#
# Defaulting this OFF is safe because flash-fastboot.sh writes the boot chain to
# BOTH slots: an uncommitted slot that rolls back lands on an identical system.
# Committing only avoids the rollback happening at all, which is cosmetic here.
# Set COMMIT_SLOT=1 on a single-phone bench where that is worth having.
if [ "${COMMIT_SLOT:-0}" != 1 ]; then
	echo ">>> not committing the slot (COMMIT_SLOT=0; both slots hold this image)"
	exit 0
fi
if [ "${ATTACHED:-1}" -gt 1 ]; then
	echo ">>> $ATTACHED phones were attached — skipping the slot commit." >&2
	echo "    Every phone answers on 10.42.0.1, so it cannot be aimed at one of them." >&2
	echo "    Harmless: both slots carry this image, so a rollback changes nothing." >&2
	exit 0
fi

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
