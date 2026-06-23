# Resume point (2026-06-23) — COMPUTE WORKS, open-GPU benchmarks captured

## STATUS: Open-GPU (Panthor + rusticl/OpenCL) runs correctly on felix G710.
gcheck 12/12 deterministic PASS, 0 faults. gbench numbers captured to
benchmarks/results.csv (Open rows). This is the apples-to-apples open-vs-
proprietary data the whole effort was for.

## The full fix stack (all in kernel/source/aosp/drivers/gpu/drm/panthor/)
1. panthor_device.c — NONE-coherent model: force `ptdev->coherent=false` AND
   `ptdev->base.dev->dma_coherent=false` (so dma_sync flushes FW+page tables).
   MCU boots, FW iface reads clean.
2. panthor_mmu.c — (a) VM_BIND sub-page fix (page-align op->size). (b) io-pgtable
   coherent_walk=ptdev->coherent (false). (c) **map user data BOs UNCACHED on the
   GPU** for non-coherent (`prot &= ~IOMMU_CACHE` when NOEXEC) — keeps executable
   (shader code) mappings CACHED for I-fetch speed. THIS is what made compute
   correct+reliable.
3. panthor_sched.c — **post-compute FLUSH_CACHE2.clean_inv_all + WAIT** appended to
   queue_run_job's call_instrs (after the user CALL, before SYNC_ADD64) so GPU L2
   output reaches DRAM before the fence signals. Killed the faults/timeouts.
4. panthor_gem.c — pin+dma_map BO pages at create-time (clean the arm64 cached
   linear-map alias before userspace WC-writes it; stops VM_BIND's dma_map clean
   from clobbering descriptors).
5. panthor_drv.c — wmb() in panthor_submit_ctx_push_jobs (drain submitting-CPU WC
   before the GPU-side worker consumes). (Minor; alias+uncached did the heavy lift.)
6. panthor_fw.c — interface last-field polls (robust iface read). DIAG prints still
   present across device/fw/mmu/drv — strip before upstreaming.

## ROOT CAUSE (the headline)
felix is non-coherent arm64. panthor maps BOs write-combine (map_wc). On arm64
drm_gem_shmem's map_wc is a NO-OP (set_pages_array_wc only works on x86 — see the
TODO at drivers/gpu/drm/drm_gem_shmem_helper.c). So WC BO pages keep a *cached*
linear-map alias; the arm64 arch calls simultaneous cached+WC aliases UNPREDICTABLE
-> cache-line-granular stale reads (observed: buffer descriptor reads NULL while the
adjacent sampler descriptor in the SAME page is correct -> shader writes a null ptr
-> no output). Mapping the data BOs uncached on the GPU side sidesteps it: GPU always
hits DRAM, which the CPU's WC writes keep fresh.

## On device (kalm@192.168.1.138, slot A, key auth installed)
- /home/kalm/panthor-fix.ko = the WORKING full-fix build.
- Mesa /opt/mesa-g710; rusticl ICD /opt/mesa-g710/rusticl-g710.icd; RUSTICL_ENABLE=panfrost.
- gcheck/gcheck3/gtime/gbench/gbench-micro on device; recompile gcc -lOpenCL.
- Run env: OCL_ICD_VENDORS=/opt/mesa-g710/rusticl-g710.icd LD_LIBRARY_PATH=/opt/mesa-g710/lib

## NUMBERS (Open / Proprietary, 800/848 MHz)
FP32 76.2/605, FP16 89.0/594, INT32 33.1/188 GIOPS, triad ~5/41.6 GB/s,
H2D 12.0/11.1, D2H 1.6/12.7, launch 624/85 us. Open is uncached-data -> memory-bound
work pays a big tax; compute lower too (Mesa compiler + occupancy + uncached args).

## REMAINING (productionization, not blockers)
- Proper DT fix: drop `dma-coherent` from gs201-gpu.dtsi (so the driver-forced
  coherent=false becomes natural) — needs dtb+vendor_boot reflash.
- Better numbers: kbase-style cached-data + explicit dma_sync (clean before submit,
  invalidate after) instead of blanket-uncached data — recovers memory bandwidth.
- Strip DIAG prints. Push G710 Mesa fork (github junkyard-computing/mesa felix-g710).
  Wire nix flake to build Mesa. Power/efficiency (ODPM) + PanVK/llama rows still PENDING.
