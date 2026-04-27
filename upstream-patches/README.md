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
