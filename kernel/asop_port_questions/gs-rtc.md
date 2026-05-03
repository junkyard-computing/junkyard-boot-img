# gs-rtc

- **AOSP path**: `private/google-modules/soc/gs/drivers/rtc/`
- **Mainline counterpart**: NONE
- **Status**: not-ported
- **Boot-relevance score**: 4/10

## What it does

`rtc-s2mpg10.c` / `rtc-s2mpg12.c` / `rtc-s2mpg14.c` — RTC subdriver registered as a child of the corresponding S2MPG MFD. For felix (gs201) the relevant one is `rtc-s2mpg12`. Provides battery-backed wall-clock + alarm wakeup.

## Mainline equivalent

No mainline driver. The s2mps11/s5m-rtc drivers handle older Samsung PMIC RTC blocks but the s2mpg register layout is different.

## Differences vs AOSP / what's missing

Everything. Without it, the system has no battery-backed RTC and Linux falls back to defaulting to its build-time epoch on every boot.

## Boot-relevance reasoning

**Score 4**: not boot-blocking — userspace just thinks it's the build epoch until NTP syncs. No connection to UFS. Becomes annoying once you actually use the device daily (every reboot resets clocks, certificate validation gets confused, journald timestamps go backwards). Lower priority than the PMIC core itself. Scoring 4 because it's downstream of fixing s2mpg12 MFD anyway.
