To: peter.griffin@linaro.org
Subject: gs201 (Tensor G2 / Pixel Fold) UFS bring-up — root cause found, patch + new question

Hi Peter,

A quick FYI plus one new question. I emailed earlier about gs201 UFS NOP_OUT
silently failing on a fork of v7.0-rc4. Found the root cause; sending the
fix as a separate patch (will Cc you).

## Root cause: UFSHCD_QUIRK_PRDT_BYTE_GRAN is wrong for gs201

The gs201 entry in `exynos_ufs_of_match` was added carrying
`UFSHCD_QUIRK_PRDT_BYTE_GRAN` inherited from gs101. On gs201 the controller
follows the UFS spec strictly: `response_upiu_offset` and `prd_table_offset`
in the UTRD are in DWORDS, not bytes.

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

Patch attached as `0002-ufs-exynos-drop-UFSHCD_QUIRK_PRDT_BYTE_GRAN-from-gs2.patch`.

I'm keeping `gs101_ufs_drvs` unchanged. gs101 hardware may also follow the
DWORDS spec and not need the quirk, in which case dropping it from gs101
would be an additional cleanup — but I don't have gs101 hardware to verify.
Worth a quick test on your end if you have a Pixel 6 to hand?


## New blocker: PHY CDR lock failure post-PWR_MODE_CHANGE

Right after the link transitions to HS:

  samsung-ufs-phy 14704000.phy: failed to get cdr lock
  exynos-ufshc 14700000.ufs: Power mode changed to : FAST series_B G_4 L_2

The "failed to get cdr lock" is from `gs101_phy_wait_for_cdr_lock` in
`drivers/phy/samsung/phy-gs101-ufs.c` — it polls TRSV_REG339's
`LN0_MON_RX_CDR_FLD_CK_MODE_DONE` bit and times out after 100×40us
(retries with `OVRD_RX_CDR_EN` overrides, also fails).

UFS init then proceeds (no early bailout on CDR-lock failure), but the
first device-management QUERY UPIU after the power-mode change times out.
The SCSI error path triggers an abort which then panics in
`scsi_eh_scmd_add+0x104/0x10c` with "WARNING: drivers/scsi/scsi_error.c:314"
on a `scmd_eh_abort_handler` workqueue. (The panic is a separate bug — the
abort handler isn't expecting the state we're in.)

NOP_OUT (issued at PWM, before the power-mode change) succeeds. The
problem appears specifically tied to HS-mode operation post-PWR_MODE_CHANGE.

So my new question: **on gs101 mainline, does `gs101_phy_wait_for_cdr_lock`
ever return error in practice?** If yes, what tuning made it pass? If no,
gs201 silicon (felix/Tensor G2) probably needs additional PHY post-pwr_change
calibration that mainline doesn't do — likely a subset of AOSP's
`post_calib_of_hs_rate_b` / `post_calib_of_hs_rate_a` cal-if writes
(`PHY_EMB_CDR_WAIT @ 0xCE4 = 0x08` looks particularly relevant given the
"CDR" in our failing function name, and `PHY_PMA_TRSV @ 0x918 = 0x01`).

I'd been gun-shy about porting AOSP cal-if writes — a previous attempt to
port the PRE-link section broke link startup outright — but the post-pwr
section is tighter and more targeted. Happy to share the cal-if file
diffs if that helps.

Thanks again for any pointers.

Best,
Chris
