# cpufreq

- **AOSP path**: `private/google-modules/soc/gs/drivers/cpufreq/`
- **Mainline counterpart**: **NONE** (closest match: `drivers/cpufreq/cpufreq-dt.c` generic OPP-based driver)
- **Status**: not-ported
- **Boot-relevance score**: 6/10

## What it does

`exynos-acme.c` — "A Cpufreq that Meets Every chipset". Single-file Samsung CPUFreq driver (~tens of KLOC across the family) covering every gs/exynos chipset. Builds per-cluster freq domains from DT, walks the **CAL framework** (`cal-if`) for per-rate voltage tables, integrates with ECT (Exynos Common Table) parser for thermal throttle tables, registers cooling devices, and exposes per-domain governors. **Critically depends on ACPM IPC** (`acpm_dvfs.h`) to actually write voltages to the PMIC — every freq change is a round-trip to the ACPM coprocessor.

## Mainline equivalent

There is no `cpufreq-exynos-gs.c` in mainline. The generic `cpufreq-dt.c` driver can drive gs101 if (a) DT lists `operating-points-v2`, (b) the regulator framework can change CPU rail voltage. (b) requires PMIC access via ACPM-I2C which is not in mainline (see `gs-i2c.md`).

## Differences vs AOSP / what's missing

Everything. The AOSP driver is a vendor-specific implementation; nothing of equivalent functionality is in mainline. Without it the CPU runs at the boot frequency (whatever BL31 left in the CMU) — fixed-rate, no DVFS.

## Boot-relevance reasoning

6/10. Boot succeeds without it (we run at fixed rate). However, the impact is performance-limiting: locked-in clocks waste battery if too high or wedge if too low. **More importantly, related to the pKVM CMU-unlock requirement** (see `project_pkvm_cmu_unlock.md`): if EL2 is not running pKVM, any CMU read aborts; if a future cpufreq driver tries to readl the CMU rate registers without pKVM enabled, we'd panic. So the *interaction* between cpufreq and our boot path is something to be aware of. Score 6 because (a) thermal management eventually requires DVFS to throttle (we don't have that), (b) CPU stuck at a single rate is a real-world stability/performance limit even if not a hard boot blocker.

