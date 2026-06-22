# kernel/panthor-port

Vendored **additive** (new-file) sources for the Panthor open-GPU port onto our
android-6.1 GKI tree. See `../patches/PANTHOR-PORT-PLAN.md` for the full plan.

These are pristine upstream-backport files that **do not exist** in our tree, so
they're carried as real readable sources (not git-diff patches). They get copied
into `kernel/source/aosp/` during `clone_kernel_source` (mirroring the tree layout
under this dir). The *reconcile* changes (drm_sched, gem_shmem, drm_gem core,
io-pgtable, dma-buf) are carried separately as `../patches/0003+*.patch`.

## Provenance

- Source: **Joshua-Riek/linux-rockchip** PR #7 head `rk-6.1-rkr1-panthor-v5`
- Commit: `305eef6c36e6c792253a1ac703a45926bf52d031`
- Fetched: 2026-06-21 via `gh api .../contents/<path>?ref=<sha>`

## Layout (mirrors aosp/ tree)

```
drivers/gpu/drm/drm_exec.c            drm_exec helper (deps all present in 6.1 ✓)
drivers/gpu/drm/drm_gpuvm.c           GPU VA manager (rbtree backend, no maple dep ✓;
                                      needs drm_gem gpuva field — additive prereq)
drivers/gpu/drm/panthor/*             the 21-file driver
include/drm/drm_exec.h
include/drm/drm_gpuvm.h
include/uapi/drm/panthor_drm.h        uABI
```
