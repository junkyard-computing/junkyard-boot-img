# usb

- **AOSP path**: `private/google-modules/soc/gs/drivers/usb/` (`dwc3/`, `gadget/`, `host/`, `typec/`)
- **Mainline counterpart**: `drivers/usb/dwc3/dwc3-exynos.c` + `drivers/usb/dwc3/core.c` + `drivers/usb/host/xhci-plat.c` + generic `drivers/usb/typec/`
- **Status**: partially-ported (Phase A peripheral mode probes + binds; EP0 SETUP RX path not working — see below)
- **Boot-relevance score**: 4/10 (does not gate boot); 10/10 for the active USB-gadget bring-up task

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

- **dwc3-exynos**: 1500-line gap is mostly the OTG state machine (Pixel does not use the dwc3 dual-role framework — they implemented their own role-switch via extcon + LDO sequencing) and CPU-PM hooks. Mainline gs101 dwc3 probes via standard dwc3-of-simple style. Phase A on gs201 hard-pins `dr_mode = "peripheral"`, which sidesteps the DRD path entirely; full DRD is Phase B and depends on a working MAX77759 TCPC port (see [typec.md](typec.md)).
- **`SOFITPSYNC = 1` for the U2-freeclk-disable case**: AOSP's dwc3-exynos sets this unconditionally on probe. Mainline only set it for host/OTG via the 210A–250A workaround. We've added a hunk in `drivers/usb/dwc3/core.c` so SOFITPSYNC is asserted whenever `snps,dis-u2-freeclk-exists-quirk` is set — which matches AOSP behaviour and is required for HS device-mode operation on gs201.
- **xhci-goog-dma**: not in mainline. AOSP allocates xHCI rings from a reserved-memory carveout. Mainline uses generic dma_alloc_coherent against the device's normal DMA mask. Irrelevant for Phase A (peripheral mode); revisit if/when we run host mode and see ring corruption.
- **OTG / role-switch**: mainline relies on UCSI / Type-C connector framework / `usb-role-switch` for role switching. felix in Phase B will need a TCPC + connector + role-switch DT topology rather than the Pixel `dwc3-exynos-otg.c` extcon design.
- **gadget functions** (`f_dm`, `f_etr_miu`): irrelevant for our use case. Mainline's `f_acm` + `f_ncm` is what configfs binds for our `/dev/ttyACM0` + `usb0` setup.

## Phase A status (active partial bring-up)

State as of 2026-05-07: dwc3-exynos + phy-exynos5-usbdrd probe with the new
`google,gs201-usb31drd-phy` compat, the UDC `11210000.usb` registers,
configfs gadget binds (CDC-NCM + CDC-ACM composite), `/dev/ttyGS0` exists,
soft-disconnect/connect cycle moves UDC to `state=default`, the host sees
`new high-speed USB device number N using xhci_hcd`. **But no SETUP packet
ever reaches dwc3's EP0 OUT TRB.** Symptom on the host:
`device descriptor read/64, error -71` (EPROTO) and infinite retry. UART
side shows ~1500 RESET + ~1500 CONNECT_DONE events, ~330 SUSPEND/EOPF
events, and **zero** endpoint events / SETUP completions. So the PHY's
analog edge detection works (HS chirp completes) but the HS-RX-enable /
calibration step that actually delivers SETUP bytes into the controller's
RX FIFO is missing. See [gs-phy.md](gs-phy.md) for the PHY-side analysis,
and the upstream-help email's question E for the full hypothesis log.

## Boot-relevance reasoning

4/10 for boot (system reaches kmscon login on UART without USB).
**10/10 for the active USB-gadget bring-up task.** felix today reaches a
login over UART; the goal of Phase A is to get `/dev/ttyACM0` + `usb0` on
the host so SSH-over-USB works without a UART cable. SS enumeration is a
separate (Phase B.5) concern that depends on porting the gs201 SS PMA
register set; HS-only is sufficient for now.

## 7.1 rebase impact

`drivers/usb/dwc3/core.c` — our `SOFITPSYNC = 1` hunk for the
`dis-u2-freeclk-exists-quirk` path is in here; if 7.1 refactors the dwc3
core init sequence we'll need to re-port. `drivers/usb/dwc3/dwc3-exynos.c`
is small enough that conflicts are unlikely. The mainline gs101 USB DT +
clock controller work landing in 7.1 is in adjacent files (DT, clk) and
should not conflict with our dwc3 patches directly. Phase B (TCPC) does
not depend on the rebase — MAX77759 still has no mainline path either way.

