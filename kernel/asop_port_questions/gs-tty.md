# tty

- **AOSP path**: `private/google-modules/soc/gs/drivers/tty/serial/`
- **Mainline counterpart**: `drivers/tty/serial/samsung_tty.c`
- **Status**: ported
- **Boot-relevance score**: 4/10

## What it does

Driver core for the Exynos onboard UARTs (s3c2410-derived UART IP block, fully reused by every Samsung Exynos including gs101/gs201). One file, `exynos_tty.c`, descended from Ben Dooks' original 2003 driver. Adds CPU-PM idle integration, debug logbuffer hooks, panic notifiers, and a fairly elaborate `EXYNOS_UART_PORT_LPM` low-power-mode dance.

## Mainline equivalent

`drivers/tty/serial/samsung_tty.c` (2871 lines vs AOSP 3363). Same lineage.
**Console (UART) on mainline is fully working bidirectionally** as of
2026-05-03 — that's the path the user's kmscon login screen renders to and
the path `serial-getty@ttySAC0` reads from.

The fix that made RX work: switch the gs201 UART DT compat from
`samsung,exynos850-uart` (selects `iotype = UPIO_MEM`, 8-bit `writeb_relaxed`
for `wr_reg(port, S3C2410_UTXH, ch)`) to `google,gs101-uart` (selects
`iotype = UPIO_MEM32`, 32-bit `writel_relaxed`). On gs201, the UART register
block requires 32-bit-aligned access; 8-bit writes raise an asynchronous
SError that surfaces inside `console_unlock`. Patch 0015 in
[upstream-patches/](upstream-patches/) adds `google,gs201-uart` as an alias
for `gs101_serial_drv_data` so DT authors can be explicit.

## Differences vs AOSP / what's missing

The +500 lines in AOSP are CPU-PM hooks (`exynos-cpupm.h`),
`EXYNOS_UART_PORT_LPM` low-power mode, the panic notifier path, and debug
logbuffer integration. None of these are functionally required — they're
observability and aggressive idle. The mainline driver already passes
characters in/out correctly.

Note for anyone reading older notes: the "AOC firmware retry-loop starves
UART RX" story applied to **AOSP**, not mainline. On mainline, AOC stays
dormant (no driver bound, no IRQ claimed) so it doesn't actually starve
anything. The repo still installs `/vendor/firmware/*` and adds
`firmware_class.path=/vendor/firmware` to the cmdline — but on mainline
that's belt-and-suspenders, not the gating fix. The gating fix was
UPIO_MEM32. See [aoc.md](aoc.md) for the AOC-side story.

## Boot-relevance reasoning

4/10. Console works on mainline (bidirectional, both kmscon and
`serial-getty@ttySAC0`). Any port-over of AOSP additions is
observability/aggressive-idle, not boot-critical. Score 4 reflects "core
boot path serial console is fine; this is a finished area."

## 7.1 rebase impact

Our patch 0015 (the `google,gs201-uart` of_match alias) is a 3-line
addition to `samsung_tty.c`'s of_match table. Conflict surface is small;
unlikely to be re-touched upstream. Re-verify that no 7.1 patch landed a
competing `google,gs201-uart` entry in mainline (preempting our patch
upstream) — if so, we may be able to drop our patch in favour of upstream.

