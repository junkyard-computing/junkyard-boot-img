# felix panthor WIP (2026-06-22) — diagnostic + fixes vs panthor-port canonical

Captured from the gitignored aosp working tree. Base = kernel/panthor-port (PR#7 / panthor-v5, UABI 1.0).

- panthor_mmu.c.diff — **KEEPER**: VM_BIND sub-page fix. Mesa 25.2.8 binds sub-page
  (0x600) BOs; panthor 1.0 rejected the unaligned size at two gates
  (panthor_vm_bind_prepare_op_ctx page-align check + bounds check). Round size to
  PAGE_SIZE + compare bounds against page-aligned BO size. Confirmed working (VM_BIND ret=0).
- panthor_fw.c.diff — coherency band-aids (poll + cache-mode experiments) + DBG prints.
  NOT a working fix: felix MCU->CPU coherency is broken; needs the upstream coherent
  FW-section memattr (AS_MEMATTR_AARCH64_SHARED) implementation. Diagnostic value only.
- panthor_drv.c.diff — DBG prints (vm_bind, group_create). Diagnostic only.

Next: upgrade panthor to a version with proper coherent FW-section mapping + UABI matching
Mesa 25.2.8. The VM_BIND keeper may be superseded by the upstream handling.
