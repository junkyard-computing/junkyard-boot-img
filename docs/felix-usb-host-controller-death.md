# felix: USB host controller dies after a SuperSpeed link drop

**Status (2026-09-25):** mechanism fully traced on mainline. The root trigger (the
SuperSpeed link dropping) is still open; **in-place recovery by re-initialising the host
controller works on a healthy controller and is under soak against real deaths.** Unit:
`34291FDHS000WV` (known-susceptible; see memory `project_felix_xhci_hc_died_under_load` —
`35071FDHS0017C` was immune on the same image under AOSP).

## What happens

A headless unit on the USB-Ethernet dongle loses its network and never gets it back.
It is **not** the Type-C port landing wrong: the TCPM reaches `sink + host` and holds it.
Captured sequence (kernel log with xHCI/hub dynamic debug, `PORTSC` decoded — link state
is bits 8:5, port-enabled bit 1):

| t | event |
|---|---|
| ~5 | r8152 dongle enumerates at SuperSpeed, `PORTSC 0x1203` (U0, enabled) |
| ~9 | `carrier on` — network up |
| **drop** | `PORTSC 0x4012c1`: **link → SS.Inactive**, port disabled. Seen at t10.6, t10.7, t169.8, t1044.7, ~t1140 — with no traffic load |
| drop + 0.1 s | hub: "Wait for inactive link disconnect detect" ×5, then **"do warm reset, full device"** (correct decision) |
| … | `usb_reset_device()` → r8152 pre-reset cancels URBs → xHCI **Stop Endpoint** |
| drop + ~5.1 s | **Stop Endpoint never completes** → `xHCI host not responding to stop endpoint command` → `HC died` |

After that the controller is gone until something re-initialises it. On mainline nothing
did: `usb-host-recover` looks for `dwc3_exynos_otg_id`, an AOSP-only sysfs node, and
restarts every 5 s forever.

## Established by experiment (do not re-chase)

- **The TCPM is not the cause.** Captured TCPM history shows `sink+host` reached at t3.6
  and held through the failure. (Every attach does include a PD hard reset that briefly
  flips the role to device — suspicious, unconnected to the death so far.)
- **A dead link is not why Stop Endpoint hangs.** With a port-only warm reset *first*
  (`usbcore.warm_reset_port_first`), the link genuinely retrained to U0 (`0x1203`) and
  stayed there — and Stop Endpoint still never completed. After an SS.Inactive event,
  stopping that device's endpoints hangs this controller regardless of link state.
- **The command ring cannot be aborted either.** Letting a Stop Endpoint timeout take the
  normal command-ring-abort path (`xhci_hcd.stop_ep_timeout_recover`): `Abort failed to stop
  command ring: -110`. The command engine is wedged; no command-level recovery exists.
- **That abort attempt is actively harmful.** It polls up to 5 s with the xHCI spinlock held
  and IRQs off; on top of the preceding wait that tripped the hard-lockup watchdog and
  **panicked the kernel** — worse than stock, which only loses the controller.

Both patches are kept, reverted, in `felix-usb-falsified-recovery-patches.diff`.

## What works: re-initialise the host controller

`usb-host-reinit` (userspace): unbind/bind the xHCI platform device `xhci-hcd.3.auto`.
Re-probing resets the controller (HCRST) and recreates both root hubs, without touching
dwc3 or the TCPM's USB role switch. On a healthy boot: same boot, dongle back at
SuperSpeed, **carrier in 6.2 s**, roles untouched.

Run it only **after** `HC died` (by then `xhci_hc_died()` has returned every URB and marked
the controller dying, so teardown issues no commands) — never while a Stop Endpoint is
pending. `usb-wedge-trace` does exactly that; `--safety` warm-reboots if the NIC does not
return, capped at 3 consecutive dying boots.

This is the fleet safety net either way. It is not a root-cause fix: the link still drops.

## Open

1. **Why the SuperSpeed link drops to SS.Inactive** — intermittent, no load, per-unit.
   Signal integrity / SS PHY (PMA) tuning is the lead (memory:
   `project_gs201_usb_pma_port`, `project_gs201_usb_ss_rxdetect_gap`).
2. Whether the PD hard reset during every attach matters.
3. Confirm `usb-host-reinit` on real deaths (soak running).
4. Kernel-side equivalent of the re-init (the xHCI code itself notes "try to recover a
   -ETIMEDOUT with a host controller reset").

## Instrumentation (how this was found — reuse it)

- **Kernel log, not tracing.** Enabling `CONFIG_FTRACE` changed `struct module`, every
  prebuilt module (incl. `dm_mod`) was rejected, and the initramfs could not assemble root
  (boot-loop to fastboot). Use cmdline-only instead:
  `log_buf_len=8M dyndbg="func handle_port_status +p; file xhci-hub.c +p; file hub.c +p"`.
- **TCPM history:** `tcpm.log_printk` (kernel commit `fae892dd`) mirrors the TCPM ring into
  the kernel log.
- **Evidence to `userdata`**, never the rootfs (100 % full): `usb-wedge-trace` (capture on
  Tx timeout / not responding / HC died), `tcpm-landing-guard` (per-boot census at 90 s —
  note it cannot see drops after 90 s), `usb-host-reinit` logs. Shared helpers in
  `/usr/local/lib/usb-evidence.sh`; functions use `local` (a clobbered loop variable once
  garbled the trigger counter).
- **The persistent journal stopped at 2026-09-24 22:12** because the rootfs is full; later
  boots are only recoverable from `pstore` (`/var/log/pstore/*console-ramoops*`), which is
  how the kernel-panic above was found.
- Soak driver: reboot via `sync; echo b > /proc/sysrq-trigger`, re-arm the A/B retry
  counter each cycle, and **stop and report** if the device does not come back.

## 2026-09-25: the link drops are driven by the DONGLE UNIT (kernel ruled out)

**Metric:** the USB3 root port's xHCI Link Error Count — `PORTLI` for port 2 at
`0x11210438` (`PORTSC` + 8), low 16 bits. Read with `busybox devmem 0x11210438 32`.
Every error forces a link recovery; the SS.Inactive drops are the recoveries that fail.
A healthy link sits near zero, so a 60 s sample scores a link in a minute instead of
waiting hours for a death.

**Controlled experiment** — same phone (`34291FDHS000WV`), same cable/passthrough; kernel
switched by A/B slot (slot B = the AOSP oracle's exact `boot`/`vendor_boot`/`dtbo`, copied
byte-for-byte, with its module tree added to the same rootfs); dongle swapped for another
unit of the same model (RTL8153A, `0bda:8153`):

| | original dongle `a0:ce:c8:76:24:06` | replacement `80:69:1a:b3:91:2c` |
|---|---|---|
| mainline 7.2 | 3.0 errors/s | 0.04 errors/s |
| AOSP 6.1 | 2.5 errors/s | 0.07 errors/s |

The dongle unit accounts for a ~40–70× difference; the kernel for none. Mainline's
SuperSpeed is as good as AOSP's. Earlier leads are superseded: "per-unit phone" (the
"immune unit" rested on one n=1 run) and "PHY/PMA mis-programming" (July diff: identical to
AOSP — and AOSP ships all 36 SS tune values as "default").

**Practical consequences:** screen dongles with a 1-minute `PORTLI` sample; record the rate
per boot for early warning; keep in-place recovery as the backstop. Open: can RX tuning
(equalisation, squelch/LFPS thresholds — register map in AOSP
`phy-exynos-usbdp-gen2-v4.c` `tune_each`) make the phone tolerate marginal dongles?
Keep the original dongle as the reproducer.

Side findings: `.139`'s rootfs was full because four stale 381 MB module trees had
accumulated (the build untars over `/lib/modules` and never deletes); removing them took it
from 100 % to 64 %. AOSP on this rootfs took ~7 min to boot vs 33 s for mainline.
