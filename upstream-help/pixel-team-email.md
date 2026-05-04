To: <PIXEL TEAM CONTACT>
Subject: Mainline Linux UFS bring-up on Pixel Fold (gs201) — six confirmed bugs + a few questions only insiders can answer

Hi <NAME>,

I'm bringing up mainline Linux on a Pixel Fold (felix / Tensor G2). The
end goal is a Debian rootfs from /dev/disk/by-partlabel/super, kernel
built straight from Linus's tree (not the AOSP gs201 fork). Six
upstream-eligible bug fixes have come out of the bring-up so far,
which I'm planning to send to LKML; before I do, I'd love a sanity
check from someone with the original gs201 UFS context.

The patches and supporting evidence live in
<MY GITHUB OR ATTACH>; copies of all six attached. Quick summary:

  0001 - ufs: exynos: preserve bootloader IOCC bits when !dma-coherent
         (mainline actively clears them; gs201 needs them set so
         controller AXI master uses Inner-Shareable transactions)

  0002 - ufs: exynos: drop UFSHCD_QUIRK_PRDT_BYTE_GRAN from gs201
         (gs201 controller follows UFS spec - DWORDS, not BYTES; the
         inherited gs101 quirk caused mainline to write the response
         offset 4x further than the controller expected. Confirmed
         with a magic-byte stamp on the response slot.)

  0003 - ufs: exynos: force 32-bit DMA mask on gs201
         (controller advertises MASK_64_ADDRESSING_SUPPORT but raises
         SYSTEM_BUS_FATAL_ERROR on >4GB DMA. This is exactly what your
         downstream driver works around with the
         `static u64 exynos_ufs_dma_mask = DMA_BIT_MASK(32)` line in
         google-modules/soc/gs/drivers/ufs/ufs-exynos.c.)

  0004 - phy: samsung-gs101-ufs: fix two PMA register transcription
         typos in tensor_gs101_pre_init_cfg (mainline writes byte
         offsets 0x974/0xA78 which AOSP's gs10x/gs201/zuma cal-if
         never touch; should be 0x9F4/0xAF8, which AOSP does write
         for gs201 — single-digit hex transposition errors in Pete
         Griffin's original mainline port. Observable in PHY
         calibration state.)

  0005 - ufs: exynos: enable PRDT prefetch on gs201 without crypto
         (AOSP unconditionally sets PRDT_PREFETCH_EN on TXPRDT;
         mainline only sets it when UFSHCD_CAP_CRYPTO is enabled,
         and gs201 can't get crypto because BL31 doesn't actually
         honour the FMP SMC pair. Matches AOSP behaviour. Held as
         a draft pending your reply — see Q3 below for context.)

  0006 - ufs: exynos: gs101: run PHY post-PMC calibration for non-HS
         (mainline gates phy_calibrate behind ufshcd_is_hs_mode in
         exynos_ufs_pre/post_pwr_mode, so the PWM-mode entries in
         tensor_gs101_post_pwr_hs_config — which match AOSP's
         post_calib_of_pwm byte-for-byte — never run for forced-PWM
         setups. Adds a per-variant post_pwr_change vops hook to drive
         the Samsung PHY framework state machine through the missing
         transitions. Held as a draft pending your reply — see Q3.)

The 0003 patch in particular makes me suspect there's institutional
knowledge of these controller quirks at Google that just never made
it upstream, hence reaching out.

## Investigated and ruled out: clock-controller / HSI2 CMU rate gap

For completeness, since I had earlier suspected this and want to save
anyone the time of suggesting it: I investigated whether the
fixed-clock stubs for `ufs_aclk` and `ufs_unipro` in `gs201.dtsi`
(rather than real CCF entries through a `cmu-hsi2` node) could be
causing the HS dl_err. They aren't.

I added a read-only ioremap probe in `ufs-exynos.c` that dumps the
HSI2 CMU dividers, muxes, and gates at three call sites
(post_link, pre_pwr_change, post_pwr_change) for both PWM-G4 boot and
HS-Rate-B G4 attempt. Findings:

- All three sites returned **byte-identical** values, in both runs.
  HSI2 CMU is untouched across PMC.
- Hardware UFS_EMBD divider at `0x18a4` reads `0x02` → /3 →
  SHARED0_DIV4 (532.992 MHz) /3 = **177.664 MHz exactly**. Matches
  the dtsi fixed-clock stub claim.
- Hardware NOC divider at gs201's `0x189c` reads `0x01` → /2 →
  SHARED0_DIV4 /2 = **266.5 MHz**. Matches the `ufs_aclk` stub claim
  of 267 MHz.
- `ufshcd_set_clk_freq()` is only called from `ufshcd_scale_clks()`
  via devfreq, never during PMC. So the kernel was never going to
  reprogram clocks at PMC anyway, and AOSP doesn't either (per code
  review of `private/google-modules/soc/gs/drivers/ufs/ufs-exynos.c`).

So the actual rates the kernel believes are correct, and PMC doesn't
need to touch CMU. (I'd briefly suspected `EXYNOS_PD_HSI0` sequencing
might explain it next, but verification before porting confirmed your
own `gs201-ufs.dtsi` uses `vcc-supply = <&ufs_fixed_vcc>` — a fixed
GPIO regulator — and doesn't tie UFS to `pd_hsi0`; that driver only
manages USB PHY rails on felix. Ruled out as a UFS lead.)

## 2026-05-03 update — wedge solved end-to-end

Before reading the original "Open questions" section below, an
important update: **the dl_err 0x80000002 wedge is fully resolved**.
gs201 mainline now boots all the way to a mounted ext4 rootfs at
HS-G4 Rate-B with both lanes locked. Two root causes pinned this
session:

1. **Three writes were missing from the AOSP cal-if walk** — a single
   write each in `tensor_gs101_pre_init_cfg`, `gs101_ufs_pre_link`,
   and `gs201_ufs_post_link`, all on the 38.4 MHz refclk path
   (`USE_UFS_REFCLK == USE_38_4_MHZ`). With all three, M-PHY CDR
   locks first iteration (`R339 = 0x18`) and link startup completes.
2. **A four-call `SMC_CMD_FMP_SECURITY` probe loop in our
   `gs201_ufs_smu_init`** had been latching FMPSECURITY0.DESCTYPE = 3
   (128-byte FMP `fmp_sg_entry` mode) as its last call. Mainline
   writes 16-byte standard PRDTs (FMP/inline-crypto disabled), so
   single-entry transfers (INQUIRY) survived but the first multi-PRD
   transfer (READ_10 32 KB / 8 PRDs) wedged with OCS=0xf at tag 6.
   Replacing the loop with a single-shot DESCTYPE=0 call unwedges it.

Most of the questions below remain interesting (especially the
`MASK_64_ADDRESSING_SUPPORT` and `UFSHCD_QUIRK_PRDT_BYTE_GRAN` ones —
those are still upstream patches), but **the "HS at any rate × gear
fails with dl_err 0x80000002" question (Q2) is closed** by the
cal-if-walk fix. I've left the original text below unedited for
context, but you can skip Q2 if you only have time to skim.

The full new patch series (12 patches now) is at
`upstream-patches/README.md` in <MY GITHUB OR ATTACH>.

**One more update from later the same day**: bidirectional UART now
works on mainline gs201. We have a `fold login:` prompt over
`serial-getty@ttySAC0` and just logged in on a kernel built straight
from upstream Linus's tree (modulo our pending patch series). The
fix involved three pieces of CMU work — a minimal
`peric0_cmu_info_gs201` with the gs201-specific PERIC0 register
offsets, the `skip_ids[]` infrastructure for CMU_TOP register holes,
and `auto_clock_gate=false` because gs201 has no DBG mirrors at
base+0x4000 for gates — but the **actual** gating bug was simpler:
the `samsung,exynos850-uart` compat that mainline's gs201 fork was
using selects `iotype = UPIO_MEM` (8-bit register access) inside
samsung_tty, and gs201's UART register block requires 32-bit-aligned
access. Switching the DT compat to `google,gs101-uart` (which
selects `UPIO_MEM32`) clears the asynchronous SError. Question F
below has more detail; the takeaway for anyone seeing similar
"console panics on first write" symptoms on gs201 is "check your
UART iotype." This entire chain is the original "AOC firmware
starves UART RX" story I had earlier — wrong root cause, AOC has
nothing to do with UART input on mainline. Question E (originally
about AOC) is reframed below to ask about gs201's CMU register-
layout deltas, which is what we actually need help with.

---

## New questions raised by this session

A. **Why does the AOSP cal-if treat addresses 0x3348 / 0x334C
   (`PA_*_TActivate`-adjacent) as `UNIPRO_ADAPT_LENGTH`-class
   conditional RMW?** The cal-if branch writes 0x82 if (val & 0x80
   && (val & 0x7F) < 2), else writes (val | 0x3) if ((val + 1) &
   0x3). For a typical reset value of 0x0, that path writes 0x3.
   Mainline previously wrote a literal 0x0. Is this a known
   silicon quirk that should be documented somewhere LKML can see,
   or am I cargo-culting? Either is fine — the patch is verifiable
   either way — but a one-line confirmation helps the cover letter.

B. **Why does the gs201 secure firmware (BL31?) leave
   FMPSECURITY0.DESCTYPE in whatever state the last
   `SMC_CMD_FMP_SECURITY` call set it to?** Specifically, is there
   an expectation that the OS calls `SMC_CMD_FMP_SECURITY(...,
   DESCTYPE)` with the value matching its `sg_entry_size`? Or is
   the bootloader supposed to leave DESCTYPE in a sensible default
   (presumably 0 = standard 16-byte PRDT) for non-FMP boots?
   Asking because the original probe-loop in our
   `gs201_ufs_smu_init` was a hack born of "we don't know what
   DESCTYPE is supposed to be on non-FMP boot" — it'd be nice to
   replace the cargo-cult comment with a real answer.

C. **Why does mainline gs201 not probe DWC3 at all?** Mainline
   defconfig has `CONFIG_USB_DWC3=y` and `CONFIG_USB_DWC3_EXYNOS=y`,
   the gs201.dtsi has `compatible = "samsung,exynos850-dwusb3"` and
   `compatible = "snps,dwc3"` (gs201.dtsi:790, 799), and yet our
   boot log shows zero `dwc3` lines in dmesg — only the usbcore
   class registrations. Is there a Tensor-specific role-switch /
   PD-controller driver missing (Maxim PMIC?), or is the DTS just
   incomplete and we need to graft from gs101.dtsi (which has the
   USBDRD31 PHY + controller scaffolding fully wired)? This is the
   only thing standing between us and an SSH-reachable mainline
   Debian on felix.

D. **Why does the gs201 secure firmware open CMU access only when
   EL2 is in pKVM?** We boot mainline with `kvm-arm.mode=protected`
   and CMU readl/writel work fine. Without that flag, every CMU
   access aborts with synchronous external abort code 0x96000010.
   Empirically discovered, but a one-line "yes, BL31 routes CMU
   through pKVM" or "no, that's a different reason" comment from
   someone in the know would let us upstream a proper note in the
   gs201 binding doc.

E. **gs201 CMU register layout — is there documentation we don't
   have?** Mainline's `clk-gs101.c` advertises `google,gs201-cmu-*`
   compats but reuses gs101's register-offset tables for everything
   except CMU_TOP. Empirically that doesn't fly:

     - CMU_TOP requires a `gs201_top_skip_ids[]` because gs201
       implements fewer SHARED-PLL fan-out dividers than gs101 (only
       SHARED0_DIV2/DIV3; everything from SHARED0_DIV4 onwards plus
       all of SHARED1/2/3 is a register hole). That's already in our
       fork as a partial port and queued upstream as a separate patch.

     - CMU_PERIC0's layout is *substantively* different (not just an
       offset shift): the PERIC0_TOP1 cluster gs101 has — IPCLK_0 /
       PCLK_0 / IPCLK_2 / PCLK_2 sub-bridges feeding the USI
       peripherals — doesn't exist on gs201 at all. Each peripheral
       on gs201 gates from RSTNSYNC directly. The "BUS" path is also
       renamed "NOC" with corresponding offset shifts (e.g.
       DIV_CLKCMU_PERIC0_BUS at 0x18d4 on gs101 → DIV_CLKCMU_PERIC0_NOC
       at 0x18e8 on gs201). For the USI0_UART path specifically:
       `DIV_CLK_PERIC0_USI0_UART` moved 0x1804 → 0x1808 (+4); the
       RSTNSYNC USI0_UART gate moved 0x20bc → 0x20c0 (+4); the user
       mux at 0x620 stayed the same.

     - There appear to be no DBG mirrors at base+0x4000 for gates on
       gs201 (only for muxes at 0x4xxx and dividers at 0x5xxx), which
       trips mainline's `auto_clock_gate=true` path — reading the
       non-existent DBG variant for the USI0_UART gate at 0x60c0
       raises an asynchronous SError that the kernel ultimately
       panics on inside `console_unlock`. We work around this by
       setting `auto_clock_gate=false` on `peric0_cmu_info_gs201`.

   We've been deriving all of this from AOSP cal-if's
   `private/google-modules/soc/gs/drivers/soc/google/cal-if/gs201/
   cmucal-sfr.c`, which appears authoritative for the offsets, but a
   confirmation that the cal-if SFR table is the canonical reference
   would be reassuring (and let us cite it in the binding doc /
   commit messages cleanly). If there's an internal doc that maps
   the gs101 → gs201 register-layout deltas across all CMU domains,
   we'd appreciate a pointer — saves a lot of empirical bisecting on
   each domain (APM, DPU, HSI0, HSI2, PERIC1 still pending).

F. **Does gs201's UART register block officially require
   32-bit-aligned access?** This is the "actual" UART RX blocker
   that gave us a few days of confused debugging. samsung_tty's
   `wr_reg(port, S3C2410_UTXH, ch)` does an 8-bit `writeb_relaxed`
   under `iotype = UPIO_MEM` (which is what `samsung,exynos850-uart`
   selects) but a 32-bit `writel_relaxed` under `iotype = UPIO_MEM32`
   (which is what `google,gs101-uart` selects). On gs201 the 8-bit
   write to the UART register block raises an asynchronous SError
   that surfaces inside `console_unlock`. Our fix: declare gs201's
   UART node with `compatible = "google,gs101-uart"` instead of
   `"samsung,exynos850-uart"`, even though the binding documentation
   has historically associated the latter with all post-Exynos850
   parts. With that change, `serial-getty@ttySAC0` works
   bidirectionally on real felix hardware (we just logged in over
   UART for the first time on a kernel built from upstream Linux).

   Question: should the gs201/gs101 UART binding doc explicitly call
   out the 32-bit-only access requirement? AOSP's bootloader and
   kernel both work because both consistently use 32-bit access
   (bootloader's earlycon uses `mmio32`, AOSP's downstream samsung
   driver presumably uses UPIO_MEM32 on these compats). Mainline
   only trips the trap because the upstream binding docs make
   `samsung,exynos850-uart` look like a viable choice for gs201.

   We'd also like to add `google,gs201-uart` (alias for
   `google,gs101-uart` on the same compat row) to the samsung_tty of_match
   table so DTs can be explicit. Sending it as a one-liner upstream
   patch unless you object. Note for the binding doc: 32-bit-only
   access also matches what we observed for gs201 CMU register reads
   (anything not 32-bit aborts) — feels SoC-wide, not UART-specific.

G. **Post-boot AOC** (was previously a UART blocker — disregard).
   Earlier drafts of this email described AOC's retry loop as
   starving UART RX on mainline. That hypothesis is wrong; the
   actual cause was UART register-access width (point F). With F
   fixed, UART works fine without an AOC driver. AOC is still
   eventually needed for low-power audio / sensor hub / hotword
   support, but that's a separate multi-month "port the AOC
   subsystem to mainline" project, not a boot blocker. Detail in
   `kernel/asop_port_questions/aoc.md` if anyone wants to chime in
   on prior art.

---

## Open questions (original — Q2 closed by 2026-05-03 update above)

1. **Is MASK_64_ADDRESSING_SUPPORT in the gs201 caps register actually
   wrong?** The AOSP driver pins dma_mask to 32-bit for the entire
   exynos UFS family at probe. Is there a known errata, or was that
   override added defensively without a specific incident behind it?
   Also: should it apply only to gs201, or is gs101 / Zuma affected
   too? I'm scoping my upstream patch to gs201-only since that's the
   hardware I have, but if someone at Google can confirm it's broader
   I'll widen the scope.

2. **HS at any rate × any gear fails with `dl_err 0x80000002`
   (TC0 replay timer expired) on the very first frame after
   `Power mode changed to: FAST series_X G_Y L_2`.** I spent quite
   a lot of debug effort chasing CDR lock as the suspected root cause
   (`gs101_phy_wait_for_cdr_lock` times out polling TRSV_REG339 bit 3
   for HS-Rate-B at G4); after porting more of AOSP into mainline as
   fork-only experiments and bisecting rate × gear × ADAPT × settle
   delay, I now believe the CDR-lock indicator is a red herring — the
   real bug is at the UniPro DL layer right after pwr_change, and CDR
   doesn't correlate with whether data flows.

   The bisect matrix:

   | rate | gear | ADAPT | settle | CDR lock | dl_err 0x80000002 |
   |------|------|-------|--------|----------|---------------------|
   | B    | 4    | off   | 0      | fail     | yes                 |
   | A    | 4    | off   | 0      | **OK**   | yes (same)          |
   | A    | 3    | off   | 0      | OK       | yes                 |
   | A    | 1    | off   | 0      | OK       | yes                 |
   | A    | 1    | off   | 100ms  | OK       | yes (just shifted)  |
   | B    | 1    | off   | 0      | fail     | yes (same)          |
   | A or B | any | **on**| 0      | n/a      | pwr_change fail upmcrs:0x5 |

   Critical observation: even when CDR `fails` at Rate-B, `Power mode
   changed to: FAST series_B G_x L_2` is reported successfully and the
   first frame still gets the same `dl_err 0x80000002`. Even when CDR
   `succeeds` cleanly at Rate-A (`cdr lock OK lane=0 after 1 iters
   first=0x18 last=0x18`), the first frame still gets the same dl_err.
   So whatever the CDR indicator (TRSV_REG339 bit 3) tracks, it's some
   PHY-internal state that distinguishes rates but doesn't gate the
   actual data path.

   The dl_err always fires within 30–40 ms of `Power mode changed`,
   regardless of how long we delay before the next frame (tested up to
   100 ms `msleep` in `post_pwr_change`). UPIU response slot stays as
   our magic-stamp `0xab` fill pattern — the controller never wrote a
   response, meaning the device never ACKed the host's frame, the host
   PA layer's TC0 replay timer expired, host gave up, SCSI mid-layer
   times out 6 s later, `ufshcd_abort` itself times out (-110), and
   the WARN at `scsi_eh_scmd_add+0x104/0x10c`
   (drivers/scsi/scsi_error.c:314) trips. Controller is wedged from
   that point.

   What I've ported from your downstream driver / cal-if into mainline
   as fork experiments (none individually fix the dl_err, none reliably
   regress anything either):
     - **`__set_pcs` mechanism** for per-lane PCS writes (raw
       `unipro_writel` bracketed by `UNIP_COMP_AXI_AUX_FIELD =
       __WSTRB | __SEL_IDX(lane)`), replacing mainline's
       `ufshcd_dme_set(UIC_ARG_MIB_SEL(addr, lane), val)`.
     - **`ufs_cal_pre_pmc` semantics** — `PA_ERROR_IND_RECEIVED` mask
       in `UNIP_DL_ERROR_IRQ_MASK`, then UserData / L2 timer writes
       via raw `unipro_writel` in AOSP order, including the
       `0x4104/0x4108/0x410C` `UNIPRO_STD_MIB` L2-timer aliases
       mainline never wrote.
     - **`ufs_cal_post_pmc`** — added a `gs101_ufs_post_pwr_change`
       vops hook that drives the Samsung PHY framework state machine
       through `CFG_PRE_PWR_HS → CFG_POST_PWR_HS` for non-HS gears
       too (mainline gates `phy_calibrate` behind `is_hs_mode`, so the
       3 PMA writes from `tensor_gs101_post_pwr_hs_config` —
       `0x20=0x60 COMN`, `0x222=0x08 TRSV`, `0x246=0x01 TRSV` — match
       AOSP's `post_calib_of_pwm` byte-for-byte but never run for our
       PWM force without this hook). Verified by R338(CAL_DONE)
       shifting `0x9d → 0x84` in PWM mode after the hook lands. For
       HS modes the existing `exynos_ufs_post_pwr_mode` already
       calls `phy_calibrate` so the hook is a no-op.
     - **`PRDT_PREFETCH_EN` on `HCI_TXPRDT_ENTRY_SIZE`** —
       AOSP unconditional, mainline only ORs it in if
       `hba->caps & UFSHCD_CAP_CRYPTO`. We can't get CRYPTO on gs201
       (BL31 doesn't honour the FMP SMC pair `SMC_CMD_FMP_SECURITY` /
       `SMC_CMD_SMU(SMU_INIT)` — both return `a0=0` but the FMP
       security registers stay at the bus-fault sentinel
       `0xffe26492`, and reading back UFSP after returns `0xfffa6492`
       which I think is just "everything denied"). So mainline gs201
       ships TX-PRDT-prefetch-disabled. Forcing it on writes
       `HCI_TXPRDT_ENTRY_SIZE = 0x8000000c` per UART; doesn't change
       any failure mode but matches AOSP for both PWM and HS.
     - One self-inflicted bug caught and reverted late in debugging
       (FYI for sanity-checking my evidence): I had transiently added
       five "extra" `dme_set(UIC_ARG_MIB_SEL, ...)` PCS writes
       intended to cover MIBs 0x11, 0x1B, 0xA9, 0xAA, 0xAB based on
       a misread of the AOSP cal-if table — the entries with type
       `PHY_PCS_*_PRD_ROUND_OFF` / `PHY_PCS_*_LR_PRD` carry `0x00` as
       a monitoring placeholder, but the `__config_uic` walker
       substitutes computed `mclk_period_rnd_off` /
       `__get_line_reset_ticks()` at write time. Result: I was
       zeroing TX_CLK_PRD and the RX/TX linereset MSBs that mainline
       had just correctly written via `VND_TX_CLK_PRD` etc. Removed.
       All numbers above reproduce cleanly with that revert in place.
     - **PA-layer state confirmed correct via DME_GET diagnostic.**
       Ported AOSP's `exynos_ufs_get_caps_after_link` +
       `exynos_ufs_update_active_lanes` as a read-only diagnostic
       (using `ufshcd_dme_get(UIC_ARG_MIB(PA_*))` instead of AOSP's
       raw `unipro_readl(handle, UNIP_PA_*)`). At HS-Rate-B G4 attempt:

       | site | MaxRxHSGear | Connected[Tx,Rx] | Active[Tx,Rx] | PwrMode |
       |------|---:|---|---|---|
       | post_link  | 4 | [2,2] | [1,1] | 0x55 |
       | post_pwr_HS | 4 | [2,2] | [2,2] | 0x11 |

       After PMC: device confirms HS-G4 support, both lanes negotiated,
       both lanes active, PwrMode = 0x11 (FAST/FAST) on both directions.
       Exactly what mainline requested. The device fully acknowledged
       the mode change. Then dl_err 0x80000002 still fires on the first
       frame at +0.04 s. So the bug is **NOT** at the mode-negotiation
       or PA-attribute level — both ends agree on the new link state.
       The bug must be below the PA layer (M-PHY signaling, PCS
       calibration, or a controller-internal handshake post-PMC that
       AOSP runs and mainline doesn't).

   Setting `PA_TxHsAdaptType = ADAPT_INITIAL` (the
   `{0x15D4, 0x3350, 0x1, UNIPRO_STD_MIB}` entry from
   `calib_of_hs_rate_a/b`) ALWAYS breaks pwr_change with upmcrs:0x5
   (PWR_FATAL_ERROR), regardless of rate (A or B), write mechanism
   (direct `unipro_writel @ 0x3350` vs `ufshcd_dme_set`), or whether
   `PA_ERROR_IND_RECEIVED` is masked first. When pwr_change fails this
   way, ALL UIC error counters on the host side read zero (pa_err,
   dl_err, fatal_err, dme_err), so the host PA is self-aborting the
   gear-change locally without any peer interaction. AOSP must rely on
   additional state (PHY writes, pre-link cal, or a different
   controller mode) for adapt to be safe; mainline isn't in that
   state.

   **The questions:**

   - **What does the device need to see before it ACKs the host's
     first frame after `PA_PWRMODE` change?** I'd expect that any
     setup writes the device cares about would happen via DME on the
     UFS link itself (which mainline does, including PA_HSSeries),
     so by the time pwr_change reports success the device should be
     ready. But it isn't — the response slot stays magic-stamped 0xab,
     the device never wrote anything, the host's TC0 replay expires.
     If there's a peer-side attribute mainline forgets to write, or
     a controller-side handshake we should be polling for, that would
     unblock me.
   - **What additional state does the host PA need before
     `PA_TxHsAdaptType=1` is safe to set?** AOSP runs this for all HS
     pwr_changes; mainline+ours blows up with upmcrs:0x5 every time
     across both rates.
   - **Is `gs101_phy_wait_for_cdr_lock` (TRSV_REG339 bit 3) actually
     load-bearing for anything in your setup, or is it a leftover
     instrumentation point?** The Rate-B-fails-CDR-but-link-still-up
     observation makes me suspect the latter. If your cal-if's
     `PHY_EMB_CDR_WAIT` poll routinely fires the kick-start writes
     (`pma_writel(0x10, byte 0x888); pma_writel(0x18, byte 0x888);`)
     several times at gs201 in the field too, that would confirm.

3. **Sustained PWM operation wedges the controller silently — second
   of two back-to-back READ_10s never completes, with zero error
   indication.** I forced PWM-G4 SLOWAUTO_MODE as a workaround for
   the HS bug above, and the device successfully enumerates
   (sda/sdb/sdc/sdd attached, GPT scanned, all 31 partitions on sda
   visible). At ~38 s into boot the udev coldplug fires; ~30 s later
   the SCSI mid-layer times out a stuck command and the host is
   re-initialised. The wedge has very specific characteristics:

   - **Trigger**: any second of two READ_10s issued in close
     succession (~10–25 ms apart) at PWM gear. The first command
     completes silently (no logged error); the second one never
     completes.
   - **Independent of**:
     - **Transfer size** — same wedge with `len=65536` (64 KB) and
       `len=32768` (32 KB after clamping `max_hw_sectors`).
     - **LBA region** — wedges on lba=0x3b8b3f0 (near end of disk)
       in one run, lba=0x8 (start of disk) in another. Initial
       hypothesis "high-LBA reads break" was wrong.
     - **Concurrency** — `rd.udev.children-max=1` cmdline serialises
       udev workers; `scsi_change_queue_depth(sdev, 1)` per-LU via a
       new `config_scsi_dev` vops hook strictly serialises commands
       per device. Both leave the wedge intact. Cross-LUN concurrency
       isn't the trigger either; the in-flight wedged command is on
       the same LU as the first (completed) command.
     - **Issuer** — udev-worker, scsi_id, kworker, all wedge identically.
   - **No error indication anywhere**: `saved_err=0x0`,
     `saved_uic_err=0x0`, "No record of pa_err / dl_err / nl_err /
     tl_err / dme_err / fatal_err / auto_hibern8_err / host_reset /
     dev_reset". Just `1 outstanding req` hung indefinitely. The
     SBFES IRQ I originally saw (saved_err=0x20000) was a *symptom*,
     not the cause — masking it via REG_INTERRUPT_ENABLE just shifts
     the failure from "immediate eh_fatal" to "30 s SCSI timeout
     then eh_fatal". Same wedge underneath.
   - **Recovery works, but re-wedges**: full host_reset (h13 pre_link
     re-runs, link comes back up, pwr_change succeeds at PWM-G4
     again) — and then the next udev cycle wedges identically.

   To get to the above, I've ported quite a lot of the AOSP
   `google-modules/soc/gs/drivers/ufs/ufs-exynos.c` and gs201
   `ufs-cal-if.c` into mainline as fork-only experiments to make sure
   I'm not missing a register write AOSP does:

   - `__set_pcs` mechanism for per-lane PCS writes ✓
   - `ufs_cal_pre_pmc` semantics including
     `PA_ERROR_IND_RECEIVED` mask + UserData/L2 timer writes via raw
     `unipro_writel` in AOSP order ✓
   - `ufs_cal_post_pmc` PWM PMA writes (byte 0x20=0x60 COMN,
     byte 0x888=0x08 TRSV, byte 0x918=0x01 TRSV) by adding a
     `gs101_ufs_post_pwr_change` vops hook that drives the Samsung
     PHY framework's state machine through CFG_PRE_PWR_HS →
     CFG_POST_PWR_HS for non-HS gears (mainline gates phy_calibrate
     behind `ufshcd_is_hs_mode`, so these writes are skipped for PWM
     in mainline). The writes do land — TRSV_REG338 CAL_DONE shifted
     from `0x9d` to `0x84` — but the wedge is unchanged.
   - `PRDT_PREFETCH_EN` on `HCI_TXPRDT_ENTRY_SIZE` (AOSP sets this
     unconditionally; mainline only sets it when
     `hba->caps & UFSHCD_CAP_CRYPTO`, and gs201 doesn't get CRYPTO
     because the FMP SMC pair `SMC_CMD_FMP_SECURITY` /
     `SMC_CMD_SMU(SMU_INIT)` aren't actually honoured by BL31 on
     this SoC). Confirmed via UART that
     `HCI_TXPRDT_ENTRY_SIZE = 0x8000000c` after the fork patch; wedge
     unchanged.
   - HCI-level configuration (`HCI_DATA_REORDER = 0xa`,
     `HCI_AXIDMA_RWDATA_BURST_LEN = WLU_EN | BURST_LEN(3)`,
     `HCI_UTRL_NEXUS_TYPE = BIT(nutrs)-1`,
     `HCI_IOP_ACG_DISABLE` cleared) all match AOSP.

   Two of these (the PWM post-PMC writes and the unconditional PRDT
   prefetch) I plan to send upstream as separate patches regardless,
   since they're correct vs your reference driver — but I want to
   wait for your reply first because I don't want to frame them as
   "PWM data-path fixes" when neither actually fixes the wedge.

   The shape of "second back-to-back command wedges silently with no
   error indication" suggests a controller-level race specific to
   PWM gear: maybe the AXI master is in some transient state from the
   first command's completion when the second arrives, or maybe the
   PMA receiver enters a state at PWM that the BUS-FATAL detector
   doesn't notice but the data path can't escape. We've ruled out
   everything we can read from the cal-if file or the host wrapper.

   **The questions:**
   - Is gs201 PWM gear simply not a tested data-path mode? On
     production Pixel Fold the device runs HS-Rate-B; PWM is just a
     transient initial state, so this controller-level race might
     never have been hit at Google.
   - If so, is the right answer "fix HS-Rate-B and forget PWM," or
     is there a setup write / quirk we should be applying for PWM
     that's not in the cal-if file?
   - If you can dump the controller's HCI register state from a
     working AOSP boot at the same point in time we wedge (right
     after a 64 KB READ_10 at PWM gear), I can compare against ours
     to see if any latched state differs.

4. **Two byte-offset → reg-index typos in mainline's
   `tensor_gs101_pre_init_cfg`** (drafted as patch 0004): mainline
   writes 0x974 / 0xA78, AOSP gs201 cal-if writes 0x9F4 / 0xAF8.
   Single hex-digit transposition errors. AOSP's gs101/zuma cal-if
   don't write either pair. Fixing them on a Pixel Fold is observable
   in PHY calibration state (`R338(CAL_DONE)` reads change between
   runs after the fix) — but per the Q2 finding, that calibration
   state doesn't gate the upper-layer link. Are 0x9F4 and 0xAF8
   SoC-specific writes (gs201-only), or do you remember whether
   gs101 silicon also benefits from them? I'd like to know whether
   the upstream patch should split the shared
   `tensor_gs101_pre_init_cfg` table per-SoC or whether the extra
   writes are benign on gs101 too.

I'm happy to share boot logs, the exact diffs I tried, or hop on a
call. There's no rush — I have a few months to land this and I'd
rather get it right than fast.

Thanks,
Chris
