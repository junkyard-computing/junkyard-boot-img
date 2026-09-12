# felix "0xcfcd UVLO" is a DECON/CMU_DISP hard-lockup, not a power event

**Status (2026-09-11):** root cause understood; runtime lockup FIXED; boot lockup STILL OPEN.
Track: mainline gs201/felix (this repo). Applies to the AOSP-GKI track only in that the
same `0xcfcd` reboot-reason string appears there too — but this document is about mainline.

## TL;DR

- The reboot reason **`0xcfcd - UVLO (IF-PMIC)`** that felix's bootloader prints is a
  **mislabel**. On mainline it is almost always a **kernel hard-lockup**, not a PMIC
  under-voltage. The bootloader prints "UVLO (IF-PMIC)" as its *default* reason whenever
  the kernel dies without setting a clean reboot reason. **Do not trust the reboot-reason.**
- The hard-lockup is a **CPU bus-stall on a DECON MMIO access whose CMU_DISP clock has
  idle-gated (Q-channel)**. The stalled CPU is stuck mid-`readl` with IRQs off, so it
  **does not answer the NMI** → the buddy watchdog panics ~10 s later.
- Two distinct manifestations, same root:
  1. **Runtime lockup** (~t130–210 s), triggered by the unclaimed inner panel's
     **DRM self-refresh** cycling (`exynos_crtc_atomic_check: plane-less update is detected`).
     **FIXED** by disabling self-refresh on the inner panel (kills the trigger).
  2. **Boot lockup** in `decon_reg_stop` (the DECON per-frame-stop `readl`), intermittent
     (~50% of boots). **STILL OPEN.** Not fixed by pKVM.

## How to recognise it

- Reboot-reason via `fastboot oem dmesg` shows `0xcfcd - UVLO (IF-PMIC)` **with
  `RST_STAT: 0x80 - SYSTEM_SWRESET_SYSTEM`** (a *software* reset). A real brownout shows
  `RST_STAT: 0xc0000 - PIN_RESET | PO_RESET`. The DSS block also shows all cores
  `(No Lockup)` and `linux debug info is not valid` because the cores lost time in a
  bus-stall, not a captured panic.
- On UART you see, live: `watchdog: CPUx: Watchdog detected hard LOCKUP on cpu y`, then
  `After 10 seconds, these CPUS still haven't responded to the NMI: y` (y is stuck below
  EL1 — the bus-stalled `readl`), then `Kernel panic - not syncing: Hard LOCKUP`.
- The wedged CPU varies (0/4/5/7). Modules loaded: panthor, edgetpu_gsa, gsa, trusty.

## Root cause

The DECON display-controller's register-access clocks live in **CMU_DISP**, which the
hardware **idle-gates via the Q-channel**. A DECON `readl` issued while that clock is
gated **stalls on the AXI bus forever** (the read transaction never completes; the CPU is
frozen inside the instruction with IRQs disabled → no NMI response → hard-lockup).

`clk/samsung` commit `d1ef1531` ("add CMU_DISP block to hold DECON clocks live") tries to
defeat this by exposing the CMU_DISP gates + the QCH `CLOCK_REQ` (bit 1) as
`CLK_IS_CRITICAL` with `auto_clock_gate=false`. **It reduces but does not eliminate** the
stalls — the block still idle-gates intermittently (~1 in many boots, and every
self-refresh cycle at runtime).

### Why d1ef1531 leaked — ROOT-CAUSED 2026-09-12

Two facts in the generic samsung clk code, which together defeat it:

1. **Global CMU auto mode overrides every per-register HWACG bit.** This is stated in
   `drivers/clk/samsung/clk-exynos-arm64.c` at the `CMU_OPT_GLOBAL_EN_AUTO_GATING` write:
   *"This overrides the individual HWACG bits in each of the individual gate, mux and qch
   registers."* So holding `CLOCK_REQ` has **no effect** while global auto mode is armed.
2. **`auto_clock_gate = false` does not disarm it — it only declines to arm it.** Nothing
   ever *clears* `CONTROLLER_OPTION`, so CMU_DISP keeps whatever the **bootloader** left
   there, and the bootloader leaves global auto mode **on**.

There is a partial escape hatch: with `!init_auto`, `exynos_arm64_init_clocks()` sets
`GATE_MANUAL` (bit 20) on each register in `clk_regs`, which the in-tree comment notes
*does* override global auto mode. But it is guarded by `is_gate_reg()`, i.e.
`GATE_OFF_START..GATE_OFF_END` = **0x2000–0x2fff** — and the gs201 CMU_DISP **QCH_CON
registers live at 0x3008–0x3020**, outside that window. So:

- the DECON **gate** bits (0x2010 `AD_APB_DECON_MAIN` PCLKM, 0x2014 `DPUB` ACLK_DECON) *were*
  genuinely held — which is why `d1ef1531` could read back a live 399 MHz DECON clock;
- the DECON **Q-channel** (0x300c `QCH_CON_DPUB_QCH`) was **never** taken out of auto mode,
  so the hardware idle-gated DPUB anyway.

That is the whole discrepancy between "the clock reads 399 MHz and the bits are held" and
"a late modeset still AXI-hangs". **A register read-back proving a bit is set is not proof
the hardware honours it** — an overriding mode elsewhere can make a held bit inert.

**Fix:** new `samsung_cmu_info.force_manual_clock_gate` flag, set for CMU_DISP. It (a)
*clears* `OPT_EN_AUTO_GATING` et al. in `CONTROLLER_OPTION` instead of merely not setting
them, and (b) extends the `GATE_MANUAL` override to the QCH window (new `is_qch_reg()`,
0x3000–0x3fff), gated on the flag so no other platform's QCH behaviour changes. It logs the
pre-existing `CONTROLLER_OPTION` value, which confirms what the bootloader left.

## The two triggers

### Runtime (FIXED)

The inner ana6707 panel is **command-mode and unclaimed** — no DRM/fbdev client modesets
it, so at t≈21 s the driver logs `no modeset claimed the panel 20000ms after handoff;
blanking it`. Because it's command-mode, `panel-samsung-drv.c` sets
`connector_state->self_refresh_aware = true`, so the generic **`drm_self_refresh_helper`**
cycles it: periodic **plane-less atomic commits** → DECON register access → CMU_DISP
idle-gate stall → hard-lockup at ~t130–210 s.

**Fix applied:** force `connector_state->self_refresh_aware = false` in
`panel-samsung-drv.c` (see `exynos_drm_connector_atomic_check`, the line
`connector_state->self_refresh_aware = !is_video_mode;`). With self-refresh off,
`plane-less update` count drops to **0** and the device runs clean through the entire
former hang window (validated to 300 s+). This is a **workaround** (it disables a
power-saving feature); the durable fix is to actually drive the inner panel with a DRM
client (fbdev), or to fully defeat the CMU_DISP idle-gate.

### Boot (root-caused 2026-09-12; fix built, awaiting hardware validation)

At boot, the bootloader hands DECON0 off running (`DECON_STATE_INIT`); the kernel stops it
before re-enabling. `decon_enable` → (INIT branch) `_decon_stop_locked` → `decon_reg_stop`
→ `decon_reg_stop_perframe_dsi` issues a `readl` on DECON regs **under `spin_lock_irqsave`
(IRQs off)**. Intermittently that `readl` hits the idle-gated block and hard-locks the CPU.
Pinned with instrumentation to exactly between markers **`DECONDBG D2 stop_locked (INIT)`**
and **`DECONDBG E pre _decon_enable_locked`**; with finer markers, to the
`decon_reg_set_win_enable` read-modify-write at the head of `_decon_reinit_locked`.

**Timing threshold (the key evidence).** A modeset at **t15–25 s completes**; one at
**t40–83 s stalls**. On UART there is no network, so kmscon waits on
`NetworkManager-wait-online` and the modeset always lands t40+ — which is why *UART* boots
hang near-deterministically while dongle boots are intermittent.

**What makes t40 different from t20 — and it is not elapsed time.** At t≈20 s the panel
handoff timer fires (`no modeset claimed the panel 20000ms after handoff; blanking it`) and
asserts the panel **reset** gpio. The inner ana6707 is a **command-mode** panel, so DECON0's
frame start is driven by the panel's **TE** signal. Killing the panel stops TE → DECON0
stops issuing frames → DECON0's `QACTIVE` to CMU_DISP deasserts → the DISP clock idle-gates
→ the next DECON SFR access bus-stalls. Before the blank, DECON0 is still streaming from
the bootloader handoff, holds QACTIVE high, and the clock cannot gate. That predicts
exactly the observed t15–25-OK / t40+-hang split.

**Confirmed 2026-09-12:** pushing `EXYNOS_PANEL_HANDOFF_TIMEOUT_MS` 20000 → 120000 made a
boot under the *exact* previously-hanging condition (USB, no network, modeset ~t40)
**complete** — userspace reached, USB gadget enumerated at t≈43 s. One boot, so not yet a
rate; but it is the first configuration that survived that condition at all.

Note this is *not* merely deferring the hang: once any modeset claims the panel,
`panel_state != PANEL_STATE_HANDOFF` and the blank never fires at all. It is still the
wrong fix (it makes correctness depend on boot finishing within the timeout, and leaves the
underlying clock bug live for every later modeset) — the real fix is the CMU_DISP
`force_manual_clock_gate` change above. **Status: fix built, not yet validated on hardware.**

### Ranking the two fixes

The clock fix is the one to keep. The handoff-timeout bump is a stopgap worth remembering
because it is a **one-line, zero-risk** way to get a bootable device while iterating on the
clock path.

## Ruled out (do not re-chase)

- **Charger / OTG-boost inrush / VSYS / S2MPG13 / cell-droop** — all chased for weeks
  against the `0xcfcd` reboot-reason. It's a mislabel; measured cell holds ~4.16–4.28 V,
  reset is `SYSTEM_SWRESET` (software). The OTG-boost soft-start fixes in HEAD may still be
  valid for a *separate* real OTG UVLO, but the residual "UVLO" is this hard-lockup.
- **pKVM (`kvm-arm.mode=protected`)** — hypothesis was that `nvhe` leaves BL31's CMU lock
  on so the d1ef1531 clock-hold is ineffective. **Tested and disproven:** under pKVM the
  boot `decon_reg_stop` hang still fires (first boot cleared it by luck; the very next
  reboot hung at the identical spot). pKVM also appears to break the edgetpu GSA firmware
  bring-up. Stay on `nvhe`.
- **TPU / pd_tpu genpd gating** — re-enabling `pd_tpu` (status=okay + edgetpu phandle)
  causes a *different* hard-lockup at the late_initcall reap; the DT deliberately keeps
  pd_tpu out of genpd. Unrelated to this bug.
- **DECON's own internal auto-CG (gate #1)** — `decon_reg_set_clkgate_mode(id, 0)`
  (`CLOCK_CON` AUTO_CG/QACTIVE). Called at `decon_probe`, at `decon_reg_stop`, and at the top
  of `_decon_reinit_locked`; the hang persists at the *identical* spot every time. It cannot
  work, and the reason is instructive: the `clkgate_mode` write is **posted**, so it returns
  and its marker prints, while the very next *read*-modify-write (`decon_reg_set_win_enable`)
  stalls. No DECON-side register write can fix a clock gated *externally* by CMU_DISP.
  Distinguish carefully: **gate #1** = DECON's internal auto-CG (ruled out), **gate #2** =
  the CMU_DISP block clock idle-gate (the actual cause).
- **Making the modeset earlier via the kernel cmdline** —
  `systemd.mask=NetworkManager-wait-online.service` appended to the boot cmdline. Tested
  2026-09-12: still hung, same `RST_STAT 0x80`. Masking the wait does not move the modeset
  early enough to beat the t20 panel blank.

## Diagnosis playbook (how this was found, how to reproduce)

- **Transport:** `uartd` on the host FTDI (`/dev/ttyUSB0 @ 115200`); felix AP-UART must be
  enabled first with `fastboot oem uart enable` (NB: `fastboot oem uart list` WEDGES the
  bootloader — never run it). `uart login --user kalm --password 0000`, then `uart run`.
- **Instrumented kernel:** add `DECONDBG` prints through `decon_enable` /
  `decon_reg_init` / `decon_disable` (and `UFSDBG` in the UFS err-handler). Build the
  built-in DRM (`DRM_SAMSUNG_FELIX=y`) — the driver is a `.ko` composite linked into
  vmlinux, so it rides `boot.img`; verify markers landed with **`grep -a` on `out/vmlinux`**
  (`strings` is NOT in the nix dev shell — it silently returns 0 and misleads you). The
  markers are `pr_info`/`decon_info` (level ≥ 4, so filtered by the cmdline `loglevel=4`);
  they still appear because the watchdog panic does `console_verbose()` +
  `console_flush_on_panic()` and dumps the ring buffer. To see them live, set
  `kernel.printk=8` early (a `/etc/sysctl.d` drop-in applies at ~t8, before the ~t20 decon).
- **Signature:** the last DECONDBG marker before the `Watchdog detected hard LOCKUP`
  pins the exact stalling sub-call.
- **Operational hazard:** repeated hangs decrement the A/B retry counter and the device
  **parks in fastboot** (retry-park safety) — on the UART rig that means it's unreachable
  (fastboot = USB) until the cable is moved and `fastboot set_active <slot>` resets it.
  Do **NOT** `pixel-bootctl mark-successful` on an untended, no-charge (UART) unit — that
  defeats the park and a hang-loop drains it to death. (Lost a unit to this once.)

## Next steps

1. **Validate `force_manual_clock_gate` on hardware.** Flash, boot on USB with no network
   (the reliably-hanging condition), and check the console/`dmesg` for
   `CONTROLLER_OPTION=0x…  -> forcing manual clock gating`. The logged value is itself the
   proof of what the bootloader left armed: if `OPT_EN_AUTO_GATING` (bit 28) is **set** in
   it, the leak explanation is confirmed outright.
2. **Soak it.** One boot proves nothing here — this bug is a coin flip and two clean boots
   have misled us before. Run ≥10 reboots.
3. **Durable runtime fix** — drive the inner panel with a DRM/fbdev client so it isn't
   left unclaimed, which removes the self-refresh churn *and* keeps DECON's QACTIVE
   asserted, addressing both triggers at the source. No `feature/mainline-fbcon-*` branch
   survives; rebuild per memory `project_fbcon_hangs_felix` (select `DRM_CLIENT_SELECTION`
   + `DRM_TTM_HELPER`, GEM `->vmap`, `DRM_FBDEV_TTM_DRIVER_OPS`, **deferred**
   `drm_client_setup()`, `cma=128M`, `.dirty = drm_atomic_helper_dirtyfb`).
4. Consider reverting `0aa178ed` ("hold VSYS in BUCK … [UNVALIDATED]") — written under the
   now-disproven power framing.

### Host-rig notes worth keeping

- **`lsusb` is not on this host's `$PATH`** (same class of trap as `strings` missing in the
  nix shell — it silently broke a boot-detection harness into never reporting success).
  Enumerate `/sys/bus/usb/devices/*/idVendor` instead.
- **Boot success can be classified with no console at all**, which matters because UART and
  USB are mutually exclusive and UART cannot charge: reboot from fastboot, then watch for
  USB gadget `18d1:d001` in sysfs (⇒ userspace reached) versus the device reappearing in
  fastboot (⇒ panic loop burned its A/B retries). This runs on USB, so the battery
  **charges** throughout — prefer it over UART for rate-measurement soaks.
- The gadget's host-side interface comes up but takes **no DHCP lease** (the phone's
  `dnsmasq` isn't serving on the mainline image), so there is no SSH over the gadget; the
  host side would need a static address. That is why a reboot soak still needs either a UART
  shell or manual intervention.

See also memory notes: `project_felix_uvlo_is_decon_hardlockup`,
`project_felix_decon_enable_boot_loop`, `project_pkvm_cmu_unlock`.
