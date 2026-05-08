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
side shows ~200 RESET + ~200 CONNECT_DONE events, ~470 device-spec events
(SUSPEND/EOPF), and **zero** endpoint events / SETUP completions. The PHY
walk in [gs-phy.md](gs-phy.md) tested 5 hypotheses with one useful learning
(FORCE_QACT is load-bearing) but nothing that closes the data-layer gap.
The active suspect is now the **dwc3-exynos layer**, not the PHY.

## dwc3-exynos layer divergence (2026-05-07 walk)

AOSP `dwc3-exynos.c` (1526 lines) carries register writes that mainline
(285 lines) only applies when explicitly opted-in via DT properties. The
walk through AOSP `dwc3_core_config()` at
`private/google-modules/soc/gs/drivers/usb/dwc3/dwc3-exynos.c:147` surfaced
five candidate divergences ranked below by likelihood-of-impact / cost.
None of these have been tested yet.

### Headline candidate — GSBUSCFG0 request-info bits

AOSP unconditionally sets `DESWRREQINFO | DATWRREQINFO | DESRDREQINFO |
DATRDREQINFO` on DWC3 ≥220A. These bits drive the AXI master's `*Cache`
signals during descriptor and data DMA — i.e. they control whether the
controller's writes to the dwc3 event ring and SETUP-packet payload
buffer use cacheable AXI attributes.

Mainline (`drivers/usb/dwc3/core.c:641-647`) only sets these when DT
carries `snps,gsbuscfg0-reqinfo`. We don't carry that property today. If
the controller is writing endpoint event entries with non-cacheable
attributes while the gadget driver reads via the standard coherent-DMA
path, the gadget could miss every event even though the controller fires
them — which **matches our symptom** (link-layer events visible at the
PHY level, zero endpoint events at the controller level).

Test cost: 1-line DT property add. Likely the single most productive
cheap test on the dwc3 side.

### Ranked test candidates

| # | What | AOSP behaviour | Mainline behaviour | Test | Result |
|---|---|---|---|---|---|
| 1 | `GSBUSCFG0` DES/DAT WR/RD request-info bits (cache attrs) | Unconditional on ≥220A | Opt-in via `snps,gsbuscfg0-reqinfo` DT | `snps,gsbuscfg0-reqinfo = <0x2222>` | **Negative** (2026-05-07) — same baseline shape (178 RESET / 158 CONDONE / 398 device events / 0 endpoint events / 0 SETUP). Cache-attrs hypothesis ruled out. |
| 2 | `GUCTL.USBHSTINAUTORETRYEN` | Unconditional | Not set from platform glue | Hunk in our wrapper or DT quirk | Workaround is host-mode bulk-IN-specific per AOSP comment; deferred unless other tests negative. |
| 3 | `GUSB3PIPECTL.DISRXDETINP3` | Set on ≥250A (cleared 180A–190A) | Available via `snps,dis_rxdet_inp3_quirk` DT | DT quirk | SS-only path; lower priority for HS-only Phase A. |
| 4 | `GUCTL.NOEXTRDL` | DT-property-driven in AOSP | Not exposed | Code addition | Pending. |
| 5 | `GSBUSCFG0.INCR*BRSTEN` (burst-enable bits) | Sets `INCRBRSTEN \| INCR16BRSTEN` plus conditional INCR8/INCR4 | Configured via `snps,incr-burst-type-adjustment` DT | `snps,incr-burst-type-adjustment = <1>, <16>` | **Negative** (2026-05-07) — same baseline shape (354 RESET / 330 CONDONE / 790 device events / 0 endpoint events / 0 SETUP). Burst-type adjustment is not the gap. |

### dwc3-side walk exhausted — gap is upstream of the controller (2026-05-07)

Five dwc3-side hypotheses tested empirically; all negative. Plus one
instrumentation cycle that pinned the silicon revision and one full-block
AOSP-workaround port. Summary:

| # | Test | Result |
|---|---|---|
| 1 | `snps,gsbuscfg0-reqinfo = <0x2222>` (AOSP cache-attr DES/DAT WR/RD bits) | Negative |
| 2 | `GUCTL.USBHSTINAUTORETRYEN` | Analytical rule-out (host-mode-only per AOSP comment); applied as part of #6 anyway |
| 3 | `GUSB3PIPECTL.DISRXDETINP3` | SS-only, applied as part of #6 anyway |
| 4 | `GUCTL.NOEXTRDL` | DT-driven in AOSP, not on the felix DT path |
| 5 | `snps,incr-burst-type-adjustment = <1>, <16>` | Negative |
| **6** | **Full AOSP DWC31 180A–190A workaround block** (LLUCTL PIPE_RESET + LTSSM_TIMER_OVRRD + EN_US_HP_TIMER, LSKIPFREQ PM timers, GUSB3PIPECTL clear DISRXDETINP3+RX_DETOPOLL, GSBUSCFG0 add INCR8+INCR4, BU31RHBDBG.TOUTCTL, GUCTL1.IP_GAP_ADD_ON=1, **GUCTL.REFCLKPER=0x34** for 125us ITP) | **Negative** |

The instrumentation cycle confirmed felix's DWC3 IP is **DWC31 v1.80a**
(`dwc->ip=0x3331 (DWC31_IP)`, `dwc->revision=0x3138302a (DWC31_REVISION_180A)`),
and that with the workaround block applied:

- `DCTL.RUN_STOP=1` ✓
- `DALEPENA = 0x3` (EP0 OUT + EP0 IN both enabled) ✓
- `DSTS.CONNECTSPD=0` (HS) ✓
- `GSBUSCFG0 = 0x22220007` (AOSP cache-attrs + INCR1+INCR4+INCR8 burst enables) ✓
- `DEVTEN = 0x00000257` (DISCONNECT + USBRST + CONNECTDONE + WAKEUP + VENDORDEVTST) ✓

**The dwc3 controller is in a textbook-correct state**, with every
version-specific AOSP workaround for the exact silicon applied, and the
SETUP-delivery problem is unchanged. The missing step is therefore
**upstream of the controller** — at the PHY's HS NRZI data-decode path,
which delivers bus bytes from the wire into the controller's RX FIFO.
The PHY's link-layer / chirp paths work (RESET + CONDONE fire); the
data-layer path silently fails.

### Plausible remaining causes (PHY data path)

- **PMA-side writes we don't make.** Our `phy_cfg_gs201` has a no-op
  PIPE3 init because the gs101 PMA register layout doesn't apply to
  gs201. AOSP's `phy_exynos_usb_v3p1_pma_ready` /
  `phy_exynos_usb_v3p1_g2_pma_ready` /
  `phy_exynos_usb_v3p1_pma_sw_rst_release` make PMA-side writes that
  configure the analog/digital boundary; we make none of them. The
  gs201 PMA register set isn't reverse-engineered yet (also blocks
  Phase B.5 SuperSpeed bring-up).
- **Bootloader handoff state.** felix's bootloader sets up the USB
  block for SuperSpeed host enumeration before handing off; we re-use
  it for HS device mode. Some SS-mode bits left enabled by the
  bootloader may interfere with HS RX without obvious symptoms.
- **Reference clock.** We feed `phy_ref` from a 26 MHz fixed-clock
  stub because cmu_hsi0's user-mux reports the bootloader PLL rate
  (~614 MHz) which trips the strict-rate check. Frequency is right
  but the actual clock signal source may be subtly wrong.

### Strategic conclusion: graft is now the right move

We have exhausted both the in-wrapper PHY register walk (5 hypotheses)
and the dwc3 controller walk (6 hypotheses, including the full AOSP
180A-190A version-specific block). None moved the SETUP-delivery
symptom. The in-tree register-write space has been thoroughly canvassed
against AOSP, and the gap is in code we can't easily port piecemeal —
the AOSP CAL-based PMA bring-up sequence, written in terms of cal-if
SFR tables we don't have for gs201's specific PMA layout.

The graft (stubbed-CAL build of `phy-exynos-usb3p1.c` running side-by-side
as A/B harness) is the cheapest remaining path. It gives us a known-working
reference to bisect against, lets us extract specific PMA writes by
side-by-side comparison rather than guessing, and unblocks Phase B.5
(SuperSpeed PIPE3 init) at the same time.

### Test ordering rationale

- Run #1 first. If it works, we have the answer in one cycle.
- If #1 negative, run #2 + #5 together (independent, cheap, both DT or
  small-hunk).
- If #1, #2, #5 all negative, the cheap dwc3-layer walk has also been
  exhausted. Escalation paths:
  - The full graft (stubbed-CAL build of `phy-exynos-usb3p1.c` +
    `dwc3-exynos.c` running side-by-side as A/B harness).
  - Reverse-engineer the gs201 PMA register set so the no-op PIPE3
    init can be properly populated — also unblocks Phase B.5
    SuperSpeed.

### Notes captured for completeness

- **`GUCTL_REFCLKPER`**: AOSP sets `0xF` for DWC31 170A and `0x34` for
  180A–190A — calibrates the ITP interval against actual ref clock
  period. We don't know which DWC3 revision gs201 reports; if the HW is
  170A and we're not programming REFCLKPER, ITP would be miscalibrated.
  Worth surfacing in a build with a probe-time `dev_info` of `GHWPARAMS6`
  (controller revision).
- **`dwc3_core_susphy_set`**: AOSP toggles `GUSB2PHYCFG.SUSPHY` based on
  link state and bus-suspend. Mainline handles SUSPHY differently (in
  the dwc3 core, not platform glue). Probably orthogonal but documented
  here so it isn't re-discovered.
- **`dwc3-exynos-otg.c` (781 lines)**: explicitly out of scope for Phase A
  because we hard-pin `dr_mode = "peripheral"`. Confirmed; not on the
  active investigation path. Phase B will need to revisit.
- **`xhci-goog-dma`**: the AOSP xhci ring carveout allocator is host-side
  only. Confirmed irrelevant for peripheral-mode Phase A.

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

