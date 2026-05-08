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

### Hypotheses tested 2026-05-07 (all negative)

A systematic AOSP register-walk through `phy_exynos_usb_v3p1_enable()` +
`phy_exynos_usb_v3p1_pipe_ovrd()` surfaced four candidate divergences from
the mainline path. Each was tested by editing
`exynos5_usbdrd_gs201_utmi_init`, building, flashing, and capturing host
dmesg. All four produced byte-identical EPROTO storms (`device descriptor
read/64, error -71` plus `Device not responding to setup address`). None
moved the symptom.

| # | Hypothesis | Edit | Result |
|---|---|---|---|
| 1 | Mainline's `exynos5_usbdrd_usb_v3p1_pipe_override` unconditionally sets `SECPMACTL_PMA_LOW_PWR` (powers down the COMBO PMA). AOSP's `phy_exynos_usb_v3p1_pipe_ovrd` gates the PMA disable on `!ss_cap` — for gs201 (ss_cap=true) it leaves the PMA powered. Expected the gs201 G2 PHY's HS analog path to share calibration with COMBO PMA. | Clear `SECPMACTL_PMA_LOW_PWR` after `exynos850_usbdrd_utmi_init` returns. | Negative — same EPROTO storm. |
| 2 | Mainline's `exynos850_usbdrd_utmi_init` unconditionally sets `LINKCTRL_FORCE_QACT` (HWACG disable). AOSP's `exynos_cal_usbphy_q_ch` only manipulates QACT for VER_03_0_0 (gs101). For VER_05_0_0+ (gs201) AOSP leaves the Q-channel alone. Expected forcing QACT high to break the natural Q-channel handshake on gs201. | Clear `LINKCTRL_FORCE_QACT` after `exynos850_usbdrd_utmi_init` returns. | **Regression — mainline's setting is load-bearing.** With FORCE_QACT cleared, the dwc3 event ring went from ~200 RESET + ~200 CONNECT_DONE down to **0 RESET + 0 CONNECT_DONE + 0 endpoint events** — even gadget-bind dumps showed no subsequent device activity. The PHY clock was auto-gating when the controller idled, killing line-state event delivery entirely. AOSP's bootloader/PMU presumably leaves QACT effectively high via a different path (or `exynos_cal_usbphy_q_ch` runs from a different code path on gs201 that we haven't found). Reverted; mainline's FORCE_QACT is correct. |
| 5 | Felix's AOSP `&usb_hs_tune` DT node has `status = "disabled"`. AOSP doesn't apply the HSPPARACON tune values on felix; the PHY runs with HSPPARACON at hardware reset values. Mainline's `gs201_tunes_utmi_postinit` block reconfigures HSPPARACON on every probe (TXVREF=8, TXRES=3, TXPREEMPAMP=1, SQRX=2, COMPDIS=7). Hypothesis: HSPPARACON tune values may put the PHY in a state AOSP never tested. | Set `gs201_usbd31rd_phy.phy_tunes = NULL` so `apply_phy_tunes()` short-circuits and HSPPARACON stays at reset. | Negative — same baseline shape (162 RESET + 144 CONDONE + 364 device events + 0 endpoint events). HSPPARACON tune is not the gap. Reverted. |
| 3 | OTP-override path: AOSP's `exynos_usbdrd_utmi_init` runs `samsung_exynos_cal_usb3phy_write_register` for every entry in `phy_drd->otp_data[]` after enable. Speculated felix carries per-device PHY calibration in OTP that mainline doesn't apply. | Investigated; **`CONFIG_EXYNOS_OTP` is not set in `felix_defconfig`**, so the OTP block (`#if IS_ENABLED(CONFIG_EXYNOS_OTP)`) is dead code on AOSP felix. Ruled out without a build. | N/A — dead code on AOSP. |
| 4 | `GUSB2PHYCFG.ENBLSLPM=1` (controller parks PHY in low-power between transfers). Speculated PHY doesn't wake fast enough to catch SETUP after CONNECT_DONE. | Investigated; AOSP DT doesn't carry `snps,dis_enblslpm_quirk` either, so AOSP also has `ENBLSLPM=1`. Not the gap. | N/A — matches AOSP. |

### Implications for the active blocker

The FORCE_QACT regression actually narrows the search usefully. Two
distinct PHY behaviours can now be characterised:

- **Link-layer reception** (the path that fires `RESET` + `CONNECT_DONE`
  events into dwc3 when the host drives the bus): healthy on gs201
  **only when** `LINKCTRL_FORCE_QACT=1`. The PHY clock has to be held
  un-gated for the link-state machine to deliver bus-event interrupts.
  Mainline's unconditional FORCE_QACT setting is load-bearing here.
- **Data-layer packet reception** (the path that delivers SETUP bytes
  from the host into the controller's RX FIFO): broken on gs201
  regardless of every PHY-register tweak we've tested. Both with
  FORCE_QACT=1 (link layer works, ~200 RESET + ~200 CONNECT_DONE,
  0 endpoint events) and with FORCE_QACT=0 (link layer also dies,
  0 of everything), the data-layer delivery never happens.
  `phy_tunes=NULL` (matching AOSP felix's `status = "disabled"`)
  also produces the baseline 200/200/0 shape.

So the missing AOSP step is **not** in the QACT/clock-gating layer and
**not** in the per-register-write differences we've enumerated inside
`phy_exynos_usb_v3p1_enable()`. Five hypotheses tested at the wrapper
level (PMA, FORCE_QACT, OTP, ENBLSLPM, HSPPARACON-tune) — exactly one
useful learning (FORCE_QACT is load-bearing). The cheap walk has hit
its limit.

Where the missing step plausibly lives now:

- **dwc3 controller programming** (GSBUSCFG0 / GUCTL / GUSB3PIPECTL).
  AOSP's `dwc3_core_config()` runs ~180 lines of register writes mainline
  doesn't, particularly the `GSBUSCFG0` request-info bits that drive AXI
  cache attributes during descriptor and data DMA. **This is now the
  active investigation.** See [gs-usb.md](gs-usb.md) for the walk results
  and ranked test plan.
- **PMA/PCS register writes beyond CNTL0/1.** Our `phy_cfg_gs201`
  has a no-op PIPE3 init because the gs101 PMA register layout doesn't
  apply on gs201. AOSP's `phy_exynos_usb_v3p1_pma_ready`,
  `phy_exynos_usb_v3p1_g2_pma_ready`, and `phy_exynos_usb_v3p1_pma_sw_rst_release`
  do PMA-side writes we never make. Reverse-engineering the gs201 PMA
  register set is the same blocker as Phase B.5.
- **Real cmu_hsi0 USB ref clock** instead of the 26 MHz fixed-clock stub.
  Speculative — but the user-mux trip we hit suggests the PHY's
  expectations about its reference-clock provider may be more nuanced
  than "any 26 MHz signal."
- **CR / SSP_CR access protocol** in `late_enable` for ss_cap.
  Single write of `0xf=0x03d0` (TX_VBOOST_LVL=0x7). Cheap to add if we
  can implement the CR-access bus protocol.

Remaining unexplored areas of the AOSP flow:

- **The HSPPARACON tune block itself.** New finding 2026-05-07 mid-walk:
  felix's AOSP `&usb_hs_tune` DT node has `status = "disabled"`. So
  AOSP **does not apply** these tune values on felix in production —
  the PHY runs with HSPPARACON at hardware reset values. Our
  `gs201_tunes_utmi_postinit` applies them (TXVREF=8, TXRES=3,
  TXPREEMPAMP=1, SQRX=2, COMPDIS=7), which means we are reconfiguring
  HSPPARACON when AOSP isn't. **Worth testing whether disabling our
  tune block (leaving HSPPARACON at reset) restores AOSP-equivalent
  behaviour.** Note: there's also a `utmi_clk` tune entry in felix's
  DT that the AOSP HSP walker doesn't handle — it's parsed but
  unused by the standard tune path.
- The Configuration-Register access protocol (`cr_access` /
  `ssp_cr_access`) used by `late_enable` for ss_cap (writes
  `0xf=0x03d0` for TX_VBOOST_LVL).
- The Test Interface (`tif_access`) override mechanism — only used
  by tune entries `tx_res_ovrd` and `tx_dis_inc`, which felix's DT
  doesn't carry.
- Anything outside the PHY: dwc3 core init, the dwc3-exynos glue, the
  controller's GCTL / DCFG / DCTL programming sequence.

The cheap walk has plausibly exhausted its ROI for the in-the-wrapper
register tweaks. Higher-confidence move from here: the actual graft
(stubbed-CAL build of `phy-exynos-usb3p1.c` running side-by-side) so we
can A/B specific writes against a known-working reference.

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

