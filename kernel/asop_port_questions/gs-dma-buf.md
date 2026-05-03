# gs-dma-buf

- **AOSP path**: `private/google-modules/soc/gs/drivers/dma-buf/heaps/samsung/`
- **Mainline counterpart**: [`drivers/dma-buf/heaps/`](kernel/source/drivers/dma-buf/heaps/) (generic system + cma heaps only)
- **Status**: partially-ported
- **Boot-relevance score**: 2/10

## What it does

A whole pile of Samsung-specific dma-buf heap providers used by the camera/video/display stacks for big contiguous and protected buffers:
- `system_heap.c` — overrides the generic system heap with downstream tweaks
- `cma_heap.c` / `chunk_heap.c` / `carveout_heap.c` — CMA + chunk + carveout heap variants
- `gcma_heap.c` / `gcma_heap_sysfs.c` — Google "Guaranteed CMA" heap (depends on `soc/google/gcma/`)
- `secure_buffer.c` — protected/DRM buffer allocations via SMC into BL31
- `samsung_heap.c` / `heap_dma_buf.c` — common framework
- `dmabuf_heap_trace.h` — tracepoints

## Mainline equivalent

Mainline has only the generic `system_heap.c` and `cma_heap.c`. No chunk/carveout/gcma/secure variants. The samsung-extended trace events and the secure buffer SMC interface have no upstream analogue.

## Differences vs AOSP / what's missing

Everything but the basic system + cma heaps. In particular: no secure-DRM heap (needed for protected video playback), no gcma (which the camera/codec memory pool used heavily on Pixel), no carveout heap for the AOC firmware backing memory (AOC uses `reserved-memory` regions instead, which is fine on mainline).

## Boot-relevance reasoning

**Score 2**: dma-buf heaps are user-space allocators consumed by codec/camera/video userspace. Mainline can boot to console and run a Debian rootfs without any of these. Useful only when you start porting v4l2/codec/display-DRM stacks. No relation to UFS HS.
