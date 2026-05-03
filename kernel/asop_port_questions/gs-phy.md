# phy

- **AOSP path**: `private/google-modules/soc/gs/drivers/phy/samsung/`
- **Mainline counterpart**: `drivers/phy/samsung/` (multiple files; see below)
- **Status**: partially-ported (USB DRD PHYs **not** ported; UFS PHY ported with caveats; MIPI partially)
- **Boot-relevance score**: 5/10

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

Practically the whole USB stack of PHYs is unported — gs101's USB3 DRD PHY, the eUSB2 PHY + repeater (which is what the **front USB-C port** physically connects through), and the USB-DP combined PHY. MIPI PHYs are needed for any DSI display work and any CSI camera work; mainline has Exynos MIPI D-PHY drivers but none with gs101 compatibles.

Important: when probing fails for the USB DRD PHY, dwc3-exynos cannot complete `usb_phy_init`, the dwc3 core never sees a phy attached, and host-mode USB doesn't enumerate. **felix today reaches console because (a) the OTG USB-C goes through the dwc3 host path that doesn't strictly need the SS PHY for HS-only ethernet dongles, and (b) we use USB ethernet from the dock for connectivity.** If the user's USB ethernet gadget were SuperSpeed-only, this would block.

## Boot-relevance reasoning

5/10. Everything boot-critical (UART, eMMC-equivalent UFS storage, kmscon framebuffer over simpledrm) is independent of these PHYs. USB enumeration is needed for ethernet and USB-C peripherals — currently working at HS speed via a partial mainline path, but **any USB-C dock or SS device will silently fail without the gs101 USB DRD PHY**. MIPI is needed for any panel/camera. Score 5 because USB-host functionality is at risk without it (a soft-blocker for "useful" boot, hard-blocker for any USB-C accessory beyond HS), but it's not in the critical path to login.

