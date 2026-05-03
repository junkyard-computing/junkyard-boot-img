# gs-bts

- **AOSP path**: `private/google-modules/soc/gs/drivers/bts/`
- **Mainline counterpart**: NONE
- **Status**: not-ported
- **Boot-relevance score**: 3/10

## What it does

Bus Traffic Shaper. Files: `exynos-bts.c`, `exynos-btsopsgs.c`, `regs-btsgs101.h`, `regs-btsgs.h`, `bts.h`. Programs the AXI/CCI QoS and bandwidth-throttle registers spread across the SoC's NoC IPs (each IP has its own BTS instance with priority/RW-split/throttle-limit registers). Hooks into PM-QoS so subsystems can request guaranteed bandwidth (e.g., display says "I need 2 GB/s sustained or I underrun"). Without it, all masters use BTS register defaults from BL31 / power-on reset.

## Mainline equivalent

No mainline driver for Exynos/GS NoC BTS exists. Mainline relies on whatever the bootloader programmed; some Samsung SoCs have downstream interconnect drivers but none for gs101/gs201.

## Differences vs AOSP / what's missing

Everything: every per-IP BTS init table, every QoS scenario callback (camera/disp/cp/etc.), every PM-QoS integration point. The hardware will continue to work at boot defaults.

## Boot-relevance reasoning

**Score 3**: Boot defaults are usually safe enough to bring the platform up — BL31 programs sensible BTS values for the current boot scenario. Missing BTS hurts you when concurrent display + storage + camera workloads collide and somebody underruns; not relevant for our current "boot to console + slow UFS" state. The UFS HS wedge happens at the controller/PHY layer well below the AXI bandwidth ceiling, so BTS is not in the critical path.
