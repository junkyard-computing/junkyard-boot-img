#!/bin/bash
#
# Step 4: run Google's own flash-all.sh on every phone in fastboot, in parallel.
#
# This calls Google's script unmodified, out of factory/. We do not reimplement
# it — it flashes the bootloader and radio, reboots between each, and then runs
# `fastboot -w update`, and that sequence is Google's to get right.
#
# ⚠ WHY A WRAPPER IS NEEDED AT ALL: flash-all.sh issues bare `fastboot` commands,
# which target "the single attached device". With a hub full of phones that is
# whichever one fastboot happens to pick. fastboot honours ANDROID_SERIAL for
# every invocation, so exporting it per phone is what makes parallel flashing
# safe. It also has to run from its own directory, because it refers to its
# images by relative path.
#
# ⚠ This WIPES each phone (`-w`). That is intended — step 5 replaces the system
# anyway.
set -uo pipefail

cd "$(dirname "$0")"

FACTORY_DIR="factory"
[ -f "$FACTORY_DIR/flash-all.sh" ] \
	|| { echo "no $FACTORY_DIR/flash-all.sh — this kit is incomplete" >&2; exit 1; }

# flash-all.sh needs a reasonably recent fastboot; the failure otherwise is
# obscure, so check it here where the message can be plain.
if command -v fastboot >/dev/null; then
	v=$(fastboot --version 2>/dev/null | sed -n 's/.*version \([0-9.]*\).*/\1/p' | head -1)
	major=$(printf '%s' "${v:-0}" | tr -d '.' | cut -c1-4)
	if [ -n "$major" ] && [ "$major" -lt 3301 ] 2>/dev/null; then
		echo "fastboot $v is too old — need 33.0.1 or newer." >&2
		echo "Get current platform-tools from developer.android.com." >&2
		exit 1
	fi
else
	echo "fastboot not found on PATH." >&2; exit 1
fi

mapfile -t devices < <(fastboot devices | awk 'NF {print $1}')
if [ "${#devices[@]}" -eq 0 ]; then
	echo "No phones in fastboot. Do step 2 first." >&2
	exit 1
fi

echo "Flashing Google's image onto ${#devices[@]} phone(s): ${devices[*]}"
echo "This reboots each phone several times. Do not unplug anything."
echo

pids=()
for d in "${devices[@]}"; do
	# Subshell: the cd and the exported serial stay local to this phone.
	( cd "$FACTORY_DIR" && ANDROID_SERIAL="$d" ./flash-all.sh ) > "google-$d.log" 2>&1 &
	pids+=($!)
done

fail=0
for i in "${!pids[@]}"; do
	if wait "${pids[$i]}"; then
		echo "  OK      ${devices[$i]}"
	else
		echo "  FAILED  ${devices[$i]}   (see google-${devices[$i]}.log)" >&2
		fail=$((fail + 1))
	fi
done

echo
if [ "$fail" -eq 0 ]; then
	echo "All ${#devices[@]} phone(s) flashed with Google's image."
	echo "They reboot into stock Android. Leave them at the welcome screen and"
	echo "put them back into fastboot (hold volume down + power while restarting),"
	echo "then continue with step 5."
else
	echo "$fail of ${#devices[@]} FAILED. Re-run just those:" >&2
	echo "    cd factory && ANDROID_SERIAL=<serial> ./flash-all.sh" >&2
	exit 1
fi
