# PanVK `VK_KHR_cooperative_matrix` via `IDPADD_V4I8` — implementation scoping

Prep done offline (device unavailable) by reading the `felix-g710` Mesa tree. Goal: give PanVK a
cooperative-matrix implementation so llama.cpp's Vulkan coopmat matmul path activates on the G710,
lowering the int8 inner product to the `IDPADD_V4I8` dot-product instruction. Upstream-first
(branch off `mesa/main`, not the fork). See [[project_gpu_llama_prefill_occupancy_gap]],
[[project_upstreaming_direction]].

## The key enabler (why this is far smaller than "write coopmat from scratch")

**The bifrost backend ALREADY emits `IDPADD` from the NIR DP4a ops.** `bifrost_compile.c:3564-3575`:
- `nir_op_udot_4x8_uadd[_sat]` → `bi_idpadd_v4u8_to()`
- `nir_op_sdot_4x8_iadd[_sat]` → `bi_idpadd_v4s8_to()`

So the *performance* path is done. The job is to make the coopmat lowering **produce
`sdot_4x8_iadd`** for the int8 accumulate, and IDPADD comes out for free. Op signature (from
`nir_opcodes.py`): `sdot_4x8_iadd(uint32 a, uint32 b, int32 c) -> int32` — a/b are 4×int8 packed in
a u32, c is the i32 accumulator. There's also **`sudot_4x8_iadd`** (signed×unsigned), which matters:
quantized GEMM is typically signed weights × unsigned activations.

## Infrastructure that already exists (reuse, don't write)

- **Generic `src/compiler/nir/nir_lower_cooperative_matrix.c`** (986 lines) — does the high-level
  work: `split_cmat_muladd` decomposes a matrix muladd into subgroup-distributed slices;
  `nir_lower_cooperative_matrix_flexible_dimensions(M,N,K)` fixes flexible dims. Drivers hook the
  per-slice muladd.
- **Template: lavapipe** (`lvp_nir_lower_cooperative_matrix.c`, 808 lines) — a *no-matrix-HW* driver
  (exactly our situation) that lowers coopmat to plain NIR. This is the file to adapt. AMD/NV/Intel
  have their own (`cmat_muladd_amd/nv`) because they target real matrix/dot HW; we're between —
  scalar layout like lavapipe, but emit `sdot_4x8` for the int8 muladd.
- **NIR cmat intrinsics** (`nir_intrinsics.py`): `cmat_construct/load/store/length/muladd/
  unary_op/binary_op/bitcast` — the ops the driver lowering sees.
- **Subgroup permute**: bifrost has `bi_clper()` (CLPER cross-lane) — the shuffle primitive needed
  to lay an 8×8 (or larger) matrix across the 16-lane subgroup. `warp size = 16` on G710.
- **PanVK shader pipeline**: `panvk_vX_shader.c` runs an ordered `NIR_PASS(...)` chain — clear
  insertion point for the flexible-dims pass + our lowering.
- **Caps template**: lavapipe `lvp_device.c:2995` enumerates `VkCooperativeMatrixPropertiesKHR`
  entries {MSize,NSize,KSize, AType,BType,CType,ResultType, scope=SUBGROUP}. Copy the shape.

**No existing coopmat scaffolding in `src/panfrost/` — greenfield there.**

## The four pieces to build

1. **Advertise** — `panvk_vX_physical_device.c` (next to `KHR_shader_integer_dot_product = true` @107):
   set `.KHR_cooperative_matrix = true`, the feature bit, and enumerate properties. Advertise the
   **int8 combo that maps to IDPADD**: A=SINT8, B=SINT8 (and a SINT8×UINT8 combo for sudot),
   C=SINT32, Result=SINT32, scope=SUBGROUP, with M/N/K sizes that tile cleanly onto 16 lanes ×
   4-wide dp (start 8×8×32 or 16×16×32; validate against what ggml requests). Also
   `cooperativeMatrixSupportedStages = COMPUTE`.
2. **Insert passes** — in `panvk_vX_shader.c`: `nir_lower_cooperative_matrix_flexible_dimensions(...)`
   then `panvk_nir_lower_cooperative_matrix()`, gated on `shader->info.cs.has_cooperative_matrix`.
3. **The lowering** — `panvk_nir_lower_cooperative_matrix.c` (adapt lavapipe ~500-800 lines):
   distribute A/B/C across the subgroup (CLPER), lower `cmat_load/store` to the layout, and lower
   `cmat_muladd` for int8 to a K-blocked sequence of **`nir_op_sdot_4x8_iadd`** (or `sudot`). FP16
   muladd → FMA (generic scalar, still gets the driver-tiling/occupancy win, just not IDPADD).
4. **Validate** — CTS `dEQP-VK.compute.cooperative_matrix.*` (khr) for correctness; then llama.

## Phasing

- **P0 — correctness:** advertise + generic scalar lowering (lavapipe-style, no IDPADD yet). Goal:
  ggml's coopmat shaders compile & run correct. May be *slower* than the current fallback — that's
  fine, it proves the pipeline.
- **P1 — the win:** route int8 `cmat_muladd` → `sdot_4x8_iadd` → IDPADD. Measure vs the current
  76/73 t/s (pp128/512) and vs libmali 123/162.
- **P2 — tuning:** tile sizes / subgroup layout / uniform-register use for the accumulator microtile;
  minimize CLPER traffic.

## Open questions to resolve WHEN THE DEVICE IS BACK (these gate the payoff)

1. **Does ggml's coopmat (cm2) path for Q4_K request int8 or fp16 coopmat?** If fp16, IDPADD does
   NOT apply (it's int8) and the win shrinks to driver-tiling only (modest). If int8, full IDPADD
   win. CHECK ggml-vulkan's coopmat shader types + what it queries. This is the single biggest
   payoff determinant.
2. **What exact M/N/K + type combos does ggml enumerate/require?** Must advertise a superset or ggml
   won't select the path. Dump ggml's `VkCooperativeMatrixPropertiesKHR` queries.
3. **Do the cheap `mmq` path FIRST** — `VK_KHR_shader_integer_dot_product` is already advertised;
   ggml's `mul_mmq` might give the IDPADD win with ZERO driver work. Both drivers fell back to fp16
   for Q4_K, so find why ggml didn't pick mmq (quant-type gate? `GGML_VK_*` env? build flag?). If
   mmq lands the int8 win, coopmat becomes lower priority.

## Effort estimate

- Advertise + insert passes: ~½ day.
- P0 lowering (adapt lavapipe): ~1 week to a passing-CTS scalar coopmat.
- P1 IDPADD routing: ~few days (the backend emit already exists; it's producing `sdot_4x8` from the
  int8 muladd + getting the packing right).
- P2 tuning + upstream MR polish (bindings, CTS, review): ongoing.

Bounded, greenfield-but-well-scaffolded, and upstreamable as a clean PanVK feature MR.
