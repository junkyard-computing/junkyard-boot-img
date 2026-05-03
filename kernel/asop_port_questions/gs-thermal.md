# thermal

- **AOSP path**: `private/google-modules/soc/gs/drivers/thermal/{google,samsung}/`
- **Mainline counterpart**: `drivers/thermal/samsung/exynos_tmu.c` (TMU only; no gs-specific cooling)
- **Status**: partially-ported (mainline TMU is generation-mismatched; cooling devices not ported)
- **Boot-relevance score**: 6/10

## What it does

Three layers:
- `samsung/gs_tmu_v3.c` (+ `exynos_acpm_tmu.c`) — **TMU v3** (Thermal Management Unit) driver for gs101/gs201/zuma. Reads SoC die-temperature sensors via the ACPM IPC plug-in (so it doesn't have to poll the registers from EL1 — the ACPM coprocessor handles the polling and the kernel queries via IPC). Registers thermal zones with multiple trip points; integrates with cpufreq cooling, GPU cooling, ISP cooling.
- `samsung/exynos_cpu_cooling.c` + `samsung/gpu_cooling.c` + `samsung/isp_cooling.c` — cooling devices that knob CPU/GPU/ISP frequencies via cpufreq/devfreq.
- `google/gs101_spmic_thermal.c`, `google/s2mpg13_spmic_thermal.c`, `google/s2mpg15_spmic_thermal.c` — PMIC-attached NTC thermistor drivers (skin temperature, board temperature) reading PMIC ADC channels.
- `google/sts4x_ambient_i2c.c` — Sensirion STS4x ambient temperature sensor over I2C.
- `google/cdev_uclamp.c` — cooling device that places per-cluster scheduler uclamp.max for thermal mitigation.

## Mainline equivalent

- TMU: `drivers/thermal/samsung/exynos_tmu.c` covers Exynos3/4/5/7. gs101/gs201 use TMU v3 which is **register-incompatible with the older TMU**. Plus the AOSP path goes through ACPM IPC, not direct register access — fundamentally different.
- CPU cooling: generic `drivers/thermal/cpufreq_cooling.c` — would work if cpufreq were present (it isn't).
- GPU/ISP cooling: not in mainline.
- s2mpg13/15 SPMIC thermal: not in mainline (PMIC absent).
- STS4x: there's an upstream `drivers/iio/temperature/sts4x.c` (different subsystem; thermal vs IIO).

## Differences vs AOSP / what's missing

Everything. **No thermal sensing on mainline today.** SoC could overheat without any throttling response. felix's stock TMU trip points (around ~95C critical, ~70C passive) are not enforced — kernel will not shut down on overheat.

## Boot-relevance reasoning

6/10. Boot succeeds. **But this is a real safety/hardware-protection concern**: under load, the gs201 application processors will hit Tj > 95C and the kernel has no way to know or react. There's no thermal-driven CPU/GPU throttling, no critical-temperature shutdown. For sustained workloads this could damage hardware. Score 6 because it's not strictly a boot issue but is a real liability for any non-idle use, and the user is a kernel hacker who will run sustained builds on this device.

