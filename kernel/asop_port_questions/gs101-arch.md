# gs101-arch

- **AOSP path**: `private/google-modules/soc/gs/` files/dirs ending in `gs101` (per-SoC tables, headers, dt-bindings)
- **Mainline counterpart**: [`drivers/clk/samsung/clk-gs101.c`](kernel/source/drivers/clk/samsung/clk-gs101.c), [`drivers/soc/samsung/gs101-pmu.c`](kernel/source/drivers/soc/samsung/gs101-pmu.c), [`drivers/pinctrl/samsung/pinctrl-exynos-arm64.c`](kernel/source/drivers/pinctrl/samsung/pinctrl-exynos-arm64.c), [`arch/arm64/boot/dts/exynos/google/gs101.dtsi`](kernel/source/arch/arm64/boot/dts/exynos/google/gs101.dtsi)
- **Status**: partially-ported
- **Boot-relevance score**: 5/10

## What it does

Tensor G1 (`gs101`) is the SoC inside the Pixel 6/6 Pro (raven, oriole). Felix is **gs201**, not gs101 — so gs101 support only matters here as the parent codebase from which gs201 deltas are derived. The AOSP gs101 files are the analogues of gs201 ones: per-SoC clock table, pinctrl table, CAL-IF data (cal-if/gs101/), PMIC GPIO bank, ITMON, PCIe RC calibration, dt-bindings headers (`gs101.h` for clocks, interrupts, pinctrl, devfreq, tmu, bcl, dm, pm-qos).

## Mainline equivalent

gs101 is the **best-supported Tensor SoC in mainline**:
- DT: `gs101.dtsi` + `gs101-oriole.dts` + `gs101-raven.dts` + `gs101-pixel-common.dtsi` + `gs101-pinctrl.dtsi` all present.
- clk: `clk-gs101.c` covers all the CMU domains gs101 needs.
- pinctrl: full coverage.
- PMU: `gs101-pmu.c` glue.
- UFS: `google,gs101-ufs` matched, with `phy-gs101-ufs.c`.
- USB, watchdog, MCT, etc. all work.

The pixel 6/6 Pro have demonstrably booted mainline (see Linaro/postmarketOS work, Will McVicker's tree). **Felix piggybacks on this work** for everything gs101 and gs201 share.

## Differences vs AOSP / what's missing

Same general gap pattern as gs201: ACPM, DVFS Manager, S2MPU, SysMMU v8/v9, gsa, debug-snapshot — none of those subsystems are in mainline. But the difference between gs101 and gs201 in mainline is that gs101 is more thoroughly de-risked: more devices boot, more bugs found and fixed.

## Boot-relevance reasoning

**Score 5**: gs101 is not the SoC in felix, so gs101-specific code paths don't run on our hardware. The score reflects "indirectly important" — every patch that lands for gs101 in mainline is one we benefit from because gs201 inherits or extends those patterns. Concretely, when we want to bring up a missing gs201 CMU domain or PD, the gs101 mainline implementation is the template. Watch gs101 mainline activity as a leading indicator for gs201 features that will be easy to extend. Direct UFS impact: zero, unless a gs101 UFS PHY patch exposes a quirk also relevant to gs201 (which our [upstream-patches/](upstream-patches/) tree already tracks).
