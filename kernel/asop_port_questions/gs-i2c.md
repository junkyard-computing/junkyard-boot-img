# i2c

- **AOSP path**: `private/google-modules/soc/gs/drivers/i2c/busses/`
- **Mainline counterpart**: `drivers/i2c/busses/i2c-exynos5.c` (+ no mainline equivalent for `i2c-acpm.c`)
- **Status**: partially-ported
- **Boot-relevance score**: 5/10

## What it does

Two drivers. (1) `i2c-exynos5.c` — the standard HSI2C controller driver for every I2C bus on gs101/gs201/zuma, supporting Auto and Manual modes, fast/fast-plus/HS speeds, FIFO/DMA, and Exynos CPU-PM hooks for clock/idle integration. (2) `i2c-acpm.c` — a virtual I2C adapter that proxies transfers through the ACPM (Active Power Management Controller) IPC channel; this is how the kernel reaches the **MAIN/SUB PMICs (s2mpg10/s2mpg12/s2mpg14)** which are wired to a private I2C bus only the ACPM coprocessor can drive. PMIC access is required for regulator control, RTC, ODPM, and PMIC-based thermal/key drivers.

## Mainline equivalent

Mainline `drivers/i2c/busses/i2c-exynos5.c` (1052 lines vs AOSP 1548) covers the standard HSI2C controller. There is **no mainline equivalent** for `i2c-acpm.c` — ACPM IPC itself is in-tree neither (no `soc/google/acpm` driver landed in mainline as of this kernel). Some ACPM-equivalent functionality on other Exynos SoCs goes through `samsung-sci` mailbox + `acpm-pmic-bus` patches that have not been merged.

## Differences vs AOSP / what's missing

`i2c-exynos5.c`:
- AOSP version is +496 lines: extra is mostly debug/error-recovery (`recover_gpio_pins`, "I2C runaway" detection, transfer logging via logbuffer), CPU-PM idle-IP integration via `<soc/google/exynos-cpupm.h>` (suppress idle while a transfer is in flight), and per-controller throttling glue. None of this is required for I2C transfers to function.
- Standard transfer / mode register programming is the same families of bits — mainline would just lack diagnostic hooks.

`i2c-acpm.c`:
- **Entirely absent from mainline.** Without it, the kernel cannot speak to the gs201 MAIN/SUB PMIC pair, which means no regulator framework consumers, no PMIC RTC, no PMIC IIO power monitor (ODPM), no PMIC keys, no PMIC thermal sensors. We currently boot without any of this because nothing the rootfs cares about needs it (storage runs on UFS regulators that come up at SoC reset, USB-PD over Tcpm is offline, audio is offline).

## Boot-relevance reasoning

5/10. Standard HSI2C is already in mainline and works for any I2C device wired to a normal bus. The ACPM-I2C path is only needed once we want PMIC-controlled rails on/off (display, camera, modem, audio, fingerprint sensor) — none of which are required to reach a kmscon login. Missing this is a wall for every post-boot peripheral, but not a boot blocker. Bumping to 5 instead of 4 because `i2c-acpm.c` is a hard gate for any future work that wants to touch PMIC-managed rails (e.g. enabling the panel, the haptics regulator, the camera 1.05V).

