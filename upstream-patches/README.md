# Upstream patches

Patches against the mainline Linux kernel discovered during the gs201
(Tensor G2 / Pixel Fold) bring-up. Each patch is a real upstream-eligible
fix, independent of the gs201-specific DT/driver changes in our fork.

## 2026-05-03 update — dl_err 0x80000002 wedge solved end-to-end

The gs201 UFS path now boots all the way to a mounted ext4 rootfs
(`KIOXIA THGJFGT1E45BAIPB`, 256 GB) at HS-G4 Rate-B with both lanes
locked, and Debian systemd reaches `multi-user.target` at kernel-time
~35 s. Two new root causes pinned this session:

1. **Three writes missing from the AOSP cal-if walk** (patch 0010).
   `tensor_gs101_pre_init_cfg`, `gs101_ufs_pre_link`, and
   `gs201_ufs_post_link` were each missing a single write that AOSP's
   `init_cfg_evt0` / `post_init_cfg_evt0` issue when `USE_UFS_REFCLK ==
   USE_38_4_MHZ` (the gs201 refclk). Without all three, the M-PHY CDR
   never locks at HS-Rate-B and link startup wedges the first SCSI
   command with `dl_err 0x80000002` (TC0_REPLAY_TIMER_EXPIRED).
2. **DESCTYPE-3 left in FMPSECURITY0 by an old probe loop** (patch
   0011). With FMP/inline-crypto disabled, mainline writes 16-byte
   `ufshcd_sg_entry` PRDTs but a probe-loop in `gs201_ufs_smu_init`
   left FMPSECURITY0.DESCTYPE=3 (128-byte FMP `fmp_sg_entry` mode),
   so single-entry PRDTs (INQUIRY) survived but the first multi-entry
   transfer (READ_10 32 KB / 8 PRDs) wedged with OCS=0xf at tag 6.

Plus three smaller felix-history fixes (0007 missing
`END_UFS_PHY_CFG` terminator, 0009 dropping misplaced post-PMC writes,
0008 a complete from-scratch GSA mailbox shim that replaces the
out-of-tree dependency on Trusty for `KDN_SET_OP_MODE`).

The **0001 IOCC patch** is still defensive but is no longer co-blocking
the boot path. The original phrasing in the patch ("matches AOSP, can
not claim this fix unblocks gs201") is now safe to keep verbatim — gs201
boots whether or not this patch is applied. It is still upstreamable
on its own merit.

## Send order (revised)

1. **0002 PRDT_BYTE_GRAN** — biggest single fix (controller writes
   response 1.5 KB further than mainline reads). Send first.
2. **0011 DESCTYPE=0** — second-biggest. Without it, multi-PRD reads
   don't land. Send right after.
3. **0010 three cal-if writes** — fixes HS-Rate-B CDR-lock at the
   38.4 MHz refclk path. Best understood after 0002/0011 are in.
4. **0003 32-bit DMA mask** — silently corrupts on >4 GB DMA;
   AOSP-confirmed and independent.
5. **0007 END_UFS_PHY_CFG** — single-line walker-overrun fix.
6. **0001 IOCC** — defensive cleanup; describe carefully because it
   reverses a recent intentional change.
7. **0004, 0005, 0006, 0008, 0009, 0012** — supporting cast.
8. **0013 gs201 CMU_TOP/MISC + skip_ids** — independent of the UFS
   series; goes to a different maintainer (linux-clk / Sylwester
   Nawrocki) than the others (linux-scsi / linux-samsung-soc / Peter
   Griffin). Send as its own thread.

`0001` is a defensive correctness fix that doesn't change observable
behavior on its own. `0011` is the only patch where landing it
dramatically changes whether this controller works on mainline.
`0013` is foundation work — by itself it doesn't make any new
hardware functional, but it unblocks per-domain follow-ups for
gs201 CMU support.

## 0001-ufs-exynos-don-t-clobber-bootloader-IOCC-bits-when-d.patch

Mainline `exynos_ufs_parse_dt` actively clears the IOCC sharability bits
when `dma-coherent` is absent from DT, instead of leaving the bootloader's
state alone. Discovered while debugging gs201 UFS:

```
exynos-ufshc 14700000.ufs: sysreg-HSI2 IOCC before-iocc-write: @0x710 = 0x00000013
exynos-ufshc 14700000.ufs: sysreg-HSI2 IOCC after-iocc-write : @0x710 = 0x00000010
```

The fix zeros `iocc_mask` (so `regmap_update_bits` becomes a no-op) instead
of `iocc_val` (which actively clears bits). Bootloader-configured IOCC
state is preserved.

**Important context — this patch reverses a deliberate design choice.**
The current "actively clear iocc bits when no dma-coherent" behavior
was intentionally introduced by Peter Griffin in April 2025:
  * `f92bb74` "scsi: ufs: exynos: Disable iocc if dma-coherent
    property isn't set"
  * `68f5ef7` "scsi: ufs: exynos: Move UFS shareability value to
    drvdata"
The patch text needs to defend the change — Peter's intent (keeping
hardware-coherency state consistent with what the kernel claims) is
defensible in isolation; what we're arguing is that the *mechanism*
(active clear) is too destructive for platforms whose bootloaders
configure IOCC bits expected to persist. Be ready for pushback.

**Important caveat:** as of this writing, our gs201 boot test still
fails with the same NOP_OUT-no-response symptom even after this
patch is applied AND `dma-coherent` is added to gs201 DT. So we
*cannot* claim this fix unblocks gs201; it's framed as a defensive
correctness fix that lays the groundwork without solving our
specific problem. Don't oversell.

**Maintainer routing:** drivers/ufs/host/ufs-exynos.c is maintained
by Alim Akhtar <alim.akhtar@samsung.com> with
linux-samsung-soc@vger.kernel.org and linux-scsi@vger.kernel.org on
Cc. **Cc Peter Griffin <peter.griffin@linaro.org>** since we're
modifying his recent change. Confirm with
`scripts/get_maintainer.pl` from inside the kernel tree before
sending.

**Send via:** `git send-email --to=... --cc=... 0001-...patch`

**Verification:** A second Claude session verified the patch against
both mainline master and our local felix submodule
(drivers/ufs/host/ufs-exynos.c:1358-1361 in both shows the
`iocc_val = 0` we're changing to `iocc_mask = 0`). linux-next
couldn't be checked directly because git.kernel.org was behind
Anubis at the time; nothing on the master log suggests a fix is
queued.

## 0002-ufs-exynos-drop-UFSHCD_QUIRK_PRDT_BYTE_GRAN-from-gs2.patch

**The actual root-cause fix.** The gs201 entry in
`exynos_ufs_of_match` was added with `UFSHCD_QUIRK_PRDT_BYTE_GRAN`
inherited from gs101. On gs201 hardware this is wrong — the
controller follows the UFS spec strictly (DWORDS), not the quirk
behavior (bytes). The 4× unit mismatch causes the controller to
write its response 1.5KB further into the UCD than mainline ever
looks.

Confirmed via magic-stamp instrumentation:

```
RSP UPIU: 00000000: abababab abababab abababab abababab    ← mainline reads here
UCD+0x800 (alt rsp loc): 00000000: 00000020 ...            ← controller actually wrote here (NOP_IN = 0x20)
```

Dropping the quirk gets us through NOP_OUT and PWR_MODE_CHANGE
to HS-G4 L2 ("Power mode changed to : FAST series_B G_4 L_2").
A separate PHY CDR-lock issue blocks the next stage of UFS init,
but that's a distinct problem.

**Maintainer routing:** same as 0001 (Alim Akhtar, Peter Griffin,
linux-samsung-soc, linux-scsi). Confirm with
`scripts/get_maintainer.pl`.

**Note:** This change keeps gs101 untouched. gs101 hardware may also
follow the UFS spec (DWORDS) and not need the quirk, in which case
dropping it from gs101 would be an additional cleanup — but I don't
have gs101 hardware to verify, so the safer scope is gs201-only.

## 0003-ufs-exynos-force-32-bit-DMA-mask-on-gs201-Tensor-G2.patch

The gs201 UFS controller advertises `MASK_64_ADDRESSING_SUPPORT` in
its capabilities register but in practice raises
`SYSTEM_BUS_FATAL_ERROR` (IS bit 17, saved_err = 0x20000) when the
AXI master is asked to DMA above the 4 GB boundary. With mainline
trusting the cap bit, the kernel hands out high-memory PRD buffers
during sustained operation; the first such buffer trips the bus
fatal and silently abandons in-flight commands.

Confirmed via OCS_INVALID instrumentation:
```
ocs-instr UCD+0x400: 00 d0 fb 99 08 00 00 00 ...
                     ^^^^^^^^^^^^^^^^^^^^^^^^
                     PRD addr = 0x0000000899fbd000  (>4 GB)
exynos-ufshc 14700000.ufs: fatal_err[0] = 0x20000 at 36254540 us
```

The downstream Android driver hard-codes `DMA_BIT_MASK(32)` for the
entire exynos UFS family, which is a pretty strong signal that this
controller bug is recognised at Google but never documented or
upstreamed. This patch adds a per-variant `dma_mask_bits` field to
`struct exynos_ufs_drv_data` and a new `.set_dma_mask` vop, then
sets `dma_mask_bits = 32` for `gs201_ufs_drvs` only. Other variants
(gs101, exynos7, fsd, exynosauto) keep the existing capability-driven
path. gs101 likely needs the same fix but I don't have hardware.

**Important caveat:** verifying this patch landed correctly does
*not* on its own resolve our gs201 SCSI hang at ~36s into boot.
After the fix, UTRL/PRD addresses are confirmed 32-bit and the
specific high-memory-DMA scenario is gone, but we still see
`fatal_err = 0x20000` from a different code path during sustained
PWM-mode operation. The high-memory DMA bug is real and worth
fixing on its own merits, even if it's not the only thing wrong on
this controller.

**Maintainer routing:** same as 0001/0002 (Alim Akhtar, Peter
Griffin, linux-samsung-soc, linux-scsi). Confirm with
`scripts/get_maintainer.pl`.

## 0004-phy-samsung-gs101-ufs-fix-two-PMA-register-transcrip.patch

Two entries in `tensor_gs101_pre_init_cfg` (in
`drivers/phy/samsung/phy-gs101-ufs.c`) target the wrong registers
because of single-digit transcription typos between the AOSP byte
offset and mainline's reg-index representation:

  | Mainline reg / byte | AOSP entry             | Fix                |
  |---------------------|------------------------|--------------------|
  | `0x25D` (= 0x974)   | `0x9F4 = 0x01`         | reg `0x27D`        |
  | `0x29E` (= 0xA78)   | `0xAF8 = 0x06`         | reg `0x2BE`        |

The bogus writes target registers AOSP's gs101/gs201/zuma cal-if
never touch, while skipping the registers AOSP unconditionally
writes for gs201 (and one of them, `0x974 = 0x01`, also clobbers
an earlier `0x974 = 0x00` entry in the same table).

**Important caveat:** the typo fixes are correct vs the AOSP
reference driver — confirmed via instrumentation that they DO
move PHY calibration state on gs201 (TRSV_REG338
`LN0_MON_RX_CAL_DONE` shifts from `0x9d` to `0x9f` at the entry
to `gs101_phy_wait_for_cdr_lock`) — but they are not on their own
sufficient to make HS-Rate-B CDR lock work on gs201. The
remaining HS-Rate-B issue (TRSV_REG339 bit 3 stays 0 across the
whole 8 ms poll window even with the typo fixes in place) is the
subject of a separate investigation. The patch stands on its own
as a transcription-typo fix; HS-Rate-B comes later.

**Maintainer routing:** drivers/phy/samsung/phy-gs101-ufs.c is
in Vinod Koul's PHY tree. Cc Peter Griffin (original author of
the file), Alim Akhtar (samsung-soc / UFS exynos co-maintainer),
linux-phy@lists.infradead.org, linux-samsung-soc, linux-arm-kernel.
Confirm with `scripts/get_maintainer.pl`.

**Send order note:** 0004 is independent of 0001/0002/0003 and can
go to a different list (linux-phy vs linux-scsi). Send it in its
own series, not bundled with the ufs-exynos ones.

## 0005-ufs-exynos-enable-PRDT-prefetch-on-gs201-without-cry.patch

Drafted 2026-05-02. **HOLD** until the Pixel team / Peter Griffin
have replied — see "Hold status" at the bottom of this file.

`exynos_ufs_post_link` only ORs `PRDT_PREFETCH_EN` (BIT(31)) into
`HCI_TXPRDT_ENTRY_SIZE` when `hba->caps & UFSHCD_CAP_CRYPTO`. On
gs201 we can't get CRYPTO (BL31 doesn't honour the FMP SMC pair),
so the bit ships clear. AOSP sets it unconditionally for every
Tensor SoC. Patch adds an explicit write in `gs201_ufs_post_link`
that overwrites the generic value with `PRDT_PREFETCH_EN | size=12`.

**Important caveat:** confirmed it changes `HCI_TXPRDT_ENTRY_SIZE`
to `0x8000000c` (UART), but does NOT on its own resolve the gs201
SCSI hang at ~38 s into boot at PWM gear (UART log
`uart-logs/2026-05-02_124614.log`). Frame as "match AOSP behaviour";
PWM survival is a separate problem.

**Maintainer routing:** same as 0001/0002/0003 (Alim Akhtar, Peter
Griffin, linux-samsung-soc, linux-scsi).

## 0006-ufs-exynos-gs101-run-PHY-post-PMC-calibration-for-no.patch

Drafted 2026-05-02. **HOLD** until the Pixel team / Peter Griffin
have replied — see "Hold status" at the bottom of this file.

`exynos_ufs_pre_pwr_mode` and `exynos_ufs_post_pwr_mode` gate
`phy_calibrate(generic_phy)` behind `ufshcd_is_hs_mode()`. So when
gs101/gs201 enters PWM gear, the Samsung PHY framework's
CFG_PRE_PWR_HS / CFG_POST_PWR_HS register tables (which include
entries tagged `PWR_MODE_PWM_ANY` and `PWR_MODE_ANY`) never run.
For tensor_gs101 those tables would otherwise apply 5 PMA writes
that match AOSP's `post_calib_of_pwm` byte-for-byte.

Patch adds `gs101_ufs_post_pwr_change` vops hook that, for non-HS
pwr_change, calls `phy_calibrate` twice to advance the PHY state
machine through both stages and apply the missing writes.

**Important caveat:** the missing writes DO change PHY state
(TRSV_REG338 `LN0_MON_RX_CAL_DONE` shifts from `0x9d` to `0x84` at
the entry to `gs101_phy_wait_for_cdr_lock` after the patch, UART
log `uart-logs/2026-05-02_121338.log`), but on a forked
(HS-Rate-B-disabled) gs201 this does NOT on its own fix the PWM SCSI
hang at ~38 s. Frame as "match AOSP behaviour / populate state the
PHY framework was already designed to populate"; PWM data-path
survival is a separate problem.

A cleaner upstream alternative would be a 2-patch series that
(a) makes `samsung_ufs_phy_config` honour the long-existing
`cfg->desc` `PWR_MODE_*` filter (currently dead code), and (b)
removes the HS-only gating in `exynos_ufs_pre_pwr_mode` /
`exynos_ufs_post_pwr_mode` outright. That benefits all variants
rather than just gs101/gs201 and avoids the per-variant hook. I
went with the per-variant hook for the first cut to keep the
blast radius small; happy to respin the cleaner version if a
maintainer prefers it.

The wasted `wait_for_cdr` poll at non-HS gears (~30 ms timeout
per PWM pwr_change) is a separate optimisation worth filing
later.

**Maintainer routing:** same as 0001/0002/0003 (Alim Akhtar, Peter
Griffin, linux-samsung-soc, linux-scsi). Cc linux-phy /
Vinod Koul / Kishon Vijay Abraham I as well — the patch is in
ufs-exynos.c but its observable effect is on the Samsung PHY
framework's state machine.

## Hold status

0001-0004 are sendable today. 0005 and 0006 are drafted but
**held** pending replies from:

- Pixel team contact (`upstream-help/pixel-team-email.md`,
  drafted, NOT sent — depends on user obtaining the contact).
- Peter Griffin (`upstream-help/email.md`, drafted, **NOT sent**
  — user has been asked to hold until approval).

Reason: 0005 and 0006 each match AOSP behaviour exactly, but
**neither fixes the gs201 PWM SCSI hang we've actually been
chasing**. Sending them now risks framing the bring-up effort as
"here are some cosmetic AOSP-parity tweaks" when in fact the real
remaining bug (PWM-gear back-to-back command wedge with zero
error indication) is genuinely not fixable from the cal-if /
HCI-config layer. Both patches are still worth sending eventually
— they're correct fixes — but they should go out *after* the
outreach so the cover letter can frame them honestly: "match AOSP;
do not on their own fix the PWM data-path issue we asked you about
in the linked thread."

---

## 0007-phy-samsung-gs101-ufs-add-missing-END_UFS_PHY_CFG-to.patch

`tensor_gs101_pre_pwr_hs_config` is missing the
`END_UFS_PHY_CFG` terminator the upstream
`samsung_ufs_phy_config()` walker uses to stop iterating. Without
it the walker reads past the array into whatever the linker placed
next — observable as occasional spurious writes at PHY config time.
Single-line correctness fix. Apply alongside 0010 since both touch
the felix PHY tables.

**Maintainer routing:** drivers/phy/samsung/phy-gs101-ufs.c —
linux-arm-kernel and the Samsung PHY maintainer chain. Cc Peter
Griffin (the original gs101 author).

## 0008-ufs-exynos-gs201-KDN_CTRL_MON-dump-GSA-mailbox-shim-.patch

A full from-scratch port of the gs201 GSA (Google Security Anchor)
mailbox protocol so we can issue `GSA_MB_CMD_KDN_SET_OP_MODE = 75`
without the AOSP Trusty dependency. ~80 LoC inline shim plus a
small dump helper. After this runs, `HSI2_KDN_CONTROL_MONITOR`
(sysreg-HSI2 +0x400) flips from 0x4 → 0x5 (MKE+RDY), matching the
AOSP-side state. Direct EL1 writes to the same register silently
NOP — only the GSA-mediated path actually programs it.

This patch isn't strictly needed for the boot path to work — it's a
parity fix with AOSP for the inline-crypto handoff, which mainline
gs201 currently doesn't use. But it's a real, isolated piece of work
that's reusable by anyone doing future gs201 inline-crypto support.

**Maintainer routing:** drivers/ufs/host/ufs-exynos.c —
linux-samsung-soc, linux-scsi, plus the Linaro folks doing Tensor
work (Peter Griffin, William McVicker).

**Caveat:** mailbox protocol details inferred from the AOSP
`google-modules/soc/gs/drivers/soc/google/gsa/gsa.c`; check the
struct layout against current AOSP HEAD before sending.

## 0009-phy-samsung-gs101-ufs-drop-H8-entry-writes-from-post.patch

`tensor_gs101_post_pwr_hs_config` previously contained two writes
that belong to the H8 (hibern8) entry sequence, not the post-PMC
table. Dropping them gives a cleaner R222/R246 state at the
`gs101_phy_wait_for_cdr_lock` entry probe. Independently a small
correctness improvement; only meaningful in combination with the
0010 cal-if-walk fixes (alone it doesn't unblock dl_err).

## 0010-ufs-phy-gs101-gs201-three-missing-writes-from-system.patch

**The big HS-Rate-B fix.** Three single-line writes from a
byte-by-byte AOSP-cal-if walk that mainline's port had quietly
missed:

1. **`PHY_PMA_COMN_REG_CFG(0x29, 0x22, PWR_MODE_ANY)`** added at the
   start of `tensor_gs101_pre_init_cfg`. AOSP's `init_cfg_evt0`
   issues this when `USE_UFS_REFCLK == USE_38_4_MHZ` (gs201
   ufs-cal.h:77). Without it, the PMA reset state for the 38.4 MHz
   refclk is wrong and HS-Rate-B negotiation fails downstream.
2. **`ufshcd_dme_set(hba, UIC_ARG_MIB(0x202), 0x02)`** added in
   `gs101_ufs_pre_link` between MIB(0x200)=0x40 and the per-lane
   writes. Same 38.4 MHz refclk path, on the UniPro side.
3. **`UNIPRO_ADAPT_LENGTH` RMW** in `gs201_ufs_post_link` for
   addresses 0x3348 / 0x334C. AOSP's cal-if treats these as
   `UNIPRO_ADAPT_LENGTH` access, which is a conditional RMW that
   writes 0x3 (not 0x0) for typical reset values. Mainline used to
   write a literal 0x0 here.

Empirical result: with all three, the M-PHY CDR locks first
iteration on both lanes (`R339 = 0x18`), `dl_err 0x80000002` is
gone, and the controller cleanly finishes link-startup at
`FAST series_B G_4 L_2`.

**Send 0010 with 0011** — they're complementary. 0010 makes the
link come up at HS-Rate-B; 0011 makes the first multi-PRD transfer
on that link land in the right buffers.

**Maintainer routing:** drivers/phy/samsung/phy-gs101-ufs.c +
drivers/ufs/host/ufs-exynos.c. Same chain as 0007.

## 0011-ufs-exynos-gs201-drop-DESCTYPE-probe-loop-set-FMPSEC.patch

**The big PRDT-format fix.** A previous round of debugging in
`gs201_ufs_smu_init` looped through `SMC_CMD_FMP_SECURITY` with
DESCTYPE = 0, 1, 2, 3 to "see if a non-3 value unlocks writes for
our mainline 16-byte PRDT setup." Each SMC succeeded, so the
*last* call latched FMPSECURITY0.DESCTYPE = 3 — the 128-byte
`fmp_sg_entry` mode AOSP uses with inline crypto.

Mainline gs201 disables FMP (no `EXYNOS_UFS_OPT_UFSPR_SECURE`), so
`exynos_ufs_fmp_init` early-returns and `ufshcd_set_sg_entry_size`
is never called. The kernel writes 16-byte `struct ufshcd_sg_entry`
while the controller reads 128-byte stride — single-entry PRDTs
(INQUIRY) survived (only entry 0 is read), but the first
multi-entry transfer wedged. Visible as:

```
[62.6s] ufshcd_abort: Device abort task at tag 6
sd 0:0:0:0: [sda] tag#6 CDB: opcode=0x28 28 00 00 00 00 08 00 00 08 00
                            -> READ_10 lba=0x8 length=8 sectors = 32 KB / 8 PRDs
UTRD: ocs=0x0f (controller never wrote)
UPIU RSP: all zero (controller never wrote)
PA/DL/NL err: 0x0
```

Fix: replace the four-call probe with a single
`SMC_CMD_FMP_SECURITY(0, SMU_EMBEDDED, 0)` so DESCTYPE=0
(16-byte standard PRDT) which is what our `sg_entry_size`
matches. `SMC_CMD_SMU(SMU_INIT)` and `SMC_CMD_FMP_SMU_RESUME`
are unchanged — those open the SMU/UFSP fence.

**This is the most-load-bearing single patch in the new series.**
Without it, every multi-PRD read or write hangs on gs201 mainline.

## 0012-ufs-phy-gs201-silence-debug-instrumentation-dev_info.patch

Bulk `dev_info → dev_dbg` for the bring-up instrumentation in
`ufs-exynos.c`, `phy-gs101-ufs.c`, and `ufshcd.c`'s
ufs-cmd-issue trace. AOSP runs with `loglevel=4` and doesn't
have these prints in the first place; with the wedge fixed,
the verbose output was throttling 115200-baud UART by ~70 s
per boot.

This is **not** an upstream-quality patch (it's a quick
"shut it up" sweep); a proper cleanup pass is owed before
sending — keep `dev_warn`/`dev_err`, drop the dump helpers
entirely or gate them behind a Kconfig debug option. Tracked
in the auto-memory `feedback_uart_verbosity.md`.

## 0013-clk-samsung-gs101-add-gs201-Tensor-G2-CMU_TOP-CMU_MI.patch

First step toward gs201 CMU support upstream. Three pieces:

1. **`skip_ids[]` infrastructure in `clk.c`/`clk.h`.** Adds a generic
   way for a CMU driver to declare clock IDs that
   `samsung_cmu_register_clocks()` should drop from its per-clock-type
   register helpers. Filters the input arrays once into a kcalloc'd
   copy, runs the existing register helpers against the filtered
   list, then frees the copies. No behavior change for any CMU
   driver that doesn't set `skip_ids`.

2. **`gs201_top_skip_ids[]` + `top_cmu_info_gs201`.** Empirical list
   of CMU_TOP clock IDs that read-fault on real gs201 hardware:
     - Power-gated sub-block bridges (BO/AUR/CSIS/DNS/DPU/G2D/G3AA/
       G3D/GDC/IPP/MCSC/MFC/TNR/TPU and their bus dividers). gs201's
       AOSP stack pre-powers these via pkvm-s2mpu + exynos-pd at EL2
       before CMU registration; mainline doesn't, so we just don't
       touch them.
     - SHARED PLL fan-out dividers from SHARED0_DIV4 onwards plus
       all of SHARED1/2/3 — register holes on gs201 (gs201 implements
       fewer fan-out dividers than gs101).
   `top_cmu_info_gs201` reuses gs101's PLL/mux/div/gate tables and
   layers `skip_ids` on top.

3. **`google,gs201-cmu-top` of_match entry + `google,gs201-cmu-misc`
   `CLK_OF_DECLARE`.** Two compats with validated cal data; the
   former wires up `top_cmu_info_gs201`, the latter shares
   `gs101_cmu_misc_init` (CMU_MISC layout is identical between
   gs101 and gs201 per AOSP cal-if `cmucal-sfr-gs201.c`).

**Deliberately NOT included:** gs201 compats for APM, DPU, HSI0,
HSI2, PERIC0, PERIC1. Their gs101 `_cmu_info` data tables don't
apply cleanly to gs201 — the most recent test (2026-05-03,
concurrent `cmu_top` + `cmu_peric0` enable on real felix
hardware) panicked the same way CMU_TOP did before its skip list
was built (`Asynchronous SError Interrupt` inside
`clk_divider_recalc_rate`). Adding these compats will require
auditing each domain's register layout against AOSP
`private/google-modules/soc/gs/drivers/soc/google/cal-if/gs201/
cmucal-sfr.c` and adding per-domain `skip_ids` lists (or full
gs201-specific `samsung_cmu_info` structs if the layouts diverge
more). Multi-day project; this patch is the foundation it builds on.

**Init-call ordering:** kept at `core_initcall` to match existing
gs101 behavior. On gs201 specifically the platform driver needs to
probe **after** pKVM has unlocked CMU access at EL2 (BL31 firewalls
the CMU register block from non-secure EL1 unless `kvm-arm.mode=
protected`), but consumers downstream of CMU all support
defer-probe so the existing ordering should work in practice. If
clk-gs101 probe ends up firing before pKVM init on real gs201
boards, a follow-up patch will move just the gs201 path to a
later initcall.

**Practical impact for the felix bring-up tree:** with this patch
applied and `cmu_top` declared in DT (with `kvm-arm.mode=
protected` on cmdline), CMU_TOP probes cleanly. UART consumers
(`samsung,exynos850-uart`) and any other downstream peripheral
that wants real clock rates from CMU_PERIC0 still defer-probe
forever — those wait for the follow-up gs201-cmu-peric0 work.
