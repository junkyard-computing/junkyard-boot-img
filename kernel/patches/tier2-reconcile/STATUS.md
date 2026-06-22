# Panthor port — Tier-2 reconcile + driver: STATUS (2026-06-22)

Snapshot of the autonomous Panthor bring-up run. The port **compiles, links, and
deploys**; it is blocked on an **early-boot hang** that needs a serial console (UART)
to localize. Everything below is reproducible from this repo + PR Joshua-Riek/
linux-rockchip#7 (head `305eef6c`).

## What works (verified)

- **Tier-1 DRM core** (drm_exec + drm_gpuvm + gem gpuva): builds clean on GKI 6.1.124
  AND **boots + runs on device** (slot B history). Committed: `kernel/panthor-port/`
  (additive sources) + `kernel/patches/0003-*`.
- **Tier-2 reconcile + the full 13k-line Panthor driver: COMPILE + LINK clean** against
  GKI 6.1.124. Only 2 fixes were needed: the missing `drm_debugfs.c`
  (`drm_debugfs_gpuva_info`) definition, and hand-applying the gem `_unlocked` bits
  (GKI already had the vm_flags refactor).
- **panthor.ko builds as a module** — add `drivers/gpu/drm/panthor/panthor.ko` to the
  `kernel_aarch64` `module_implicit_outs` in `aosp/BUILD.bazel`, and set
  `kmi_symbol_list_strict_mode = False` there (panthor imports our new
  drm_gpuvm/drm_exec exports that aren't in the stock KMI; fine for a custom build).
  GKI does NOT pull it into the dist staging archives — grab it from
  `bazel-out/.../bin/aosp/kernel_aarch64/panthor.ko` and install by hand.
- **CSF firmware**: felix is Mali-G710 **arch 10.8.6**, so panthor requests
  `arm/mali/arch10.8/mali_csffw.bin`. The **linux-firmware arch10.8 blob (282624 B) is
  the exact match** — this is the blob the mainline track never had. Install to the
  rootfs `/lib/firmware/arm/mali/arch10.8/`.
- **Mesa userspace**: `mesa-opencl-icd` (rusticl) + `mesa-vulkan-drivers` (PanVK) are
  installed on the device. Benchmark harness is `benchmarks/gbench.c` (OpenCL → rusticl,
  `RUSTICL_ENABLE=panfrost`); "Open" rows of `benchmarks/results.csv` await GPU.

## Tier-2 carry pieces (in this repo)

- `kernel/panthor-port/` — additive sources, NOW INCLUDING the wholesale-replaced
  `scheduler/*.c`, `drm_gem_shmem_helper.c`, `gpu_scheduler.h`, `drm_gem_shmem_helper.h`
  (PR-head). rsync these over GKI's during clone.
- `kernel/patches/tier2-reconcile/*.patch` — the small reconcile deltas (gem.c,
  dma-buf, io-pgtable custom-alloc, drm_debugfs def, gem dma/fb/ttm helpers). Apply with
  proper headers; `drm_gem.c.partial.patch` omits the already-applied gpuva hunk.
- Plus a `drm_client.c` change (lines 259/347/369 → `drm_gem_v*map_unlocked`) and the
  DT `mali` node → `arm,mali-valhall-csf` (lowercase IRQ names, `clocks=<&gpu_clk 0>`,
  `power-domains=<&pd_embedded_g3d>` — the LEAF cores domain, which genpd powers along
  with its parent pd_g3d).

## THE BLOCKER — early-boot hang (needs UART)

The Tier-2 kernel **hangs in early boot, before journald persists anything** (proven:
the shared persistent journal — readable from the good slot since `super` is shared —
shows ONLY full ~5000-line successful boots; failed slot-A boots leave zero journal).

Ruled OUT by build+boot bisection (each ~30 min via the rollback-safe deploy):
- NOT panthor's probe (hangs with panthor removed from /lib/modules).
- NOT the DT change (hangs with the kbase `arm,malit6xx` node too).
- NOT `dma_resv_assert_held` (it's a no-op — `CONFIG_DEBUG_LOCK_ALLOC` is unset).
- NOT the io-pgtable custom-allocator (default path is correctly guarded).
- NOT the gem_shmem/scheduler wholesale-replace ALONE (a bisect reverting them to GKI
  still hung — though that bisect was partly inconsistent, see below).

Narrowed suspect: the **`_unlocked` locking conversions in the display/framebuffer
path** — `drm_gem_dma_helper.c`, `drm_gem_framebuffer_helper.c`, `drm_client.c` were
converted from `dma_buf_vmap`/`drm_gem_vmap` to the `_unlocked` (resv-lock-taking)
variants. fbcon/fbdev console setup runs this at early boot. On felix's exynos display
path this may deadlock or fault. (The last bisect mixed GKI's old-locking gem_shmem
with these new-locking callers — an inconsistent state — so it isn't a clean result.)

### Recommended next step (with UART at the bench)

1. Boot a Tier-2 slot with the serial console attached; capture where it freezes
   (`earlycon`, `ignore_loglevel`). That single log localizes it in minutes vs the
   ~30-min blind cycles.
2. Most likely fix: do the gem_shmem/scheduler as a **minimal-delta port** (add only the
   drm_sched-workqueue API + gem_shmem locked/unlocked API panthor needs) instead of
   wholesale-replacing GKI's files, and convert the display-path callers consistently
   with whatever gem_shmem version is in tree.
3. Then panthor probe: the power-domain fix (`pd_embedded_g3d`) is ready; expect
   `/dev/dri/renderD129` + an `arm/mali/arch10.8` firmware load in dmesg, then run
   `RUSTICL_ENABLE=panfrost ./gbench` and fill `results.csv`.

Device is safe on slot B (kbase, working). All boot-chain flashes were rollback-safe;
`super`/rootfs only got additive changes (modules, firmware, Mesa).
