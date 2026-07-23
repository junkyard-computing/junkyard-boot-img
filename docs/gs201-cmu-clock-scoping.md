# gs201 CMU clock-controller bring-up — scoping

## Why

The ODPM power meter (fixed 2026-07-22, both PMICs) let us diff mainline felix
(.138) idle power against the AOSP oracle (.108, same Debian userspace, same
hardware) rail-by-rail. Result: **mainline draws +407 mW at idle**, and the two
biggest rails are:

| rail | mainline | AOSP | gap | blocked on |
|---|--:|--:|--:|---|
| L2S_PLL_MIPI_UFS | 145 mW | 20 mW | **+125 mW** | CMU_TOP → HSI2_UFS distribution clock never gated |
| S5M_VDD_INT | 115 mW | 17 mW | **+99 mW** | no cmu_disp → DPU clocks run ungated at bootloader default |

Both were meter-diagnosed to the same root: **the gs201 CMU clock tree is
incomplete**, so idle IP clocks that AOSP's cal-if gates/scales run continuously
on mainline. ~224 mW — over half the idle gap — is behind this one project. It
is also the largest single lever for idle *thermal*.

Neither is DVFS/voltage: INT idles at 100 MHz (below AOSP's 200 MHz) at the same
~0.55 V, yet draws 7× the current — active current from ungated clocks. UFS is
the link-hibernated PLL that never idles. Details in
`reference_no_energy_metrics_mainline.md`.

## Current CMU state (gs201.dtsi + clk-gs101.c)

The mainline samsung CMU driver (`drivers/clk/samsung/clk-gs101.c`) already
carries gs201 compatibles and info structs. What is actually wired and working:

| CMU | compat | info struct | DT status | works? |
|---|---|---|---|---|
| cmu_hsi0 | gs201-cmu-hsi0 | hsi0_cmu_info (gs101 map) | enabled | **YES** (USB/dwc3) |
| cmu_peric1 | gs201-cmu-peric1 | peric1_cmu_info (gs101 map) | enabled | **YES** (DSIM PCLK) |
| cmu_peric0 | gs201-cmu-peric0 | peric0_cmu_info_gs201 | enabled | yes |
| cmu_top | gs201-cmu-top | top_cmu_info_gs201 | **disabled** | **NO — SError** |
| cmu_hsi2 | gs201-cmu-hsi2 | hsi2_cmu_info (gs101 map) | **no DT node** | untested |
| cmu_disp | gs201-cmu-dpu | dpu_cmu_info (gs101 map) | **no DT node** | untested |

Two facts that de-risk the whole project:
1. **hsi0 and peric1 reuse the gs101 register maps unchanged and work on gs201.**
   So gs201 CMU blocks are largely byte-compatible with gs101; only some blocks
   (top, peric0) needed gs201 variants.
2. **pKVM CMU access is solved.** hsi0 CMU reads succeed under our
   `kvm-arm.mode=protected` boot, so EL1 can reach CMU blocks. The cmu_top
   SError is NOT the BL31 firewall (`project_pkvm_cmu_unlock`) — it is a bad
   register offset (see below).

## Root causes

- **cmu_top SError:** `top_cmu_info_gs201` still has ≥1 divider register at a
  gs101 offset that gs201 does not implement; `clk_divider_recalc_rate` reads it
  → `Asynchronous SError Interrupt` at probe (per the DT comment, boot test
  2026-05-03). This is a data bug in the div/mux table, fixable by diffing
  against AOSP cmucal, not a firewall or a missing driver.
- **cmu_hsi2 / cmu_disp:** the info structs exist but reuse gs101 maps and have
  no DT node, so nothing instantiates them. UFS falls back to `fixed-clock`
  stubs; DPU runs at bootloader-default clocks with no gating. The HSI2 map is
  known to differ from gs101 (e.g. gs201 DIV_HSI2_UFS_EMBD @0x189c vs gs101's
  0x1898 = MMC_CARD), so hsi2/dpu will likely need gs201 variants like top did.

## Reference

AOSP `private/google-modules/soc/gs/drivers/soc/google/cal-if/gs201/cmucal-sfr.c`
is the authoritative gs201 register map. Confirmed blocks:
`SFR_BLOCK(CMU_TOP, 0x1e080000)`, `SFR_BLOCK(CMU_DISP, 0x1c200000)`,
`SFR_BLOCK(CMU_HSI2, 0x14400000)`. Each `SFR(name, offset, block)` +
`SFR_ACCESS(field, bit, width, reg)` gives the exact offset and bit for every
mux/div/gate. This is the same source that fixed the s2mpg13 meter — read it,
don't infer.

## Plan (strictly phased — each phase independently validated & rollback-safe)

Dependency: hsi2 and disp CMUs draw their input distribution clocks from
cmu_top, so **cmu_top must be fixed first**. All validation is on slot B; slot A
(AOSP) stays intact, so a bad kernel rolls back via `pixel-bootctl
mark-unbootable` / retry exhaustion. UFS/DPU changes risk the rootfs/display —
recover by rollback or fastboot reflash.

### Phase 0 — fix CMU_TOP (linchpin) — ✅ DONE 2026-07-22 (kernel cb54dc49b2cf)
Enabled `cmu_top` in gs201.dtsi. It probes cleanly (no SError — the SHARED0_DIV4+
holes were already in the skip list), system boots healthy, all rails unchanged
(consumers still on stubs). The clock tree now exposes `fout_shared0_pll`,
`dout_cmu_hsi2_ufs_embd`, `dout_cmu_disp_bus`.

**BUT the rates are wrong** (harmless while unused, blocks Phase 1). The gs101
register map is offset from gs201 by a SYSTEMATIC delta, measured against
cmucal-sfr.c:
- **PLL_CON\* registers: gs201 = gs101 + 0x40** (all 4 shared PLLs). The driver
  reads shared0 CON3 at 0x10c → decodes DIV_M=137 → 841.728 MHz; the real reg is
  0x14c → DIV_M=347 → 2131.968 MHz (matches the DT stub back-computation).
- **MUX registers: gs201 = gs101 − 0x4** (e.g. HSI2_UFS_EMBD mux 0x10ac→0x10a8,
  HSI0_USB31DRD mux 0x1090→0x108c).
- **DIV and GATE registers: same offset** (HSI2_UFS_EMBD div 0x18a4, gate 0x20cc
  match). So dividers/gates are fine; PLLs and muxes are mis-decoded.
- `dout_cmu_hsi2_ufs_embd` reads 0 because its mux selects shared0_div4, which is
  in the skip list as a register-hole. On gs201 div4 exists as a *rate* (the stub
  computes shared0/4 = 532.992 MHz) but its DIV register aborts — so re-add it as
  a **fixed-factor** clock (shared0 ÷ 4), not a register divider.

### Phase 1 — CMU_HSI2 → UFS (+125 mW)  [prereq: correct cmu_top rates above]
First fix the cmu_top rates (gs201 PLL +0x40 / MUX −0x4 variants of top_pll_clks
& top_mux_clks; fixed-factor shared0_div4). Validate every rate against the stub
back-computations / AOSP clk_summary — failure here is a SILENT wrong rate, not a
SError, so compare rates explicitly. THEN:
- Diff `top_cmu_info_gs201`'s `top_div_clks` (and mux/gate) offsets against AOSP
  gs201 CMU_TOP. Find the divider(s) at a gs101-only offset; correct or drop.
- `gs201_top_skip_ids` already exists — extend it for clocks gs201 lacks.
- Enable the `cmu_top` DT node. Boot-test: no SError, and the shared-PLL /
  distribution rates read back sane (compare to the fixed-clock stub rates that
  were back-computed from raw registers — they should match).
- **Risk:** SError → slot B won't boot → rollback. Med. **Payoff:** none direct,
  but unblocks Phase 1 & 2.
- **Effort:** the biggest table (PLLs+muxes+divs+gates), but the fix may be a
  handful of offsets. Bounded by "find the one bad divider."

### Phase 1 — CMU_HSI2 → UFS (+125 mW)
- Verify/branch `hsi2_cmu_info` to a gs201 variant with cmucal-correct HSI2
  offsets (mux + gate only; no div — small).
- Add the `cmu_hsi2` DT node (compat gs201-cmu-hsi2, reg 0x14400000, parent
  clocks from cmu_top).
- Replace the `ufs_aclk` / `ufs_unipro` fixed-clock stubs in the UFS node with
  real `&cmu_hsi2 CLK_...` gate clocks (core_clk / sclk_unipro_main / fmp).
- **Validate:** UFS still enumerates + rootfs I/O sane (gear4, 0 errors); then
  measure L2S_PLL_MIPI_UFS with the meter. Expect the gated-idle rail to fall
  from ~144 mW toward AOSP's ~20 mW as ufshcd clock-gating now actually gates
  the CMU clocks. If it does NOT drop, the PLL-idle hypothesis is wrong and we
  learn the refclk PLL is independent — a real result either way.
- **Risk:** wrong offset SErrors, or bad gate breaks UFS → rootfs unbootable →
  rollback. Med-high. **Payoff:** up to +125 mW.

### Phase 2 — CMU_DISP → INT (+99 mW)
- gs201 variant of `dpu_cmu_info` (mux+div+gate) from cmucal CMU_DISP @0x1c200000.
- Add `cmu_disp` DT node; wire DECON/DSIM (`1c240000.drmdecon`) real clocks
  (currently the DECON node has no `clocks` at all).
- Add idle scaling: either a `devfreq_disp` domain (AOSP has one) or at least a
  lower idle DPU clock, so the display draws less on VDD_INT when static.
- **Validate:** display comes up on both panels; measure VDD_INT.
- **Risk: HIGHEST.** Idling the DPU path triggers the known `pd_dpu`-off-when-
  idle wedge (`project_outer_screen_bringup` — needs ACPM/EL3 SMC; stopping the
  console made .138 unreachable ×2 during diagnosis). This phase may pull in the
  pd_dpu/ACPM-SMC work as a prerequisite. Scope Phase 2 only after Phase 1
  proves the methodology.

## Methodology / guardrails

- One CMU per flash; validate on slot B; never touch slot A. A wrong offset =
  SError = won't boot = rollback (cheap, but costs a bench cycle).
- Cross-reference **every** offset against AOSP cmucal-sfr.c before flashing;
  the SError is unforgiving (external abort, no partial success).
- Reuse the gs101 map only when it's proven byte-identical for that block
  (hsi0/peric1 were); assume hsi2/disp need gs201 variants until proven.
- Measure the target rail before/after with the ODPM meter — the whole point is
  the power delta; do not declare a win on "it booted".
- Keep KASAN off for these (clock init is early); rely on the SError being loud.

## Open questions / unknowns

- Does gating the HSI2 CMU clocks actually idle the refclk PLL on L2S? Strongly
  implied by elimination (AOSP's only structural difference), but unproven until
  Phase 1 measures it. This is the single biggest bet in the project.
- Phase 2 may be blocked behind pd_dpu/ACPM-SMC regardless of cmu_disp.
- CMU_TOP shared PLLs feed many blocks; changing top must not disturb the
  already-working hsi0/peric1/CPU/GPU clocks (they currently get parents from
  the fixed-clock stubs / acpm, not cmu_top — verify the stubs can be retired
  incrementally rather than all at once).

## Recommendation

Do **Phase 0 + Phase 1** as the first milestone: it's bounded, it's the +125 mW
rail (biggest single gap), and Phase 1 is the experiment that proves or kills
the whole thesis. Defer Phase 2 (INT/DPU) until Phase 1 validates the approach
*and* the pd_dpu wedge is addressed, since it's the riskiest and partly
independently blocked.
