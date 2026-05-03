# edgetpu

- **AOSP path**: `private/google-modules/edgetpu/` (felix uses the `janeiro` variant)
- **Mainline counterpart**: **NONE** (Google-proprietary ML accelerator)
- **Status**: not-ported
- **Boot-relevance score**: 1/10

## What it does

Driver for Google's Edge TPU ML accelerator block (TPU v4-derived, "darwinn-2.0" per the Kconfig help text). `janeiro` is the gs201/Tensor G2 variant; sibling subtrees `abrolhos` and `rio` target other Pixel SoCs. The driver provides a chardev with custom IOCTLs, host-side mailbox/KCI command channel to firmware running on the TPU, IOMMU-backed DMA buffer mapping (`edgetpu-google-iommu.c`, `edgetpu-dmabuf.c`), firmware loader, telemetry/tracing extraction, software watchdog, device-group/multi-tenant isolation, and a power-management state machine. Configures select `DMA_SHARED_BUFFER`, `IOMMU_API`, `SYNC_FILE`. Userspace consumer is the closed-source TFLite Edge TPU runtime / Tensor "Visual Core" pipeline.

## Mainline equivalent

None. There is no upstream Edge TPU driver, no upstream binding, and Google has not posted RFC patches. Some other ML accelerators live under `drivers/accel/` (Habana, AMD AIE, Intel IVPU) using DRM-accel UABI, but Edge TPU is not one of them.

## Differences vs AOSP / what's missing

Everything. Even the firmware blob signing / loading interface depends on Google-specific gsa (Google Security Authenticator) bits that aren't upstream either.

## Boot-relevance reasoning

Edge TPU not probing has no effect on boot — it's a coprocessor that userspace opts into. Score is 1.
