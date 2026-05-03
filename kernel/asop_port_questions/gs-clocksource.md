# gs-clocksource

- **AOSP path**: `private/google-modules/soc/gs/drivers/clocksource/`
- **Mainline counterpart**: [`drivers/clocksource/exynos_mct.c`](kernel/source/drivers/clocksource/exynos_mct.c)
- **Status**: ported (v1/v2 MCT); not-ported (v3 MCT)
- **Boot-relevance score**: 4/10

## What it does

Two drivers:
- `exynos_mct.c` (`CLKSRC_EXYNOS_MCT_GS`) — vendored Exynos Multi-Core Timer for gs101/gs201 (matches `samsung,exynos4210-mct`).
- `exynos_mct_v3.c` + `exynos_mct_v3.h` (`CLKSRC_EXYNOS_MCT_V3_GS`) — newer MCT v3 used by Zuma and later.

These provide the per-CPU clockevent + global clocksource that the scheduler needs.

## Mainline equivalent

Mainline `drivers/clocksource/exynos_mct.c` is well-supported, matches `samsung,exynos4210-mct`, and is what gs101.dtsi/gs201.dtsi reference (`compatible = "samsung,exynos4210-mct"`). v3 MCT has no mainline driver, but felix is gs201 → v1/v2 MCT, so we don't need v3.

## Differences vs AOSP / what's missing

For gs201 felix specifically, nothing material — the AOSP fork has minor downstream tweaks (debug counters, ETM hooks) but the core clockevent path is identical. We're already booting on the mainline driver.

## Boot-relevance reasoning

**Score 4**: clocksource is essential infrastructure but mainline already has it working for gs201. Score reflects "if it broke we couldn't boot at all" — so the *category* is critical, but our mainline coverage is fine, so there is nothing to port. No relation to UFS HS wedge (that's a UNIPRO PHY problem, not a kernel timekeeping problem).
