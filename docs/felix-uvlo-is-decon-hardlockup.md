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
self-refresh cycle at runtime). The residual leak is not yet root-caused (candidates: a
clock DECON touches that is not in the held set; or a HW Q-channel race the gate-hold
can't fully win).

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

### Boot (OPEN)

At boot, the bootloader hands DECON0 off running (`DECON_STATE_INIT`); the kernel stops it
before re-enabling. `decon_enable` → (INIT branch) `_decon_stop_locked` → `decon_reg_stop`
→ `decon_reg_stop_perframe_dsi` issues a `readl` on DECON regs **under `spin_lock_irqsave`
(IRQs off)**. Intermittently that `readl` hits the idle-gated block and hard-locks the CPU.
Pinned with instrumentation to exactly between markers **`DECONDBG D2 stop_locked (INIT)`**
and **`DECONDBG E pre _decon_enable_locked`** (i.e. inside `_decon_stop_locked` /
`decon_reg_stop`). **Not yet fixed.**

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

1. **Fix the boot `decon_reg_stop` hang** — instrument `decon_reg_stop_perframe_dsi` to
   pin the exact register, then either force+read-back the CMU_DISP clock immediately
   before the access, or skip the per-frame stop in the INIT branch (bootloader frame
   state is unknown anyway), or root-cause the d1ef1531 leak.
2. **Durable runtime fix** — drive the inner panel with a DRM/fbdev client so it isn't
   left unclaimed (branch `feature/mainline-fbcon-*`), which removes the self-refresh churn
   without disabling the power-saving feature.
3. Once both hold, re-run the multi-reboot soak to validate (the soak harness lives in the
   session scratchpad: `rbsoak.sh`).

See also memory notes: `project_felix_uvlo_is_decon_hardlockup`,
`project_felix_decon_enable_boot_loop`, `project_pkvm_cmu_unlock`.
