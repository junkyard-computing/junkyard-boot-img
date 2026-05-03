To: peter.griffin@linaro.org
Subject: gs201 (Tensor G2 / Pixel Fold) UFS bring-up — root cause + 4 patches (+ 2 drafts) + new questions

Hi Peter,

A FYI plus one new question. I emailed earlier about gs201 UFS NOP_OUT
silently failing on a fork of v7.0-rc4. Since then I've found four
upstream-eligible bugs in the gs201 path; the patches are drafted
(0001-0004 in my repo at <MY GITHUB OR ATTACH>) and I'll Cc you when
sending. One of them (0004) touches your `phy-gs101-ufs.c`, so heads-up
below.

Two more patches (0005 PRDT_PREFETCH_EN and 0006 phy_calibrate for
non-HS pwr_change) are drafted but held — both match AOSP behaviour
byte-for-byte, but neither on its own resolves the new HS-mode bug
described in the "New blocker" section, and I'd rather not muddy the
0001-0004 series with "matches AOSP, doesn't actually fix anything
visible" patches before you've had a chance to see the new question.

## 0002 — root cause: UFSHCD_QUIRK_PRDT_BYTE_GRAN is wrong for gs201

The gs201 entry in `exynos_ufs_of_match` was added carrying
`UFSHCD_QUIRK_PRDT_BYTE_GRAN` inherited from gs101. On gs201 the
controller follows the UFS spec strictly: `response_upiu_offset` and
`prd_table_offset` in the UTRD are in DWORDS, not bytes.

With the quirk set, `ufshcd_host_memory_configure` writes
`response_upiu_offset = ALIGNED_UPIU_SIZE` (literal 0x200, "bytes"). The
controller reads 0x200, treats it as DWORDS, writes the response UPIU at
UCD+0x800 instead of UCD+0x200. Mainline reads at UCD+0x200 (per the C
struct layout) and sees nothing — exactly the
"controller signals UTRCS, doorbell clears, response slot empty, no UIC
errors at any layer" symptom.

Confirmed by stamping the response slot with 0xAB before submitting NOP_OUT
and dumping memory at the alternate location:

  RSP UPIU: 00000000: abababab abababab abababab abababab    ← UCD+0x200 (mainline reads here)
  UCD+0x800 (alt rsp loc): 00000000: 00000020 00000000 ...    ← controller actually wrote here (NOP_IN = 0x20)

Dropping the quirk from `gs201_ufs_drvs` makes mainline emit dword
offsets, which the controller correctly interprets, and NOP_OUT
completes. PWR_MODE_CHANGE to HS-G4 L2 then succeeds:

  exynos-ufshc 14700000.ufs: Power mode changed to : FAST series_B G_4 L_2

I'm keeping `gs101_ufs_drvs` unchanged. gs101 hardware may also follow the
DWORDS spec and not need the quirk, in which case dropping it from gs101
would be an additional cleanup — but I don't have gs101 hardware to verify.
Worth a quick test on your end if you have a Pixel 6 to hand?

## 0001 — IOCC bits should not be actively cleared when no dma-coherent

This one reverses a piece of your `f92bb74` ("scsi: ufs: exynos: Disable
iocc if dma-coherent property isn't set") in mechanism only — keeps your
intent. mainline's `exynos_ufs_parse_dt` currently sets `iocc_val = 0`
when `dma-coherent` is absent, which then *actively clears* the
bootloader-configured IOCC sharability bits via
`regmap_update_bits`:

  exynos-ufshc 14700000.ufs: sysreg-HSI2 IOCC before-iocc-write: @0x710 = 0x00000013
  exynos-ufshc 14700000.ufs: sysreg-HSI2 IOCC after-iocc-write : @0x710 = 0x00000010

The patch zeros `iocc_mask` instead, so `regmap_update_bits` becomes a
no-op when DT doesn't request IOCC, and the bootloader's pre-configured
state survives. I'd love your sanity check on the framing — happy to
defend it on-list, but you'd see it before me.

## 0003 — gs201 controller cap MASK_64_ADDRESSING_SUPPORT lies

The gs201 UFS controller advertises `MASK_64_ADDRESSING_SUPPORT` (cap bit
24) but raises `SYSTEM_BUS_FATAL_ERROR` (IS bit 17, saved_err 0x20000)
when the AXI master is asked to DMA above the 4 GB boundary. Trapped
during sustained operation when the kernel's general allocator handed
out a high-memory PRD buffer:

  ocs-instr UCD+0x400: 00 d0 fb 99 08 00 00 00 ...    ← PRD addr = 0x899fbd000 (>4 GB)
  exynos-ufshc 14700000.ufs: fatal_err[0] = 0x20000 at 36254540 us

The downstream Android driver hard-codes `DMA_BIT_MASK(32)` for the entire
exynos UFS family
(`google-modules/soc/gs/drivers/ufs/ufs-exynos.c`), which suggests this
is a known-but-undocumented controller bug at Google. Patch adds a
per-variant `dma_mask_bits` field and a `.set_dma_mask` vop, sets it to
32 only for `gs201_ufs_drvs`. gs101 likely needs the same fix but I
don't have hardware — happy to drop a follow-up if you can confirm.

## 0004 — two PMA register transcription typos in tensor_gs101_pre_init_cfg

This one touches your file directly so I want to flag it before sending.
While bisecting AOSP's gs201 cal-if against
`drivers/phy/samsung/phy-gs101-ufs.c`'s `tensor_gs101_pre_init_cfg`, I
found two entries that look like single-digit byte-offset → reg-index
typos:

  AOSP gs201 ufs-cal-if `init_cfg_evt0`:
    {0x0000, 0x9F4, 0x01, ..., PHY_PMA_TRSV, ...}
    {0x0000, 0xAF8, 0x06, ..., PHY_PMA_TRSV, ...}

  Current mainline:
    PHY_TRSV_REG_CFG_GS101(0x25D, 0x01, ...)   /* byte 0x974 */
    PHY_TRSV_REG_CFG_GS101(0x29E, 0x06, ...)   /* byte 0xA78 */

`0x974` differs from `0x9F4` by one swapped hex digit; `0xA78` from
`0xAF8` likewise. Neither `0x974` nor `0xA78` is written by AOSP's
gs101, gs201, or zuma cal-if; both `0x9F4` and `0xAF8` are. The bogus
`0x25D=0x01` write also clobbers the `0x25D=0x00` entry at the top of
the same table.

Tested on Pixel Fold: the fix is observable — `TRSV_REG338`
(`LN0_MON_RX_CAL_DONE` register) at the entry to
`gs101_phy_wait_for_cdr_lock` shifts from `0x9d` to `0x9f`, indicating
an extra calibration step now completes. But it's not on its own
sufficient to make HS-Rate-B CDR lock work on gs201 (CDR lock check
still times out — see new question below).

The shared `tensor_gs101_pre_init_cfg` is used by both gs101 and gs201
drvdata; AOSP's gs101 cal-if doesn't write `0x9F4`/`0xAF8` so this
patch adds two extra unconditional writes for gs101. Likely benign
(PMA register defaults) but I'd appreciate a sanity check from someone
with gs101 hardware before this lands.

## New blocker: HS data-path is dead post-PWR_MODE_CHANGE on gs201

This started as a CDR-lock investigation; after a much wider bisect I
now think CDR is a red herring and the actual bug is at the UniPro DL
layer right after pwr_change. Both rates fail identically, but they
fail at different observable layers.

The bisect matrix (all with the AOSP-mechanism ports landed; full
matrix in my notes if you want):

  | rate | gear | ADAPT | CDR lock | dl_err 0x80000002 |
  |------|------|-------|----------|---------------------|
  | B    | 4    | off   | fail     | yes                 |
  | A    | 4    | off   | OK       | yes (same)          |
  | A    | 3    | off   | OK       | yes                 |
  | A    | 1    | off   | OK       | yes                 |
  | B    | 1    | off   | fail     | yes (same)          |
  | A or B | any | on   | n/a      | pwr_change fail upmcrs:0x5 |

Two surprises in there. First, **Rate-A locks CDR cleanly** (`cdr lock
OK lane=0 after 1 iters first=0x18 last=0x18`) where Rate-B always
fails (`TRSV_REG339 first=0x00 last=0x00 across 100 polls`). Second,
**Rate-B's CDR-lock failure does not actually gate anything** — even
when CDR fails, mainline reports `Power mode changed to: FAST series_B
G_x L_2` and the first frame still gets the same dl_err 0x80000002.
So whatever your `gs101_phy_wait_for_cdr_lock` indicator is tracking
(TRSV_REG339 bit 3), it's some PHY-internal state that distinguishes
rates but doesn't gate the actual data path on this silicon. I think
my months of TRSV_REG339-chasing missed this because I was always at
Rate-B; the CDR-lock failure correlated with the dl_err but didn't
cause it.

The real bug: at HS (any rate, any gear), the device never ACKs the
host's first frame after pwr_change. UPIU response slot stays as my
magic-stamp `0xab` fill pattern (controller never wrote anything),
host's TC0 replay timer expires after ~37 ms (I added a 100 ms
`msleep` in `post_pwr_change` to test settle-delay; the dl_err just
shifted by exactly 100 ms). 6 s later the SCSI mid-layer times out
the stuck command, `ufshcd_abort` itself times out (-110), and the
WARN at `scsi_eh_scmd_add+0x104/0x10c`
(drivers/scsi/scsi_error.c:314) trips. Controller is wedged.

What I've ported from AOSP (none individually fix it, none reliably
regress anything either — the AOSP-mechanism stack is now a no-op
black box on top of the original failure):

  - **`__set_pcs` mechanism for per-lane PCS writes** —
    `unipro_writel(val, sfr)` bracketed by
    `UNIP_COMP_AXI_AUX_FIELD = __WSTRB | __SEL_IDX(lane)`,
    replacing mainline's `ufshcd_dme_set(UIC_ARG_MIB_SEL(addr, lane),
    val)`. Same MIBs, same computed `mclk_period` /
    `__get_line_reset_ticks` values mainline already wrote via
    `VND_RX_CLK_PRD`/`VND_TX_CLK_PRD`/`VND_RX_LINERESET_VALUE2` etc.
    aliases.
  - **`ufs_cal_pre_pmc` semantics** — `PA_ERROR_IND_RECEIVED` mask
    in `UNIP_DL_ERROR_IRQ_MASK` (BIT(15)), then UserData / L2 timer
    writes via raw `unipro_writel` in AOSP order including the
    `UNIPRO_STD_MIB` `0x4104/0x4108/0x410C` aliases mainline never
    wrote.
  - **`ufs_cal_post_pmc` for PWM**: drafted as patch 0006 (see
    below) — adds a `gs101_ufs_post_pwr_change` vops hook that
    drives the Samsung PHY framework state machine through
    `CFG_PRE_PWR_HS → CFG_POST_PWR_HS` for non-HS gears too,
    applying the 3 PMA writes from `tensor_gs101_post_pwr_hs_config`
    that match AOSP's `post_calib_of_pwm` byte-for-byte but
    otherwise never run because `phy_calibrate` is gated behind
    `is_hs_mode` in `exynos_ufs_pre/post_pwr_mode`. Verified
    R338(CAL_DONE) shifts `0x9d → 0x84` after the hook fires for PWM,
    so the writes land. For HS modes the existing
    `exynos_ufs_post_pwr_mode` already calls `phy_calibrate` so the
    hook is a no-op.
  - **`PRDT_PREFETCH_EN`**: drafted as patch 0005 — AOSP unconditional,
    mainline only ORs it into `HCI_TXPRDT_ENTRY_SIZE` if
    `hba->caps & UFSHCD_CAP_CRYPTO`. We can't get CRYPTO on gs201
    (BL31 doesn't actually program FMP — `SMC_CMD_FMP_SECURITY` /
    `SMC_CMD_SMU(SMU_INIT)` both return `a0=0` but the FMP security
    registers stay at `0xffe26492` / `0xfffa6492` bus-fault sentinels),
    so mainline gs201 ships TX-PRDT-prefetch-disabled.

Also tried **`PA_TxHsAdaptType = ADAPT_INITIAL`**
(MIB 0x15D4 = 0x1; the only UNIPRO_STD_MIB entry in AOSP's
`calib_of_hs_rate_a/b` that mainline doesn't already do): always
breaks pwr_change with `upmcrs:0x5` (PWR_FATAL_ERROR), regardless of
rate, write mechanism, mask order, or write order. With everything
else AOSP-faithful but adapt skipped, pwr_change succeeds — but the
dl_err follows. So adapt requires some additional precondition
mainline isn't providing.

I'm holding 0005 and 0006 as drafts pending your reply because
neither actually fixes the dl_err and I don't want to mislead the
maintainers by framing them as data-path fixes; they're "matches
AOSP behaviour, doesn't on its own help". I'll send them in the
0001-0004 series eventually, but the cover letter would be cleaner
with your reply included.

So my new question: **on gs101 (Pixel 6/Pro) mainline, does HS-Rate-B
boot a real Linux rootfs end-to-end?** If yes, the gs201 difference
narrows dramatically — ideally to a per-SoC PMA write or quirk
I can extract from a diff between gs101 and gs201 in your AOSP cal-if.
If you've never tested mainline past initial probe (i.e. you saw
"Power mode changed" succeed and called it done), that itself is a
useful data point — would mean the dl_err might lurk on gs101 too
and just hasn't been hit because nobody ran a real SCSI workload on
mainline gs101. Either answer narrows my search.

Secondary: **does `gs101_phy_wait_for_cdr_lock` ever return error in
your gs101 mainline testing?** If never — ok, my "Rate-B fails CDR
on gs201, Rate-A locks" observation is a real silicon difference
(gs201 PHY at Rate-B is broken in some way gs101 isn't). If
sometimes — interesting, would mean the indicator is flaky on gs10x
generally and reinforces my "CDR is a red herring" suspicion.

As before, no rush — happy to share boot logs, the exact diffs I
tried, or hop on a call. There's a few months of runway on this.

Best,
Chris
