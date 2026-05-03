# tty

- **AOSP path**: `private/google-modules/soc/gs/drivers/tty/serial/`
- **Mainline counterpart**: `drivers/tty/serial/samsung_tty.c`
- **Status**: ported
- **Boot-relevance score**: 4/10

## What it does

Driver core for the Exynos onboard UARTs (s3c2410-derived UART IP block, fully reused by every Samsung Exynos including gs101/gs201). One file, `exynos_tty.c`, descended from Ben Dooks' original 2003 driver. Adds CPU-PM idle integration, debug logbuffer hooks, panic notifiers, and a fairly elaborate `EXYNOS_UART_PORT_LPM` low-power-mode dance.

## Mainline equivalent

`drivers/tty/serial/samsung_tty.c` (2871 lines vs AOSP 3363). Same lineage. Mainline driver supports gs101 directly via the standard `samsung,*-uart` compatible chain. **Console (UART) on mainline is fully working** — that's the path the user's kmscon login screen renders to.

## Differences vs AOSP / what's missing

The +500 lines in AOSP are CPU-PM hooks (`exynos-cpupm.h`), `EXYNOS_UART_PORT_LPM` low-power mode, the panic notifier path, and debug logbuffer integration. None of these are functionally required — they're observability and aggressive idle. The mainline driver already passes characters in/out correctly with no AOC firmware required for the *driver itself* (the AOC blob that vendor/firmware ships only matters because the AOC coprocessor's retry-loop starves UART RX, which is solved by installing `/vendor/firmware`).

## Boot-relevance reasoning

4/10. Console works on mainline. The active boot issue around UART (the AOC firmware starvation) is solved via `/vendor/firmware`, not by changing the TTY driver. Any port-over of AOSP additions is observability/aggressive-idle, not boot-critical. Score 4 reflects "core boot path serial console is fine; this is a finished area."

