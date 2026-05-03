# gs-watchdog

- **AOSP path**: `private/google-modules/soc/gs/drivers/watchdog/`
- **Mainline counterpart**: [`drivers/watchdog/s3c2410_wdt.c`](kernel/source/drivers/watchdog/s3c2410_wdt.c)
- **Status**: ported
- **Boot-relevance score**: 4/10

## What it does

`s3c2410_wdt.c` (`S3C2410_WATCHDOG_GS`) — vendored fork of the standard S3C/Exynos watchdog driver. Adds `S3C2410_SHUTDOWN_REBOOT` config to keep the WDT kicking even after `wdt->shutdown()` so a stuck shutdown reboots the box.

## Mainline equivalent

Mainline `drivers/watchdog/s3c2410_wdt.c` is the upstream and recognises `google,gs101-wdt` and `google,gs201-wdt` (the gs201.dtsi we're booting on declares both `cl0` and `cl1` watchdog instances with these compats).

## Differences vs AOSP / what's missing

The downstream "reboot-on-stuck-shutdown" knob is the only material addition. Otherwise the upstream and downstream drivers are equivalent for our needs.

## Boot-relevance reasoning

**Score 4**: needed for proper system robustness post-boot. Mainline has it working. No relation to UFS. Score is moderate because if the watchdog fired during a UFS hang it could mask the bug, but you can disable it from userspace with `wdctl`.
