# Panthor DRM port onto android-6.1 (felix / gs201) — scoping plan

Goal: bring up the **open** Mali CSF driver (Panthor) on the android-6.1 track so we
can run an apples-to-apples GPU benchmark against the proprietary kbase
(`benchmarks/results.csv`, the open column). The GPU clock provider this driver
binds is **already done and verified on device** (`clk-acpm-gpu.c`, carried via
`0001`/`0002` here; g3d 202 MHz / g3dl2 302 MHz). This doc scopes the remaining
DRM lift.

Reference: **Joshua-Riek/linux-rockchip#7** "Panthor driver backport"
(author hbiyik), base `rk-6.1-rkr1` → head `rk-6.1-rkr1-panthor-v5`,
+22401/−3027 across **253 files**. It backports mainline ~6.10 Panthor onto a
6.1 *RK BSP* fork.

## Headline: 253 PR files collapse to ~52 against our tree

Our tree is **Google GKI 6.1.124** (`aosp/` repo project), a *different* 6.1 fork
than the PR's RK BSP base. Two consequences:

1. **Do not `git apply` the PR diffs.** They're against RK BSP context that won't
   match GKI. Port by *content/result*, not by patch hunks.
2. **GKI is much newer than the RK BSP base**, so most of the PR's prerequisite
   backports are already in our tree and drop out entirely:

| PR cluster | files | status in our tree | action |
|---|---|---|---|
| `vm_flags_set/clear/mod` accessor refactor (mm/sound/net/security/infiniband/xen/usb/scsi/…) | ~150 | **present** (`mm.h:856`, verified) | **DROP** |
| `include/linux/mm.h`, `mm_types.h` (the accessor defs) | 2 | **present** | **DROP** |
| `rockchip/*`, rk3588 dts, `rockchip_defconfig`, regulator-coupler | 14 | RK-only, irrelevant | **DROP** |

That removes ~166 files. What remains is the genuine DRM/MMU/dma-buf core plus the
Panthor driver itself.

## Strategy: in-tree replace (same as hbiyik), blast radius verified contained

Verified preconditions that make wholesale replacement of the shared DRM core safe:

- **No android vendor hooks** in our `drivers/gpu/drm/scheduler/*.c` or
  `drm_gem_shmem_helper.c` (grep for `ANDROID_`/`trace_android`/`vendor_hook` =
  0). GKI's copies are upstream-clean, so we can lift them to the
  Panthor-required versions without preserving android-specific surgery.
- **Felix builds no other `drm_sched` consumer** (`gs201_defconfig` has no
  `DRM_SCHED`/`DRM_PANFROST`/`DRM_LIMA`; `panfrost/`+`lima/` source exists but is
  not configured in). Replacing the scheduler can't regress another driver.
- **KMI stability is not a gate**: this repo rebuilds the kernel *and* all
  vendor_dlkm/system_dlkm modules from source in one bazel build, so ABI churn in
  drm_sched/gem is self-consistent. kbase (proprietary) does not link drm_sched.

Our base `drm_sched` is the **old kthread-based API** (`drm_sched_init(sched, ops,
hw_submission, hang_limit, timeout, timeout_wq, score, name, dev)` — no
`drm_sched_init_args`, no submit workqueue). Panthor needs the **~6.8 workqueue
rework**. That reconcile is the single highest-risk piece of the whole port.

## Tier 1 — additive, drop-in new files (low risk, ~13.5k lines, mostly mechanical)

Pure-add (zero deletions); they don't exist in our tree, so they can't conflict.
Only risk is compile-time API drift against GKI 6.1 (each is written for ~6.10).

| file | lines | notes |
|---|---|---|
| `drivers/gpu/drm/drm_exec.c` + `include/drm/drm_exec.h` | 340+123 | locked-object exec helper; self-contained |
| `drivers/gpu/drm/drm_gpuvm.c` + `include/drm/drm_gpuvm.h` | 2721+1244 | GPU VA manager; depends on drm_exec + maple_tree/rbtree (present in 6.1) |
| `drivers/gpu/drm/panthor/*` (21 files) | ~13k | the driver: device, drv, fw, gem, gpu, heap, mmu, sched, devfreq, regs |
| `include/uapi/drm/panthor_drm.h` | 945 | uABI — copy verbatim from mainline |
| `drivers/dma-buf/dma-buf.c` + `include/linux/dma-buf.h` | 43+2 | adds `dma_buf_vmap_unlocked`/`dma_buf_vunmap_unlocked` (**MISSING** in our tree) — pure add |
| `drivers/iommu/io-pgtable.c` + `io-pgtable-arm.c` + `include/linux/io-pgtable.h` | 23+39/16+31 | **custom page-table allocator hook** (Brezillon) — panthor_mmu passes `cfg.alloc/free`. `ARM_MALI_LPAE` + `ARM_OUTER_WBWA` already present; only the alloc/free hook + `io_pgtable_caps` is new |
| `drivers/gpu/drm/Kconfig` + `Makefile` | 15+4 | wires `DRM_GPUVM`/`DRM_EXEC`/`DRM_PANTHOR` |

## Tier 2 — semantic reconcile (medium→high risk; merge by content, not patch)

These exist in our tree with different content; the PR both adds and deletes.
Recommended approach per file: take mainline **v6.10** as the source of truth for
the post-rework version, diff against our GKI 6.1 copy, port the delta.

| file | +/− | risk | what changes |
|---|---|---|---|
| `drivers/gpu/drm/scheduler/sched_main.c` | 570/246 | **HIGH** | kthread→workqueue run-job/free-job; new `drm_sched_init` arg-struct; `drm_sched_wakeup`, `drm_sched_run_job_queue` |
| `drivers/gpu/drm/scheduler/sched_entity.c` | 200/119 | **HIGH** | entity submit path for wq scheduler |
| `drivers/gpu/drm/scheduler/sched_fence.c` | 26/3 | med | `drm_sched_fence_scheduled` deadline plumbing |
| `include/drm/gpu_scheduler.h` | 100/32 | **HIGH** | the API surface every consumer sees; must stay self-consistent |
| `drivers/gpu/drm/scheduler/gpu_scheduler_trace.h` | 1/1 | low | trace field rename |
| `drivers/gpu/drm/drm_gem_shmem_helper.c` | 148/153 | **HIGH** | locked/unlocked vmap/pin/get_pages rework; refcount churn |
| `include/drm/drm_gem_shmem_helper.h` | 103/117 | **HIGH** | matching header rework |
| `drivers/gpu/drm/drm_gem.c` | 28/1 | med | `drm_gem_object_funcs` additions (`evict`, `status`), `drm_gem_lru` |
| `include/drm/drm_gem.h` | 82/0 | low | additive struct/fn decls for the above |
| `drm_gem_dma_helper.c/.h`, `drm_gem_framebuffer_helper.c`, `drm_gem_ttm_helper.c` | small | low | follow gem_shmem signature changes |
| `include/drm/drm_drv.h`, `drm_device.h`, `drm_debugfs.h` | small | low | `DRIVER_GEM_GPUVA`, debugfs gpuvm dump hooks |
| `drivers/base/arm/.../dma-buf-test-exporter.c` | 1/1 | low | kbase-test-module adapts to unlocked vmap; only if that test module is built |

## Build wiring (after files land)

- `gs201_defconfig` fragment (or `custom_defconfig`): `CONFIG_DRM_GPUVM=m`,
  `CONFIG_DRM_EXEC=m`, `CONFIG_DRM_SCHED=m`, `CONFIG_DRM_PANTHOR=m`,
  `CONFIG_IOMMU_IO_PGTABLE_LPAE=y` (already on for kbase).
- `private/devices/google/gs201/BUILD.bazel`: add the new `.ko`s to `module_outs`
  (`drm_gpuvm.ko`, `drm_exec.ko`, `gpu-sched.ko`, `panthor.ko`) — same edit shape
  as the `clk-acpm-gpu.ko` line already added by `0002`.
- kbase and Panthor must not both bind `mali@28000000`. Either gate kbase off in
  this build, or give Panthor its own DT node and leave kbase's `status="disabled"`.

## DT + firmware (last step, after it compiles + probes)

- Add a `panthor` DT node: `compatible = "arm,mali-valhall-csf"`,
  `clocks = <&gpu_clk 0>, <&gpu_clk 1>` (the verified provider — cells:
  0=g3d, 1=g3dl2), `power-domains = <&pd_g3d>`, the 3 G3D interrupts
  (`IRQ_G3D_IRQJOB/IRQMMU/IRQGPU`), `reg = <0x0 0x28000000 0x480000>`.
- CSF firmware: Panthor wants **arch 10.8** (`mali_csffw.bin`). felix OTA ships
  r54p2 which is arch10.8-valid (per `project_panthor_felix_gpu_state`). Stage it
  into the rootfs `/lib/firmware/arm/mali/arch10.8/`.

## Carry mechanism (how this lands in-repo)

The existing `kernel/patches/*.patch` mechanism applies to repo-managed projects
after `repo sync`. For ~13.5k lines of *new* files a single git-diff patch is
unreviewable. Recommended hybrid:

- **Additive files** (Tier 1): vendor the actual sources under
  `kernel/panthor-port/` in this repo and `rsync` them into `aosp/` during
  `clone_kernel_source` (new step, after the existing `apply_patch` block). Keeps
  them readable and diff-able in *our* git history.
- **Reconcile files** (Tier 2): small git-diff patches `0003-*`…, one per area
  (`drm-sched-wq`, `gem-shmem`, `gem-core`, `io-pgtable-alloc`,
  `dma-buf-vmap-unlocked`), applied idempotently like `0001`/`0002`.

## Execution order (each step gated by a build before the next)

1. Tier 1 additive files + Kconfig/Makefile + io-pgtable + dma-buf → **build the
   core alone** (`DRM_GPUVM`/`DRM_EXEC` =m, panthor =n) to shake out API drift.
2. drm_sched wq reconcile → build with `DRM_SCHED=m` (still panthor=n). Highest
   risk; isolate it.
3. gem_shmem + gem reconcile → build.
4. `DRM_PANTHOR=m` → build the driver.
5. DT node + firmware → flash boot/vendor_boot/dtbo to **inactive slot**
   (A/B-safe, never touch `super`), probe, `dmesg | grep panthor`, check
   `/dev/dri/renderD*`.
6. Mesa panfrost/PanVK + rusticl userspace in rootfs → re-run gbench/llama,
   fill the open column of `benchmarks/results.csv`.

## Open risks / unknowns

- **drm_sched wq rework is the crux.** If it fights GKI 6.1 internals harder than
  expected, fallback is to vendor a *private-namespace* copy of drm_sched compiled
  only for panthor — avoids touching the shared symbol, at the cost of a forked
  scheduler. Decide after step 2.
- maple_tree API used by drm_gpuvm: present in 6.1 but verify the exact helpers
  (`mtree_*`) panthor relies on exist.
- devfreq: `panthor_devfreq.c` expects an OPP table; our clock provider exposes
  rates but no OPP nodes yet — may need an `operating-points-v2` table or to stub
  devfreq off initially.
- Mali CSF firmware arch match is empirical; r54p2==arch10.8 is believed-valid but
  unproven against *this* Panthor revision (EINVAL on the mainline graft was a
  version mismatch — see `project_panthor_felix_gpu_state`).
