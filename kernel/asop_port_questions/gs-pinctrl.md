# gs-pinctrl

- **AOSP path**: `private/google-modules/soc/gs/drivers/pinctrl/gs/`
- **Mainline counterpart**: [`drivers/pinctrl/samsung/`](kernel/source/drivers/pinctrl/samsung/) (`pinctrl-samsung.c`, `pinctrl-exynos.c`, `pinctrl-exynos-arm64.c`)
- **Status**: ported
- **Boot-relevance score**: 7/10

## What it does

Vendored copy of the standard Samsung Exynos pinctrl framework with a `pinctrl-gs201.c` SoC table and a `pinctrl-gs.c` glue layer. Drives every GPIO bank (`gpa0`..`gpp29`...) plus EINT controllers across the SoC. Compatible: `samsung,gs101-pinctrl`. Also ships SLG51000/SLG51002 pinctrl drivers (`pinctrl-slg51000.c` / `-slg51002.c`) for PMIC-side GPIOs.

## Mainline equivalent

Mainline has full `samsung,gs101-pinctrl` and `samsung,gs201-pinctrl` (oh wait, mainline uses `google,gs201-pinctrl` — see below) support in `pinctrl-exynos-arm64.c` with the gs101 / gs201 SoC tables. Mainline gs201.dtsi wires nine pinctrl instances (`google,gs201-pinctrl`) successfully — that's what we're booting on, that's what gives us UART pinmux, USB pinmux, etc. SLG51000/SLG51002 pinctrl is not in mainline.

## Differences vs AOSP / what's missing

For SoC pinctrl: nothing material. Mainline's bank tables are complete enough to bring up the platform (UART, ethernet/USB pinmux all work). Spot-check shows the mainline tables match AOSP's bank layouts. PMIC-side pinctrl (slg51000/slg51002) is missing; these are camera-rail GPIO expanders that don't matter for boot.

## Boot-relevance reasoning

**Score 7**: pinctrl is boot-critical (you can't talk UART/USB/ethernet without pinmux), but mainline already has it. Worth scoring high because if it had been missing we'd be dead in the water. UFS pin muxing (`ufs_rst_n`, `ufs_refclk_out`) is also handled by the same pinctrl driver — we know it works because the bus enumerates at PWM-G1. So pinctrl is not implicated in the HS-Rate wedge. Nothing to port.
