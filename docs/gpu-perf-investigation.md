# Open-GPU performance on mainline felix (Panthor / PanVK vs closed libmali)

Investigation into why the **open** GPU stack (mainline kernel + Panthor DRM +
Mesa PanVK/rusticl) on the Pixel Fold's Mali-G710 was slower than the **closed**
ARM stack (AOSP kernel + kbase + `libmali`), and how much of that gap we closed.

Both stacks run the **same G710 MC7 silicon** — `.108` (AOSP/kbase/libmali, the
closed oracle) and `.138` (mainline/Panthor/PanVK, open). All numbers below are at
a pinned GPU clock of **848 MHz** unless noted.

## TL;DR

The gap had two independent halves:

1. **Memory subsystem** (~1.4–1.5×) — the mainline MIF (DRAM) devfreq governor
   never saw GPU traffic, so GPU workloads ran with memory pinned at its 421 MHz
   floor. **Fixed in-kernel via the interconnect framework** (shipped). This half
   is *closed*.
2. **Compiler codegen** (the rest) — panfrost's Valhall backend is register-file
   bound and ~13–17% behind the closed compiler on raw throughput, more on
   register-heavy shaders. This half is **research-grade** and remains open; every
   simple lever was build-tested and found dead or zero-sum.

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
