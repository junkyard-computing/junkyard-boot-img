# gxp

- **AOSP path**: `private/google-modules/gxp/` (felix uses the `gs201/amalthea` variant)
- **Mainline counterpart**: **NONE** (Google-proprietary neural / DSP accelerator)
- **Status**: not-ported
- **Boot-relevance score**: 1/10

## What it does

Driver for GXP — Google's "Generic Pixel Processor", the on-die neural/DSP accelerator that sits next to the Edge TPU on Tensor SoCs ("amalthea" is the gs201 IP block name). Architecturally similar to the edgetpu driver: chardev + IOCTLs, firmware loader, mailbox/DCI command channel, IOMMU-backed DMA mapping (`gxp-dma-iommu.c`, `gxp-dmabuf.c`, `gxp-dma-fence.c`), per-virtual-device isolation (`gxp-vd.c`), domain pool, doorbells, low-power-mode state machine (`gxp-lpm.c`), DVFS (`gxp-devfreq.c`), thermal hookup, per-core telemetry, debug dump, monitor/BPM performance counters, and a sub-system-MMU table manager (`gxp-gsx01-ssmt.c`). Depends on Google's GCIP (Generic Coprocessor Infrastructure for Pixel) helper library shipped under `gcip-kernel-driver/`.

## Mainline equivalent

None. No upstream driver, no DT binding, no RFC posting. Like Edge TPU, this is fully Google-proprietary and depends on signed firmware images authenticated by gsa.

## Differences vs AOSP / what's missing

Everything, plus a transitive dependency on the GCIP library that is also out-of-tree.

## Boot-relevance reasoning

Userspace coprocessor — does not gate boot. Score is 1.
