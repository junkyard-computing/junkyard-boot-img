# media

- **AOSP path**: `private/google-modules/soc/gs/drivers/media/platform/exynos/`
- **Mainline counterpart**: `drivers/media/platform/samsung/s5p-mfc/` (older MFC); no SMFC
- **Status**: partially-ported (older MFC generations only)
- **Boot-relevance score**: 2/10

## What it does

Two Exynos multimedia accelerators:
- `mfc/` — **MFC** (Multi-Format video Codec). Hardware H.264/H.265/VP9/AV1 encoder/decoder. Used by Android camera/video pipelines.
- `smfc/` — **SMFC** (Still-MFC). JPEG codec accelerator; HW-accelerated JPEG encode/decode.

## Mainline equivalent

- MFC: `drivers/media/platform/samsung/s5p-mfc/` covers Exynos3..Exynos7-era MFC. **gs101/gs201 use a newer MFC v12+ which the s5p-mfc driver does not cover.** No mainline driver for the gs-MFC.
- SMFC: `drivers/media/platform/samsung/s5p-jpeg/` covers older Exynos JPEG hardware. Same generation gap.

## Differences vs AOSP / what's missing

Generation gap. The AOSP driver supports the gs101/gs201/zuma generations of MFC and SMFC; mainline supports the s5p-era ones up to Exynos7. We have neither driver currently.

## Boot-relevance reasoning

2/10. Pure post-boot multimedia hardware. A Debian userspace would do video via libavcodec on CPU. Boot completes without it.

