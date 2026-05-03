# pci

- **AOSP path**: `private/google-modules/soc/gs/drivers/pci/controller/dwc/` (and `dwc-whi/`)
- **Mainline counterpart**: `drivers/pci/controller/dwc/pci-exynos.c` (and the generic `pcie-designware*` core)
- **Status**: partially-ported (mainline driver is generic Designware glue; AOSP gs-specific RC + per-SoC PHY CAL is not ported)
- **Boot-relevance score**: 4/10

## What it does

PCIe Root Complex driver for gs101/gs201/zuma. Wraps the Synopsys DesignWare PCIe IP (the same core used by every modern Exynos SoC) with per-SoC PHY calibration tables (`pcie-exynos-gs101-rc-cal.c`, `pcie-exynos-gs201-rc-cal.c`, `pcie-exynos-zuma-rc-cal.c`), L1.x ASPM tuning, link-up/link-down state machine, ITMON debug hooks, MSI/MSI-X demux, and an extensive PM-QoS/notifier interface used by the modem driver to coordinate L1.2 entry/exit. The `dwc-whi/` variant is a White-Hot-Iron (WHI = unclear, but appears to be a Pixel-specific stripped-down build) flavor missing the zuma cal file.

## Mainline equivalent

`drivers/pci/controller/dwc/pci-exynos.c` (396 lines vs AOSP `pcie-exynos-rc.c` 5957). Mainline has been refactored down to a minimal Designware platform glue — it relies on the generic `pcie-designware-*.c` for most of the controller work. Standard `samsung,exynos5433-pcie` style binding; gs101/gs201/zuma compatibles are not present.

## Differences vs AOSP / what's missing

The gap is enormous (~5500 lines). High-level missing:
- gs101/gs201 PHY CAL tables (PHY register sequences for L0/L1/L1.1/L1.2 entry, RX EQ tuning, signal-integrity bring-up). Without the right cal sequence the link will not train.
- modem-coordination IPC (`exynos-pci-noti.h`, `exynos-pci-ctrl.h`) — the AOSP modem driver registers callbacks here for PCIe LTSSM transitions during modem boot/suspend. No modem on mainline anyway.
- ITMON (Interconnect Transaction Monitor) hooks for hung-bus diagnostics.
- Compatible string `samsung,gs101-pcie` is not in mainline `pci-exynos.c`'s `of_match_table`.

## Boot-relevance reasoning

4/10. felix has two PCIe controllers — one for the WiFi card (bcm4389), one reserved for the cellular modem. We have neither WiFi nor modem brought up in mainline (WiFi blacklisted via `bcmdhd4389` in module_order.txt, modem firmware not loaded). PCIe is not exercised on boot path, console works without it, ethernet is over USB (not PCIe). Score 4 because (a) PCIe failing to probe doesn't stop boot, (b) any future WiFi work must port this — making it pre-requisite for "complete" device support, not "bootable" device support.

