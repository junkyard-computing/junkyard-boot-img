#!/bin/bash
# Mirror UART to terminal and save a timestamped copy to uart-logs/.
# Annotates known boot stages inline (in color, on stderr so the log file
# stays clean) using markers learned from prior felix boots.
#
# Usage:
#   ./capture-uart.sh                       # /dev/ttyUSB0 @ 115200 8N1
#   ./capture-uart.sh /dev/ttyUSB1 921600   # custom port/baud
#
# Ctrl-C stops capture cleanly.

set -euo pipefail

PORT="${1:-/dev/ttyUSB0}"
BAUD="${2:-115200}"
LOG_DIR="${LOG_DIR:-uart-logs}"

[ -e "$PORT" ] || { echo "Error: $PORT does not exist" >&2; exit 1; }

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H%M%S).log"

# 8N1 raw, no flow control, no echo, deliver each byte immediately.
sudo stty -F "$PORT" "$BAUD" cs8 -cstopb -parenb \
    -icanon -echo -echoe -echok -echoctl -echoke \
    -ixon -ixoff -crtscts \
    min 1 time 0

echo "Capturing $PORT @ ${BAUD} 8N1"
echo "Log:    $LOG_FILE"
echo "Stop:   Ctrl-C"
echo "----"

# The annotator: reads the live stream and prints colored stage banners
# to stderr (so they appear on the terminal but never enter the log file).
annotate() {
    awk '
        function banner(label,    bar) {
            bar = "============================================================"
            printf("\n\033[1;36m%s\n>>> %s\n%s\033[0m\n", bar, label, bar)
            fflush()
        }
        function ok(label) {
            printf("\033[1;32m✓ %s\033[0m\n", label); fflush()
        }
        function bad(label) {
            printf("\033[1;31m✗ %s\033[0m\n", label); fflush()
        }
        {
            # Standard 2-arg match: sets RSTART/RLENGTH on the whole pattern.
            # Strip "B_VCELL(" (8 chars) and the trailing ")" (1 char) to get
            # the digits.  Works on mawk + gawk.
            if (match($0, /B_VCELL\([0-9]+\)/)) {
                v = substr($0, RSTART + 8, RLENGTH - 9)
                printf("\033[1;33m⚡ battery: %s mV\033[0m\n", v); fflush()
            }
            if      (/dmc Done/)                               banner("DRAM training complete")
            else if (/BL31 early platform setup/)              banner("BL31 (EL3) starting")
            else if (/trusty_init done/)                       banner("Trusty/TEE up")
            else if (/welcome to lk\/MP/)                      banner("LK bootloader running")
            else if (/\[GS\] acpm locks regulators/)           banner("ACPM up, regulators locked")
            else if (/UFS device found/)                       ok("BL: UFS controller sees device")
            else if (/KIOXIA THGJFGT1E45BAIPB/)                ok("BL: UFS read succeeded")
            else if (/UFS\] shutdown complete/)                banner("BL handing off (UFS dropped)")
            else if (/Starting Linux kernel/)                  banner("Handoff to Linux kernel")
            else if (/Booting Linux on physical CPU/)          banner("Kernel running")
            else if (/Protected hVHE mode/)                    ok("pKVM up (CMU access unlocked)")
            else if (/Unpacking initramfs/)                    banner("Unpacking initramfs")
            else if (/scsi host0: ufshcd/)                     banner("UFS driver probing")
            else if (/link startup succeeded/)                 ok("UFS link startup succeeded")
            else if (/link startup failed/)                    bad("UFS link startup failed")
            else if (/NOP OUT failed/)                         bad("UFS NOP OUT failed (device unresponsive)")
            else if (/Invalid device management cmd response/) {
                if (!nopout_seen++) bad("UFS: invalid cmd response (NOP OUT round starting)")
            }
            else if (/Direct-Access *KIOXIA/)                  ok("SCSI sees KIOXIA UFS LUN! (rootfs reachable)")
            else if (/EXT4-fs.*mounted filesystem/)            ok("ext4 rootfs mounted")
            else if (/dracut-cmdline-ask/) {
                if (!dracut_seen++) banner("dracut initramfs running")
            }
            else if (/systemd\[1\]: System time advanced/)     ok("systemd up in initrd")
            else if (/Reached target initrd-switch-root/)      banner("switching from initrd to real root")
            else if (/login:/)                                 ok("Reached login prompt!")
            else if (/Synchronous External Abort/)             bad("Sync external abort (BL31 firewall trip?)")
            else if (/Unable to handle kernel paging request/) bad("Kernel oops")
            else if (/Kernel panic/)                           bad("Kernel panic")
            else if (/SError Interrupt/)                       bad("SError (firewall/abort)")
        }
    '
}

# Pipeline:
#   cat                  raw bytes from the port (immediate)
#   tee LOG_FILE         clean copy to disk
#   tee >(annotate >&2)  fork annotator that emits banners to stderr;
#                         tee's stdout goes to /dev/null since we already
#                         showed the line via the previous tee.
#
# Wait — with that layout the user wouldn't see the raw stream. Instead:
#
#   cat | tee LOG_FILE | tee >(annotate >&2)
#
# The final tee writes its stdin to: stdout (the terminal) AND the
# annotate process's stdin. annotate writes only to stderr (also the
# terminal). So the user sees the raw stream interleaved with banners.
exec sudo stdbuf -o0 cat "$PORT" \
   | stdbuf -o0 tee "$LOG_FILE" \
   | stdbuf -o0 tee >(annotate >&2)
