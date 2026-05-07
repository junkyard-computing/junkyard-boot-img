# phy

- **AOSP path**: `private/google-modules/soc/gs/drivers/phy/samsung/`
- **Mainline counterpart**: `drivers/phy/samsung/` (multiple files; see below)
- **Status**: partially-ported (UFS PHY ported with caveats — see [gs-ufs.md](gs-ufs.md) and patches 0004/0007/0009/0010; USB DRD PHY has a Phase A wrapper for HS-only peripheral mode but is still missing the HS-RX-enable sequence and the SS PMA register set; MIPI partially)
- **Boot-relevance score**: 5/10 (does not gate boot, since boot now reaches kmscon over UART without USB); 10/10 for the active USB-gadget bring-up task

## What it does

A pile of Samsung/Exynos PHY drivers used across the SoC:
- `phy-exynos-usbdrd.c` / `phy-exynos-usb3p1.c` — USB3 DRD (SuperSpeed) PHY for the dwc3 controller. gs101/gs201 use a Synopsys USB3.1 PHY; gen2-v4 register definitions for the second (zuma) generation.
- `phy-exynos-snps-usbdp.c` / `phy-exynos-usbdp-gen2-v4.c` — USB-C DisplayPort alt-mode PHY (combined USB3+DP, with TCA register block).
- `phy-exynos-eusb.c` + `eusb_repeater.c` — Embedded USB2 (eUSB2) PHY + on-board repeater (felix uses an eUSB-attached USB2 hub for the front USB-C port).
- `exynos-usb-blkcon.c` — USB block control (PHY isolation, refclk gating).
- `phy-exynos-mipi.c` / `phy-exynos-mipi-dsim.c` — MIPI CSI/DSI D/C-PHY for camera and display panels.

UFS PHY is **not** in this directory — that's `phy-gs101-ufs.c` in mainline already (see `gs-ufs.md`).

## Mainline equivalent

- USB DRD: `drivers/phy/samsung/phy-exynos5-usbdrd.c` exists but covers Exynos5 series only. **No gs101/gs201 USB DRD PHY in mainline.**
- USB2 (S5PV210/Exynos4): `phy-s5pv210-usb2.c`, `phy-exynos4*-usb2.c`. Generic enough that with right DT it would probe but the gs201 USB2 sits behind eUSB which has no mainline driver at all.
- MIPI DSI D-PHY: `drivers/phy/samsung/phy-exynos-dp-video.c`, `phy-exynos-mipi-video.c`. Not gs101 specific; gs101 may need a new compatible.
- USB-DP combined: nothing equivalent in mainline.
- eUSB / eusb_repeater: nothing equivalent in mainline.

## Differences vs AOSP / what's missing

USB DRD PHY: a Phase A port has been started in
`drivers/phy/samsung/phy-exynos5-usbdrd.c` adding a `google,gs201-usb31drd-phy`
compat with a `phy_cfg_gs201` config. Concretely landed:

- **`exynos5_usbdrd_gs201_utmi_init` wrapper**: runs the gs101 UTMI init,
  then performs the AOSP `phy_exynos_usb_v3p1_enable()` ss_cap power-stable
  handshake — `ANA_PWR_EN | PCS_PWR_STABLE | PMA_PWR_STABLE` set on
  `G2PHY_CNTL1` (offset 0x90), `UPCS_PWR_STABLE` set + `TEST_POWERDOWN`
  cleared on `G2PHY_CNTL0` (offset 0x8c). These registers are gs201-only
  (gs101 mainline doesn't touch them).
- **HSP register cleanup**: clears `HSP_EN_UTMISUSPEND` and `HSP_COMMONONN`
  after the gs101 init sets them, matching AOSP felix's
  `common_block_disable=0` DT setting.
- **HSPPARACON tune block (`gs201_tunes_utmi_postinit`)**: TXVREF=8, TXRES=3,
  TXPREEMPAMP=1, SQRX=2, COMPDIS=7. Direct translation of AOSP felix's
  `&usb_hs_tune` properties.
- **PIPE3 init left as a no-op**: any of the gs101 SS PMA writes that aren't
  also valid on gs201 crash ep0out DEPCFG. Setting just
  `CLKRST_LINK_PCLK_SEL` alone (which the gs101 driver does) breaks ep0out
  enable on gs201 — empirically, the link's pipe_pclk source genuinely
  needs the SS PMA to come up, but the gs101 PMA register layout doesn't
  apply on gs201 and we don't have the gs201 PMA register reference.

What's still missing — and is the active blocker for Phase A:

- **HS RX-path enable / calibration after CONNECT_DONE.** AOSP CAL
  (`phy_exynos_usb_v3p1_*`) runs an HS-RX-enable + analog calibration
  sequence after the controller signals CONNECT_DONE that mainline's
  `phy_init` lifecycle never reaches. Symptom: PHY analog edge detection
  works (line-state events fire repeatedly), but no actual SETUP bytes
  reach the controller's RX FIFO. Mainline's `phy_calibrate` hook is the
  sensible attach point but the gs201 register set isn't reverse-engineered
  yet. See the upstream-help email's question E for the full state dump.
- **gs201 SS PMA register table** for a non-stub PIPE3 init (Phase B.5
  debt, needed for SuperSpeed).

eUSB2 / eusb_repeater: not relevant on felix's USB-C port path (felix
appears to take the direct USB3-DRD path, not the eUSB2-then-hub path that
oriole/raven use). Re-verify when porting Phase B if surprises appear.

MIPI PHYs: needed for any DSI display work and any CSI camera work;
mainline has Exynos MIPI D-PHY drivers but none with gs101/gs201 compatibles.

## Boot-relevance reasoning

5/10. Everything boot-critical (UART login, UFS storage, ext4 rootfs)
is independent of these PHYs. **10/10 for the active USB-gadget bring-up
task** — see [gs-usb.md](gs-usb.md) for symptom and the upstream-help email
question E for the open question. MIPI is needed for any panel/camera.
Score 5 reflects "boot succeeds without it; USB-gadget bring-up is the
single open partial bring-up that's gated on closing the HS RX gap here."

## 7.1 rebase impact

Two relevant deltas in mainline 7.1:

- **gs101 USB DT + clock controller is now full upstream.** Our gs201 USB
  Phase A wrapper sits on top of `phy-exynos5-usbdrd.c`; if 7.1 has any
  changes to that file (refactors, new compats, register-write reordering)
  we'll need to merge them through. Re-grep for `EXYNOS850_DRD_*` constants
  and `phy_cfg_*` config arrays after the rebase.
- **UFS PHY framework changes** in `phy-samsung-ufs.c` / `phy-gs101-ufs.c`,
  if any. Patches 0004 (PMA register transcription typos), 0007 (missing
  END terminator), 0009 (cargo-cult H8-entry write removal), and 0010
  (three missing 38.4 MHz refclk path writes) all live in
  `phy-gs101-ufs.c`'s table arrays; rebase will need to handle conflicts
  if upstream re-touched the same arrays.

MIPI D-PHY: the recent gs101 DPU work in 7.1 may bring gs101 MIPI D-PHY
compats; if so, those become the obvious template for any gs201 MIPI
D-PHY port.

