# gs-soc

- **AOSP path**: `private/google-modules/soc/gs/drivers/soc/google/`
- **Mainline counterpart**: partial (`drivers/soc/samsung/exynos-pmu.c` covers PMU only; `drivers/soc/samsung/exynos-chipid.c` covers chipid; nothing else)
- **Status**: not-ported (most subsystems)
- **Boot-relevance score**: 2/10 for boot; 8/10 for the USB gadget bring-up task (D2 verification 2026-05-02 confirmed `EXYNOS_PD_HSI0` is a **USB power-island driver**, not a UFS one; with UFS HS now fixed the relevance shifts to USB)

## What it does

This is the biggest, most load-bearing collection in the AOSP tree. Subsystems include:

- **`acpm/`** — Always-On Power Management Controller IPC. The ACPM is a tiny coprocessor inside the SoC that owns DVFS, deep-sleep, and a bunch of I2C-over-mailbox transactions for the PMIC. Files: `acpm.c`, `acpm_ipc.c`, `acpm_flexpmu_dbg.c`, `acpm_mfd.c`, `acpm_mbox_test.c`, `power_stats.c`, plus `fw_header/` firmware blobs.
- **`cal-if/`** — Chip Abstraction Layer Interface. Per-SoC tables for the CMU (clock-management unit), PMU calibration (`pmucal_*`), VCLK/QCH descriptions. ~50 files, half of them per-SoC tables (`gs101/`, `gs201/`, `zuma/`).
- **`debug/`** — debug-snapshot, ETM/coresight, ITMON (interconnect monitor) per-SoC, exynos-adv-tracer, EHLD (early hardlockup detector), SJTAG.
- **`gsa/`** — Google Security Architecture (the in-package security island).
- **`s2mpu/`** — Stage-2 IOMMU/firewall for protecting peripheral DMA.
- **`pkvm-s2mpu/`** — pKVM-controlled S2MPU.
- **`exynos-cpupm.c` / `exynos-cpuhp.c`** — CPU power management + hotplug.
- **`exynos-pd*.c`** — power-domain drivers (`EXYNOS_PD`, `EXYNOS_PD_HSI0`, `EXYNOS_PD_EL3`).
- **`exynos-pm*.c`** — system suspend/resume.
- **`exynos-bcm_dbg*.c`** — bus performance counter debug.
- **`exynos_pm_qos.c`** — vendor PM-QoS framework.
- **`exynos-dm.c`** — DVFS Manager.
- **`gs-chipid.c`** — chip ID + lot ID + ASV (adaptive supply voltage) bin readout.
- **`exynos-seclog.c`** — secure-world log relay.
- **`pixel_stat/`, `vh/`, `pa_kill/`, `kernel-top.c`** — Android-only stats/vendor hooks/OOM kill helpers; not relevant.
- **`eh/`** — Emerald Hill HW compressor.
- **`gnssif_spi/`, `modemctl/`** — GNSS / modem control.
- **`gcma/`** — guaranteed CMA region manager.
- **`hardlockup-watchdog.c`** — soft hardlockup detector.
- **`exynos-pd_hsi0.c`** — **specific HSI0 (USB / UFS) power-domain manager**.

## Mainline equivalent

- chipid: `drivers/soc/samsung/exynos-chipid.c` — ported.
- PMU: `drivers/soc/samsung/exynos-pmu.c` — `google,gs101-pmu` + `google,gs201-pmu` matched, ported.
- ACPM: NONE. Mainline has no ACPM IPC driver. There's a stub `samsung,gs201-acpm-ipc` compatible referenced in gs201.dtsi but no real driver.
- cal-if / cmucal / pmucal: NONE; mainline replaced this entirely with the standard CCF in `drivers/clk/samsung/`.
- debug-snapshot, ITMON, ETM: NONE.
- gsa, s2mpu, pkvm-s2mpu: NONE.
- power domains (`EXYNOS_PD*`): NONE for gs101/gs201 (mainline has older Exynos PD via PMU).
- exynos-cpupm / exynos-dm / exynos_pm_qos: NONE; replaced by generic genpd / cpuidle / pm_qos in mainline.
- All Android vendor/hooks/stats: not applicable.

## Differences vs AOSP / what's missing

Most of this directory. The handful that are ported (chipid, PMU) are the easy ones. The big functional gaps for boot:
- **ACPM IPC driver**: gs201.dtsi declares `google,gs201-acpm-ipc` and exposes ACPM-managed clocks via `dt-bindings/clock/google,gs201-acpm.h`, but with no driver bound those clocks are dead. CPU-cluster freq, MIF freq, INT freq, GPU freq all live behind ACPM in the AOSP design. Mainline currently scales nothing.
- **EXYNOS_PD_HSI0**: a dedicated power-domain driver for the HSI0 island that contains UFS+USB. Manages UFS LDO power-on sequencing. Without it, mainline relies on whatever PD state BL31 left HSI0 in. That can absolutely affect UFS analog: incomplete sequencing of `LDO11`/`LDO12` (UFS analog) is a classic source of "PWM works but HS doesn't because the PHY analog isn't fully settled" bugs.
- **debug-snapshot / ITMON**: not boot-blocking but you'd love to have them for diagnosing UFS bus errors.
- **GSA / S2MPU**: needed before any peripheral that the bootloader marked as protected can talk over the bus.

## Boot-relevance reasoning

**Score 2** (downgraded from 9 → 5 → 2).

Two ruling-outs in sequence:

- **C1+C2 (2026-05-02) ruled out the clk-rate hypothesis.** See [gs-clk.md](gs-clk.md). MIF/INT being at any particular rate doesn't change the HSI2 CMU dividers we measured directly, and those rates are correct.

- **D2 (2026-05-02) ruled out `EXYNOS_PD_HSI0`** for UFS-on-felix specifically. Verification before porting: AOSP's own `private/devices/google/gs201/dts/gs201-ufs.dtsi` uses `vcc-supply = <&ufs_fixed_vcc>` (a `regulator-fixed` driven by `gpp0 1` GPIO) — **identical to our mainline dtsi**. AOSP doesn't tie UFS to `pd_hsi0` either. No `vccq`, `vccq2`, or PMIC rails referenced anywhere in felix's DT. Inspecting `exynos-pd_hsi0.c`: it manages `vdd_hsi/vdd30/vdd18/vdd085` (USB PHY supplies) and calls `eusb_repeater_update_usb_state()`. It's a **USB regulator driver**; the "HSI0" naming refers to the HSI0 power island, which on felix contains USB only (UFS lives in HSI2). Porting it would do nothing for UFS.

What's left in this directory that's still potentially useful (but lower-relevance):

- **ACPM IPC**: load-bearing for devfreq/thermal-aware DVFS once UFS HS works, but not implicated in the boot-time HS wedge.
- **debug-snapshot, ITMON**: would help diagnose bus errors if we hit any, but our wedge has no bus-error signature.
- **GSA / S2MPU**: needed before any peripheral marked protected by the bootloader can talk over the bus.

None was on the path to fixing the dl_err 0x80000002 wedge (now resolved by
patches 0010 + 0011 in the UFS path; see [gs-ufs.md](gs-ufs.md)).

**For the USB gadget bring-up task**: `exynos-pd_hsi0.c` is suddenly
relevant. The HSI0 power island contains the USB31DRD controller, the
USB31DRD PHY, the eUSB2 PHY + repeater, and their associated rails
(`vdd_hsi/vdd30/vdd18/vdd085`). On mainline today we route all 8 USB
supplies through a single `reg_placeholder` fixed-1V8 stub and rely on the
bootloader to have left HSI0 in a usable PD state. That has been enough to
get HS chirp + line-state events firing, but it does **not** sequence the
PHY rails through the AOSP-style power-stable handshake — and given that
our open Phase A blocker is "PHY analog edges work but HS RX path is dead",
porting `exynos-pd_hsi0.c` (or at least its PHY-rail sequencing semantics)
is now a credible suspect line of investigation. Score 8/10 for that task.
