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

fb oem disable-verification
fb oem disable-verity
fb erase init_boot
fb erase boot
fb flash boot boot.img
fb erase vendor_boot
fb flash vendor_boot vendor_boot.img
fb erase dtbo
fb flash dtbo "$DTBO"
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
fb erase vendor_kernel_boot
# fb oem uart disable
fb reboot

popd
