# gs-iommu

- **AOSP path**: `private/google-modules/soc/gs/drivers/iommu/`
- **Mainline counterpart**: [`drivers/iommu/exynos-iommu.c`](kernel/source/drivers/iommu/exynos-iommu.c) (older SysMMU only — does NOT cover gs101/gs201's v8/v9 SysMMU)
- **Status**: not-ported
- **Boot-relevance score**: 5/10

## What it does

A complete SysMMU stack for gs101/gs201/zuma's v8/v9 IOMMU plus a separate PCIe IOMMU and helpers:
- `samsung-iommu.c` + `samsung-iommu-fault.c` — v8 SysMMU driver (`samsung,sysmmu-v8`)
- `samsung-iommu-v9.c` + `samsung-iommu-fault-v9.c` — v9 SysMMU driver (`samsung,sysmmu-v9`)
- `samsung-iommu-group.c` — group/domain helpers (`SAMSUNG_IOMMU_GROUP`)
- `samsung-secure-iova.c` — secure IOVA allocator for protected buffers
- `iovad-best-fit-algo.c` — alternate "best fit" IOVA allocator
- `exynos-pcie-iommu-{whi,zuma}.c` — separate PCIe-side IOMMU per board family

Each peripheral master block (DPU, codecs, GPU, ISP, etc.) has its own SysMMU instance; this driver attaches per-master, programs page tables, and handles faults.

## Mainline equivalent

Mainline `exynos-iommu.c` only matches `samsung,exynos-sysmmu` (the older SysMMU v1–v5 used on Exynos4/5). It does not handle SysMMU v8 or v9, so there is **no mainline driver for the gs101/gs201 SysMMU instances**. Mainline `gs201.dtsi` simply omits SysMMU nodes entirely and the masters that would have been behind one (DPU, codecs, ISP, etc.) aren't present in mainline either.

## Differences vs AOSP / what's missing

100% of v8/v9 support, all PCIe-IOMMU code, the secure IOVA allocator, the best-fit IOVA algorithm. To bring up GPU, display, codec, or ISP on mainline, this would be the gating dependency.

## Boot-relevance reasoning

**Score 5**: The SysMMU is **not on the UFS path** — UFS uses its own descriptor DMA via the UFS host controller and goes straight to the SoC interconnect, no SysMMU translation. So missing this driver does not affect our UFS HS wedge. It does block bring-up of every other DMA-capable peripheral (display, GPU, video codec, camera ISP, AOC), which is why the score isn't lower. For our current "console + ethernet works" state we don't need it; the moment you want display or camera, this becomes a hard requirement (port v9 first; gs201 felix is all v9).
