# gs-clk

- **AOSP path**: `private/google-modules/soc/gs/drivers/clk/gs/`
- **Mainline counterpart**: [`drivers/clk/samsung/clk-gs101.c`](kernel/source/drivers/clk/samsung/clk-gs101.c)
- **Status**: partially-ported
- **Boot-relevance score**: 3/10 (downgraded from 10 after C1+C2 probe ruled out)

## What it does

`clk_exynos_gs.ko` is the AOSP-side gs clock-controller glue. It is a thin shim built from `composite.c` plus per-SoC files (`clk-gs101.c`, `clk-gs201.c`, `clk-zuma.c`) and registers a single `samsung,gs201-clock` provider that walks every CMU domain through Samsung's "CAL-IF" chip-abstraction layer ([`drivers/soc/google/cal-if/`](kernel/source.aosp-backup/private/google-modules/soc/gs/drivers/soc/google/cal-if/)). Per-clock register offsets, MUX trees, divider tables, and gate masks live in the cal-if `gs201/cmucal-sfr.c`/`cmucal-vclklut.c` blobs, not in the clk driver itself. The driver depends on `CAL_IF` and is more an opinionated pre-init/early-clock provider than a normal CCF driver — most clocks end up exposed as "vclks" for the DVFS manager.

## Mainline equivalent

Mainline has `drivers/clk/samsung/clk-gs101.c` (4875 lines, written from scratch using the standard Samsung CCF infrastructure — completely different code lineage from the AOSP cal-if approach). It registers per-CMU drivers (`google,gs101-cmu-{apm,dpu,hsi0,hsi2,peric0,peric1}`) and added gs201 variants for the same domains plus `gs201-cmu-top` and `gs201-cmu-misc`. `samsung,gs201-clock` (the AOSP single-tree compatible) does NOT exist in mainline.

## Differences vs AOSP / what's missing

Mainline gs201 CMU coverage is **incomplete**. Confirmed present: TOP, APM, DPU, HSI0, HSI2, PERIC0, PERIC1, MISC. Confirmed absent: every other domain AOSP cal-if knows about (CMU_AOC, CMU_BO, CMU_BUS0, CMU_BUS1, CMU_BUS2, CMU_CPUCL0/1/2, CMU_DPUB, CMU_G2D, CMU_G3D, CMU_GDC, CMU_HSI1 (PCIe), CMU_ISP, CMU_MFC, CMU_MIF, CMU_NOCL{0,1A,1B,2AA,2AB}, CMU_TPU, etc.). For UFS specifically, gs201.dtsi in mainline still uses **fixed-clock** stubs `ufs_aclk` and `ufs_unipro` rather than real clock references — the in-tree comment says "ufs_aclk's actual rate would come from HSI2_NOC (gs201's BUS divider, at offset 0x189c — different from gs101's 0x1898 which holds MMC_CARD on gs201). Not yet measured; leaving at [stub]." So the UFS controller sees a frozen, untweakable refclk that may not match the rate the bootloader programmed, and may not match what the PHY needs for HS gears. `clk-gs201.c` upstream is `clk-gs101.c` with overrides; the gs201 HSI2/UFS divider table and PLL spec table do not appear to have been imported yet.

## Boot-relevance reasoning

**Score 3** (downgraded from 10).

A direct probe (C1 + C2 runs, 2026-05-02) **ruled out** the original "wrong-rate-at-HS" hypothesis. An ioremap-based read-only probe in `ufs-exynos.c` dumped HSI2 CMU dividers, muxes, and gates at three call sites (post_link, pre_pwr_change, post_pwr_change) for both PWM-G4 boot and HS-Rate-B G4 attempt. Findings:

1. All three call sites returned **byte-identical** values, in both PWM and HS runs. **HSI2 CMU is untouched across PMC.**
2. Hardware UFS_EMBD divider at `0x18a4` reads `0x02` → DIVRATIO=2, /3 → SHARED0_DIV4 (532.992 MHz) /3 = **177.664 MHz**, exactly matches mainline's `ufs_unipro` fixed-clock stub claim.
3. Hardware NOC divider at gs201's `0x189c` reads `0x01` → DIVRATIO=1, /2 → SHARED0_DIV4 /2 = **266.5 MHz**, exactly matches mainline's `ufs_aclk` fixed-clock stub claim of 267 MHz.
4. Looking at mainline `ufshcd.c`: `ufshcd_set_clk_freq()` is **only** called from `ufshcd_scale_clks()` via devfreq. It is never called during PMC. The original framing ("set_clk_freq becomes no-op at PMC because clk is fixed") was wrong on two counts: the kernel doesn't try to change clocks at PMC anyway, AND the fixed-clock rates match reality.
5. Looking at AOSP `ufs-exynos.c`: AOSP also doesn't touch HSI2 dividers at PMC. So mainline's behavior on this path matches AOSP byte-for-byte.

**The clk-stub gap was NOT the cause of the HS wedge.** The ufs_aclk dtsi note about the rate being "claimed PCLK_AVAIL_MAX, not actually measured" was a leftover concern from before the probe — the rate is right. The UFS HS bring-up was unblocked by patches 0010 + 0011 in [gs-ufs.md](gs-ufs.md), not by anything in the clk path.

What's still true: a future port that wires up real CCF clocks via `cmu-hsi2 { compatible = "google,gs201-cmu-hsi2"; }` (the driver hook already exists in `clk-gs101.c:4845`) plus `cmu-top` would be cleaner long-term, would let devfreq scale UFS, and would handle suspend/resume properly. But it is not on the critical path for any active bring-up. Score 3 reflects "infrastructure cleanup, not a bug fix."

What did land in the clk path during the UART/USB bring-up effort:

- **Patch 0013 — gs201 CMU_TOP / CMU_MISC.** Adds a `skip_ids[]` mechanism
  + an empirical register-hole list for gs201's truncated SHARED-PLL fan-out
  (gs201 only implements SHARED0_DIV2/DIV3; everything from SHARED0_DIV4
  onwards plus all of SHARED1/2/3 is a register hole that gs101 has and
  gs201 doesn't).
- **Patch 0014 — gs201 CMU_PERIC0 (USI0_UART chain).** A minimal validated
  `peric0_cmu_info_gs201` with gs201-specific register offsets (DIV at
  0x1808 vs gs101's 0x1804; GATE at 0x20c0 vs gs101's 0x20bc). gs201 has
  no PERIC0_TOP1 cluster, so the gs101 tables can't be reused as-is. Also
  forces `auto_clock_gate = false` because gs201 has no DBG mirrors at
  base+0x4000 for the gate registers (only for muxes at 0x4xxx and dividers
  at 0x5xxx); reading the non-existent DBG variant raises an asynchronous
  SError that ultimately panics inside `console_unlock`.

For the **USB gadget bring-up task**, cmu_hsi0 (USI0_UART path + USB ref
clock fan-out) is in mainline. However the user-mux for the USB ref clock
reports back the bootloader PLL rate (~614 MHz), which trips
`phy-exynos5-usbdrd`'s strict-rate check. We currently feed `phy_ref` from a
26 MHz fixed-clock stub. A real cmu_hsi0 USB ref clock entry that exposes
the 26 MHz feed would replace that stub but is not on the critical path.

Secondary concern unchanged: gs201 CMU_MISC is in mainline but several adjacent domains needed by AOC, MIF, and HSI1 (PCIe) are not — those subsystems will quietly clamp to bootloader rates even when they "appear" to work. That's still a real gap but not boot-blocking.

## 7.1 rebase impact

Three areas to re-check after rebasing on 7.1:

- **gs101 cmu_dpu** has recent activity in mainline 7.1. If a gs201 cmu_dpu
  hook lands too, we'd want to enable it on felix; otherwise it's a template
  for a future port.
- **gs101 cmu_hsi0 / USB ref clock**: our 26 MHz fixed-clock stub for
  `phy_ref` is a workaround for the user-mux reporting back the wrong rate.
  If 7.1's gs101 cmu_hsi0 work changes the user-mux behaviour (e.g. exposes
  the 26 MHz feed as a child), we may be able to drop the stub.
- **Our patches 0013 + 0014** (gs201 CMU_TOP/MISC + CMU_PERIC0) sit on top
  of `clk-gs101.c`; rebase will re-touch this file. If upstream merges any
  gs201 CMU work in the meantime (e.g. someone else upstreams the
  `skip_ids[]` mechanism), we'll need to reconcile.
