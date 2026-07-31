# Open-GPU performance on mainline felix (Panthor / PanVK vs closed libmali)

Investigation into why the **open** GPU stack (mainline kernel + Panthor DRM +
Mesa PanVK/rusticl) on the Pixel Fold's Mali-G710 was slower than the **closed**
ARM stack (AOSP kernel + kbase + `libmali`), and how much of that gap we closed.

Both stacks run the **same G710 MC7 silicon** — `.108` (AOSP/kbase/libmali, the
closed oracle) and `.138` (mainline/Panthor/PanVK, open). All numbers below are at
a pinned GPU clock of **848 MHz** unless noted.

## TL;DR

The gap had two independent halves:

1. **Memory subsystem** — TWO in-kernel fixes, now **fully closed to PARITY**: (a) the mainline
   MIF (DRAM) devfreq governor never saw GPU traffic → coupled GPU DVFS to a MIF bandwidth vote
   via the **interconnect framework** (BW ~4→11.9); (b) the GPU **g3dl2 (L2/bus/memory-interface)
   clock** was stuck at its 151 MHz idle rate because the mainline OPP only scaled the shader core
   → **pinned it to 996 MHz in panthor** (BW 11.9→**33.9 GB/s = closed's 34.7**). Both shipped.
2. **Compiler codegen** (the residual, ~1.30×) — panfrost's Valhall backend is register-file
   bound on the **FP path specifically** (integer compute is now at parity too; see the 2026-07-28
   head-to-head at the end). Research-grade and remains open; every simple lever was build-tested
   dead or zero-sum.

**→ For the current, validated same-day head-to-head (rc5 vs AOSP, post-g3dl2), see the
"g3dl2 FIX VALIDATED @ PARITY" section at the end of this doc.** The table just below is the
pre-g3dl2 historical snapshot.

| llama.cpp Qwen2.5-0.5B Q4_K @848 MHz | open **before** | open **after** | closed (.108) |
|---|---|---|---|
| pp128 (prefill) | 22.4 | **33.9** | ~124 |
| pp256 | 21.1 | **32.7** | — |
| pp512 (`-ub 128`) | hang | **26.8** | 162 |
| tg128 (decode) | 6.75 | **9.4** | 32 |
| clpeak global BW | ~4 (then hung) | **11.9 GB/s** | 33.7 |
| clpeak FP32 | hung | **548 GFLOPS** | 730 |

The open-vs-closed gap narrowed from ~4.7–5.6× to **~3.4–3.7×** with the memory
fix alone. The residual is compiler codegen.

---

## Part 1 — The memory-subsystem fix (MIF interconnect coupling)

### Symptom
A clock-scaling test on decode showed ~84 ms/token was **independent of the GPU
core clock** — a sign the bottleneck was memory, not compute. The MIF (DRAM
interface) devfreq was sitting at its **421 MHz floor** (max 3172 MHz) during GPU
workloads, even though a CPU memory stress (`md5sum`) *would* ramp it.

### Root cause
The `gs201-ppc` performance counters that drive the `bus-mif` `simple_ondemand`
governor are wired to the **CCI memory ports** — i.e. CPU/coherent traffic. The
G710 reaches DRAM on a path those counters do **not** observe, so a pure-GPU
workload looks idle to the MIF governor. The closed AOSP stack couples GPU DVFS to
a MIF bandwidth QoS vote (`pixel_gpu_dvfs_qos.c`: per-OPP `int_min`/`mif_min`);
mainline Panthor has no such coupling.

### Fix (kernel, upstream-idiomatic — DT + defconfig only)
Wire the GPU into the standard **interconnect (ICC) framework** so Panthor's
per-OPP bandwidth vote raises the memory clock, exactly as the OPP core already
supports:

- `bus_mif` becomes the DMC interconnect **provider** (`#interconnect-cells`,
  `samsung,data-clock-ratio=8`) — a bandwidth vote maps to a `MIN_FREQUENCY`
  `dev_pm_qos` floor of `peak_kBps / 8` kHz, composing with `simple_ondemand`.
- A **passive `bus_int`** exynos-bus node (ACPM INT clock) is the source node of
  the path `GPU → bus_int → bus_mif`. **A two-node path is required**: the ICC
  core's `apply_constraints()` only calls the provider `.set()` for the *second*
  node of a hop, so a single-node self-path (`<&bus_mif &bus_mif>`) is a no-op and
  panthor probe dies with `-EINVAL`. The real path also votes INT, matching AOSP's
  `int_min`+`mif_min`.
- The GPU OPP table carries `opp-peak-kBps` per level (top OPP = 25.376 GB/s → MIF
  3172 MHz).
- defconfig: `CONFIG_INTERCONNECT_SAMSUNG=y`, `CONFIG_INTERCONNECT_EXYNOS=y`.

Chain: panthor `dev_pm_opp_set_rate` → OPP core `_set_opp_bw` → `icc_set_bw` →
`exynos-generic-icc` → `dev_pm_qos` MIN_FREQUENCY on `bus_mif` (+`bus_int`).

### Result
GPU at 848 MHz auto-raises MIF **421 → 3172 MHz** with zero manual tuning, and
drops back to the floor when the GPU idles (load-gated, no idle-power regression).
Recovered ~1.4–1.5× across prefill, decode, and OpenCL bandwidth.

Commits: kernel `felix` branch (`gs201.dtsi`), boot-img `feature/linux-kernel`
(`felix.config` + gitlink).

### rusticl / OpenCL confirmation
The same MIF fix, measured via clpeak, cleanly separates what's memory-bound from
what isn't:

- **Bandwidth-bound work improved**: clpeak global BW ~4 → **11.9 GB/s**, and the
  clpeak compute stage — which used to *hang* — now completes (starvation was the
  trigger). First open clpeak compute numbers: FP32 **548**, FP16 **550**, INT32
  **184** GIOPS (INT ≈ closed's 189).
- **Shared-mem/register-bound work unchanged**: the hand GEMMs are flat
  (`gemm_cl` 23.5, `gemm_cl2` 77.2 GFLOPS) — MIF clock never touches on-chip LS
  traffic. This is the compiler half, isolated.

---

## Part 2 — The compiler gap

### Is it purely the compiler? (yes — proven without the closed blob)

The closed `libmali` is NDA and clean-room contamination rules forbid
disassembling it (or the public Android Mali blob) to guide panfrost. So instead we
**characterized the silicon directly** — clean, upstream-legitimate, no proprietary
code in the loop.

The decisive isolation is clpeak FP32, a **register-light** MAD kernel: **closed
730 vs open 548 GFLOPS, both at 848 MHz on the same 7-core silicon, same kernel
source**. A register-light kernel doesn't spill, so RA can't explain it — same
clock, same cores, same HW config. It can only be the compiler. The gap
decomposes into a **codegen-efficiency** factor (visible even register-light) and a
**register-allocation** factor (register-heavy shaders on top).

### FMA throughput characterization (`fmabench.c`)

Directly measuring achieved FP32 FMA throughput vs instruction-level parallelism
(independent accumulators), on the open stack:

| ILP (accumulators) | registers | threads | GFLOPS |
|---|---|---|---|
| 8  | 12 | 2 | 452 |
| 16 | 20 | 2 | 547 |
| 24 | 28 | 2 | 587 |
| 32 | 36 | 1 | 608 |
| 48 (explicit scalars) | 52 | 1 | 631 |
| 56 (explicit scalars) | 60 | 1 | **637** |

- Panfrost's real FMA peak is **637 GFLOPS = 87% of closed's 730** with hand-tuned
  ILP. clpeak's 548 merely **under-provisions ILP** for Valhall.
- Throughput is **ILP/register-file bound**: it climbs with in-flight FMAs until
  the 64-register file is full (~60 regs), then can go no further.
- Using a `float a[N]` **array** caps at 608 and falls off a cliff at N≥34: the
  loop stops unrolling (`max_unroll_iterations=32`), the array becomes
  dynamically-indexed and spills to **scratch** → 69 GFLOPS. Explicit scalar
  accumulators avoid the array and reach 637.

### Every simple lever — build-tested, all dead or zero-sum

| Lever | Result |
|---|---|
| **Occupancy** (force Threads=2) | Dead. More ILP at Threads=1 (608) beats Threads=2 (≤587). Also wedged the GPU when forced. |
| **FMA+FADD dual-issue** | Dead. FADD shares the FMA pipe (274 vs 455 GFLOPS when mixed). |
| **Immediate constants** (fewer reg reads) | Slower (476 vs 547) — the FAU path has its own overhead, so it's not read-port bound. |
| **LS vectorization** (`PAN_SHARED_ALIGN`) | Dead + dangerous. The `mem_vectorize_cb` alignment check encodes the real **16-byte straddle rule** (`scratch_access_size_align_v9`); relaxing it makes the HW fault → GPU wedge. Not conservatism — hardware. |
| **Deref-to-if-else threshold** | No-op on decode. The scratch there is a 128-byte Q4_K staging buffer, not a small indexable accumulator. |
| **Valhall scheduler / load hoisting** (`PAN_HOIST_LOADS`) | Dead. Disasm confirmed it changed scheduling, but perf was identical — the 3 async message slots already keep the HW-max 3 loads in flight. Throughput-bound, not latency-bound. |
| **Raise unroll limit** (32 → 128) | **Net loss.** FMA +5% but llama **prefill −64%** (33.9 → 12.3): mul_mm re-unrolls into a 1252-spill catastrophe, defeating the shipped `PAN_PRESSURE_UNROLL`. Zero-sum against the register file. |

### The unifying wall
Every path leads to the **64-register file**. It caps FMA ILP (spill at ~33
accumulators), caps the llama GEMM tile (128 accumulators ≫ 64 → spill or
scratch), and makes unroll policy zero-sum (helps register-light, crushes
register-heavy). The closed compiler uses the same register file ~13–20% more
efficiently — via better spill/schedule co-design that we cannot reverse-engineer
without the (forbidden) closed compiler as a reference.

### What *did* ship on the compiler side
- **`PAN_PRESSURE_UNROLL`** — demotes forced SPIR-V unroll hints so NIR's cost
  model decides, keeping register-heavy GEMMs rolled instead of spilling (~2×
  prefill on the shaders that carry `[[unroll]]`). Committed to `felix-g710`.
- **gpu_id normalization** (`panthor_kmod.c`) — the gs201 Panthor kernel reports
  `gpu_id` with the arch nibbles in bits [15:0] (compact) instead of [31:16], so
  Mesa decoded arch 0 and PanVK rejected the G710 → llvmpipe fallback. Detect and
  expand the compact form. **Without this the open GPU doesn't run at all.**

---

## Part 3 — Status

| Item | Where | State |
|---|---|---|
| MIF interconnect coupling | kernel (`gs201.dtsi`) + defconfig | **Shipped** (`felix` / `feature/linux-kernel`) |
| `PAN_PRESSURE_UNROLL` | Mesa `felix-g710` | **Shipped** (`c00a209`) |
| gpu_id normalization | Mesa `felix-g710` | Committed with this work |
| FMA / codegen residual (~13–20%) | Mesa panfrost Valhall backend | **Research-grade**; register-pressure-aware unrolling is the only non-dead lever, not yet tractable |

The residual codegen gap is **not a knob**. The one lever with a real mechanism —
register-pressure-*aware* unrolling (unroll iff the unrolled live-set fits 64
registers) — requires a pre-RA pressure estimate that accounts for post-unroll
array scalarization. That's genuine compiler research, not a config change, and is
left as future work rather than shipped as the (proven) zero-sum regression.

---

## Part 4 — Reproduction

Harnesses (clean-room; they characterize the silicon, no proprietary code):

- `panthor-mesa-artifacts/fmabench.c` — ILP-swept FP32 FMA + FMA/FADD-mix kernels;
  reports achieved GFLOPS. `fmapure.c` (single-kernel, for clean disasm/shaderdb)
  and `fmascalar.c` (explicit-scalar generator, defeats array-rolling) accompany it.
- Build on-device: `gcc -O2 fmabench.c -o fmabench -lOpenCL`.
- Run under rusticl:
  `RUSTICL_ENABLE=panfrost OCL_ICD_VENDORS=<mesa>/libRusticlOpenCL.so \
   LD_LIBRARY_PATH=<mesa> ./fmabench <ACC> <global_size> <iters>`.
- Compiler stats / disasm: prefix with
  `MESA_SHADER_CACHE_DISABLE=true BIFROST_MESA_DEBUG=shaderdb` (or `=shaders`).

Fast native Mesa build loop on-device (`.138`, `/userdata/mesa`): the build breaks
on `mesa_clc` linking only because `/usr/lib/llvm-19/lib/libclang-cpp.so` is a
0-byte stub — the real `libclang-cpp.so.19.1` is installed. `sudo ln -sf
libclang-cpp.so.19.1 libclang-cpp.so` unblocks it permanently (~20 s incremental
builds thereafter).

GPU/MIF pinning for measurement:
- GPU: `echo userspace > /sys/class/devfreq/28000000.gpu/governor;
  echo 848000000 > .../userspace/set_freq`.
- MIF now auto-couples via the interconnect fix; to force it manually,
  `echo <hz> > /sys/class/devfreq/bus-mif/min_freq`.

---

## Session 2026-07-14: unrolling dead, prefill root-caused as occupancy-1 latency

Two levers pursued to closure, both instrumented and measured on `.138` (PanVK,
GPU pinned userspace@848 MHz, `MESA_SHADER_CACHE_DISABLE=1` so env-gated compiler
changes aren't served stale from the shader cache).

### 1. Register-pressure-aware force-unroll — DEAD (proven)
Built a per-loop pressure gate in `bifrost_nir.c` (force `nir_loop_control_unroll`
when loop-carried phis + IV-indexed temp-array lengths ≤ budget, trip ∈ [1,cap]).
- llama: **0 firings** even wide-open (budget=1000). NIR's cost model already
  unrolls known-trip loops ≤32; the hot `mul_mm` K-loop has a runtime-dynamic trip
  (`max_trip_count=0`) so it's ineligible and un-fully-unrollable anyway.
- Engineered a Vulkan probe (`vkcompute.c` + fixed-trip-48 register-light shader)
  that *does* fire the gate: unrolls correctly, **zero speedup** (~675 GFLOPS both).
  The rolled loop is already FMA-pipe-saturated (8-way ILP hides latency; Valhall
  loop overhead is negligible). Premise falsified. Reverted;
  patch → `panthor-mesa-artifacts/pressure-unroll-force-gate.patch`.

### 2. llama PREFILL root cause: occupancy-1, memory-latency-bound
`BIFROST_MESA_DEBUG=shaderdb` on a real prefill (demote ON = production):

| metric | value |
|---|---|
| total shader-cycles | 3339 |
| cycles in occupancy=1 shaders | **88%** |
| cycles in spilling shaders | 73% |
| hot shaders | 100% load/store-bound (cycles == ls, FMA ~99% idle) |

Top shaders are pinned at **1 thread / 64 registers** (the accumulator tile fills
the file, leaving no room for a 2nd warp to hide load latency). The FMA units are
not the bottleneck — a register-light Vulkan FMA probe hits **682 GFLOPS ≈ 93% of
closed 730**.

**The demote is essential:** disabling `PAN_PRESSURE_UNROLL` *doubles* total
shader-cycles (3339 → 7257) as every matmul unrolls and spills (33k–43k spill cost).

**Force-2-thread occupancy — REGRESSES 2.2×.** Added `PAN_OCC2` to `bi_ra.c`
(pre-spill SSA to 32 so the existing 2-thread RA attempt succeeds). Shaders flip to
2-thread/32-reg as intended, but pp128 drops **33.9 → 15.4**: spill *bandwidth* on
already-LS-bound matmuls outweighs latency-hiding, and the 2nd warp then contends
for the same saturated bandwidth. Reverted;
patch → `panthor-mesa-artifacts/occ2-force-occupancy.patch`. Register demand is
**intrinsic** to the tile, so 2-thread is unreachable without spilling.

### Conclusion
Panfrost codegen is **not** leaving large easy performance on the table for llama
prefill; the bottleneck is intrinsic latency-bound matmuls. The headline "124 (closed)
vs 34 (open) pp128" is **confounded** — `.108` closed runs a different llama backend
(libmali OpenCL), not the same Vulkan shaders, so it is not a compiler A/B (a clean
same-shader comparison is impossible: rusticl OpenCL on `.138` is dead — no ICD +
Rust-frontend build failure — and there's no Vulkan on AOSP `.108`). Remaining levers
are all hard/uncertain: the 65-loop / 583440-spill pathological shader (~33% of
cycles, likely inlined Q4_K dequant), llama.cpp Vulkan tile tuned for Valhall's
32-reg/2-thread sweet spot (source, not codegen), or software-pipelining for MLP at
occupancy 1.

### Spikes: which in-scope lever, given latency-bound prefill

Constraint: **no llama.cpp changes.**

**Boundedness (decisive cheap test).** Scale clocks and watch throughput. Dropping
*both* GPU and MIF 40% (848→510 MHz; MIF is coupled to GPU by our interconnect fix)
costs only **10%** of pp128 (33.86→30.52). Neither compute (GPU clock) nor bandwidth
(MIF) binds ⇒ **memory-latency-bound**. (A clean MIF-only sweep is blocked by our own
interconnect `dev_pm_qos` MIN floor — under GPU load it holds MIF at max and userspace
can't undercut it. Working as designed.)

**Spike 2 — llama.cpp Valhall tile: OUT OF SCOPE.** For the record it is the *clean*
route to 2-thread occupancy (a smaller `warptile` per-thread tile `tm×tn` fits ≤32 reg
with no spilling — the opposite of OCC2). ggml-vulkan.cpp picks l/m/s by shared-memory
fit; no coopmat on G710 so the scalar path gives per-thread accumulator tiles l=4×4,
m=4×2, s=2×2; llama already rolls the BK loop via `ggml_vk_roll_bk_loop`. But changing
the tile is a llama.cpp host change → excluded. The driver cannot change the tile, only
how it compiles the given shader.

**Spike 3 — MLP / software pipelining: capped by hardware.** The right lever for a
latency-bound kernel in principle (hide latency with more in-flight loads, no extra
traffic). But the packed Valhall schedule already uses **all 3 async message slots**
(slot0/1/2 ≈ 1110 each) with partial wait-batching (wait012=173 alongside ~900 single
wait0/1/2). **3 message slots is a hardware cap** → at most 3-deep MLP per thread, which
cannot hide hundreds-of-cycles DRAM latency at occupancy-1. Deeper scheduler batching
is a modest, bounded win for a large scheduler effort.

**Spike 1 — 65-loop spill monster: bounded, being characterized.** ~33% of cycles,
highest spill cost (583440, 255:615). Because prefill is latency- not bandwidth-bound,
cutting spill *traffic* may not move throughput much — though spill *fills* are
themselves latency-exposed loads, so some gain is plausible. Under active investigation.

### Synthesis
llama prefill is memory-latency-bound at occupancy-1. The only lever that truly hides
that latency is 2-thread occupancy, which needs a smaller tile — blocked either by
llama.cpp source (out of scope) or by spilling (proven −2.2×). The 3 async message slots
cap what single-thread MLP can recover. Net: panfrost codegen is not the bottleneck, and
the in-scope driver levers offer only modest bounded gains. The durable deliverable is
this diagnosis + the reusable `vkcompute` Vulkan-compute harness + the saved patches
(`pressure-unroll-force-gate.patch`, `occ2-force-occupancy.patch`).

### Spill monster characterized: a rematerialization gap (fixable, general)

The 65-loop / 583440-spill-cost shader (~33% of prefill cycles) is a **Q4_K
dequant/unpack kernel**, not a matmul — its op mix is integer bit-manipulation
(IADD, IMUL, LSHIFT_OR/AND, RSHIFT, ICMP, CSEL, CLZ dominate; fma ≈ 9). Disassembling
its region shows **~1768 thread-local spill/fill ops** (`STORE.i32.tl` 498 +
`LOAD.i32.tl` 536 + `flow*.tl` fills) against only **~588 real global loads** — so
**~75% of its memory traffic is spilling, not data.**

**Root cause — the spiller can't rematerialize what this kernel is made of.**
`bi_spill_ssa.c:can_remat()` rematerializes only *constant-sourced* ops: `IADD_IMM`
(with `only_const_sources`), `LD_PKA` (constant address), `MOV` (constant/FAU). It does
**not** remat register-sourced `IADD`/`IMUL`/`LSHIFT`/`RSHIFT` — exactly the
address/index/bitfield arithmetic a dequant kernel is built from. Under register
pressure it therefore *spills those computed i32 values* (all the `.i32.tl` traffic)
instead of recomputing them. The post-SSA LCRA spill path (`bi_ra.c:770`, "spill after
every store, fill before every load") has no remat at all.

**Fix (concrete, upstream-clean, general):** extend `can_remat`/`remat_to` to
single-level rematerialization of register-sourced ALU (`IADD_IMM` with a reg source,
`IMUL`/`LSHIFT`/`RSHIFT` by a constant) when the operands are live at the fill point —
recompute cheap addresses/indices instead of spilling them. Benefits any
pressure-heavy integer kernel, not just llama.

**Caveat on payoff:** prefill is latency-bound and `.tl` spills hit *fast local memory*
(not DRAM), so cutting the spill *count* may not translate 1:1 to throughput — it must
be measured. But this is the one remaining in-scope lever with a real, generalizable
mechanism behind it.

### Fix implemented: rematerialization in the spiller (+1.6% prefill, validated)

Extended panfrost's rematerialization to the two spill paths, both **safe by
construction** and **default-on** (opt-out `PAN_NO_LCRA_REMAT` / `PAN_NO_REMAT_REG`):

1. **`bi_ra.c` LCRA spiller** (`bi_spill_register`) — this post-SSA path, not
   `bi_spill_ssa`, is where the monster's 615 fills come from (`bi_spill_ssa` does
   ~14 fills across *all* of llama). At each fill, if the spilled value's def is a
   single-32-bit `MOV_I32`/`IADD_IMM_I32` with **constant/uniform** sources,
   recompute it instead of `LOAD.tl`. Const/FAU sources never change → value-
   identical, no liveness needed. (Register sources are unsafe here: post-
   `bi_out_of_ssa`, a reg source may be redefined between def and use — tried and
   reverted.)
2. **`bi_spill_ssa.c`** (`insert_reload`) — opportunistic reg-sourced remat of
   `IADD_IMM` when the source is live in `W` at the reload site (SSA form ⇒ single
   def ⇒ safe); the spilled memory copy is always a fallback.

**Result:** monster fills 615→597; **pp128 33.89→34.42, pp256 31.65→32.18 (+1.6%)**,
consistent across rounds. **Correctness:** greedy token IDs byte-identical off vs on
(validated with `gentest.c`, a minimal `libllama`+Vulkan greedy generator). Small,
but the first real forward step on prefill — and a clean, general, upstreamable
panfrost improvement that never touches llama.cpp.

**Remaining headroom / TODO:** the ~597 still-filled values are register-sourced
(computed addresses, loaded data). Catching them needs SSA-preserving reg-remat in
the LCRA (a single-def check) — the larger "RA doesn't know rematerialization" work.
Also: precompute a def-map instead of the current O(n)-per-spill scan (compile time).

> **UPDATE (see 2026-07-27 below): the "single-def reg-remat in the LCRA" TODO
> immediately above was subsequently implemented, validated correct, and found
> perf-dead — it is NOT open headroom. Do not re-attempt it. The live next lever
> is *cost-model-gated* remat.**

---

## Session 2026-07-27: device offline — log reconciliation (single-def reg-remat is DEAD, not open headroom)

Autonomous grounding pass. `.138` was **offline** (no host-reachable IP), so no
on-device build / benchmark / token-validation was possible — **the measured chase
could not advance this session.** Two corrections were banked by cross-checking the
git trees and session memory against this log:

### 1. The "single-def reg-remat" TODO above was already done, and it's DEAD
It was implemented, validated, and reverted on **2026-07-14**; this log never
recorded the outcome. The saved `panthor-mesa-artifacts/lcra-reg-remat-singledef.patch`
*is* that reverted attempt (re-reviewed this session):

- **Correctness sound** — greedy token IDs byte-identical off-vs-on. The safety
  argument (single-def ⇒ SSA-value-stable post-out-of-ssa; def dominates the fill so
  sources are available; `value < orig_ssa_alloc` excludes spill temps; `!src.memory`
  excludes already-spilled sources) holds.
- **No perf win → wash / slight regression.** Naive reg-remat hits the **remat
  pressure trap**: recomputing a value at each fill *extends its source operands' live
  ranges*, adding register pressure that offsets the fill savings. It also caught only
  a few of the monster's fills — most are multi-def or `LOAD.i32`, not single-def
  `MOV`/`IADD_IMM`.

So single-def reg-remat joins the proven-dead list. Const-only remat (`3ca7ae7`,
+1.6%) remains the shipped state.

### 2. Refined next lever = pressure/cost-model-*gated* reg-remat
Not a safety check — a **cost model**. Remat only when it does **not** push the
live-set past the 64-reg budget, *or* when the source is **already live** at the fill
point (no live-range extension). This is the real "RA doesn't know rematerialization"
project. Its value is entirely empirical and **measurement-gated on the device**;
per this log's own "keep only measured wins" rule it was NOT implemented blind here.

### Tree / backup status (verified)
The validated const-only remat is safely on **`origin/felix-g710 @ 3ca7ae7`**
(github `junkyard-computing/mesa`) — not at risk of a device-wipe loss. Host
`mesa-fork` was fast-forwarded `c00a209 → 3ca7ae7` to match. The authoritative
on-device tree at `/userdata/mesa` is unreachable while `.138` is down.

**Net:** the measured open-vs-closed chase is blocked on the device being online
(+ a human at the bench). When `.138` is back and SSH-reachable, the on-device
build+benchmark can be driven autonomously; the first lever to try is
**cost-model-gated remat**, and **single-def reg-remat must not be re-attempted.**

### Correction (same day): `.138` was NOT down — and the lever's workload is what's missing

`.138` is up at **`192.168.1.138`** (bench subnet is `192.168.1.x`, not `10.x` —
the earlier "offline" call probed the wrong subnet). AOSP oracle `.108` is up at
`192.168.1.108`. On-device state after mounting `/userdata` (`sda31`, manual mount,
mountpoint had to be `mkdir`'d on this fresh 00127 boot):

- **Present & working:** Mesa source `/userdata/mesa/src`; harnesses
  `/userdata/gpuwork/` (`vkcompute`, `fmabench`, `gentest`, `probe.spv`); built libs
  `/opt/mesa-g710/lib` (rusticl + PanVK) and system `panvk-g710.json` ICD; GPU pin
  (`userspace`@848) + Vulkan measurement path **verified**; driver = const-only remat
  (`3ca7ae7`).
- **MISSING (wiped by the 00127 rootfs reflash of `/home/kalm`):** `llama-vk` +
  the `qwen2.5-0.5b-q4km.gguf` model. No `.gguf`, no `llama-bench`, no
  `libggml-vulkan` on device.
- **The saved `.spv` are NOT the monster.** `/userdata/gpuwork/*.spv` are all
  `mul_mat_vec_q4_k_*` — the **decode** path. `mul_mat_vec_q4_k_f32_f32.spv`
  compiles to **0:0 spills:fills, 37 regs, 1 thread** (shaderdb) — register-light, no
  spilling. The spill monster is `mul_mm` (**prefill** matrix-matrix Q4_K), which is
  generated inside ggml-vulkan at prefill time and needs `llama-vk` + a model to
  materialize.

**Consequence:** the cost-model-remat lever targets the prefill monster, so its only
faithful metric (llama prefill spills/fills + pp t/s) is unavailable until `llama-vk`
+ a model are restored. Options to unblock: (a) rebuild `llama-vk` on-device + restore
the `.gguf` model (real metric); (b) engineer a synthetic register-heavy spilling
integer shader as a vkcompute proxy for the LCRA reg-remat path (autonomous, but a
proxy, not the real monster). The register-light microbench path (`fmabench`/
`vkcompute` FMA) is intact but already at the ~90%+ codegen wall — no headroom there.

### Workload restored + fresh baselines (2026-07-27, both devices live)

Chose option (a). Rebuilt `llama-vk` on `.138` from scratch (reflash had wiped it):
apt'd the Vulkan toolchain (cmake/ninja/glslc/vulkan-headers/spirv-headers),
`git clone` llama.cpp, `-DGGML_VULKAN=ON`, and re-downloaded
`qwen2.5-0.5b-q4km.gguf` (491 MB). Build at `/userdata/llmwork/`.

**Fresh scoreboard @ 848 MHz:**

| metric | value | note |
|---|---|---|
| closed FP32 (`.108` clpeak, libmali) | **725–737 GFLOPS** | float→float16; confirms the "closed ~730" anchor live |
| open pp128 (`.138` PanVK, pre-remat `/opt` driver) | **33.84 t/s** | matches doc baseline |
| open tg64 | **9.53 t/s** | |
| **monster** `mul_mm` Q4_K (shaderdb) | **5463 instrs, 1114 cyc, 65 loops, 255:615 spills:fills, 583440 cost, 64 reg, 1 thread** | exact reproduction of the documented monster |

Note the installed `/opt/mesa-g710` driver is the **pre-remat** build (615 fills),
so it is a clean anchor to A/B remat against (const-only `3ca7ae7` gave 597).

**Fill-population characterization (disasm of a real prefill):** 1036 `LOAD.i32.tl` +
889 `STORE.i32.tl` across prefill (~615 fills in the monster). Consecutive fills load
**distinct** values (e.g. `r7` ← `byte_offset` 8,12,16,20 — different values, not a
repeated reload), which caps *both* reg-remat reach (few single-def `MOV`/`IADD_IMM`)
*and* reload-coalescing reach (fills are distinct, not redundant). This points at an
**intrinsically large live-set**, not redundancy — corroborating the wall.

### MEASURED: LCRA rematerialization has ZERO reach on the current monster (lever dead)

Built the reg-remat driver on-device and measured, rather than inferred. The reflash
had also wiped mesa's build deps (manually-built SPIRV-Tools static libs, LLVM/clang
dev, meson, mako, X/wayland dev, and the `/mesa/{src,build}` source-path symlinks the
build dir hardcodes) — all restored, driver relinked with the reg-remat change (verified
in the `.so`: `strings` shows `PAN_NO_LCRA_REMAT`/`PAN_NO_LCRA_REG_REMAT`).

Three env-gated tiers, shaderdb, stock llama.cpp master (Q4_K `mul_mm` monster):

| tier | gate | monster spills:fills | total prefill fills |
|---|---|---|---|
| all remat OFF | `PAN_NO_LCRA_REMAT=1` | 255:**615** | 994 |
| const-only | `PAN_NO_LCRA_REG_REMAT=1` | 255:**615** | 994 |
| const + reg-remat (default) | — | 255:**615** | 994 |

**Identical across all three tiers, and across *every* shader in the prefill** (994
fills / 451 spills every time; a per-shader `diff` of the fill columns is empty).
So on the current stock llama.cpp workload, extending remat to register sources — the
queued "lever #1" — reduces fills by **exactly zero**, and even the shipped const-only
remat catches nothing here (vs the Jul-14 monster where const-only caught 18 → 597;
the difference is the newer llama.cpp `mul_mm` codegen, whose 615 fills are entirely
ineligible: loaded data + non-single-def computed values, not cheap rematable ops).

**Verdict: the rematerialization lever is DEAD on this monster — zero reach, not a
pressure-trap issue.** A cost model is moot because there are no eligible fills to gate.
This is the measured confirmation of the intrinsic-pressure wall: the monster's spills
are irreducible by rematerialization. Remaining driver-side theory (all uncertain/large):
reduce the live-set via pressure-aware scheduling to reach 2-thread occupancy (OCC2 by
pre-spilling was already −2.2×; the clean route is a smaller tile = llama.cpp source =
out of scope). The register-light codegen wall (~87–93% of closed) and this measured
register-heavy wall together **quantify** the residual gap.

### Reload-coalescing lever: implemented, modest fill reach, no perf gain

Since remat was dead, implemented **reload coalescing** in the LCRA spiller (driver-only,
no llama.cpp change): reuse a value filled earlier in a block (valid until it is
redefined) instead of filling before every use — gated `PAN_LCRA_COALESCE=1`, restricted
to single-channel spills. Measured (shaderdb): monster **615 → 605 fills** (cost 583440 →
576840), prefill **994 → 984**. Small reach — the monster's 65 loops mean many block
boundaries, and the coalescer resets per block, so the bulk of the ~2.3× reload ratio
(cross-block) isn't captured. pp128 **33.85 → 33.94** (noise, no gain), consistent with
the pressure-saturation wall. Token-identical OFF vs ON (coalescing is correct-by-
construction; verified equal output).

### ⚠ CRITICAL: the reflash-restored toolchain rebuilds a MISCOMPILING driver

While validating, found that the **freshly-rebuilt** `libvulkan_panfrost.so` produces
**garbage** llama output (20× `?`), whereas the **pre-existing `/opt/mesa-g710` driver
(Jul-15) is CORRECT** and CPU is correct:

| stack | "Once upon a time" greedy completion |
|---|---|
| CPU (`-ngl 0`) | "…the world was a place of wonder and discovery. The sun was shining…" ✓ |
| GPU, `/opt` driver (Jul-15) | coherent (wonder/sun/shining/story) ✓ |
| GPU, my fresh rebuild | `????????????????????` ✗ |

**The garbage is NOT the lever patches** — both default to no-op/off, and the fresh
driver's compiler spill/fill counts match `/opt` exactly (615). It is a **build-toolchain
or source regression** introduced when rebuilding on the reflash-restored deps (prime
suspect: the SPIRV-Tools static libs I built from `vulkan-sdk-1.4.309.0`, which mesa links
for SPIR-V optimization; also possible: mesa source is `26.2.0-devel` vs `/opt`'s 25.2.8,
or LLVM 19.1.7). **Consequence:** the runtime pp128 A/B above is on a broken driver and is
not trustworthy as inference perf; the *compile-time* fill-count results (remat/coalesce)
are still valid as compiler behavior. **`/opt/mesa-g710` is the known-good driver** for any
valid perf measurement. Fixing the rebuild (match `/opt`'s SPIRV-Tools/mesa versions) is the
prerequisite for finalizing any driver-side lever on a correct driver.

### Rebuild regression diagnosed: stale-object ABI mismatch (clean rebuild in flight)

Isolated it: with **all** local compiler transforms off (`PAN_PRESSURE_UNROLL=0` + all
remat off) the fresh driver is **still garbage** → not the felix patches. Same source was
correct Jul-14, so the regression is in the rebuild environment. Root cause found: the
on-device build dir `/userdata/mesa/build` had **424 pre-reflash object files (Jul-15)
mixed with 646 newly-compiled ones** — old objects compiled against pre-reflash
headers/libs, new ones against the freshly-installed SPIRV-Tools/LLVM. That ABI mismatch
inside one linked `.so` is a classic silent-corruption → garbage-compute cause (the
incremental build only recompiled what my `bi_ra.c` edits touched, leaving the stale
majority). Fix: **`ninja -t clean` + full rebuild** so every object is from one consistent
toolchain (launched, ~1029 targets); verify GPU output coherent afterward → gives a
known-good *modifiable* driver (vs `/opt`, correct but without the lever-patch tree).
Method notes: isolate GPU-compute correctness with `llama-cli -ngl 0` (CPU) vs GPU greedy
on a raw prompt (`-no-cnv -st`, `cat -v` the output; literal `?` = garbage token IDs;
`-no-cnv` is often ignored for Instruct models → chat mode); `llama-bench` gives throughput
but **not** correctness. Shell gotcha: `pkill -f llama-cli` matches your own SSH shell — use
`pkill -x llama-cli`.


---
# ⚠ RECOVERED SECTIONS (chronological; verify placement)


<!-- [recovered 2026-07-28T16:19:13; auto-placement failed, appended] -->
### Rebuild regression diagnosed: stale-object ABI mismatch (clean rebuild in flight)

Isolated the miscompile: with **all** local compiler transforms off
(`PAN_PRESSURE_UNROLL=0` + all remat off) the fresh driver is **still garbage** → not
the felix patches. The same source was validated correct on Jul-14, so the regression is
in the **rebuild environment**. Root cause found: the on-device build dir
`/userdata/mesa/build` had **424 pre-reflash object files (Jul-15) mixed with 646
newly-compiled ones** — the old objects were compiled against the pre-reflash headers/libs,
the new ones against the freshly-apt/source-installed SPIRV-Tools/LLVM/etc. That ABI
mismatch across a single linked `.so` is a classic silent-corruption → garbage-compute
cause (the incremental build only recompiled what my `bi_ra.c` edits touched, leaving the
stale majority). Fix: **`ninja -t clean` + full rebuild** so every object comes from one
consistent toolchain (launched, ~1029 targets). Verify GPU output coherent afterward; that
gives a known-good *modifiable* driver (vs `/opt`, which is correct but not the tree with
the lever patches). Method notes for the record: isolate GPU-compute correctness with
`llama-cli -ngl 0` (CPU) vs GPU greedy on a raw prompt (`-no-cnv -st`, `cat -v` the output;
literal `?` = garbage token IDs; `-no-cnv` is often ignored for Instruct models → chat
mode); `llama-bench` reports throughput but **not** correctness. Shell gotcha: `pkill -f
llama-cli` matches your own SSH shell — use `pkill -x llama-cli`.


<!-- [recovered 2026-07-29T06:04:39; auto-placement failed, appended] -->
1. **Memory subsystem** — TWO in-kernel fixes, now **fully closed to PARITY**: (a) the mainline
   MIF (DRAM) devfreq governor never saw GPU traffic → coupled GPU DVFS to a MIF bandwidth vote via
   the **interconnect framework** (BW ~4→11.9); (b) the GPU **g3dl2 (L2/bus/memory-interface) clock**
   sat at its 151 MHz idle rate because the mainline OPP only scaled the shader core → **pinned it
   to 996 MHz in panthor** (BW 11.9 → **33.9 GB/s = closed's 34.7**). Both shipped.
2. **Compiler codegen** (the residual, ~1.30×) — panfrost's Valhall backend is register-file bound
   on the **FP path specifically** (integer compute is now at parity too). Research-grade, remains
   open; every simple lever was build-tested dead or zero-sum.

**→ Current validated same-day head-to-head (rc5 vs AOSP, post-g3dl2) is the "g3dl2 FIX VALIDATED
@ PARITY" section at the END of this doc. The table just below is the pre-g3dl2 historical snapshot.**


<!-- [recovered 2026-07-30T00:37:21; auto-placement failed, appended] -->
## ★ DEAD LEVER (structural): "rusticl > PanVK frontend gap" — the NIR pipeline is SHARED (2026-07-29)

Chased the lead that rusticl (OpenCL) emits ~10% faster FP code than PanVK (Vulkan) on the shared
Valhall backend, i.e. a portable frontend/NIR-opt win. **It is not a lever — proven from source, not
just benchmarks.**

Numbers that seeded the lead (note: DIFFERENT benchmarks — clpeak vs vkpeak — different kernels):
| width       | rusticl clpeak | PanVK vkpeak | libmali vkpeak |
|-------------|----------------|--------------|----------------|
| fp32-scalar | 558.8          | 477.3        | 685.7          |
| fp32-vec4   | 725.3 (↑30%)   | 391.1 (↓18%) | 716.6 (↑)      |
| fp16-vec4   | —              | 893.0 (↑88%) | 1407.8 (↑)     |

The eye-catcher was PanVK's fp32-**vec4 regressing below its own scalar** while both rusticl and
libmali speed up. But the source kills it as a frontend lever:

1. **Both frontends feed byte-identical shared pipelines.** PanVK (`panvk_vX_shader.c:507`) and
   gallium/rusticl (`pan_shader.c:114,561`) both call the same `pan_preprocess_nir` (the whole
   `bi_optimize_loop`: `nir_opt_vectorize`, `nir_opt_load_store_vectorize`, algebraic, DCE, CSE) and
   the same `pan_shader_compile`→`pan_postprocess_nir` (backend). PanVK's own comment
   (`panvk_vX_shader.c:480`): the shared stage runs the opt loop and *"Nothing here should be
   API-specific."* There is no per-driver NIR-opt pipeline to diff — it's one pipeline.
2. **fp32 has no frontend vectorization lever.** `bi_vectorize_filter` (`bifrost_nir.c:109`) returns
   width **1** for 32-bit ALU (Valhall packs only 16/8-bit), so fp32-vec4 = 4 scalar FMAs for BOTH
   frontends. A frontend cannot change fp32 arithmetic codegen. (fp16/fp8 packing is also in the
   shared filter → shared.)
3. **The only frontend-specific NIR is memory-model lowering** — PanVK lowers Vulkan
   descriptors/SSBO/UBO/push_const/global/shared via `nir_lower_explicit_io`
   (`panvk_vX_shader.c:844-906`); rusticl uses raw CL global pointers. That is API-inherent
   *addressing*, not a missing opt pass. The shared backend still re-runs `nir_opt_load_store_vectorize`
   (`bifrost_nir.c:357`, gated by `mem_vectorize_cb` alignment) over PanVK's lowered loads, so even
   descriptor loads get re-coalesced.

Conclusion: the clpeak-vs-vkpeak FP numbers compare different kernels through different memory models;
the fp32-vec4 "regression" is a property of vkpeak's vec4 descriptor-load kernel, not a PanVK codegen
defect. **No portable frontend-opt win exists, and none of this touches the llama int8/IDPADD path**
(also the identical shared pipeline; already characterized as a broad ~2× codegen-maturity gap, no
single lever). The one theoretical residual — weaker Vulkan-descriptor alignment making
`mem_vectorize_cb` bail → narrower PanVK loads — is API alignment-plumbing, memory-bound-only, capped,
and would need a full rusticl+vulkan rebuild with forced-stderr shaderdb just to observe (shipped
release build routes shaderdb through a debug-callback neither clpeak nor vkpeak registers → no stats
without a rebuild). Not worth a heavy flaky-device rebuild for a capped synthetic-FP upside.

**Loop stopped** per its own stop condition ("STOP if the gap proves to be a benchmark artifact or
FP-only with no int-dot/llama relevance"). Both are true. The honest remaining open-vs-closed headroom
is broad panfrost codegen/scheduling maturity (no single lever) — already the standing conclusion.


<!-- [recovered 2026-07-30T00:55:46; auto-placement failed, appended] -->
## ★ DIAGNOSTIC: coopmat is dead as a parity lever — NEITHER driver uses it (2026-07-29)

Settling the "option 2 (codegen) vs option 3 (cooperative_matrix feature)" fork before committing:
- **PanVK implements zero `VK_KHR_cooperative_matrix`** (empty grep across `src/panfrost/vulkan/`).
- **libmali (.108, v1.r54p2) does NOT advertise `VK_KHR_cooperative_matrix` either** (`vulkaninfo | grep
  -i cooperative` empty).
- **llama.cpp reports `int dot: 1 | matrix cores: none` on BOTH** drivers → both run llama down the
  identical integer-dot-product `mmq` path (`matmul_q4_k_q8_1` → IDPADD).

Therefore libmali's ~2× is **raw codegen quality on the same shader path** — NOT a feature panfrost is
missing. Option 3 (implement coopmat in PanVK) is thus a *speculative novel* optimization (might beat
libmali, might not — the closed driver proves you don't need it), not a catch-up lever. **Option 2 is
the confirmed target.** Constraint: we cannot disasm libmali (clean-room wall), so option 2 = improve
panfrost's OWN codegen guided by its own shaderdb signals, not by an oracle. Go/no-go gate = profile
the real `matmul_q4_k` shader at the instruction-selection/scheduling level (never done — prior work
only measured spill/occupancy) to see if the 2× is a systematic fixable pattern or diffuse maturity.
Needs the light vulkan-only debug rebuild (proven in "loop iter 5").


<!-- [recovered 2026-07-30T01:04:28; auto-placement failed, appended] -->
## ★★★ REFRAME: the llama matmul is LOAD/STORE-ISSUE BOUND, not arithmetic — libmali PROVES ~2× mem traffic is removable (2026-07-29)

Profiled the REAL `matmul_q4_k` shaders (no rebuild needed after all — the shipped release build DOES
honor `BIFROST_MESA_DEBUG=shaderdb`/`shaders`; earlier empty dumps were Mesa's on-disk shader cache
serving llama's pipelines without recompiling. Fix: `MESA_SHADER_CACHE_DISABLE=true`). shaderdb on
`.138` PanVK, pp8:

```
11519 instrs, 1013 cycles, fma 10, cvt 116, sfu 143, ls 1013, 1 thr, 10:2 spills   <- cycles == ls
 5463 instrs, 1096 cycles, fma  9,             ls 1096, 1 thr, 255:597 spills       <- cycles == ls
10235 instrs, 1377 cycles, fma 26,             ls 1377, 1 thr, 292:577 spills       <- cycles == ls
```

**In every matmul shader the compiler's cycle estimate EQUALS the load/store count.** Arithmetic
(fma/cvt/sfu) is fully hidden under LS — these shaders are **100% load/store-issue bound.** The entire
prior chase (spills, occupancy, remat, coopmat, RA) mis-framed the wall as arithmetic/register codegen.
It is a **memory-issue-rate** wall.

Memory-op histogram (disasm, all matmul shaders), split thread-local (spill/fill) vs global:
- **spill/fill `.tl`**: 1209 `LOAD.i32.tl` + 1062 `STORE.i32.tl` ≈ 2372 ops, ~all narrow 32-bit
  (spilled values are scalar → `bi_memmov_to` per-SSA-value at `bi_spill_ssa.c:427`; not a
  failure-to-widen, the values ARE scalar).
- **global/shared**: 3976 `LOAD.i32` + 3625 `STORE.i32` dominate; `LOAD.i128` only 91, `STORE.i128`
  218. ~90% of ALL memory ops are narrow 32-bit.

**The key argument (why this is a real, non-speculative lever):** LS throughput is fixed silicon (same
G710). libmali is ~2× faster on an LS-bound shader ⟹ libmali MUST issue ~2× fewer effective memory
ops. So ~2× of panfrost's memory traffic is **removable in principle** — libmali's existence proves it,
no oracle/disasm needed. This converts "diffuse maturity, no lever" into a concrete target: **cut the
memory-op count.** Candidate sub-levers, ranked:
1. **Redundant global-load elimination / load CSE across the unrolled body** — the 11519-instr shader
   is LS-bound (1013 ls) with only 10 spills, so its LS is legit+redundant loads, not spills. If the
   heavy unroll reloads the same weights/scales/addresses, GVN/CSE across iterations cuts ls directly.
2. **Fill reduction via remat** — spilling shaders have ~2.3× more fills than spills (597 vs 255; 577
   vs 292) → spilled values reloaded repeatedly. Extending reg-remat (currently only `IADD_IMM_I32`,
   `bi_spill_ssa.c:447`) to recompute more fill sources cuts `LOAD.i32.tl` = cuts ls. (Prior remat
   work was measured on t/s pre-reframe; re-measure specifically on ls/fill count.)
3. **Load widening** — coalesce consecutive narrow global loads to i128 (`nir_opt_load_store_vectorize`
   / `mem_vectorize_cb`, gated by `bytes <= combined_align`). Bounded by whatever ggml already
   vectorized at source; correctness-sensitive (unaligned wide load faults).

Next iteration: pick sub-lever 1 or 2 (both cut `ls` directly, both fully driver-side/upstreamable,
neither touches llama), implement, and measure the **ls-count delta** (fast inner signal via shaderdb)
before even needing a thermal t/s A/B. GO decision for option 2 = confirmed.


<!-- [recovered 2026-07-30T01:34:37; auto-placement failed, appended] -->
### Iter 2 (2026-07-29): localized the LS traffic to `.wls` shared-mem staging; widening DEAD, unroll-demote NO-OP; pressure-reduction is the live lever

Disassembled the matmul shaders and classified the memory ops:
- **The dominant ls ops are `.wls` = workgroup local storage (shared memory)** — the tiled-matmul's
  stage-to-shared/load-from-shared, NOT global weight loads. `STORE.i32.wls` → barrier →
  `LOAD.i32.wls`, one 32-bit word each, in long unrolled runs.
- **351 of 371 `.wls` loads use `byte_offset:0` with the address computed in a register** (distinct
  per-access bases). The offsets are RUNTIME per-thread values (the shader's swizzled tiling), not
  compile-time constants. `nir_opt_load_store_vectorize` merges only constant-offset-adjacent accesses
  → runtime-addressed scalars are fundamentally unmergeable. **Sub-lever 3 (load widening) is DEAD** —
  the narrowness is inherent to the shader's per-thread shared-mem access pattern, not a driver miss.
  (Confirmed the vectorizer DOES run on shared post-lowering: `bi_optimize_late` @ `bifrost_nir.c:1320`
  from `bifrost_compile_shader_nir`, modes include `nir_var_mem_shared`.)
- **`PAN_PRESSURE_UNROLL=1` is a NO-OP** (byte-identical shaderdb) — ggml's shader carries no SPIR-V
  `Unroll` LoopControl hint; the heavy unroll comes from NIR's cost-based `nir_opt_loop_unroll`.

Two shader classes emerge:
1. **Clean matmul** (11519 instr, 1013 ls, only 10:2 spills) — LS-bound purely on legit runtime-addressed
   `.wls` staging. No spill lever, no widening lever. If this is the runtime-dominant shader the gap is
   unfixable driver-side (algorithm-fixed shared-mem volume + 1-thread occupancy exposing LS latency;
   2-thread needs 32 regs but it needs 64 → the known break-even catch-22).
2. **Spilling matmuls** (5463 instr: 255:597 spills:fills / 1096 ls; 10235 instr: 292:577 / 1377 ls) —
   here **~78% of ls is spill/fill traffic**. They spill because unroll pushes pressure past 64 regs.
   **The live lever:** reduce NIR unroll aggressiveness (pressure-aware) so these fit in 64 regs without
   spilling → the ~577-597 dynamic fill-loads vanish → direct ls cut. Needs a rebuild (NIR unroll
   threshold), correctness-safe (fewer unrolls only), fully driver-side.

Iter-3 plan: FIRST confirm which shader class dominates llama runtime (GGML perf breakdown / dispatch
count) — if class 1 dominates, the chase is at its honest floor; if class 2 (the spillers) dominates,
rebuild PanVK with reduced/pressure-aware loop unrolling and measure spill+ls delta then thermal t/s.
Device left at baseline; no driver changes iter 2.


<!-- [recovered 2026-07-30T02:04:33; auto-placement failed, appended] -->
### Iter 3 (2026-07-29): unroll-reduction is a DEAD LEVER — a ~4× regression. Unrolling is load-bearing.

Built PanVK with `nir_opt_loop_unroll` env-gated (`PAN_NO_LOOP_UNROLL`, `bifrost_nir.c:316`), default
off (sanity: unset reproduced baseline shaderdb byte-for-byte). Skipping unrolling transformed the
matmul shaders on paper — biggest shader 11519→4098 instrs, **1013→209 ls, 10:2→0:0 spills, 1→2
threads**; worst spiller 255:597→55:112 spills. Both prior "levers" (spill elimination AND 2-thread
occupancy) fired at once, because rolled bodies fit in far fewer registers.

**But t/s (thermal-controlled A/B, same .so, env toggle, cache disabled) is a ~4× REGRESSION:**
| metric | baseline | PAN_NO_LOOP_UNROLL=1 |
|--------|----------|----------------------|
| pp128  | 75.9 / 75.7 | **19.2 / 17.6** |
| tg64   | 12.48    | 12.22 (~flat) |

The static-ls reduction was an illusion: rolled loops execute their bodies N times, and unrolling is
**load-bearing** — it supplies the register-blocking ILP that hides LS latency in the GEMM. Fully
unrolled at 1-thread WITH spilling beats fully rolled at 2-threads WITHOUT spilling by 4×. This
**definitively proves that for this prefill matmul, ILP dominates occupancy and spill-avoidance** —
panfrost's heavy-unroll strategy is already the right call, and the shaderdb cycle model (cycles==ls)
badly under-weights the ILP that hides that LS latency in practice. Reverted to baseline; source clean.

## ★★ HONEST FLOOR (2026-07-29): every structural lever for the open/closed llama gap is now tested & dead

Across this chase the option-2 (codegen) lever hunt is EXHAUSTED. Each candidate, tested and killed:
| lever | result |
|-------|--------|
| coopmat / matrix-cores | dead — NEITHER driver uses it (libmali's 2× is on the same int-dot path) |
| rusticl>PanVK frontend | dead — shared NIR pipeline; the FP "gap" was a clpeak-vs-vkpeak artifact |
| load/store widening | dead — `.wls` shared-mem offsets are runtime-addressed, unmergeable |
| reduce loop unrolling | dead — ~4× REGRESSION; unrolling is load-bearing ILP |
| 2-thread occupancy (PAN_FORCE_2THREAD) | break-even |
| remat (whitelist + remat-aware eviction) | dead — never fires in a saturated file |
| spiller reload-coalescing | modest fill reach, no perf gain |
| g3dl2 GPU L2/bus clock | ★ THE WIN — memory-BW parity (34 GB/s = closed) |

What remains of the ~2× compute gap is **diffuse backend instruction-selection + scheduling maturity
WITHIN the (correct) heavily-unrolled body** — libmali emits a tighter/better-overlapped unrolled GEMM
on the same silicon and same shader. There is NO single lever; closing it is the broad panfrost-compiler
grind (post-unroll scheduler LS/arith overlap, instruction selection), a multi-week upstream effort, not
an autonomous loop-iterable experiment. Bandwidth parity (g3dl2) was the extractable structural win.
Recommendation: treat the residual as a documented known gap; a deeper push means committing to
panfrost backend-scheduler work as a project, not more lever-hunting.


<!-- [recovered 2026-07-30T03:03:49; auto-placement failed, appended] -->
### Grind iter 1 (2026-07-29): the SCHEDULER is not a lever either — the shader is LS-ISSUE-bound, not latency-bound

Committed to the backend grind; started with latency hiding. Findings, three independent confirmations
that scheduling/scoreboard can't move this:
- **`bi_pressure_schedule` is purely pressure-minimizing + latency-blind** (`bi_pressure_schedule.c`:
  `choose_instr` picks min pressure-delta, bottom-up; bails unless it lowers max pressure, line 263).
  Suspected it re-serialized the unroll's natural MLP. **Disproved: `BIFROST_MESA_DEBUG=nopsched` is
  FLAT** (pp128 75.78 vs 75.76; spills 255:597→255:687). The pass barely fires and isn't the culprit.
- **MLP is HW-capped at 3 slots** (`VA_NUM_GENERAL_SLOTS = 3`, `valhall.h`), round-robin assigned
  (`va_assign_slots`, `counter++ % 3`). At most 3 async loads in flight — can't deepen the pipeline by
  scheduling; it's a hardware ceiling.
- **Wait-NOPs are only ~1.5% of instructions** (592 `NOP.flowN` across ~40k instrs). So exposed
  latency is a minor term; the shader is **LS-ISSUE-RATE bound** — the ~1000 LS ops per matmul shader
  themselves consume the cycles (cycles==ls is literally the issue count). Barely any stall for a
  latency scheduler to recover (~a few % best case, not the 2×).

Conclusion: no scheduling/scoreboard lever exists. An issue-bound shader is moved ONLY by **fewer LS
ops**, and the dominant LS traffic is inherent shared-memory tile staging (runtime-addressed,
barrier-synced — see grind's earlier iters). The 2× is panfrost issuing more LS-cycles than libmali for
the same matmul; whether that's more shared round-trips, spill traffic, or narrower ops is the only
remaining question. No driver changes this iter (nopsched is an env flag; device at baseline).
Grind iter 2 target: LS-op VOLUME — is panfrost issuing avoidable/redundant shared-mem staging vs the
theoretical minimum? That's the last place an issue-bound shader can be helped.


<!-- [recovered 2026-07-30T03:28:01; auto-placement failed, appended] -->
### Grind iter 2 (2026-07-29): widening DEAD both sides; HARD CEILING = panthor has no perf counters

LS-op volume angle:
- The vectorizer ALREADY merges the shared accesses it can: disasm shows 95 `LOAD.i64.wls`, 18
  `STORE.i64.wls`, 2 `LOAD.i128.wls` alongside 371+240 narrow i32. It is NOT leaving mergeable ops on
  the table — the 611 narrow `.wls` ops use runtime-computed offsets (`%reg, byte_offset:0`, per-thread
  indexing) that are fundamentally unmergeable. **Widening confirmed DEAD on BOTH load and store sides.**
  The shared-staging volume is shader-dictated, not a driver inefficiency.

**HARD INSTRUMENTATION CEILING (the real blocker):** the whole "LS-issue-bound" narrative rests on the
compiler's NAIVE static estimate (cycles==ls) — the same model that misled the unroll experiment. To
verify the true bottleneck (is the LSU actually saturated? occupancy? latency? arith?) needs real Mali
HW perf counters. **panthor (mainline kernel driver) exposes NO performance counters** — no perf/hwcnt
ioctl in `panthor_drm.h`, no debugfs, no pps/gfx-pps. (kbase/closed HAS them; panthor doesn't.) And
libmali is a black box (clean-room, can't disasm/instrument). So the diffuse 2× cannot be localized:
no measurement, no oracle. Every driver-side lever that CAN be tested blind is now tested and dead.

**This is the honest floor of the autonomous grind.** Two project-level paths could unblock, both
multi-week, both upstreamable, both needing an explicit decision (not loop iterations):
1. **Implement panthor performance-counter support (KERNEL)** — a known missing panthor feature; would
   give real HW counters to finally localize the gap, then target it. Aligns with the planned kernel pass.
2. **Implement `VK_KHR_cooperative_matrix` in PanVK (MESA)** — the one lever that changes the SHADER
   llama runs (its coopmat mul_mm path, a tighter tiling) via a driver feature, without touching llama.
   Speculative payoff (neither driver uses it today) but it's the only way to sidestep the shader-dictated
   shared-staging bottleneck. Backed by IDPADD/fp16-dot.
Bandwidth parity (g3dl2) remains the extracted structural win; the compute residual is a documented,
measurement-blocked known gap. Device at baseline; no driver changes iters 1-2 of the grind.
