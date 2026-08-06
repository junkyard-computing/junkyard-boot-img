#!/bin/bash
#
# Unlock the bootloader on every phone in fastboot.
#
# ⚠ Each phone will show a confirmation you must accept with the VOLUME and
# POWER buttons. This cannot be automated. Unlocking also FACTORY RESETS the
# phone, which is fine here — we are about to erase it anyway.
#
# "OEM unlocking" must already be enabled in Android's developer settings, or
# this fails with a permission error.
set -uo pipefail

mapfile -t devices < <(fastboot devices | awk 'NF {print $1}')
[ "${#devices[@]}" -gt 0 ] || { echo "No devices in fastboot." >&2; exit 1; }

for d in "${devices[@]}"; do
	echo "  unlocking $d — accept the prompt on the phone"
	fastboot -s "$d" flashing unlock
done
echo "Done. Confirm every phone shows an unlocked bootloader before continuing."
