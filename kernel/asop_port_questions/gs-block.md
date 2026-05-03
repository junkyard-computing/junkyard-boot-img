# gs-block

- **AOSP path**: `private/google-modules/soc/gs/drivers/block/zram/`
- **Mainline counterpart**: [`drivers/block/zram/`](kernel/source/drivers/block/zram/) (generic), no GS-specific equivalent
- **Status**: partially-ported (generic upstream zram is fully usable; the GS-specific Emerald Hill HW compressor hooks are not)
- **Boot-relevance score**: 1/10

## What it does

A vendored fork of the kernel's zram driver renamed `ZRAM_GS`, with extra hooks for the Google "Emerald Hill" hardware compression engine (`ZCOMP_EH`, depends on `GOOGLE_EH` from `soc/google/eh/`). Files: `zram_drv.{c,h}`, `zcomp.{c,h}`, `zcomp_cpu.c`, `zcomp_eh.c`. Adds `ZRAM_GS_WRITEBACK` (writeback to backing dev) and `ZRAM_GS_MEMORY_TRACKING` knobs. None of this changes how the block layer enumerates real storage — it's all about RAM-backed swap.

## Mainline equivalent

Mainline `drivers/block/zram/` provides full zram functionality including writeback, memory tracking, and pluggable compressor backends (lzo/lz4/zstd/842) — basically the same feature set minus the EH hardware compressor.

## Differences vs AOSP / what's missing

The only missing piece of substance is `zcomp_eh.c` and the `GOOGLE_EH` hardware compressor driver in `soc/google/eh/eh_main.c`. Without it you fall back to CPU-based compression. Everything else (writeback, idle tracking, sysfs attributes) is in mainline already — possibly with renamed knobs but functionally equivalent.

## Boot-relevance reasoning

**Score 1**: zram is opt-in user-space swap configuration. Mainline zram is fully functional. The Emerald Hill compressor is a power/perf optimization for swap-heavy workloads on Android — completely irrelevant to whether the device boots, and irrelevant to the UFS bring-up. Skip.
