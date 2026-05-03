# gpu

- **AOSP path**: `private/google-modules/soc/gs/drivers/gpu/exynos/`
- **Mainline counterpart**: `drivers/gpu/drm/panthor/` (for the **Mali GPU** itself, which is **NOT** here)
- **Status**: not-ported (and partially **misleading** — see below)
- **Boot-relevance score**: 3/10

## What it does

This directory contains **only `g2d/`** — the Samsung **FIMG2D** 2D-graphics accelerator driver. FIMG2D is a fixed-function 2D blitter (color fill, blit, alpha-blend, color-conversion) used by the Android SurfaceFlinger fast-path and some camera ISP pipelines. **The actual 3D GPU (Mali-G710 on gs201) is in a separate AOSP repo entirely** (`private/google-modules/gpu/mali_kbase/`), not under `soc/gs/drivers/gpu/`.

## Mainline equivalent

- FIMG2D: **no mainline driver**. It is a fully proprietary Samsung IP block with userspace contracts that don't fit DRM or V4L2.
- Mali-G710 (the actual 3D GPU): mainline `drivers/gpu/drm/panthor/` supports Mali Valhall (G710 era). gs201 binding may or may not be wired.

## Differences vs AOSP / what's missing

FIMG2D is an Android-stack-only optimization; nothing on a Debian rootfs ever calls it. Loss is theoretical (SurfaceFlinger isn't running).

## Boot-relevance reasoning

3/10. Boot uses simpledrm framebuffer (the bootloader hands us a pre-configured framebuffer; mainline simpledrm presents it as the kmscon backend). We do not need any GPU/2D driver for console. FIMG2D specifically would never be touched by a Debian userspace.

