# gs201-arch

- **AOSP path**: `private/google-modules/soc/gs/` files/dirs ending in `gs201` (per-SoC tables, headers, dt-bindings)
- **Mainline counterpart**: scattered support across `drivers/clk/samsung/clk-gs101.c` (covers TOP/APM/DPU/HSI0/HSI2/PERIC0/PERIC1/MISC), `drivers/soc/samsung/exynos-pmu.c`, `drivers/pinctrl/samsung/pinctrl-exynos-arm64.c`, `drivers/phy/samsung/phy-gs101-ufs.c`, `drivers/ufs/host/ufs-exynos.c`, `arch/arm64/boot/dts/exynos/google/gs201.dtsi`
- **Status**: partially-ported
- **Boot-relevance score**: 10/10

## What it does

Tensor G2 (`gs201`) is the SoC inside the Pixel 7/7 Pro/Fold. The AOSP tree disperses gs201-specific data across many directories; key files:
- `drivers/clk/gs/clk-gs201.c` — SoC clock controller wrapper
- `drivers/pinctrl/gs/pinctrl-gs201.c` — pinmux SoC table
- `drivers/mfd/s2mpg1x-gpio-gs201.c` — PMIC GPIO bank table
- `drivers/soc/google/cal-if/gs201/` — entire CAL register/clock/PMU/ASV table set (cmucal-sfr.c, cmucal-vclklut.c, asv_gs201.c, flexpmu_cal_*.h, acpm_dvfs_gs201.h, etc.)
- `drivers/soc/google/debug/gs201-itmon.c` — interconnect monitor SoC table
- `drivers/pci/controller/dwc/pcie-exynos-gs201-rc-cal.c` — PCIe RC calibration
- `drivers/ufs/gs201/` — gs201-specific UFS host glue
- `include/dt-bindings/{clock,interrupt-controller,pinctrl,soc/google}/gs201*.h` — DT-binding constants

These files are what differentiate gs201 from gs101 inside the AOSP tree. gs201 is closely related to gs101 — same Cortex-X1/A78/A55 layout but new Mali GPU (Valhall/Mali-G710), different MIF/INT topology, different SysMMU revisions in some IPs, and notable for **PCIe + UFS sharing the HSI block** with subtle layout changes vs gs101.

## Mainline equivalent

Mainline has gs201 as a "lite" first-class SoC:
- DT: `arch/arm64/boot/dts/exynos/google/gs201.dtsi` is wired up but light — only ~40 unique compatible strings (vs ~200+ in AOSP `gs201/gs201.dtsi`).
- clk: `clk-gs101.c` extends into gs201 with TOP/APM/DPU/HSI0/HSI2/PERIC0/PERIC1/MISC. Critical absences: AOC, BUS0/1/2, CPUCL{0,1,2}, G3D, MIF, MFC, NOCL*, ISP, TPU.
- pinctrl: works, all 9 instances bound.
- PMU: `google,gs201-pmu` matches.
- watchdog: `google,gs201-wdt` matches (cl0 + cl1).
- UFS: `google,gs201-ufs` matches in `ufs-exynos.c`, with PWM-only working currently.
- PHY: `phy-gs101-ufs.c` covers `google,gs201-ufs-phy` (we have local patches enroute upstream — see [upstream-patches/](upstream-patches/)).
- chipid: works via `exynos-chipid.c`.

## Differences vs AOSP / what's missing

What mainline lacks that AOSP gs201 ships:
1. **CAL-IF / CMUCAL / PMUCAL / ACPM** — entire chip-abstraction subsystem for clocks/PM. Mainline replaced with standard CCF in `clk-gs101.c` but **only for a subset of CMUs**.
2. **Per-CMU coverage**: most non-peripheral CMUs not modelled in CCF (see [gs-clk.md](gs-clk.md)).
3. **Power domains**: `EXYNOS_PD_HSI0` (UFS+USB power island) — see [gs-soc.md](gs-soc.md).
4. **DVFS Manager + ACPM-DVFS**: no in-kernel DVFS; CPU/MIF/INT freqs frozen at bootloader handoff.
5. **PMIC stack**: s2mpg12/13 MFD + regulator + RTC + powermeter all absent.
6. **SPMI master**: no driver to talk to s2mpg PMICs even if they were ported.
7. **SysMMU v8/v9**: GPU/DPU/codec masters can't be brought up without these.
8. **ITMON** for bus-error diagnostics.
9. **SoC-specific quirks** in `ufs-exynos.c` (we have draft upstream patches for a few; none yet shipped to mainline).

## Boot-relevance reasoning

**Score 10**: gs201 *is* the platform we're booting. Every driver gap discussed in the other gs-* files compounds here. The most impactful gaps for current state:
- Missing **HSI2 CMU clock entries** → UFS clocks are fixed-clocks → HS gear can't be programmed correctly (very likely root cause).
- Missing **HSI0 PD driver** → UFS analog island sequencing left to BL31, possibly incomplete for HS PMC.
- Missing **PMIC + regulator** → can't tweak UFS rails for HS.
- Missing **ACPM** → MIF/INT can't follow UFS bandwidth requests.

This is the umbrella module-name; concretely, focus first on porting the gs201 HSI2 entries in `clk-gs101.c` (or, ideally, splitting gs201 into its own `clk-gs201.c`) so `ufs_aclk` becomes a real CCF clock with reprogrammable dividers. That alone will likely change UFS HS behavior. See [gs-clk.md](gs-clk.md), [gs-soc.md](gs-soc.md).
