# gs-pwm

- **AOSP path**: `private/google-modules/soc/gs/drivers/pwm/`
- **Mainline counterpart**: [`drivers/pwm/pwm-samsung.c`](kernel/source/drivers/pwm/pwm-samsung.c)
- **Status**: ported
- **Boot-relevance score**: 2/10

## What it does

`pwm-exynos.c` (`PWM_EXYNOS`, builds `pwm-samsung.ko`) — vendored fork of the standard Samsung PWM-Timer driver for the SoC's PWM block, used for haptics, backlight, and fan control. Single file, ~600 lines.

## Mainline equivalent

Mainline `drivers/pwm/pwm-samsung.c` is the upstream of the same driver. It supports the Samsung S3C/Exynos PWM Timer including newer Exynos generations. The downstream version mostly tracks upstream with a few minor downstream additions (typically clock-handling tweaks).

## Differences vs AOSP / what's missing

Trivial diffs at most. No functional gap relevant to felix.

## Boot-relevance reasoning

**Score 2**: PWM is consumed by haptic feedback, display backlight, optionally fan control. None of which apply to our boot path (no display brought up; haptics not used). Zero relevance to UFS.
