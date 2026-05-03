# gs-dma

- **AOSP path**: `private/google-modules/soc/gs/drivers/dma/`
- **Mainline counterpart**: [`drivers/dma/pl330.c`](kernel/source/drivers/dma/pl330.c)
- **Status**: ported (mainline pl330) + a small samsung-specific shim (`samsung-dma.c`, `SAMSUNG_DMADEV`) is not-ported
- **Boot-relevance score**: 3/10

## What it does

`pl330.c` is the AOSP fork of the ARM PrimeCell DMA-330 driver with downstream patches (peri-id mapping for gs101/gs201, secure-channel handling, IPC-mailbox callbacks). `samsung-dma.c` provides a legacy "samsung_dmadev" wrapper API that some old Samsung audio/secure subsystems use to claim PL330 channels by Samsung-specific DT properties rather than via standard `dma-router`. Built as `pl330_dma_gs.ko` and `samsung_dmadev.ko`.

## Mainline equivalent

Mainline `drivers/dma/pl330.c` is the well-maintained upstream version of the same driver and matches `arm,pl330`/`arm,primecell`. There is no `samsung-dma` shim in mainline; nobody uses that vendor API anymore.

## Differences vs AOSP / what's missing

The vendor `pl330.c` adds a few minor tweaks (extra peripheral channel IDs, downstream debug, secure-IO attribute pass-through). The legacy `samsung-dma.c` API is missing entirely — but the only consumers were the AOSP audio HAL DMA channels and a couple of secure DMA paths.

## Boot-relevance reasoning

**Score 3**: PL330 from mainline is fully functional for general-purpose DMA. UFS uses its own UTRD-style descriptors via the UFS controller (no PL330 involvement), so this has zero relation to UFS HS. The vendor shim only matters if you bring up secure DMA or the AOSP audio stack.
