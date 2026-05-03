# aoc-ipc

- **AOSP path**: `private/google-modules/aoc_ipc/`
- **Mainline counterpart**: **NONE**
- **Status**: not-ported
- **Boot-relevance score**: 6/10

## What it does

A tiny support library (just `aoc_ipc_core.c` + two headers, ~few hundred LoC) that defines the on-the-wire AOC service-descriptor format and the read/write primitives over the shared SRAM/DRAM ring buffers and message queues that AOC and the AP use to talk. It exposes typed accessors (`aoc_service_is_queue`, `aoc_service_is_ring`, `aoc_service_total_size`, `aoc_service_message_size`, `aoc_service_can_read_message`, `aoc_service_read`, `aoc_service_write`, etc.) with `AOC_UP` (FW→AP) / `AOC_DOWN` (AP→FW) direction flags, and is consumed by `aoc_core` (linked in via `../aoc_ipc/aoc_ipc_core.o` in the AOC Kbuild) and by AOC userspace daemons that mmap the same shared region. Designed to compile both inside the kernel and in userspace (`#ifdef __KERNEL__` paths everywhere) so the AP-side kernel driver and the AOC-side firmware can share one source of truth for the IPC layout.

## Mainline equivalent

None. This is the protocol library for the AOC remote-processor IPC and only makes sense paired with the AOC core driver. Conceptually parallel to `drivers/remoteproc/qcom_glink*` (the GLINK / SMEM IPC protocol used between Qualcomm AP and remote DSPs) or the rpmsg / virtio_rpmsg stack, but the wire format and discovery rules are entirely Google-private.

## Differences vs AOSP / what's missing

Entire library is absent from mainline. Any AOC port has to bring this verbatim because it defines the structures the AOC firmware writes into shared memory at boot — there is no flexibility to redesign it without also rebuilding the firmware.

## Boot-relevance reasoning

Score 6/10 — same justification as `aoc` itself, since this library is meaningless without the AOC core driver and offers nothing usable on its own. The two should be ported together as one work item; splitting them out into separate modules is purely a Google source-tree organizational choice (the same `aoc_ipc_core.c` is also linked into AOC userspace daemons, which is why it lives in its own directory).
