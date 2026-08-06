#!/usr/bin/env bash
# Offline acceptance gate for boot/rootfs.img — run BEFORE flashing.
#
# Reads the ext4 image with debugfs (no mount, no root) and asserts the
# properties whose absence has previously shipped a broken image. Run it via
# the build container, which has e2fsprogs:
#
#   tools/dockershell tools/gate-image.sh
#
# Every check here exists because it failed silently once. In particular the
# ownership block: three separate rsyncs (overlay, vendor firmware, ARM blobs)
# ran without --chown=root:root, leaving 18 directories and 1456 files owned by
# uid 1000 — including `/` itself. Nothing errored. The visible consequence was
# that systemd-tmpfiles REFUSED every rule under /sys with "Detected unsafe path
# transition / (owned by kalm) -> /sys" and still exited 0, so the USB
# autosuspend fix was a silent no-op and the dongle kept dropping off the bus.
set -uo pipefail

IMG="${1:-boot/rootfs.img}"
fail=0
pass=0

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

[ -f "$IMG" ] || { red "no image at $IMG"; exit 2; }
command -v debugfs >/dev/null || { red "debugfs not found — run under tools/dockershell"; exit 2; }

dbg() { debugfs -R "$1" "$IMG" 2>/dev/null; }

ok()  { green "  ok    $*"; pass=$((pass+1)); }
bad() { red   "  FAIL  $*"; fail=$((fail+1)); }

# ---- ownership -------------------------------------------------------------
# uid/gid must be 0 everywhere outside /home. Checked on the ancestors too:
# an earlier partial fix added --chown=root:root to the rsyncs, which corrects
# the files rsync writes but NOT the pre-existing directories it descends
# through, so /, /etc and /usr stayed uid 1000 and tmpfiles still refused.
head_ "ownership (uid/gid must be 0)"
for p in / /etc /usr /usr/lib /usr/local /usr/local/bin /usr/local/sbin \
         /etc/systemd /etc/systemd/system /etc/udev /etc/udev/rules.d \
         /etc/tmpfiles.d /etc/NetworkManager /vendor /vendor/firmware \
         /usr/lib/dracut /usr/lib/dracut/modules.d \
         /etc/tmpfiles.d/usb-autosuspend.conf \
         /etc/udev/rules.d/99-usb-no-autosuspend.rules \
         /usr/local/sbin/usb_gadget /usr/local/sbin/netcheck-recover \
         /usr/local/bin/pixel-bootctl /usr/local/bin/pixel-ota \
         /vendor/firmware/aoc.bin ; do
    line="$(dbg "stat \"$p\"" | grep -m1 'User:')"
    if [ -z "$line" ]; then bad "$p — MISSING from image"; continue; fi
    uid="$(printf '%s' "$line" | sed -n 's/.*User: *\([0-9]\+\).*/\1/p')"
    gid="$(printf '%s' "$line" | sed -n 's/.*Group: *\([0-9]\+\).*/\1/p')"
    if [ "$uid" = 0 ] && [ "$gid" = 0 ]; then ok "$p"
    else bad "$p — uid=$uid gid=$gid (want 0/0)"; fi
done

# ---- files that must be present -------------------------------------------
# firmware-realtek is the one that took a day to find: without rtl8153a-4.fw the
# r8152 dongle loads with -2, runs without its errata patch, and intermittently
# fails to get a DHCP lease.
head_ "required files"
for p in /lib/firmware/rtl_nic/rtl8153a-4.fw \
         /usr/sbin/dnsmasq \
         /etc/NetworkManager/conf.d/10-unmanage-usb0.conf \
         /etc/systemd/system/netcheck-recover.timer \
         /etc/systemd/system/usb-gadget.service \
         /etc/systemd/system.conf.d/10-watchdog.conf \
         /etc/systemd/system.conf.d/10-bounded-shutdown.conf ; do
    if dbg "stat \"$p\"" | grep -q 'Inode:'; then ok "$p"; else bad "$p — MISSING"; fi
done

# ---- enabled units ---------------------------------------------------------
# .wants symlinks are how this image enables units (never `systemctl enable`).
head_ "enabled units"
mu="$(dbg 'ls -l /etc/systemd/system/multi-user.target.wants')"
tw="$(dbg 'ls -l /etc/systemd/system/timers.target.wants')"
for u in usb-gadget.service pstore-beacon.service network-beacon.service \
         boot-slot-issue.service dongle-mac-issue.service ; do
    printf '%s' "$mu" | grep -q "$u" && ok "enabled: $u" || bad "NOT enabled: $u"
done
printf '%s' "$tw" | grep -q netcheck-recover.timer \
    && ok "enabled: netcheck-recover.timer" || bad "NOT enabled: netcheck-recover.timer"

# mark-slot-successful marked EVERY boot good, which destroys A/B rollback:
# a slot that boots but has no network would still be committed. Only
# netcheck-recover marks a slot successful now, and only after it proves it has
# an address. Retired via RETIRED_OVERLAY_PATHS; assert it really is gone.
head_ "retired units must be absent"
for u in mark-slot-successful.service netcheck-recover.service ; do
    if printf '%s' "$mu" | grep -q "$u"; then bad "still enabled: $u"; else ok "absent from multi-user.wants: $u"; fi
done

# ---- content spot-checks ---------------------------------------------------
head_ "content"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if dbg "dump /etc/tmpfiles.d/usb-autosuspend.conf $tmp/asp" >/dev/null 2>&1 && [ -s "$tmp/asp" ]; then
    grep -q 'autosuspend' "$tmp/asp" && grep -q -- '-1' "$tmp/asp" \
        && ok "tmpfiles sets usbcore autosuspend=-1" \
        || bad "usb-autosuspend.conf present but does not set -1"
else bad "could not read /etc/tmpfiles.d/usb-autosuspend.conf"; fi

if dbg "dump /etc/apt/sources.list $tmp/sl" >/dev/null 2>&1 && [ -s "$tmp/sl" ]; then
    grep -q non-free-firmware "$tmp/sl" \
        && ok "sources.list has non-free-firmware" \
        || bad "sources.list missing non-free-firmware"
else bad "could not read /etc/apt/sources.list"; fi

# ---- verdict ---------------------------------------------------------------
printf '\n'
if [ "$fail" -eq 0 ]; then green "GATE PASS — $pass checks"; exit 0
else red "GATE FAIL — $fail failed, $pass passed"; exit 1; fi
