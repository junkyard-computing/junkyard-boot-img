#!/bin/bash
#
# Flash every phone currently in fastboot, in parallel.
#
# The actual flashing is done by flash-fastboot.sh — the same script used to
# flash our own development phones, unchanged. It is pointed at this folder's
# images/ directory rather than a repo checkout. One tested flashing path
# instead of a second copy that drifts out of step with it.
#
# ⚠ super.img is 7.9 GB PER PHONE. Eight phones on one hub is ~63 GB through a
# single USB controller, so this is limited by host USB bandwidth, not by the
# phones. Slow is normal here and slow is not stalled. A powered hub is not
# optional.
set -uo pipefail

cd "$(dirname "$0")"

# COMMIT_SLOT=0: flash-fastboot.sh can commit a phone's boot slot over its USB
# gadget, but every phone presents itself on the SAME address (10.42.0.1), so
# that cannot work with more than one plugged in. It is also unnecessary here —
# both slots receive the same image, so a phone that rolls back lands on an
# identical system. See README, "About slots".
export COMMIT_SLOT=0
export IMAGE_DIR=images
export DTBO=images/dtbo.img

mapfile -t devices < <(fastboot devices | awk 'NF {print $1}')

if [ "${#devices[@]}" -eq 0 ]; then
	echo "No phones in fastboot. Do step 2 first." >&2
	exit 1
fi

echo "Flashing ${#devices[@]} phone(s): ${devices[*]}"
echo

pids=()
for d in "${devices[@]}"; do
	./flash-fastboot.sh "$d" > "flash-$d.log" 2>&1 &
	pids+=($!)
done

# Wait on each child individually and report per phone. Backgrounding without
# waiting would let one failure in a batch of twenty scroll past unnoticed, and
# an unnoticed failure here is a phone that ships broken.
fail=0
for i in "${!pids[@]}"; do
	if wait "${pids[$i]}"; then
		echo "  OK      ${devices[$i]}"
	else
		echo "  FAILED  ${devices[$i]}   (see flash-${devices[$i]}.log)" >&2
		fail=$((fail + 1))
	fi
done

echo
if [ "$fail" -eq 0 ]; then
	echo "All ${#devices[@]} phone(s) flashed. They are rebooting now."
	echo "Next: check each screen — see README step 6."
else
	echo "$fail of ${#devices[@]} FAILED. Re-run just those:" >&2
	echo "    ./flash-fastboot.sh <serial>" >&2
	exit 1
fi
