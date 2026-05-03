# video

- **AOSP path**: `private/google-modules/video/gchips/` (a.k.a. BigWave / BigOcean)
- **Mainline counterpart**: **NONE** (closest cousin is `drivers/media/platform/samsung/s5p-mfc/`, which is a different IP)
- **Status**: not-ported
- **Boot-relevance score**: 2/10

## What it does

Driver for "BigWave" / "BigOcean" — Google's in-house AV1 decoder IP block (the "bigo" prefix is everywhere). Source header at `bigo.c` reads "Driver for BigWave/BigOcean video accelerator, Copyright 2022 Google LLC." Provides a `/dev/video_codec` misc device, an IOMMU-backed buffer path (`bigo_iommu.c`), runtime PM and DVFS (`bigo_pm.c`), an SLC partition (`bigo_slc.c`), a priority queue scheduler (`bigo_prioq.c`), and an Exynos SMC bridge for protected-content paths. Depends on `EXYNOS_BTS` (bandwidth-traffic-shaper). Userspace-facing UABI is custom, not V4L2.

## Mainline equivalent

None. `drivers/media/platform/samsung/` carries `s5p-mfc/` (Samsung's older Multi-Format Codec, a V4L2 mem2mem driver — wrong IP), `s5p-jpeg`, `s5p-g2d`, `exynos-gsc`, `exynos4-is`, `s3c-camif`. None of these are BigWave. Searching mainline for "bigwave" or "bigocean" returns nothing.

## Differences vs AOSP / what's missing

Everything. There is no upstream driver, no DT binding, and the UABI is non-V4L2. Upstreaming would require either rewriting around V4L2 mem2mem stateless decoder ops or going through DRM/accel — neither is a small task. The IP also depends on Exynos BTS and SLC, neither of which is present in our mainline build.

## Boot-relevance reasoning

A hardware video decoder has zero effect on boot. Userspace can fall back to software decoding (libdav1d) for any AV1 needs once the device is up. This is a pure post-boot accelerator and ranks alongside the GPU and camera — not on the path to fixing UFS or anything else. Score is 2.
