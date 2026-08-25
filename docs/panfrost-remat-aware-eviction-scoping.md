# Remat-aware eviction in panfrost's SSA spiller — scoping

Goal: close (some of) the ~1.5× gap by which panfrost compiles the int-dot `matmul_q4_k_q8_1`
shader worse than libmali. Root cause established: the shader is register-heavy and 100% LS-bound;
much of the LS traffic is spill fills; panfrost's rematerialization can't cut it because reg-sourced
remat is *opportunistic* (fires only if a spilled value's sources happen to be live), and in a
max-spilling shader the sources are spilled too. The whitelist-extension patch (`patches/0001`) was
a DEAD LEVER for exactly this reason (never fired; see gpu-perf-investigation.md). llama stays
UNTOUCHED — this is a general Valhall RA improvement; llama is only the measuring stick.

## Where we are in the code (bi_spill_ssa.c)
Implements **Braun & Hack, "Register Spilling and Live-Range Splitting for SSA-Form Programs"** —
the MIN algorithm over **next-use distances**. Eviction candidates are sorted by `cmp_dist` and the
top-k kept in the register working set `W`. `cmp_dist` (line ~571) ALREADY has remat-preference —
**but only for CONSTANT-remat** (`ctx->remat[node]`, the constant/uniform `remat_to` table): it
prefers to spill those, keeping non-rematerializable values in registers. Register-sourced remat
(`can_remat_reg`/`reg_remat_available`, line ~444/481) has **zero eviction influence** and no
source-liveness guarantee — it's a pure reload-time fallback.

## The two coupled changes (this is the hard part)

**A. Eviction preference for reg-remat.** Extend `cmp_dist` (and the `remat` predicate feeding it)
to *also* prefer spilling register-rematerializable values, not just constant ones. Straightforward
in isolation (~a cmp_dist tweak), but useless alone — same reason the whitelist failed.

**B. Keep the (shared) sources live — the structural piece.** For the reg-remat to actually fire,
a value X's sources must be in `W` at X's use points. Braun-Hack's next-use model has no notion of
"recompute from live sources," so we model it by **virtual uses**: when X is chosen for reg-remat
from source A, treat A as used at each of X's use points (extend A's live range to cover them). MIN
then naturally keeps A in `W` near where X is needed → the remat fires and the fill disappears.

**C. The cost model — whether it pays off at all.** Change B *increases* pressure on A (longer live
range). It only wins when A is **shared** — feeds many reg-remat values — so one live A enables many
remats. This is plausible for Q4_K dequant: a loaded weight byte + base address feed multiple
nibble-extractions (LSHIFT/RSHIFT/AND). But the loaded byte itself is a memory value (can't remat),
so the real decision is "keep byte+addr live (cost: 2 regs) to rematerialize N derived nibbles
(save: N fills)" — net win iff N>2 and it doesn't push other values out. The cost model must:
estimate, per candidate cluster, `fills_saved - extra_spills_from_extended_source_liveness`, and
only commit reg-remat (with the virtual-use extension) when positive. Getting this right is the
project; the whitelist dead-lever is the cautionary tale for committing remat blindly.

## Phasing — prototype-first with an early kill gate
- **P0 (spike, ~days): does the mechanism even fire?** Implement B crudely (no cost model): for
  every `can_remat_reg` value, add virtual uses of its reg sources at its uses; extend `cmp_dist`
  (A) to prefer spilling them. Build, correctness (CTS `dEQP-VK` spill tests + llama token-identical),
  and — critically — measure with **thermal-controlled back-to-back A/B** (the +5% mirage lesson).
  GATE: if fills on `matmul_q4_k_q8_1` don't drop AND pp512 doesn't move beyond noise → the shared-
  source premise is false → STOP, it's the wall. (Crude B may regress other shaders from pressure —
  that's fine at P0, we're only checking the mechanism fires and helps the target.)
- **P1 (if P0 fires): the cost model (C).** Add the per-cluster benefit estimate; only extend source
  liveness when net-positive. Re-validate CTS + full shader-db (no global regression) + A/B.
- **P2: upstream.** Author against `mesa/main` as an MR (per the no-forks goal); it's a general
  Valhall RA improvement, upstreamable on its own merits.

## Risks / honest odds
- **Correctness:** modifying a Braun-Hack spiller is correctness-critical — CTS + token-identical are
  mandatory gates, not afterthoughts.
- **Payoff genuinely uncertain:** the obvious version already failed; even the deep version may find
  the net benefit is small (libmali's edge could be partly *scheduling*, which this doesn't touch).
  P0 exists to find that out cheaply before sinking P1/P2 weeks.
- **No global regression:** extending source liveness raises pressure; must confirm shader-db across
  many shaders doesn't regress (the pressure-unroll lever died exactly here).
- **Bench reality:** the device is load-crash-prone (native builds must be `-j2`/niced) and network-
  flaky — expect multi-session, and A/B must control thermal.

## Effort
P0 ~3-5 focused days (the virtual-use plumbing + cmp_dist + validation harness). P1 ~1-2 weeks
(cost model + no-regression). This is real compiler R&D, not a lever.
