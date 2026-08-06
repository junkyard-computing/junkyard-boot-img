#!/bin/bash
#
# Reboot every adb-visible phone into fastboot.
#
# Phones you have not used before will show an "allow USB debugging?" dialog.
# Accept it on each, then run this again — devices stuck at "unauthorized" are
# reported rather than silently skipped.
set -uo pipefail

lines=$(adb devices | tail -n +2 | awk 'NF')
[ -n "$lines" ] || { echo "No devices found by adb."; exit 1; }

n=0
while read -r id state; do
	case "$state" in
		device)       echo "  rebooting $id to fastboot"; adb -s "$id" reboot bootloader; n=$((n+1)) ;;
		unauthorized) echo "  !! $id is UNAUTHORIZED — accept the dialog on the phone, then re-run" >&2 ;;
		*)            echo "  !! $id is '$state' — skipped" >&2 ;;
	esac
done <<< "$lines"

echo "$n device(s) sent to fastboot. Wait for the fastboot screen on each."
