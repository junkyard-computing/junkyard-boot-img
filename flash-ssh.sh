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
#   5. Arm `pixel-ota flash-rootfs --staged --no-reboot` — the in-place rootfs
#      reflash via systemd's shutdown initramfs.
#   6. One reboot applies both: the shutdown initramfs dd's the new rootfs onto
#      `super`, then the bootloader boots the freshly-switched slot.
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
# binaries. pixel-bootctl is built into the overlay by the Makefile; pixel-ota
# is source-only here, so it must be cross-built first (see the error below).
BOOT_IMG="${BOOT_IMG:-$here/boot/boot.img}"
VENDOR_BOOT_IMG="${VENDOR_BOOT_IMG:-$here/boot/vendor_boot.img}"
# Note: `-` not `:-` so an explicit empty DTBO_IMG= skips dtbo (unset = default).
DTBO_IMG="${DTBO_IMG-$here/kernel/source/out/felix/dist/dtbo.img}"
ROOTFS_IMG="${ROOTFS_IMG:-$here/boot/rootfs.img}"
PIXEL_BOOTCTL_BIN="${PIXEL_BOOTCTL_BIN:-$here/rootfs/overlay/usr/local/bin/pixel-bootctl}"
PIXEL_OTA_BIN="${PIXEL_OTA_BIN:-$here/tools/pixel-ota/target/aarch64-unknown-linux-musl/release/pixel-ota}"

SSH_OPTS="${SSH_OPTS:-}"
# shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split.
sshc() { ssh $SSH_OPTS "$HOST" "$@"; }
scpc() { scp $SSH_OPTS "$@"; }
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
  build it: nix develop -c bash -c 'cd tools/pixel-ota && \\
    RUSTFLAGS=\"-C linker=rust-lld -C strip=symbols\" \\
    cargo build --release --target aarch64-unknown-linux-musl'"
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
gzip -c -- "$ROOTFS_IMG" | sshc "sudo sh -c 'gzip -dc > \"$stage/rootfs.img\"'"

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

# 7) One reboot applies new slot + rootfs flash ------------------------------
log "rebooting $HOST (connection will drop)"
sshc 'sudo systemctl reboot' || true
log "done — $HOST flashes super from the shutdown initramfs, then boots the new slot."
