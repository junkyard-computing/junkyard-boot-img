#!/bin/bash
#
# flash-nmap.sh — find our devices on the network and OTA them with flash-ssh.
#
# flash-ssh.sh updates ONE device you already know the address of. A fleet has
# neither property: addresses come from DHCP (and the lease follows the dongle's
# MAC, so an address moves when a dongle is swapped), a reflashed unit comes back
# on whatever DHCP hands it next, and at thousands of units nobody holds a list
# of what is out there. So this script discovers the fleet instead of being told
# it: nmap the subnets for SSH, fingerprint every host that answers, and update
# the ones that prove they are ours.
#
# ═══ WHAT MAKES A DEVICE "OURS" ═══════════════════════════════════════════════
#
# NOT the address — DHCP reassigns it, and a machine you have never seen can turn
# up on an address one of yours used yesterday.
#
# NOT a serial allowlist either. An inclusion list you cannot enumerate is not a
# safety gate, it is a bottleneck: at fleet scale the serials are exactly what
# you DON'T know in advance (this script's survey is how you find them out).
#
# Two things are checked instead, and both are properties of the device rather
# than of the network it happens to sit on:
#
#   1. IT LETS US IN, AS ROOT. The probe is BatchMode — key auth only, never a
#      password prompt — so reaching the login shell already means this device
#      carries our deploy key in authorized_keys, and `sudo -n` means it grants
#      that key root. Somebody else's Pixel does not. This is the strongest
#      signal available and it is cryptographic, not conventional. Use -i to pin
#      a specific fleet key (adds IdentitiesOnly, so agent keys can't stand in).
#
#   2. IT IS RUNNING OUR IMAGE. A gs201/felix device tree, aarch64, plus at least
#      --min-marks (default 2) artifacts only our overlay installs: the
#      90rootfs-flash dracut module, netcheck-recover, usb-gadget.service,
#      /etc/image-version. Two independent markers tolerate one being retired
#      later without the gate silently opening or slamming shut.
#
#   3. ★ AND IT IS RUNNING THE IMAGE YOU EXPECT. `--from-version V` (repeatable,
#      globs allowed) requires the device's stamped IMAGE_VERSION to be one you
#      named. This is the gate that replaces the serial allowlist, because it is
#      the one you can actually enumerate: contractors flash a known initial
#      image, so the version on those units is knowable in advance even when
#      their serials are not. It is a per-DEVICE claim like a serial — not a
#      property of the address — and unlike a serial list it does not grow with
#      the fleet. A unit reporting anything else (someone else's build, a
#      half-finished bring-up, a version you have never shipped) is left alone.
#      `--fleet ID` is the same idea stamped explicitly: /etc/junkyard-fleet must
#      read ID (images stamp it from FLEET_ID in the Makefile), for when two
#      fleets share a network and both run our images.
#
# What you maintain by hand is the EXCLUSION list (--exclude-serial-file), which
# stays small and knowable — the bench units, the AOSP oracle, anything mid
# experiment — while the inclusion side scales by itself. Guards you can't keep
# current are guards that get bypassed.
#
# ═══ AND BECAUSE THE ROOTFS HALF DOES NOT ROLL BACK ═══════════════════════════
#
# The boot chain goes to the inactive slot and the bootloader rolls it back on
# its own. `super` does not: it is a single non-slotted partition written in
# place, on units with no screen, no buttons and no physical access. Pushing a
# bad image to 2000 of those in one sweep is unrecoverable at a scale where a
# truck roll is the only fix.
#
# So a fleet run is CANARIED AND WAVED, and that is not optional:
#   * --canary N units go first (default 3). Every one of them must come back
#     ON THE NEW IMAGE VERSION or the run stops. Nothing else is touched.
#   * then --wave N at a time (default 25), each wave verified before the next.
#   * --max-fail PCT (default 10) trips a circuit breaker on cumulative failures.
#   * verification re-scans and matches by SERIAL, because a reflashed device
#     may well come back on a different address.
#
# Devices already running the target version are skipped, so re-running the same
# command is how you converge a fleet: sweep, fix what failed, sweep again.
#
# ⚠ TRANSPORT, at thousands: each device is sent the compressed rootfs (~1 GB on
# the wire) from THIS host. 2000 units is ~2 TB through one uplink — days, not
# hours, no matter how you set --jobs, and every wave contends with the same
# link. Fixing that means the devices PULLING from a per-rack mirror rather than
# this host pushing (or a torrent/multicast scheme). Nothing here does that yet;
# scope this script to a rack/subnet at a time and run it near the devices.
#
# Usage:
#   ./flash-nmap.sh 10.0.0.0/24                          # survey only (default)
#   ./flash-nmap.sh --from-version 'v7.1*' --flash 10.0.0.0/24
#   ./flash-nmap.sh --flash --fleet krg-lab -i ~/.ssh/fleet 10.0.0.0/22
#
# Targets are nmap host specs: CIDR, ranges, hostnames — anything nmap accepts.
#
# Options:
#   -f, --flash              actually flash (default: survey + inventory only)
#       --from-version V     only flash devices whose CURRENT IMAGE_VERSION
#                            matches V (glob ok, repeatable, comma-separated ok).
#                            The scalable stand-in for a serial allowlist — use
#                            the version the contractors flashed.
#   -i, --identity KEY       SSH key to authenticate with (implies IdentitiesOnly)
#       --fleet ID           require /etc/junkyard-fleet to read ID
#       --min-marks N        overlay markers required to call it ours (default 2)
#       --match REGEX        device-tree match (default 'felix|gs201')
#   -x, --exclude ADDR       never touch this address (repeatable)
#   -X, --exclude-serial-file F   never touch these serials (one per line, # ok)
#       --exclude-serial S   never touch this serial (repeatable)
#   -S, --serial-file F      NARROW to these serials (optional; for retries)
#       --expect-version V   image version devices must report after flashing
#                            (default: read from the local rootfs.img)
#       --force              flash even devices already on the target version
#       --canary N           units in the first, strictly-verified wave (default 3)
#       --wave N             units per wave thereafter (default 25)
#       --max-fail PCT       abort if cumulative failures exceed this % (default 10)
#       --settle SECONDS     how long to wait for a wave to come back (default 900)
#   -j, --jobs N             concurrent flashes within a wave (default 4)
#       --probe-jobs N       concurrent SSH probes while scanning (default 64)
#   -u, --user U             SSH user (default kalm, or $DEVICE_USER)
#   -p, --port N             SSH port (default 22)
#       --hosts-from F       skip nmap; read addresses from a file
#       --insecure-hostkeys  don't check/record host keys (see below)
#   -y, --yes                skip the confirmation prompt (for cron/CI)
#   -n, --no-verify          flash without waiting for devices to come back.
#                            Disables the canary gate and the circuit breaker —
#                            you are choosing to find out later.
#   -h, --help               this text
#
# Host keys: a reflash regenerates them, so a device you have flashed before
# fails with "IDENTIFICATION HAS CHANGED" until its old key is dropped. During
# post-flash verification this script drops the key itself (it caused the
# change). Everywhere else the default stays strict; --insecure-hostkeys turns
# checking off wholesale, which also means you are no longer authenticating the
# device, so keep it to a network you trust.
#
# Env: everything flash-ssh.sh honours (SSH_OPTS, BOOT_IMG, ROOTFS_IMG,
#      DTBO_IMG, USERDATA_MNT, USERDATA_MKFS, SCP_RATE_KBIT, ...) is passed
#      through to each per-device run unchanged.
#
# Exit: 0 = survey done / everything flashed. 1 = some devices failed or the run
#       was stopped by the canary/circuit breaker. 2 = usage or preflight error
#       (nothing was touched).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

DO_FLASH=0; ASSUME_YES=0; NO_VERIFY=0; FORCE=0
JOBS=4; PROBE_JOBS=64; CANARY=3; WAVE=25; MAX_FAIL_PCT=10; SETTLE=900
PORT=22; MIN_MARKS=2
DEVICE_USER="${DEVICE_USER:-kalm}"
MATCH_RE="${DEVICE_MATCH:-felix|gs201}"
FLEET_ID="${FLEET_ID:-}"
IDENTITY=""; HOSTS_FROM=""; EXPECT_VER="${EXPECT_VERSION:-}"; EXPECT_DEV="${EXPECT_DEVICE:-}"
INSECURE_HOSTKEYS=0
declare -a TARGETS=() ONLY_SERIALS=() SKIP_SERIALS=() EXCLUDES=() FROM_VERSIONS=()
# FROM_VERSION=a,b in the environment works too, for cron/CI.
[ -n "${FROM_VERSION:-}" ] && IFS=, read -r -a FROM_VERSIONS <<< "$FROM_VERSION"

die()  { printf 'flash-nmap: %s\n' "$*" >&2; exit 2; }
log()  { printf '\n>>> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//; $d'; }

# Value-taking options go through val(), not ${2:?...}: a usage slip should exit
# 2 like every other usage error here, and `--user ''` (meaning "whatever
# ssh_config picks") must be legal, which ${2:?} rejects. It writes REPLY rather
# than echoing, because a `die` inside a command substitution would kill only the
# subshell and let the parse continue with an empty value.
val() { [ "$#" -ge 2 ] || die "$1 needs a value"; REPLY="$2"; }

# One-serial-per-line, # comments allowed. Same format for both lists so an
# exclusion file can be built by pasting from a survey's inventory.csv.
read_serials() {  # <file> <array-name>
	local f="$1" arr="$2" line
	[ -r "$f" ] || die "cannot read serial file: $f"
	while read -r line; do
		line="${line%%#*}"; line="${line//[[:space:]]/}"
		[ -n "$line" ] && eval "$arr+=(\"\$line\")"
	done < "$f"
}

while [ $# -gt 0 ]; do
	case "$1" in
		-f|--flash)            DO_FLASH=1 ;;
		--from-version)        val "$@"; IFS=, read -r -a _fv <<< "$REPLY"
		                       FROM_VERSIONS+=("${_fv[@]}"); shift ;;
		-i|--identity)         val "$@"; IDENTITY="$REPLY"; shift ;;
		--fleet)               val "$@"; FLEET_ID="$REPLY"; shift ;;
		--min-marks)           val "$@"; MIN_MARKS="$REPLY"; shift ;;
		--match)               val "$@"; MATCH_RE="$REPLY"; shift ;;
		-x|--exclude)          val "$@"; EXCLUDES+=("$REPLY"); shift ;;
		-X|--exclude-serial-file) val "$@"; read_serials "$REPLY" SKIP_SERIALS; shift ;;
		--exclude-serial)      val "$@"; SKIP_SERIALS+=("$REPLY"); shift ;;
		-S|--serial-file)      val "$@"; read_serials "$REPLY" ONLY_SERIALS; shift ;;
		--expect-version)      val "$@"; EXPECT_VER="$REPLY"; shift ;;
		--expect-device)       val "$@"; EXPECT_DEV="$REPLY"; shift ;;
		--force)               FORCE=1 ;;
		--canary)              val "$@"; CANARY="$REPLY"; shift ;;
		--wave)                val "$@"; WAVE="$REPLY"; shift ;;
		--max-fail)            val "$@"; MAX_FAIL_PCT="$REPLY"; shift ;;
		--settle)              val "$@"; SETTLE="$REPLY"; shift ;;
		-j|--jobs)             val "$@"; JOBS="$REPLY"; shift ;;
		--probe-jobs)          val "$@"; PROBE_JOBS="$REPLY"; shift ;;
		-u|--user)             val "$@"; DEVICE_USER="$REPLY"; shift ;;
		-p|--port)             val "$@"; PORT="$REPLY"; shift ;;
		--hosts-from)          val "$@"; HOSTS_FROM="$REPLY"; shift ;;
		--insecure-hostkeys)   INSECURE_HOSTKEYS=1 ;;
		-y|--yes)              ASSUME_YES=1 ;;
		-n|--no-verify)        NO_VERIFY=1 ;;
		-h|--help)             usage; exit 0 ;;
		-*)                    die "unknown option: $1 (try --help)" ;;
		*)                     TARGETS+=("$1") ;;
	esac
	shift
done

for n in JOBS PROBE_JOBS CANARY WAVE MAX_FAIL_PCT SETTLE MIN_MARKS PORT; do
	v="${!n}"
	case "$v" in ''|*[!0-9]*) die "$n must be a number (got '$v')" ;; esac
done
[ "$JOBS" -ge 1 ] && [ "$WAVE" -ge 1 ] || die "--jobs and --wave must be >= 1"

# ---------------------------------------------------------------------------
# 0) Local preflight — fail before touching the network, not halfway through it.
# ---------------------------------------------------------------------------
if [ -z "$HOSTS_FROM" ]; then
	[ ${#TARGETS[@]} -gt 0 ] || { usage; exit 2; }
	command -v nmap >/dev/null 2>&1 || die "nmap not found — 'nix develop' provides it, or use --hosts-from FILE"
else
	[ -r "$HOSTS_FROM" ] || die "cannot read host file: $HOSTS_FROM"
fi
[ -z "$IDENTITY" ] || [ -r "$IDENTITY" ] || die "cannot read ssh key: $IDENTITY"

ROOTFS_IMG_LOCAL="${ROOTFS_IMG:-$here/boot/rootfs.img}"

if [ "$DO_FLASH" = 1 ]; then
	# flash-ssh.sh checks these too, per device — but discovering a missing
	# rootfs.img after unit 700 has already rebooted leaves the fleet in mixed
	# state for no reason.
	for f in "${BOOT_IMG:-$here/boot/boot.img}" \
	         "${VENDOR_BOOT_IMG:-$here/boot/vendor_boot.img}" \
	         "$ROOTFS_IMG_LOCAL" \
	         "${PIXEL_BOOTCTL_BIN:-$here/rootfs/overlay/usr/local/bin/pixel-bootctl}" \
	         "${PIXEL_OTA_BIN:-$here/rootfs/overlay/usr/local/bin/pixel-ota}"; do
		[ -f "$f" ] || die "missing local artifact: $f (build first)"
	done
	[ -x "$here/flash-ssh.sh" ] || die "flash-ssh.sh not executable at $here/flash-ssh.sh"
fi

# The version a flashed device must report back. Read it straight out of the
# image we are about to ship (debugfs, no mount, no root — same trick
# tools/gate-image.sh uses), so "did it take?" is answered against the artifact
# rather than against a number someone typed. Without it, verification can still
# tell that the version CHANGED, which catches a device that never rebooted but
# not one that rolled back to a previous image of ours.
if [ -z "$EXPECT_VER" ] && [ -f "$ROOTFS_IMG_LOCAL" ] && command -v debugfs >/dev/null 2>&1; then
	EXPECT_VER=$(debugfs -R 'cat /etc/image-version' "$ROOTFS_IMG_LOCAL" 2>/dev/null | tr -d '\r' | head -n1)
	EXPECT_VER="${EXPECT_VER//[[:space:]]/}"
	# Only when not given explicitly — an operator-supplied --expect-device must
	# win, exactly as --expect-version does. Deriving unconditionally here would
	# silently discard the override and make the flag look like it did nothing.
	if [ -z "$EXPECT_DEV" ]; then
		EXPECT_DEV=$(debugfs -R "cat /etc/image-device" "$ROOTFS_IMG_LOCAL" 2>/dev/null | tr -d "\r" | head -n1)
		EXPECT_DEV="${EXPECT_DEV//[[:space:]]/}"
	fi
fi

# ★ REFUSE TO FLASH BLIND. Everything downstream that makes a fleet sweep safe is
# a comparison against $EXPECT_VER, and both comparisons were written to DEGRADE
# PERMISSIVELY when it is empty:
#
#   * the idempotence skip is guarded by [ -n "$EXPECT_VER" ], so nothing is ever
#     "already up to date" — a re-run reflashes the whole fleet, and each reflash
#     overwrites `super` in place, destructively and with no rollback.
#   * post-flash verification reads
#         [ -z "$EXPECT_VER" ] || [ "${IMGVER_OF[$h]}" = "$EXPECT_VER" ]
#     which with an empty value is TRUE for any device that answers. The canary —
#     "every one must come back ON THE NEW IMAGE VERSION or the run stops" —
#     silently becomes "did it come back at all".
#
# That second one is not theoretical. A device whose target slot fails AVB rolls
# back and returns on the OLD image, reachable and healthy-looking (that is
# exactly the bug flash-ssh.sh's vbmeta normalisation fixes). A reachability-only
# canary passes it, reports the wave green, and the run proceeds to push the same
# broken update across the fleet — the precise scenario the canary exists to stop.
#
# The comment above claims verification can still detect that the version
# CHANGED. It cannot: classify_all() resets IMGVER_OF on every rescan, so the
# pre-flash value is gone by the time we compare, and no before/after snapshot is
# kept anywhere. Treat that as intent, not behaviour.
#
# Survey mode is unaffected and still works without debugfs — it makes no such
# comparisons. Only --flash needs the anchor, so only --flash insists on it.
if [ "$DO_FLASH" = 1 ] && [ -z "$EXPECT_VER" ]; then
	die "cannot determine the target image version, and --flash needs it.

  Every safety comparison in a sweep is made against it: without it, devices
  already up to date are reflashed anyway (a destructive, non-rollback-safe
  write to 'super'), and post-flash verification degrades to a reachability
  check that would pass a device which rolled back to the OLD image.

  Fix either way:
    * install e2fsprogs so debugfs can read /etc/image-version out of
      $ROOTFS_IMG_LOCAL directly (preferred — the anchor then comes from the
      artifact you are shipping, not from a number someone typed), or
    * pass --expect-version <version> explicitly."
fi

# SSH options for the PROBE. BatchMode is load-bearing, not a convenience: it is
# what makes "we got in" mean "our key is authorized" instead of "someone typed a
# password". Never remove it.
probe_opts=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5
            -o ServerAliveCountMax=2 -o LogLevel=ERROR -o Port="$PORT")
if [ -n "$IDENTITY" ]; then
	# IdentitiesOnly so a loaded agent key cannot quietly satisfy the check that
	# is supposed to prove the FLEET key opens this device.
	probe_opts+=(-o IdentitiesOnly=yes -i "$IDENTITY")
	export SSH_OPTS="${SSH_OPTS:-} -o IdentitiesOnly=yes -i $IDENTITY"
fi
if [ "$INSECURE_HOSTKEYS" = 1 ]; then
	probe_opts+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
	export SSH_OPTS="${SSH_OPTS:-} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
else
	probe_opts+=(-o StrictHostKeyChecking=accept-new)
fi
# `-o Port=`, NOT `-p`: flash-ssh.sh hands SSH_OPTS to BOTH ssh and scp, and in
# scp `-p` means "preserve timestamps" — the port number would be swallowed as a
# source path. `-o Port=` means the same thing to both.
[ "$PORT" != 22 ] && export SSH_OPTS="${SSH_OPTS:-} -o Port=$PORT"

# An empty --user means "whatever ssh_config says"; don't build a bare "@addr",
# which ssh reads as an empty username and rejects.
sshtarget() { if [ -n "$DEVICE_USER" ]; then printf '%s@%s' "$DEVICE_USER" "$1"; else printf '%s' "$1"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
stamp=$(date +%Y%m%dT%H%M%S)
logdir="$here/out/flash-nmap/$stamp"
mkdir -p "$logdir" || die "cannot create log dir $logdir"

# ---------------------------------------------------------------------------
# 1) Discovery — who has tcp/22 open.
# ---------------------------------------------------------------------------
discover() {  # -> $tmp/hosts
	if [ -n "$HOSTS_FROM" ]; then
		sed 's/#.*//' "$HOSTS_FROM" | tr -s '[:space:]' '\n' | grep -v '^$' > "$tmp/hosts" || true
	else
		# -Pn: do not require an ICMP echo first. A unit that is up but firewalled
		#      to ping is exactly the unit you are trying to reach.
		# -n:  no reverse DNS — at fleet scale it only adds minutes and confusion.
		# shellcheck disable=SC2086  # NMAP_OPTS is intentionally word-split.
		nmap -n -Pn --open -p "$PORT" ${NMAP_OPTS:-} -oG - "${TARGETS[@]}" 2>/dev/null \
			| awk '/^Host:/ && /open/ {print $2}' > "$tmp/hosts" || true
	fi
	local x
	for x in "${EXCLUDES[@]:-}"; do
		[ -n "$x" ] || continue
		grep -vxF "$x" "$tmp/hosts" > "$tmp/hosts.f" 2>/dev/null || : > "$tmp/hosts.f"
		mv "$tmp/hosts.f" "$tmp/hosts"
	done
}

# ---------------------------------------------------------------------------
# 2) Fingerprint — one SSH round-trip per host, read-only.
# ---------------------------------------------------------------------------
# Everything the classifier needs comes back from a single remote script, so a
# sweep costs one connection per host. Strictly read-only: reads /proc and /etc,
# runs `sudo -n true` (a no-op probe, not a privileged action), prints key=value.
# POSIX sh — it runs before we know what is over there.
read -r -d '' PROBE_SH <<'REMOTE' || true
set -u
p() { printf '%s=%s\n' "$1" "$2"; }

p arch   "$(uname -m 2>/dev/null)"
p kernel "$(uname -r 2>/dev/null)"
p uptime "$(cut -d. -f1 /proc/uptime 2>/dev/null)"

# Board identity. The device tree is the honest answer: the AOSP felix DT sets a
# model string and a `google,gs201` compatible. /proc/device-tree entries are
# NUL-terminated and `compatible` is a NUL-separated list.
p model  "$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
p compat "$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null || true)"

# Serial + running slot come from the bootloader via bootconfig (cmdline on older
# images). bootconfig writes `key = "value"`, cmdline writes `key=value`; one sed
# handles both. We do not know serials in advance — this is where they come from,
# and once known they are how a device is tracked across a reboot that changes
# its address.
serial=""; slot=""
for f in /proc/bootconfig /proc/cmdline; do
	[ -r "$f" ] || continue
	[ -n "$serial" ] || serial=$(sed -n 's/.*androidboot\.serialno[[:space:]]*=[[:space:]]*"\{0,1\}\([A-Za-z0-9]\{1,\}\).*/\1/p' "$f" 2>/dev/null | head -n1)
	[ -n "$slot" ]   || slot=$(sed -n 's/.*slot_suffix[^_]*_\([ab]\).*/\1/p' "$f" 2>/dev/null | head -n1)
done
p serial "$serial"
p slot   "$slot"

# Image identity, stamped by the Makefile's provenance target.
imgver=""
[ -r /etc/image-version ] && imgver=$(head -n1 /etc/image-version 2>/dev/null)
if [ -z "$imgver" ] && [ -r /etc/os-release ]; then
	imgver=$(sed -n 's/^IMAGE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -n1)
fi
p imgver "$imgver"

# Which DEVICE the running image was BUILT for (Makefile DEVICE -> /etc/image-device).
# Distinct from what hardware this is: the device tree says what the board is, this
# says what the image expects. They can disagree, and nothing else here would notice.
imgdev=""
[ -r /etc/image-device ] && imgdev=$(head -n1 /etc/image-device 2>/dev/null | tr -d '[:space:]')
if [ -z "$imgdev" ] && [ -r /etc/os-release ]; then
	imgdev=$(sed -n 's/^IMAGE_DEVICE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -n1)
fi
p imgdev "$imgdev"

# Fleet stamp, when the image carries one (Makefile FLEET_ID).
fleet=""
[ -r /etc/junkyard-fleet ] && fleet=$(head -n1 /etc/junkyard-fleet 2>/dev/null | tr -d '[:space:]')
p fleet "$fleet"

# Overlay markers: things only OUR rootfs installs. Counted, not listed, so the
# gate degrades gracefully when one of them is eventually retired.
marks=0
for m in /usr/lib/dracut/modules.d/90rootfs-flash/flash-rootfs.sh \
         /usr/local/sbin/netcheck-recover \
         /etc/systemd/system/usb-gadget.service \
         /etc/image-version; do
	[ -e "$m" ] && marks=$((marks + 1))
done
p marks "$marks"

# Preconditions flash-ssh.sh needs. Reported, not enforced, so a survey can tell
# you *why* a device of yours is not flashable.
sudo -n true 2>/dev/null && p sudo yes || p sudo no
[ -x /bin/busybox ] && p busybox yes || p busybox no

udsrc=$(findmnt -fnro SOURCE --mountpoint /userdata 2>/dev/null)
if [ -n "$udsrc" ]; then
	p userdata "mounted:$udsrc"
elif [ -b /dev/disk/by-partlabel/userdata ]; then
	p userdata present
else
	p userdata none
fi
REMOTE

probe_one() {  # <addr>
	# `timeout` bounds the whole exchange: ConnectTimeout only covers the TCP/
	# banner phase, and a half-wedged device (the classic symptom here — link up,
	# address held, no packets moving) can accept a connection and then never
	# answer. A fleet sweep must not hang on one of those.
	timeout 25 ssh "${probe_opts[@]}" "$(sshtarget "$1")" 'sh -s' \
		<<< "$PROBE_SH" > "$tmp/$1.kv" 2> "$tmp/$1.err" || true
}

probe_all() {  # <addr...>
	local h running=0
	for h in "$@"; do
		probe_one "$h" &
		running=$((running + 1))
		if [ "$running" -ge "$PROBE_JOBS" ]; then wait -n 2>/dev/null || wait; running=$((running - 1)); fi
	done
	wait
}

kv() { sed -n "s/^$2=//p" "$1" | head -n1; }

# Glob, not equality: shipped versions carry a git rev and kernel suffix
# (v7.2-gdeadbee+k6.1.99), so 'v7.2*' is what an operator actually knows. An
# empty version never matches — a device that cannot say what it is running is
# not a device to reimage on a guess.
version_allowed() {  # <imgver>
	local v="$1" pat
	[ -n "$v" ] || return 1
	for pat in "${FROM_VERSIONS[@]}"; do
		# shellcheck disable=SC2053  # RHS is a glob pattern on purpose.
		[[ "$v" == $pat ]] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
# 3) Classify.
# ---------------------------------------------------------------------------
declare -A SERIAL_OF=() INFO_OF=() VERDICT_OF=() REASON_OF=() IMGVER_OF=() ADDR_OF=() IMGDEV_OF=()
declare -A KERN_OF=() SLOT_OF=() UD_OF=()
declare -a MATCHED=()

classify_all() {  # <addr...> ; fills the arrays above, MATCHED = flashable ones
	MATCHED=(); SERIAL_OF=(); INFO_OF=(); VERDICT_OF=(); REASON_OF=(); IMGVER_OF=(); ADDR_OF=(); IMGDEV_OF=()
	KERN_OF=(); SLOT_OF=(); UD_OF=()
	local h f verdict reason arch model compat serial slot imgver fleet marks
	local sudoq busybox userdata kern s
	declare -A seen_serial=()
	for h in "$@"; do
		f="$tmp/$h.kv"; verdict=skip; reason=""
		if [ ! -s "$f" ]; then
			# Surface ssh's own words: "Permission denied", "Host key verification
			# failed" and "Connection timed out" are three different problems, and a
			# bare "unreachable" sends you looking in the wrong place. Permission
			# denied is also the expected answer for a machine that isn't ours.
			reason=$(head -n1 "$tmp/$h.err" 2>/dev/null | cut -c1-90)
			[ -n "$reason" ] || reason="no response to ssh probe"
			VERDICT_OF[$h]=skip; REASON_OF[$h]="$reason"; INFO_OF[$h]=""; SERIAL_OF[$h]=""
			continue
		fi
		arch=$(kv "$f" arch);     model=$(kv "$f" model);   compat=$(kv "$f" compat)
		serial=$(kv "$f" serial); slot=$(kv "$f" slot);     imgver=$(kv "$f" imgver)
		imgdev=$(kv "$f" imgdev)
		fleet=$(kv "$f" fleet);   marks=$(kv "$f" marks);   kern=$(kv "$f" kernel)
		sudoq=$(kv "$f" sudo);    busybox=$(kv "$f" busybox); userdata=$(kv "$f" userdata)

		SERIAL_OF[$h]="$serial"; IMGVER_OF[$h]="$imgver"; IMGDEV_OF[$h]="$imgdev"
		KERN_OF[$h]="$kern"; SLOT_OF[$h]="$slot"; UD_OF[$h]="$userdata"
		INFO_OF[$h]="${imgver:-?} k${kern:-?} slot ${slot:-?} ud=${userdata:-?}"
		[ -n "$serial" ] && ADDR_OF[$serial]="$h"

		if ! printf '%s %s' "$model" "$compat" | grep -Eqi -- "$MATCH_RE"; then
			reason="not a match for '$MATCH_RE' (model='${model:-?}')"
		elif [ "$arch" != aarch64 ]; then
			reason="arch $arch"
		elif [ -n "$FLEET_ID" ] && [ "$fleet" != "$FLEET_ID" ]; then
			reason="fleet stamp '${fleet:-none}' != '$FLEET_ID'"
		elif [ -n "$EXPECT_DEV" ] && [ -n "$imgdev" ] && [ "$imgdev" != "$EXPECT_DEV" ]; then
			# ★ The image we are about to push was built for a DIFFERENT device than
			# the one this unit is running. Nothing else here catches that: lynx
			# (Pixel 7a) is ALSO gs201, so the device-tree match accepts it, the
			# deploy key is the same, the overlay markers are the same, and two
			# images built from one commit for two devices carry an IDENTICAL
			# IMAGE_VERSION. Every other gate says yes.
			#
			# An in-layout upgrade would at least fail AVB on the inactive slot and
			# roll back. A MIGRATION writes the whole partition and destroys both
			# halves before anything can reject it, so this has to be caught here.
			reason="image built for '$imgdev', this fleet run ships '$EXPECT_DEV'"
		elif [ "${marks:-0}" -lt "$MIN_MARKS" ]; then
			# Right board, our key works, but it is not running our rootfs — a
			# stock-Android or third-party image on identical hardware. Flashing it
			# would be reimaging someone else's device.
			reason="only ${marks:-0}/$MIN_MARKS image markers — not running our rootfs"
		elif [ -z "$serial" ]; then
			reason="no androidboot.serialno — cannot track it across a reboot"
		elif [ "$sudoq" != yes ]; then
			reason="no passwordless sudo for ${DEVICE_USER:-ssh default user}"
		elif [ "$busybox" != yes ]; then
			reason="/bin/busybox missing (pixel-ota flash-rootfs needs it)"
		elif [ "$userdata" = none ]; then
			reason="no userdata partition to stage on"
		elif [ -n "${seen_serial[$serial]:-}" ]; then
			# One device, two addresses — routine here: a unit can answer on both its
			# dongle's DHCP address and the USB gadget's 10.42.0.1 at once. Flashing
			# it twice in parallel would race two OTAs against one `super`.
			reason="duplicate of ${seen_serial[$serial]} (same serial $serial)"
		else
			verdict=ok; seen_serial[$serial]="$h"
		fi
		VERDICT_OF[$h]="$verdict"; REASON_OF[$h]="$reason"
		[ "$verdict" = ok ] && MATCHED+=("$h")
	done
}

log "scanning ${TARGETS[*]:-$HOSTS_FROM} for tcp/$PORT"
discover
mapfile -t HOSTS < "$tmp/hosts"
[ ${#HOSTS[@]} -gt 0 ] || { log "no hosts with tcp/$PORT open"; exit 0; }
note "${#HOSTS[@]} host(s) with tcp/$PORT open"

log "fingerprinting ${#HOSTS[@]} host(s) over SSH (read-only, key auth only)"
probe_all "${HOSTS[@]}"
classify_all "${HOSTS[@]}"

# ---------------------------------------------------------------------------
# 4) Inventory — the survey IS the serial list, so write it down.
# ---------------------------------------------------------------------------
# At this scale nobody hand-maintains an inventory; every run regenerates one.
# Its main use is the reverse of an allowlist: paste the handful of lines you
# want left alone into a file and pass it as --exclude-serial-file next time.
inv="$logdir/inventory.csv"
{
	printf 'address,serial,verdict,image_version,kernel,slot,userdata,detail\n'
	for h in "${HOSTS[@]}"; do
		# Commas become semicolons: a device-tree model or an ssh error message can
		# contain one, and a shifted column here silently mis-buckets the summary.
		printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$h" "${SERIAL_OF[$h]:-}" "${VERDICT_OF[$h]}" \
			"${IMGVER_OF[$h]:-}" "${KERN_OF[$h]:-}" "${SLOT_OF[$h]:-}" "${UD_OF[$h]:-}" \
			"$(printf '%s' "${REASON_OF[$h]}" | tr ',' ';')"
	done
} > "$inv"

# Full per-host detail goes to the log; the terminal gets counts plus the
# exceptions. A 2000-line table scrolled past is not a report.
{
	printf '%-16s %-16s %-7s %s\n' ADDRESS SERIAL STATUS DETAIL
	for h in "${HOSTS[@]}"; do
		if [ "${VERDICT_OF[$h]}" = ok ]; then
			printf '%-16s %-16s %-7s %s\n' "$h" "${SERIAL_OF[$h]:--}" OURS "${INFO_OF[$h]}"
		else
			printf '%-16s %-16s %-7s %s\n' "$h" "${SERIAL_OF[$h]:--}" skip "${REASON_OF[$h]}"
		fi
	done
} > "$logdir/survey.txt"

log "survey"
note "$(printf '%5d hosts answered tcp/%s' "${#HOSTS[@]}" "$PORT")"
note "$(printf '%5d ours (right board, our key, our image)' "${#MATCHED[@]}")"
# Why the rest were dropped, bucketed — at scale the pattern is the signal.
awk -F, 'NR>1 && $3!="ok" {
		r=$8; sub(/^ */,"",r);
		if (r ~ /Permission denied/)              b="ssh key not authorized (not ours)";
		else if (r ~ /IDENTIFICATION HAS CHANGED/) b="host key changed (reflashed? ssh-keygen -R)";
		else if (r ~ /timed out|No route|refused|no response/) b="unreachable / no ssh";
		else if (r ~ /image markers/)             b="our board+key but not our rootfs";
		else if (r ~ /--from-version/)            b="our image, but not a version we were told to update";
		else if (r ~ /not a match/)               b="different hardware";
		else if (r ~ /duplicate/)                 b="second address of a device already listed";
		else                                       b=r;
		c[b]++ }
	END { for (k in c) printf "    %5d %s\n", c[k], k }' "$inv" | sort -rn
note "inventory -> $inv"
note "full table -> $logdir/survey.txt"

[ ${#MATCHED[@]} -gt 0 ] || { log "nothing of ours found"; exit 0; }

# ---------------------------------------------------------------------------
# 5) Narrow — optional serial filter, mandatory exclusions, up-to-date skip.
# ---------------------------------------------------------------------------
declare -a TO_FLASH=()
uptodate=0; otherver=0
for h in "${MATCHED[@]}"; do
	s="${SERIAL_OF[$h]}"
	if [ ${#ONLY_SERIALS[@]} -gt 0 ]; then
		hit=0; for x in "${ONLY_SERIALS[@]}"; do [ "$x" = "$s" ] && hit=1; done
		[ "$hit" = 1 ] || continue
	fi
	# Idempotence FIRST, before the version filter: a device already on the target
	# is done, and that is a different (and more useful) statement than "not in
	# --from-version". Checking the filter first would report a converged fleet as
	# a fleet full of unexpected versions. This is also what makes re-running the
	# same command the way to converge — each sweep picks up only what the last
	# one missed.
	if [ "$FORCE" != 1 ] && [ -n "$EXPECT_VER" ] && [ "${IMGVER_OF[$h]}" = "$EXPECT_VER" ]; then
		uptodate=$((uptodate + 1)); continue
	fi
	# Running one of OUR images, but not one we were told to update. This is the
	# gate that stands in for a serial allowlist: the contractors' initial image
	# version is knowable up front even when serials are not, so an unexpected
	# version means an unexpected device.
	if [ ${#FROM_VERSIONS[@]} -gt 0 ] && ! version_allowed "${IMGVER_OF[$h]}"; then
		otherver=$((otherver + 1)); continue
	fi
	skip=0
	for x in "${SKIP_SERIALS[@]:-}"; do
		[ -n "$x" ] || continue
		if [ "$x" = "$s" ]; then note "excluded by serial, leaving alone: $h ($s)"; skip=1; fi
	done
	[ "$skip" = 1 ] && continue
	TO_FLASH+=("$h")
done
[ "$otherver" -gt 0 ] && note "$otherver device(s) of ours on other image versions — not in --from-version, leaving alone"
[ "$uptodate" -gt 0 ] && note "$uptodate device(s) already on $EXPECT_VER — skipping (--force to reflash)"
note "${#TO_FLASH[@]} device(s) eligible to flash"

if [ "$DO_FLASH" != 1 ]; then
	log "survey only — nothing was modified. Add --flash to update."
	exit 0
fi
if [ ${#TO_FLASH[@]} -eq 0 ]; then
	# An empty target list means opposite things — the fleet is converged, or your
	# --from-version is stale and matched nothing. Give the breakdown rather than
	# a verdict, since only you know which one you expected.
	log "nothing to flash"
	note "${#MATCHED[@]} device(s) of ours: $uptodate already on ${EXPECT_VER:-the target}, $otherver on other versions, the rest excluded"
	[ "$otherver" -gt 0 ] && note "if those should have been updated, check --from-version against $inv"
	exit 0
fi

# ---------------------------------------------------------------------------
# 6) Confirm.
# ---------------------------------------------------------------------------
log "ABOUT TO FLASH ${#TO_FLASH[@]} DEVICE(S)"
if [ ${#TO_FLASH[@]} -le 20 ]; then
	for h in "${TO_FLASH[@]}"; do printf '    %-16s %-16s %s\n' "$h" "${SERIAL_OF[$h]}" "${INFO_OF[$h]}"; done
else
	for h in "${TO_FLASH[@]:0:5}"; do printf '    %-16s %-16s %s\n' "$h" "${SERIAL_OF[$h]}" "${INFO_OF[$h]}"; done
	printf '    ... and %d more (full list in %s)\n' "$((${#TO_FLASH[@]} - 5))" "$inv"
fi
printf '\n'
if [ ${#FROM_VERSIONS[@]} -gt 0 ]; then
	note "Only devices currently on: ${FROM_VERSIONS[*]}"
else
	# Not fatal — after the first sweep the fleet is on our version anyway and the
	# filter has to move with it — but silence here would be the wrong default.
	note "⚠ No --from-version: EVERY device running any of our images is a target."
	note "  If the contractors flashed a known initial image, name it — that is the"
	note "  cheapest way to keep this sweep off units you did not mean to touch."
fi
note "Target image version: ${EXPECT_VER:-unknown (no --expect-version, no debugfs)}"
note "Boot chain goes to the inactive slot (A/B-safe, rolls back on its own)."
note "The rootfs half overwrites 'super' in place: DESTRUCTIVE and NOT rollback-safe."
if [ "$NO_VERIFY" = 1 ]; then
	note "--no-verify: no canary gate, no circuit breaker. A bad image reaches ALL of them."
else
	note "Canary $CANARY, then waves of $WAVE; run aborts if failures exceed $MAX_FAIL_PCT%."
fi
if [ "$ASSUME_YES" != 1 ]; then
	[ -t 0 ] || die "refusing to flash non-interactively without -y"
	# Type the COUNT, not "yes". The failure this catches is the one that matters
	# at fleet scale — a target spec wider than you meant. If the number in front
	# of you isn't the number you expected, you stop.
	printf '\nType the number of devices to confirm (%d): ' "${#TO_FLASH[@]}"
	read -r answer
	[ "$answer" = "${#TO_FLASH[@]}" ] || { log "aborted — nothing was modified"; exit 2; }
fi

# ---------------------------------------------------------------------------
# 7) Flash, in waves, verifying each one.
# ---------------------------------------------------------------------------
log "logs -> $logdir"

flash_one() {  # <addr>
	local addr="$1" serial="${SERIAL_OF[$1]}"
	if "$here/flash-ssh.sh" "$(sshtarget "$addr")" > "$logdir/$addr.log" 2>&1; then
		printf 'sent %s %s\n' "$addr" "$serial" > "$logdir/$addr.status"
	else
		printf 'FAIL %s %s\n' "$addr" "$serial" > "$logdir/$addr.status"
	fi
}

# Verify by SERIAL, not by address: the device reboots into a fresh rootfs, so it
# may take a new DHCP lease, and it definitely has new SSH host keys. We re-scan
# the same targets and look for the serial we sent to.
verify_serials() {  # <serial...> -> writes $tmp/verified (one serial per line)
	local deadline=$((SECONDS + SETTLE)) missing=("$@") s h
	: > "$tmp/verified"
	while [ ${#missing[@]} -gt 0 ] && [ "$SECONDS" -lt "$deadline" ]; do
		# A felix takes ~40-60s to come back, and each poll is a full re-scan of the
		# target spec, so polling faster mostly just re-scans the subnet. POLL_SECONDS
		# exists to shrink it for testing.
		sleep "${POLL_SECONDS:-30}"
		discover
		mapfile -t rescan < "$tmp/hosts"
		[ ${#rescan[@]} -gt 0 ] || continue
		# We just reflashed these; their host keys changed BECAUSE OF US, so
		# dropping the stale entries is the honest bookkeeping rather than a
		# security bypass. Only for addresses in this wave's rescan.
		if [ "$INSECURE_HOSTKEYS" != 1 ]; then
			for h in "${rescan[@]}"; do ssh-keygen -R "$h" >/dev/null 2>&1 || true; done
		fi
		probe_all "${rescan[@]}"
		classify_all "${rescan[@]}"
		local still=()
		for s in "${missing[@]}"; do
			h="${ADDR_OF[$s]:-}"
			if [ -n "$h" ] && { [ -z "$EXPECT_VER" ] || [ "${IMGVER_OF[$h]}" = "$EXPECT_VER" ]; }; then
				printf '%s\n' "$s" >> "$tmp/verified"
				note "back: $s at $h (${IMGVER_OF[$h]:-?})"
			else
				still+=("$s")
			fi
		done
		missing=("${still[@]}")
		[ ${#missing[@]} -gt 0 ] && note "waiting for ${#missing[@]} device(s), $((deadline - SECONDS))s left"
	done
	[ ${#missing[@]} -eq 0 ] || printf '%s\n' "${missing[@]}" > "$tmp/lost"
}

declare -a REMAINING=("${TO_FLASH[@]}")
attempted=0; failed=0; succeeded=0; wave_no=0
declare -a FAILED_LIST=()

while [ ${#REMAINING[@]} -gt 0 ]; do
	wave_no=$((wave_no + 1))
	if [ "$wave_no" = 1 ] && [ "$NO_VERIFY" != 1 ] && [ "$CANARY" -gt 0 ]; then
		size="$CANARY"; label="canary"
	else
		size="$WAVE"; label="wave $wave_no"
	fi
	[ "$size" -gt ${#REMAINING[@]} ] && size=${#REMAINING[@]}
	batch=("${REMAINING[@]:0:size}")
	REMAINING=("${REMAINING[@]:size}")

	log "$label: flashing ${#batch[@]} device(s), up to $JOBS at a time (${#REMAINING[@]} queued after this)"
	running=0
	for h in "${batch[@]}"; do
		note "starting $h (${SERIAL_OF[$h]}) -> $logdir/$h.log"
		flash_one "$h" &
		running=$((running + 1))
		if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || wait; running=$((running - 1)); fi
	done
	wait

	# Which ones flash-ssh.sh actually managed to arm and reboot.
	sent_serials=();
	for h in "${batch[@]}"; do
		attempted=$((attempted + 1))
		if grep -q '^sent' "$logdir/$h.status" 2>/dev/null; then
			sent_serials+=("${SERIAL_OF[$h]}")
		else
			failed=$((failed + 1)); FAILED_LIST+=("$h ${SERIAL_OF[$h]} (flash-ssh failed)")
			note "FAILED to flash $h: $(tail -1 "$logdir/$h.log" 2>/dev/null | cut -c1-100)"
		fi
	done

	if [ "$NO_VERIFY" = 1 ]; then
		succeeded=$((succeeded + ${#sent_serials[@]}))
	elif [ ${#sent_serials[@]} -gt 0 ]; then
		log "$label: waiting up to ${SETTLE}s for ${#sent_serials[@]} device(s) to come back on ${EXPECT_VER:-a new version}"
		verify_serials "${sent_serials[@]}"
		nver=$(wc -l < "$tmp/verified" 2>/dev/null || echo 0)
		succeeded=$((succeeded + nver))
		if [ -s "$tmp/lost" ]; then
			while read -r s; do
				failed=$((failed + 1)); FAILED_LIST+=("$s (flashed, did not come back on the target version)")
			done < "$tmp/lost"
			rm -f "$tmp/lost"
		fi
	fi

	# ---- gates ----
	if [ "$label" = canary ] && [ "$failed" -gt 0 ]; then
		log "CANARY FAILED — stopping with ${#REMAINING[@]} device(s) untouched"
		note "The canary is why a bad image costs $CANARY device(s) here, not ${#TO_FLASH[@]}."
		note "Fix the image (or the failing units) and re-run: devices already updated"
		note "are skipped, so the same command resumes where this stopped."
		break
	fi
	if [ "$attempted" -gt 0 ] && [ $((failed * 100 / attempted)) -gt "$MAX_FAIL_PCT" ]; then
		log "CIRCUIT BREAKER: $failed/$attempted failed (> $MAX_FAIL_PCT%) — stopping with ${#REMAINING[@]} untouched"
		break
	fi
done

# ---------------------------------------------------------------------------
# 8) Summary.
# ---------------------------------------------------------------------------
log "results"
note "$(printf '%5d flashed and verified' "$succeeded")"
note "$(printf '%5d failed' "$failed")"
note "$(printf '%5d not attempted (run stopped early)' "${#REMAINING[@]}")"
if [ "$failed" -gt 0 ]; then
	printf '\n'
	for l in "${FAILED_LIST[@]}"; do printf '    FAIL %s\n' "$l"; done
	printf '\n'
	note "A device that failed BEFORE its reboot is untouched or half-staged, not"
	note "bricked: flash-ssh.sh stages and verifies the image before arming anything."
	note "One that flashed but did not come back needs a look — start with its log."
fi
printf '\n'
note "logs + inventory: $logdir"
note "Re-run the same command to converge: updated devices are skipped automatically."
[ "$failed" -eq 0 ] && [ ${#REMAINING[@]} -eq 0 ] && exit 0
exit 1
