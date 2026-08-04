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
#   1. Preflight (NO changes): ssh reachable, passwordless sudo, /bin/busybox
#      present, AND — because the rootfs reflash must stage onto a persistent,
#      non-`super` partition — that userdata is mounted with room for the image.
#      The deployed fleet image mounts userdata (/dev/sda31) at /userdata via its
#      setup.sh; we query the device for that mount and, if it is NOT mounted,
#      FAIL here before touching anything (we do not format/mount it ourselves).
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

# userdata must already be mounted: the rootfs reflash stages the image on a
# persistent partition that is NOT `super`, and pixel-ota --staged refuses to
# stage on the target partition. The fleet image's setup.sh formats /dev/sda31
# and mounts it at /userdata — we query THAT mount (not a by-partlabel symlink,
# which the deployed image doesn't rely on). If it isn't mounted we fail; we do
# not format/mount it ourselves, that's setup.sh's job.
ud_mnt="${USERDATA_MNT:-/userdata}"
# Exact-mountpoint match (no --target): findmnt returns the SOURCE only if
# $ud_mnt is *itself* a mountpoint; a bare non-mounted directory yields nothing.
ud_src=$(sshc "findmnt -fnro SOURCE --mountpoint '$ud_mnt' 2>/dev/null" || true)
[ -n "$ud_src" ] || die "$ud_mnt is not a mountpoint on $HOST — run the fleet setup.sh there first; rootfs staging needs a persistent non-super partition. Aborting before any changes."
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
