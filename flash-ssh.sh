#!/bin/bash
#
# flash-ssh.sh — flash a *running* felix over SSH with pixel-ota, no fastboot.
#
# flash-fastboot.sh needs the device sitting in the bootloader on USB. This path
# updates a device that is already booted and reachable on the network (the image
# ships openssh-server): it flashes the inactive boot slot with pixel-ota,
# switches to it, and reflashes the live rootfs in place — the userspace analog
# of an OTA. Meant for fleet use, so it is non-interactive.
#
# What it does, in order:
#   1. Preflight: ssh reachable, passwordless sudo, /bin/busybox present, AND —
#      because the rootfs reflash must stage onto a persistent, non-`super`
#      partition — a mounted userdata with room for the image. If userdata is not
#      mounted we MOUNT IT (see the automount block below); we never format it
#      unless USERDATA_MKFS=1 is passed explicitly.
#   2. Ensure pixel-bootctl + pixel-ota are on the device. The running fleet
#      image predates both tools, so we assume NEITHER is present: we CHECK each
#      and scp+install only the ones that are missing.
#   3. Stage rootfs.img onto userdata (the long, fail-prone transfer happens
#      while the device is still untouched, so a failure here changes nothing).
#   4. Boot chain: copy boot/vendor_boot/dtbo and run `pixel-ota update` — writes
#      the inactive slot and switches the active slot (no reboot).
#   5. Arm the in-place rootfs reflash: `pixel-ota flash-rootfs --staged
#      --no-reboot` AND touch `<userdata>/pixel-ota/flash-pending`.
#      ★ The flag is the part that matters. pixel-ota's own systemd
#      shutdown-pivot is INERT on these images (dracut-shutdown.service is
#      /bin/true); the reflash is actually done by the overlay's 90rootfs-flash
#      dracut PRE-MOUNT hook, which triggers on that flag and nothing else.
#      Omitting it makes this script silently flash only HALF the update.
#   6. One reboot applies both: the dracut pre-mount hook writes the staged
#      image onto `super` before root is mounted (verifying rootfs.img.sha256
#      first), then the bootloader boots the freshly-switched slot.
#
# WARNING: the rootfs reflash is destructive and rollback-free — a bad image
# bricks the root and needs fastboot/recovery. The boot-chain half is A/B-safe.
#
# Usage: ./flash-ssh.sh [user@]host
#   Env: SSH_OPTS                       extra ssh/scp options (e.g. "-i key")
#        USERDATA_MNT                   device staging mountpoint (default /userdata)
#        USERDATA_DEV                   staging partition (default: the GPT
#                                       partition labelled `userdata`)
#        USERDATA_MKFS=1                allow mkfs.ext4 on it if it is not ext4.
#                                       DESTRUCTIVE — erases the 229 GB partition.
#        BOOT_IMG / VENDOR_BOOT_IMG / DTBO_IMG / ROOTFS_IMG / PIXEL_OTA_BIN /
#        PIXEL_BOOTCTL_BIN              override artifact paths
set -euo pipefail

HOST="${1:-}"
[ -n "$HOST" ] || { echo "usage: $0 [user@]host" >&2; exit 2; }

here="$(cd "$(dirname "$0")" && pwd)"
# Build outputs (same images flash-fastboot.sh flashes) + the static aarch64
# binaries. Both pixel-bootctl and pixel-ota are cross-built into the overlay by
# the Makefile (.build_pixel_bootctl / .build_pixel_ota), so we read them from
# there.
BOOT_IMG="${BOOT_IMG:-$here/boot/boot.img}"
VENDOR_BOOT_IMG="${VENDOR_BOOT_IMG:-$here/boot/vendor_boot.img}"
# Note: `-` not `:-` so an explicit empty DTBO_IMG= skips dtbo (unset = default).
DTBO_IMG="${DTBO_IMG-$here/kernel/source/out/felix/dist/dtbo.img}"
ROOTFS_IMG="${ROOTFS_IMG:-$here/boot/rootfs.img}"
PIXEL_BOOTCTL_BIN="${PIXEL_BOOTCTL_BIN:-$here/rootfs/overlay/usr/local/bin/pixel-bootctl}"
PIXEL_OTA_BIN="${PIXEL_OTA_BIN:-$here/rootfs/overlay/usr/local/bin/pixel-ota}"

SSH_OPTS="${SSH_OPTS:-}"

# RATE LIMIT — conservative pacing for an intermittent, UNEXPLAINED fault.
# Off by default. Read this before turning it on or quoting a number from it.
#
# THE FAULT IT HEDGES AGAINST: the phone's xHCI HOST CONTROLLER dies outright,
# taking the dongle with it and stranding the unit:
#     xHCI host not responding to stop endpoint command
#     xHCI host controller not responding, assume dead / HC died; cleaning up
#     r8152 ...: Tx status -2        <- consequence, NOT the cause
# A Stop Endpoint command that fails to retire makes the xHCI core do an
# unconditional xhci_halt() + xhci_hc_died() (xhci-ring.c), so one stalled
# endpoint takes the whole bus down. On a fielded unit the network is the only
# way in, so an OTA that trips this destroys the thing it depends on. That part
# is well established.
#
# ★★ WHAT IS NOT ESTABLISHED: that throughput causes it.
# An earlier version of this comment asserted a "cliff between 89 and 133 Mb/s"
# and called the cap load-bearing. THAT WAS WRONG and is retracted. Measured on
# 34291FDHS000WV 2026-08-03, same unit, same evening:
#     ~923 Mb/s (line rate, wired source) -> 60s clean, 0 HC deaths
#     10 consecutive trials, 89 GiB moved -> 0 HC deaths, no reboot
# The original "cliff" was an artifact of the traffic SOURCE: every early
# measurement came from a WiFi-attached laptop that could not push past
# ~133 Mb/s. Rate never was the variable.
#
# Also retracted from that era: that the mainline port is immune (at line rate
# the two tracks are indistinguishable), and that
# `snps,parkmode-disable-ss-quirk` fixes it (it was already installed for the
# last observed failure). Real HC deaths that day: 5, all at or before 19:26;
# none in any later trial. The trigger is still UNIDENTIFIED and the fault is
# INTERMITTENT — it has produced both quiet and failing phases with no isolated
# variable, which is why this knob exists at all.
#
# WHY IT DEFAULTS OFF: capping at 80 Mb/s makes an 8 GB rootfs push take ~13min
# instead of ~80s, and there is no evidence it prevents anything. Paying a 10x
# slowdown for a hedge against a mechanism we have disproven is the wrong trade.
# Set SCP_RATE_KBIT to a positive value to pace transfers if a unit starts
# showing HC deaths again — it is a mitigation of last resort, not a fix.
#
# ★ UNITS: scp -l is Kbit/s, NOT KB/s. 80000 = 80 Mb/s. Writing -l 700 here
# (a mistake made once) is 700 Kbit/s ~ 87 KB/s and would take ~25h for an
# 8 GB rootfs.
SCP_RATE_KBIT="${SCP_RATE_KBIT:-0}"
if [ "$SCP_RATE_KBIT" -gt 0 ] 2>/dev/null; then
	SCP_LIMIT="-l $SCP_RATE_KBIT"
else
	SCP_LIMIT=""
fi

# shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split.
sshc() { ssh $SSH_OPTS "$HOST" "$@"; }
# shellcheck disable=SC2086  # SSH_OPTS and SCP_LIMIT are intentionally word-split.
scpc() { scp $SCP_LIMIT $SSH_OPTS "$@"; }
log()  { printf '\n>>> %s\n' "$*"; }
die()  { printf 'flash-ssh: %s\n' "$*" >&2; exit 1; }

# 1) Local preflight ---------------------------------------------------------
for f in "$BOOT_IMG" "$VENDOR_BOOT_IMG" "$ROOTFS_IMG" "$PIXEL_BOOTCTL_BIN"; do
	[ -f "$f" ] || die "missing local artifact: $f"
done
# dtbo is OPTIONAL: some images (e.g. the original fleet image) ship none and
# rely on the dtbo already on the device. Set DTBO_IMG= to skip it; a non-empty
# path that doesn't exist is a misconfiguration, so fail on that.
if [ -n "$DTBO_IMG" ] && [ ! -f "$DTBO_IMG" ]; then
	die "DTBO_IMG set but not found: $DTBO_IMG (set DTBO_IMG= to flash without dtbo)"
fi
[ -f "$PIXEL_OTA_BIN" ] || die "pixel-ota not built: $PIXEL_OTA_BIN
  build it: nix develop -c make .build_pixel_ota   (or build the rootfs)"
img_size=$(stat -c %s "$ROOTFS_IMG")

# 2) Device preflight — query state, make NO changes -------------------------
log "preflight $HOST"
sshc true 2>/dev/null      || die "cannot ssh to $HOST"
sshc sudo -n true 2>/dev/null || die "passwordless sudo not available on $HOST"
sshc 'test -x /bin/busybox'   || die "/bin/busybox missing on $HOST (pixel-ota flash-rootfs needs it)"

# userdata must be mounted: the rootfs reflash stages the image on a persistent
# partition that is NOT `super`, and pixel-ota --staged refuses to stage on the
# target partition.
ud_mnt="${USERDATA_MNT:-/userdata}"
# Exact-mountpoint match (no --target): findmnt returns the SOURCE only if
# $ud_mnt is *itself* a mountpoint; a bare non-mounted directory yields nothing.
ud_src=$(sshc "findmnt -fnro SOURCE --mountpoint '$ud_mnt' 2>/dev/null" || true)

# AUTOMOUNT — this used to be a hard failure ("run setup.sh there first"), which
# made the common case fail: THIS SCRIPT REPLACES THE WHOLE ROOTFS, so whatever
# mounted /userdata (an fstab entry, the fleet setup.sh) is gone the moment the
# OTA lands. Every device is therefore un-stageable on its *second* flash-ssh run
# unless someone re-mounts by hand — on units whose only access is the network.
# Mounting is also cheap and non-destructive: it is a read of the GPT plus a
# mount(2), on a partition this script is about to write a staging file into
# anyway. Formatting is the destructive part, and that stays opt-in.
if [ -z "$ud_src" ]; then
	log "$ud_mnt is not a mountpoint on $HOST — mounting userdata"
	# Run it as one remote root script: locating the partition, checking the
	# filesystem and mounting have to be a single atomic decision, and a heredoc
	# beats three layers of ssh quoting.
	#
	# ext4 is REQUIRED, not merely preferred: the 90rootfs-flash dracut hook
	# mounts the staging partition with a hard `mount -t ext4` (it runs before
	# root is up, with no filesystem autodetect and no f2fs module loaded). A
	# staged image on an f2fs userdata would be invisible to the hook — i.e. the
	# silent half-flash this script exists to prevent. So we refuse a non-ext4
	# userdata rather than stage into a partition the flash hook cannot read.
	mount_out=$(sshc "sudo sh -s -- '$ud_mnt' '${USERDATA_DEV:-}' '${USERDATA_MKFS:-0}'" <<'REMOTE' || true
set -u
mnt="$1"; dev="$2"; allow_mkfs="$3"

if [ -z "$dev" ]; then
	# by-partlabel is the authoritative name; sda31 is only where it happens to
	# land today, and the label survives a repartition that renumbers it.
	if [ -b /dev/disk/by-partlabel/userdata ]; then
		dev=$(readlink -f /dev/disk/by-partlabel/userdata)
	else
		dev=$(lsblk -rno PATH,PARTLABEL 2>/dev/null | awk '$2=="userdata"{print $1; exit}')
	fi
fi
[ -n "$dev" ] && [ -b "$dev" ] || {
	echo "ERR no GPT partition labelled 'userdata' found (set USERDATA_DEV=/dev/...)"; exit 1; }

fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
if [ "$fstype" != ext4 ]; then
	if [ "$allow_mkfs" = 1 ]; then
		echo "MKFS $dev was '${fstype:-unformatted}' — reformatting ext4 (USERDATA_MKFS=1)"
		mkfs.ext4 -F -L userdata "$dev" >/dev/null 2>&1 || { echo "ERR mkfs.ext4 failed on $dev"; exit 1; }
	else
		echo "ERR $dev is '${fstype:-unformatted}', not ext4 — the 90rootfs-flash dracut hook mounts it with 'mount -t ext4' and would not see the staged image. Re-run with USERDATA_MKFS=1 to reformat it (DESTRUCTIVE: erases userdata)."
		exit 1
	fi
fi

# Already mounted somewhere else (a leftover /data, a different USERDATA_MNT on a
# previous run): adopt that mountpoint rather than fail on "already mounted". One
# partition, one staging directory — mounting it twice would just as easily leave
# the image on the copy the flash hook doesn't read.
cur=$(findmnt -fnro TARGET --source "$dev" 2>/dev/null | head -n1)
if [ -n "$cur" ]; then
	echo "MOUNTED $dev $cur"
	exit 0
fi

mkdir -p "$mnt"
mount -t ext4 "$dev" "$mnt" || { echo "ERR mount $dev -> $mnt failed"; exit 1; }
echo "MOUNTED $dev $mnt"
REMOTE
	)
	printf '%s\n' "$mount_out" | sed 's/^/    /'
	mounted_line=$(printf '%s\n' "$mount_out" | grep '^MOUNTED ' | tail -n1)
	[ -n "$mounted_line" ] || die "could not mount userdata on $HOST (see above). Aborting before any changes."
	# The remote side reports where it ACTUALLY ended up, which is not always
	# $ud_mnt (it adopts an existing mount of the same partition). Stage there.
	ud_mnt=${mounted_line##* }
	ud_src=$(sshc "findmnt -fnro SOURCE --mountpoint '$ud_mnt' 2>/dev/null" || true)
	[ -n "$ud_src" ] || die "$ud_mnt still not a mountpoint on $HOST after mounting"
fi
log "userdata mounted at $ud_mnt ($ud_src)"

avail=$(sshc "df -B1 --output=avail '$ud_mnt' | tail -1 | tr -d ' '" || true)
case "$avail" in
	''|*[!0-9]*) die "could not read free space on $ud_mnt ($HOST)" ;;
esac
[ "$avail" -ge "$img_size" ] || die "not enough space on $ud_mnt: need $img_size, have $avail"

# 3) Ensure the tools are on the device (check, copy only if missing) --------
ensure_bin() {  # <name> <local-path>
	local name="$1" src="$2"
	if sshc "command -v '$name' >/dev/null 2>&1 || test -x '/usr/local/bin/$name'"; then
		log "$name already on $HOST"
	else
		log "$name missing on $HOST — installing"
		scpc "$src" "$HOST:/tmp/$name"
		sshc "sudo install -m 0755 '/tmp/$name' '/usr/local/bin/$name' && rm -f '/tmp/$name'"
	fi
}
ensure_bin pixel-bootctl "$PIXEL_BOOTCTL_BIN"
ensure_bin pixel-ota "$PIXEL_OTA_BIN"

# 4) Stage the rootfs first — the long transfer, while nothing has changed ---
stage="$ud_mnt/pixel-ota"
log "staging rootfs.img onto $stage (in-place reflash is DESTRUCTIVE, no rollback)"
sshc "sudo mkdir -p '$stage'"
# gzip the stream so the image's large zero regions don't cross the wire in
# full (gzip is Priority:required on the device). sudo sh writes it as root onto
# userdata, where pixel-ota --staged resolves it back to the userdata partition.
#
# NOTE on the rate cap: this path deliberately does NOT go through scpc(), so
# SCP_RATE_KBIT does not apply. It is safe anyway — what matters for the
# host-controller bug is the WIRE rate, and the wire carries the COMPRESSED
# stream. A mostly-empty 7.9 GiB image compresses to ~1 GB, measured at ~1.3
# MB/s on the wire, far under the ~90 Mb/s cliff. Do not "optimise" this into a
# raw uncompressed transfer without re-reading the rate-limit comment above.
gzip -c -- "$ROOTFS_IMG" | sshc "sudo sh -c 'gzip -dc > \"$stage/rootfs.img\"'"

# Stage the digest next to the image so the 90rootfs-flash dracut hook can
# refuse a truncated write. The hook writes the staged image over `super`, which
# is NOT slotted — a partial image means an unbootable device with no rollback,
# recoverable only by fastboot on a unit that by design has no physical access.
# Staging is a long interruptible transfer and arming the flag is a separate
# step, so "flag set, image incomplete" is reachable; it was observed for real
# (a 1.06 GB fragment of a 7.9 GiB image left over from an aborted run).
#
# Written AFTER the image so the digest can never look valid for a partial file:
# if the transfer above dies, no .sha256 exists and the hook flags the write as
# unverified rather than silently trusting it.
log "staging rootfs.img.sha256 + .size (integrity gate for the flash hook)"
rootfs_sha=$(sha256sum -- "$ROOTFS_IMG" | cut -d' ' -f1)
printf '%s\n' "$rootfs_sha" | sshc "sudo sh -c 'cat > \"$stage/rootfs.img.sha256\"'"
# Size is the FALLBACK the hook uses when sha256sum is unusable in the
# initramfs. That happened for real on 35041FDHS0032G: sha256sum was installed
# but produced nothing, the hook refused a good image, and the unit ended up
# with a new kernel on the old rootfs. Size is weaker than a digest but catches
# the failure that actually occurs here — a truncated staging transfer.
rootfs_size=$(stat -c%s -- "$ROOTFS_IMG")
printf '%s\n' "$rootfs_size" | sshc "sudo sh -c 'cat > \"$stage/rootfs.img.size\"'"
# Verify the staged copy end-to-end before anything is armed.
remote_sha=$(sshc "sudo sha256sum '$stage/rootfs.img' | cut -d' ' -f1")
[ "$remote_sha" = "$rootfs_sha" ] || die "staged rootfs.img digest mismatch (local $rootfs_sha, remote $remote_sha)"
log "staged rootfs verified: $rootfs_sha"

# 5) Boot chain: flash inactive slot + switch (no reboot) --------------------
log "boot chain -> inactive slot (pixel-ota update)"
rdir=$(sshc 'mktemp -d')
# shellcheck disable=SC2064  # expand $rdir/$HOST now, into the EXIT trap.
trap "ssh $SSH_OPTS '$HOST' 'rm -rf \"$rdir\"' >/dev/null 2>&1 || true" EXIT
scpc "$BOOT_IMG"        "$HOST:$rdir/boot.img"
scpc "$VENDOR_BOOT_IMG" "$HOST:$rdir/vendor_boot.img"
if [ -n "$DTBO_IMG" ]; then
	scpc "$DTBO_IMG" "$HOST:$rdir/dtbo.img"
else
	log "no DTBO_IMG — leaving the device's existing dtbo in place"
fi
# ★ Normalise the TARGET slot's AVB flags BEFORE pixel-ota switches to it.
#
# `fastboot oem disable-verity` / `oem disable-verification` (flash-fastboot.sh)
# apply ONLY to the slot that was active when they ran. The other slot keeps AVB
# enforcement on, so our unsigned/repacked boot chain fails verification there,
# the slot never reaches earlycon, all 7 retries burn in a SINGLE reboot cycle,
# and the bootloader rolls back.
#
# Measured on 35071FDHS0017C (2026-08-04), after a run that reported complete
# success and wrote byte-perfect images to slot B:
#     vbmeta_a  flags=0x00000003   <- HASHTREE_DISABLED|VERIFICATION_DISABLED
#     vbmeta_b  flags=0x00000000   <- still enforcing
# The device came back on slot A running the OLD image. Nothing on the host side
# indicates a problem: FLASH_SSH_EXIT=0, and boot_b/vendor_boot_b/dtbo_b all
# hashed identical to the local images. The only tells are `pixel-bootctl status`
# showing the target at `retry count: 0, successful: false` and pstore being empty
# (felix has no dmesg-ramoops), so the failed attempts leave no log at all.
#
# AVB vbmeta header: flags is u32 BE at offset 0x78 (=120). Bit0 HASHTREE_DISABLED,
# bit1 VERIFICATION_DISABLED. Writing it by hand is exactly what
# `fastboot --disable-verification flash vbmeta` does to the image before flashing;
# it works because an UNLOCKED device does not enforce the vbmeta signature (slot A
# already boots with verifiedbootstate=orange / verifyerrorpart=vbmeta). Only the
# top-level vbmeta needs it — VERIFICATION_DISABLED makes libavb skip the chained
# vbmeta_system/vbmeta_vendor, which is why those read 0x00 on the slot that works.
#
# Safe from the running OS: this touches only the INACTIVE slot, and it is
# reversible (the original value is 0x00000000).
log "normalising AVB flags on the target slot (else it fails verification and rolls back)"
# Sent as a quoted here-doc so the remote script needs no shell escaping.
sshc 'sudo sh -s' <<'AVBFIX' || die "could not normalise the target slot's AVB flags"
set -e
act=$(grep -o 'slot_suffix = "[^"]*"' /proc/bootconfig | cut -d'"' -f2)
case "$act" in
	_a) tgt=b ;;
	_b) tgt=a ;;
	*)  echo "cannot determine active slot (got '$act')" >&2; exit 1 ;;
esac
dev=/dev/disk/by-partlabel/vbmeta_$tgt
[ -b "$dev" ] || { echo "no such partition: $dev" >&2; exit 1; }
rd() { dd if="$dev" bs=1 skip=120 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n'; }
before=$(rd)
printf '\000\000\000\003' | dd of="$dev" bs=1 seek=120 count=4 conv=notrunc 2>/dev/null
sync
after=$(rd)
echo "    active=$act  target=vbmeta_$tgt  flags: 0x$before -> 0x$after"
[ "$after" = "00000003" ] || { echo "vbmeta_$tgt flags did not take" >&2; exit 1; }
AVBFIX

sshc "sudo pixel-ota update '$rdir'"

# 6) Arm the in-place rootfs reflash (no reboot) -----------------------------
log "arming rootfs reflash (pixel-ota flash-rootfs --staged)"
sshc "sudo pixel-ota flash-rootfs --staged --no-reboot '$stage/rootfs.img'"

# ★ AND set the flag the mechanism that ACTUALLY RUNS keys on.
#
# pixel-ota arms its own systemd shutdown-pivot, which is INERT on these images
# (dracut-shutdown.service is /bin/true here). The reflash is really performed by
# the overlay's 90rootfs-flash dracut PRE-MOUNT hook, which triggers on
# `<userdata>/pixel-ota/flash-pending` and nothing else.
#
# Without this touch the OTA silently does HALF the job: the boot chain switches
# slots and comes up fine, so the run looks successful, while `super` is never
# written and the device keeps running the OLD rootfs. Reproduced end-to-end
# 2026-08-03 — the hook logged exactly this and correctly declined:
#     rootfs-flash: hook invoked
#     rootfs-flash: no pending flash (looked for .../flash-pending + .../rootfs.img)
# and the device came back on the previous rootfs with flash-ssh reporting
# success. A silent half-flash is worse than a loud failure: it invites you to
# conclude the new image is running when it is not.
#
# Safe to set unconditionally: the hook clears the flag BEFORE it writes
# (write-once), so a crash mid-write cannot loop-flash, and a stale flag with no
# image is a no-op. The digest staged above is what protects the write itself.
log "arming the dracut pre-mount hook (userdata:/pixel-ota/flash-pending)"
sshc "sudo touch '$stage/flash-pending' && sudo sync"
sshc "sudo ls -l '$stage/'" | sed 's/^/    /'

# 7) One reboot applies new slot + rootfs flash ------------------------------
log "rebooting $HOST (connection will drop)"
sshc 'sudo systemctl reboot' || true
log "done — $HOST flashes super from the shutdown initramfs, then boots the new slot."
