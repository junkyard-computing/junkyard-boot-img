# gs-mfd

- **AOSP path**: `private/google-modules/soc/gs/drivers/mfd/`
- **Mainline counterpart**: NONE for s2mpgXX; partial for slg51000/slg51002
- **Status**: not-ported
- **Boot-relevance score**: 8/10

## What it does

MFD cores for the felix-family PMICs:
- `s2mpg10` / `s2mpg11` — gs101 (raven/oriole) main + sub PMICs
- `s2mpg12` / `s2mpg13` — **gs201 (pantah/felix) main + sub PMICs**
- `s2mpg14` / `s2mpg15` — Zuma main + sub PMICs
- `s2mpg1x-gpio*` / `s2mpg1415-gpio` — PMIC-as-GPIO expander
- `slg51000-core.c` / `slg51002-core.c` — Dialog SLG51002 secondary regulators (camera-domain power)

S2MPG1X talks over a Samsung-proprietary "Speedy" bus on gs101 (custom SoC hw block) and over **SPMI on gs201** (s2mpg12/13 PMICs). The driver reads regulator/power-meter/RTC subdevs and registers them with the kernel.

## Mainline equivalent

- `s2mpgXX`: no mainline driver. Mainline has `s2mpa01.c` / `s2mps11.c` for older Samsung PMICs but the s2mpg series is a different register layout entirely.
- `slg51000`: mainline has `drivers/regulator/slg51000-regulator.c` (regulator-only, no MFD core; it talks I2C directly).
- `slg51002`: no mainline driver.

## Differences vs AOSP / what's missing

Everything for s2mpg10/11/12/13/14/15 — MFD cores, IRQ controllers, GPIO expanders, the Speedy/SPMI register access plumbing. Mainline has no awareness of these PMICs at all. The slg51002 (used for camera LDOs on felix) is missing.

## Boot-relevance reasoning

**Score 8**: the s2mpg12/13 PMIC pair is the **main power source for gs201** — every CPU-cluster rail, every DRAM/MIF rail, USB/PCIe analog rails, UFS analog supplies (`vcc-supply`, `vccq-supply`, `vccq2-supply`) all originate at s2mpg12/13. Mainline currently can't change those rails — it inherits whatever voltages BL31 / s-eos handed off. That has two consequences for UFS:
1. Mainline's `ufs-exynos.c` won't get a useful regulator handle for VCC/VCCQ, so calls like `regulator_set_voltage()` / `regulator_set_load()` for power-mode-change become no-ops. Some PHY-init sequences expect to bump VCCQ briefly during HS gear change.
2. Without the s2mpg12 RTC subdriver mainline has no battery-backed RTC.

The PMIC is unlikely to be the root cause of HS-Rate-A/B wedge (we'd see broader instability if rails were under-volted), but it's plausibly contributing — and porting it is a prerequisite for any UFS-rail experiment. Score 8 reflects "boot-critical infrastructure, currently invisible to the kernel."
