# usb

- **AOSP path**: `private/google-modules/soc/gs/drivers/usb/` (`dwc3/`, `gadget/`, `host/`, `typec/`)
- **Mainline counterpart**: `drivers/usb/dwc3/dwc3-exynos.c` + `drivers/usb/host/xhci-plat.c` + generic `drivers/usb/typec/`
- **Status**: partially-ported
- **Boot-relevance score**: 4/10

## What it does

The full USB stack for gs101/gs201:
- `dwc3/dwc3-exynos.c` (1526 LoC) — Synopsys DWC3 platform glue with extcon for OTG role-switch, custom OTG state machine in `dwc3-exynos-otg.c`, LDO management (`dwc3-exynos-ldo.h`), CPU-PM hooks, and an explicit USB-C / xhci-goog-dma integration.
- `host/xhci-exynos.c` — xHCI platform glue extending xhci-plat with vendor PM and a per-device "goog DMA" memory allocator (`xhci-goog-dma.c`) that allocates xHCI ring memory from a reserved carveout instead of the generic DMA pool.
- `gadget/function/` — Pixel-specific gadget functions (`f_dm` for diagnostic-monitor, `f_etr_miu` for trace).
- `typec/tcpm/` — Pixel TCPM glue around the upstream Type-C port-manager framework.

## Mainline equivalent

- `drivers/usb/dwc3/dwc3-exynos.c` — only 285 lines, generic Designware glue. No gs101/gs201 compatible explicitly listed.
- `drivers/usb/host/xhci-plat.c` — generic, used as the xhci backend.
- `drivers/usb/typec/tcpm/` — full upstream framework; no Pixel-specific glue.
- `drivers/usb/gadget/function/` — has `f_acm`, `f_eem`, `f_ncm`, `f_ecm`, `f_rndis` etc. but **no `f_dm`, no `f_etr_miu`**.

## Differences vs AOSP / what's missing

- **dwc3-exynos**: 1500-line gap is mostly the OTG state machine (Pixel does not use the dwc3 dual-role framework — they implemented their own role-switch via extcon + LDO sequencing) and CPU-PM hooks. Mainline gs101 dwc3 probes via standard dwc3-of-simple style, but role-switch is whatever the upstream DRD framework does — which, paired with no SS PHY (see `gs-phy.md`), means SS host enumeration is unreliable.
- **xhci-goog-dma**: not in mainline. AOSP allocates xHCI rings from a reserved-memory carveout. Mainline uses generic dma_alloc_coherent against the device's normal DMA mask. Probably fine on gs201 (we don't see DMA aborts), but worth knowing if xhci ring corruption appears.
- **OTG / role-switch**: mainline relies on UCSI or generic DRD for role switching. felix needs the Pixel `dwc3-exynos-otg.c` for proper role transitions if a USB-C cable is hot-plugged.
- **gadget functions**: irrelevant for our use case.

## Boot-relevance reasoning

4/10. felix today comes up in host mode (USB-C dock with USB-Ethernet) without any of this. SS enumeration is unreliable but HS host works. None of this is in the path to console. Score 4 because losing role-switch breaks user-visible USB-C accessory swapping, which matters once we want to use it as a real device but doesn't block boot.

