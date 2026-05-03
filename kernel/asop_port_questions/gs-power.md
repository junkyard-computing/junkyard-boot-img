# power

- **AOSP path**: `private/google-modules/soc/gs/drivers/power/reset/`
- **Mainline counterpart**: generic `drivers/power/reset/` (no `debug-reboot` analog)
- **Status**: not-ported
- **Boot-relevance score**: 3/10

## What it does

Single file: `debug-reboot.c`. Implements `reboot=` argument parsing for non-standard debug reboot commands — strings like `panic`, `watchdog`, `dump_sjtag`, etc. — to deliberately trigger watchdog resets, panics, or hardware-debug entry from userspace via `/sys/kernel/reboot/cmd`. Useful for capturing crash dumps and exercising the SoC's debug paths during bringup.

## Mainline equivalent

Mainline `drivers/power/reset/` has lots of platform reset drivers (syscon-reboot, gpio-restart, ltc2952-poweroff, etc.) but no equivalent debug-reboot multiplexer. Mainline equivalent functionality: sysrq triggers, `/proc/sysrq-trigger c` for kernel panic, `echo c > /proc/sysrq-trigger`.

## Differences vs AOSP / what's missing

Whole driver. Standard reboot/poweroff on felix works through the gs201 watchdog + arm-smccc PSCI calls; that's already wired in mainline so plain `reboot` and `poweroff` work. What's missing is the *debug-reboot* paths.

## Boot-relevance reasoning

3/10. Standard reboot/poweroff is fine without this. The debug paths would be useful for capturing crash dumps when the UFS HS bringup wedges; arguably the user could benefit from a forced sjtag dump on hang. Not a boot blocker.

