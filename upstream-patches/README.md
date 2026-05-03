# Upstream patches

Patches against the mainline Linux kernel discovered during the gs201
(Tensor G2 / Pixel Fold) bring-up. Each patch is a real upstream-eligible
fix, independent of the gs201-specific DT/driver changes in our fork.

## Send 0002 first — it's the bigger win.

`0001` is a defensive correctness fix that doesn't change observable
behavior on its own. `0002` is the actual root-cause fix that gets gs201
past NOP_OUT and is verifiable end-to-end. Send `0002` first; `0001` can
follow as a related cleanup.

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
