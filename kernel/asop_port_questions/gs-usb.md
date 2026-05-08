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

## Graft verdict — PHY HS-init exonerated (2026-05-07)

After both the dwc3-side walk and the PHY-side walk closed without a
fix, we ran the AOSP CAL graft as an A/B PHY-init harness on
`feature/usb-graft`: `phy-exynos-usb3p1.c` (~1130 lines after trim) +
`phy-samsung-usb-cal.h` + `phy-exynos-usb3p1-reg.h` + `phy-exynos-usb3p1.h`
copied into [drivers/phy/samsung/](../source/drivers/phy/samsung/),
linked into a composite `phy-exynos5-usbdrd-mod.ko` via the existing
mainline driver scaffold. New OF compatible
`google,gs201-aosp-usb31drd-phy` selects a `gs201_aosp_utmi_init`
wrapper that builds a stack-local `struct exynos_usbphy_info` from the
AOSP felix DT property values (`version=0x301`,
`refclk=DIFF_19_2MHZ`, `refsel=CLKCORE`, `common_block_disable=1`,
`not_used_vbus_pad=1`) and calls
`phy_exynos_usb_v3p1_link_sw_reset` → `_enable` → `_pipe_ovrd` —
the **complete AOSP CAL HS bring-up** verbatim. Mainline's
`exynos850_usbdrd_utmi_init` is bypassed entirely on this path.

**Result: identical SETUP-delivery failure as the mainline init path.**
Symptoms in UART (felix side) + host dmesg:

- AOSP wrapper executes cleanly: `DWC3-DBG: AOSP CAL graft phy_init
  (regs_base=...)` → `... done`. No error returns, no probe deferral.
- dwc3 reaches HS connect: `conndone HIGHSPEED ep0 maxpkt=64` fires.
  Post-CONDONE state dump shows DCTL=0x8cf00000 (RUN_STOP=1),
  DALEPENA=0x3 (EP0 OUT/IN enabled), DSTS=0x00820000
  (CONNECTSPD=HIGHSPEED), DEVTEN=0x257.
- EP0 OUT TRB primed: `ep0_out_start ret=0`.
- Host enumerates and assigns address: `usb 5-1.4.3: new high-speed
  USB device number 64 using xhci_hcd` (cycles through 64..117 over
  retry attempts).
- **DCFG.DevAddr stays 0** across every CONDONE re-print
  (DCFG=0x00e00800 unchanged) — proves the gadget side never received
  a SET_ADDRESS SETUP. Same proof-by-DCFG as the pre-graft mainline
  path.
- Host reports `device descriptor read/64, error -71` and
  `Device not responding to setup address` — same -EPROTO loop.

**Implication.** PHY HS-init code is not the root cause. AOSP CAL ↔
mainline both produce a working link layer (chirp, hi-speed handshake,
RESET, CONDONE) but neither delivers SETUP packets to dwc3's EP0 OUT
TRB. The gap is downstream of any HS PHY register write the AOSP
driver makes — i.e. *not* fixable by porting more PHY code.

What this rules out:
- HSPPARACON tune values (graft uses `tune_param=NULL`, would have
  applied bootloader defaults like the mainline path; same result).
- POR / SW-reset sequence ordering (AOSP CAL has its own complete
  sequence; same result).
- HSP_EN_UTMISUSPEND / HSP_COMMONONN handling (AOSP path SETS both
  per `common_block_disable=1`, mainline path CLEARS both; same
  result either way).
- SSP_PLL FSEL programming (AOSP REFCLK_DIFF_* path is a no-op for
  this register; mainline reaches the same final state).
- LINKCTRL_FORCE_QACT cycling (AOSP toggles via
  `exynos_cal_usbphy_q_ch`; mainline relies on bootloader default;
  same end-state).
- `phy_power_en` HSP_TEST_SIDDQ clear for `EXYNOS_USBCON_VER_03_0_0`
  (AOSP does it, mainline doesn't, but the bit is already clear from
  bootloader; same result).
- Combo (G2) PHY late-power signals — irrelevant for
  HS-only path; both AOSP `g2pma_*` and our mainline G2PHY_CNTL0/CNTL1
  writes leave the HS path unaffected.

What it leaves on the table — DT diff against AOSP's `gs201.dtsi`:

1. **dwc3 DMA carveout (`memory-region = <&xhci_dma>`)** — top
   suspect. AOSP's inner Synopsys dwc3 node binds DMA allocations to
   the `xhci_dma` reserved-memory pool (4 MiB shared-dma-pool at
   `0x97000000`, declared in `gs201/dts/gs101-dma-heap.dtsi:162`).
   Mainline dwc3 has no `memory-region` and uses generic
   `dma_alloc_coherent`, which lands in normal DRAM. If the gs201
   interconnect / S2MPU only permits dwc3 master access to the
   `0x97000000` window, then:
   - Event ring writes from the controller succeed (small/aligned
     allocations may happen to fall in a permitted region by luck —
     consistent with the CONDONE events we DO see arrive).
   - EP0 OUT SETUP TRB writes silently drop because the gadget's
     usb_request DMA buffer falls in a non-permitted region — exactly
     the symptom (DCFG.DevAddr=0 across all retries, host -EPROTO).
   Mainline `of_dma_configure` auto-routes `dma_alloc_coherent` for
   any device with `memory-region` referencing a `shared-dma-pool` —
   no driver changes needed; pure DT.
2. **S2MPU (`s2mpus = <&s2mpu_hsi0>`)** — AOSP DT line 791 puts the
   `s2mpus` phandle on the **PHY node**, not the dwc3 node. The
   `s2mpu_hsi0` block is at `0x11070000` (`gs201-s2mpu.dtsi:140`),
   `compatible = "google,s2mpu"`. Notice `s2mpu_hsi1` /
   `s2mpu_hsi2` are `always-on` while `s2mpu_hsi0` is **not** —
   meaning S2MPU_HSI0 is something the kernel needs to actively
   configure. Mainline has no `google,s2mpu` driver. If the
   bootloader programs S2MPU permissively for early boot but ATF
   /power transitions reset it, the dwc3 master would lose access
   without the kernel reprogramming.
3. **HSI0 sub-power-domain (`sub_pd_hsi0`)**: AOSP defines
   `sub_pd_hsi0` (line 833) with `compatible = "exynos-pd-hsi0"` and
   parents to `pd_hsi0`. Mainline DT references `pd_hsi0` but no
   sub-PD. If a controller sub-block (e.g. EP0 buffer fetcher, event
   ring DMA master) is held in reset by the sub-PD remaining
   unconfigured, the high-level controller can probe and reach
   CONDONE but the data-receive path stays dead. No mainline driver
   for `exynos-pd-hsi0` either.
4. **Bus clock (`VDOUT_CLK_TOP_HSI0_NOC`, "bus")**: AOSP's outer
   wrapper has THREE clocks (`aclk`, `sclk`, `bus`); the gs201.dtsi
   we already have (and gs101 mainline drvdata) only declare two
   (`aclk`, `sclk` for the inner dwc3, plus `phy_ref` and `aclk`
   for the PHY). The HSI0 NOC bus clock not being explicitly held
   on by Linux could mean it gates whenever the NOC is idle — and
   if SETUP delivery requires NOC traffic at a moment when no other
   activity holds the clock on, the SETUP gets stuck.
5. **`is_not_vbus_pad = <1>`** appears on AOSP's outer wrapper but
   isn't in any standard binding — out of scope.
6. **`direct-usb-access`** — AOSP-only custom property; semantics
   unclear, likely tied to USB-offload / faceauth — not relevant for
   our gadget.

Next investigation order (cheapest → most expensive):

- **Test 1 (memory-region + dma-coherent)** — DONE 2026-05-07,
  NEGATIVE. Declared `xhci_dma@97000000` `shared-dma-pool`
  (4 MiB, no-map) in gs201-android-handoff.dtsi; added
  `memory-region = <&xhci_dma>;` and `dma-coherent;` on
  `&usbdrd31_dwc3` in felix.dts. Boot log confirms the reserved-mem
  node was recognized (`OF: reserved mem: initialized node
  xhci_dma@97000000, compatible id shared-dma-pool`) but **no
  "assigning to device" message** — `of_dma_configure` did not
  propagate the carveout to the inner dwc3 platform device.
  Symptom: completely unchanged. Same DCFG=0x00e00800
  (DevAddr=0), same host -EPROTO loop. Even if the carveout had
  been wired up, the symptom shows the gap is not where dwc3's
  DMA buffers land.
  - Possible follow-up if we revisit: the dwc3 inner device
    created by `of_platform_populate` may need an explicit
    `of_reserved_mem_device_init_by_idx()` call from
    dwc3-exynos's probe path. Mainline dwc3-exynos doesn't do
    this; AOSP's `xhci-goog-dma` allocator handles the carveout
    end-to-end including the mapping. Mainline path would need
    ~30 lines in dwc3-exynos to call the helper. Low effort but
    not justified until we have stronger reason to believe the
    DMA pool is the issue.
- **Test 2 (HSI0 NOC bus clock)**: add the third `bus` clock to the
  dwc3 binding + drvdata. Need to identify which mainline gs101 clk
  ID corresponds to AOSP's `VDOUT_CLK_TOP_HSI0_NOC`.
- **Test 3 (S2MPU)** — DONE 2026-05-08, NEGATIVE.
  - Stub `google,s2mpu` driver added at
    [drivers/soc/samsung/gs201-s2mpu-stub.c](../source/drivers/soc/samsung/gs201-s2mpu-stub.c)
    (probe-only, ioremaps regs, no register writes). DT node
    `s2mpu_hsi0@11070000` enabled in felix.dts; `s2mpus =
    <&s2mpu_hsi0>;` phandle on the PHY. CONFIG_GS201_S2MPU_STUB=y.
    Stub probes successfully: UART line `gs201-s2mpu-stub
    11070000.s2mpu: S2MPU stub claimed`.
  - Same flash also added a **`dma-ranges` identity-mapping
    constraint on the outer `&usbdrd31` wrapper**:
    `dma-ranges = <0x80000000 0x0 0x80000000 0x40000000>;` —
    forces the inner dwc3's `dma_alloc_coherent` allocations to
    physical 0x80000000-0xc0000000 (lower DRAM bank, identity).
    Verified working: EP0 TRB instrumentation went from
    `ep0_trb_addr=0x8_9556a000` (upper bank, 34 GiB) to
    `ep0_trb_addr=0x8283f000` (lower bank, identity-mapped, no
    offset translation).
  - Symptom: **completely unchanged**. DCFG.DevAddr stays 0 across
    every CONDONE/SET_ADDRESS retry; TRB ctrl=0x00000c23 (HWO=1)
    on every ep0_out_start re-prime, the controller NEVER consumes
    the TRB; host gets the same -EPROTO loop.
  - Together these two changes pin the TRB to physical addresses
    that are AT MINIMUM in the same window the bootloader's own
    fastboot USB transfers use. If S2MPU were the gate, this
    region would be permitted (the bootloader's fastboot path
    works against the same hardware). It isn't, so S2MPU is
    exonerated as the SETUP-delivery cause.
  - First attempt of the dma-ranges constraint
    (`<0x0 0x0 0x80000000 0x40000000>;`) used an offset-translating
    mapping (child-addr=0, parent-addr=0x80000000). The kernel
    honored it, but `dma_alloc_coherent` returned child-side
    `0x0281f000` and the dwc3 master then DMA-wrote to literal
    physical `0x0281f000` — below DRAM. That tested whether
    of_dma_configure propagates dma-ranges to the inner platform
    device (it does — bph went from 0x8 to 0x0), but didn't test
    S2MPU since the address landed in unmapped memory. Identity-
    mapped retry above is the actually-decisive test.
- **Test 4 (sub_pd_hsi0)**: same shape as #3 — stub
  `exynos-pd-hsi0`, see whether the sub-PD lifecycle hooks change
  anything. Lower priority now that S2MPU is ruled out.

## Where the gap is now (2026-05-08)

Empirical state after the S2MPU + dma-ranges test:

- PHY init code: not the gap (AOSP CAL graft = mainline init).
- dwc3 controller register state: textbook-correct (RUN_STOP=1,
  EP0 OUT/IN enabled, DALEPENA=0x3, EP0 TRB armed for SETUP with
  HWO=1, ctrl=0xc23).
- DMA pool location: not the gap (TRB now in lower-bank physical
  identity-mapped DRAM, same region bootloader uses).
- S2MPU permissions: not the gap (lower bank known-permitted).
- Bus reset / chirp / HS handshake: working (RESET + CONDONE
  fire on every host plug attempt).
- EP0 TRB consumption: **broken**. Across many CONDONE cycles
  the controller never consumes the TRB (HWO stays 1) and never
  fires an EP0 XferComplete event. The host's SETUP packets exist
  on the wire (host's xhci doesn't time out at the link layer)
  but the dwc3's MAC layer never frames them.

The remaining surface where the gap can hide:

1. **UTMI/PIPE bridge between PHY and dwc3 controller** — the
   bytes go PHY → UTMI → controller MAC. If UTMI isn't clocked
   right, or the bridge is held in some pseudo-reset, the chirp
   (which is link-state, NOT byte-stream) succeeds while the
   actual SETUP byte stream fails. **CR-port sub-test (Phase G.10,
   2026-05-08): NEGATIVE.** Re-grafted minimal CR-port machinery
   (`phy_exynos_usb_v3p1_cr_access` + `cal_cr_write` from the AOSP
   tree) and forced the unconditional CR write
   (`0x1010 = 0x80`, `RXDET_MEAS_TIME`) regardless of the
   `version > 0x500` gate. The CR-port hardware responds (readback
   was `0x00000000`, not `0xFFFFFFFF`), the protocol completes
   (function returns 0), but the data-path symptom is identical —
   720 RESET + 720 CONDONE cycles and ZERO endpoint events across
   ~50 host plug attempts. This exonerates the embedded SS PHY's
   RXDET timing as a contributor on gs201's combo PHY.

## Phase G.11 — GFLADJ refclk programming (active 2026-05-08)

Walking AOSP's `dwc3-exynos.c:356` (`dwc3_exynos_core_init`) found a
significant divergence at lines 365–383 — for our exact silicon
revision (DWC31 180A-190A) AOSP runs an unconditional GFLADJ
programming block:

```c
if (DWC3_VER_IS_WITHIN(DWC31, 180A, 190A)) {
    /* FOR ref_clk 19.2MHz */
    reg = dwc3_exynos_readl(dwc->regs, DWC3_GFLADJ);
    /* preserve the 30MHz fladj (= dwc->fladj) */
    reg |= DWC3_GFLADJ_REFCLK_240MHZ_DECR(0xc);
    reg |= DWC3_GFLADJ_REFCLK_240MHZDECR_PLS1;
    reg |= DWC3_GFLADJ_REFCLK_LPM_SEL;
    reg &= ~DWC3_GFLADJ_REFCLK_FLADJ_MASK;     /* zero */
    reg |= DWC3_GFLADJ_30MHZ_SDBND_SEL;
    dwc3_exynos_writel(dwc->regs, DWC3_GFLADJ, reg);
}
```

Mainline has the same machinery but as
`drivers/usb/dwc3/core.c:dwc3_ref_clk_period`. It computes the
fields from `clk_get_rate(dwc->ref_clk)` (with `dwc->ref_clk_per`
from `snps,ref-clock-period-ns` as a fallback only when no clock
is set).

### What instrumentation found

A `dev_info` added in `dwc3_ref_clk_period()` reports:

```
DWC3-DBG: ref_clk_period rate=614400000 period=1ns fladj=78450 decr=0 lpm_sel=1 GUCTL=0x00416802 GFLADJ=0x00b27220
```

`clk_get_rate(dwc->ref_clk)` on felix (with the inner dwc3 node's
`clocks = <&cmu_hsi0 CLK_GOUT_HSI0_USB31DRD_I_USB31DRD_REF_CLK_40>;
 clock-names = "ref";`) returns **614,400,000 Hz** — that's the
upstream PLL rate (`32 × 19.2 MHz`), not the divided-down 19.2 MHz
that actually clocks the dwc3 reference.

Consequence: mainline programs

- `period = 1e9 / 614400000 = 1ns` (should be `52`)
- `decr = 480000000 / 614400000 = 0` (should be `25`, i.e.
  `DECR=12 + PLS1=1` per AOSP)
- `fladj = (125000 * 1e9) / (614e6 * 1) - 125000 = 78450`
  (should be `0` per AOSP for 19.2 MHz)
- `GUCTL.REFCLKPER = 0x802` (the low 10 bits of `0x00416802`)
- `GFLADJ = 0x00b27220` (all the wrong fields)

Hypothesis: HS bus timing depends on these being correct. Chirp
and bus-reset are link-state events that don't depend on refclk
timing — they fire regardless. But byte-level NRZI decode and
the controller's MAC-layer SOF/ITP timing **do** depend on
GFLADJ + GUCTL.REFCLKPER. With `GUCTL.REFCLKPER = 0x802` instead
of `52`, the controller's internal time base is 16x off,
causing it to drop or misframe SETUP packets even though the
PHY is presenting valid bus traffic.

### gs101 clk driver as the underlying culprit

`drivers/clk/samsung/clk-gs101.c:2701` defines
`CLK_GOUT_HSI0_USB31DRD_I_USB31DRD_REF_CLK_40` as a `GATE()` whose
parent is `mout_hsi0_usb31drd`. Gate clocks inherit their parent's
rate. The mux's parent on felix is the upstream USB31DRD PLL
configured by the bootloader for 614.4 MHz, but the actual line
that clocks the dwc3 reference input is divided down to 19.2 MHz
at the silicon level — divide that the kernel's clock tree
representation doesn't reflect.

Two paths to a long-term fix:

1. **Audit the gs101 clk driver's USB31DRD chain** and add the
   missing divider so `clk_get_rate(REF_CLK_40)` returns 19.2 MHz.
   The clock name itself ("`_REF_CLK_40`") is misleading — it
   suggests 40 MHz but felix is 19.2; gs101 (which the driver
   was originally built for) may have had this clock at a
   different rate. Fixing the clock tree is the proper upstream
   answer.

2. **Patch dwc3 core.c to prefer `dwc->ref_clk_per`** when both
   the clock and the period override are set. One-line change.
   Useful as a workaround for any platform whose clock-tree
   accounting is wrong.

### Phase G.11c workaround test

Cheapest immediate test (in flight 2026-05-08):

- Add `snps,gfladj-refclk-lpm-sel-quirk;` and
  `snps,ref-clock-period-ns = <52>;` to the inner dwc3 node in
  felix.dts.
- `/delete-property/ clocks;` and `/delete-property/ clock-names;`
  on the inner dwc3 node so `dwc->ref_clk` is NULL and the
  override path runs.
- `clk_ignore_unused` in our kernel cmdline keeps the
  bootloader-enabled HSI0 ref clock running, so the controller +
  PHY still get their reference signal at 19.2 MHz.

Expected post-fix values:

- `rate = 19230769` (= `1e9 / 52`)
- `period = 52`
- `fladj = 0` (matches AOSP)
- `decr = 24` (or 25 depending on integer div)
- `GUCTL.REFCLKPER = 0x34` (= 52)
- `GFLADJ.REFCLK_LPM_SEL = 1`

If SETUP delivery starts working with this fix in place, GFLADJ
miscalibration was the gap and we've found the answer. If it
doesn't, GFLADJ refclk programming is exonerated and the gap
sits even deeper.

### Result (Phase G.11d, 2026-05-08): NEGATIVE

The override took effect cleanly. Post-fix instrumentation:

```
DWC3-DBG: ref_clk_period rate=19230769 period=52ns fladj=0 decr=24 lpm_sel=1
GUCTL=0x0d016802 GFLADJ=0x0c800020
```

- `rate = 19230769` (= `1e9 / 52`, ~19.23 MHz) ✓
- `period = 52` ns ✓
- `fladj = 0` ✓ (matches AOSP exactly)
- `decr = 24` (close to AOSP's 25, integer-div drift)
- `lpm_sel = 1` ✓
- `GUCTL.REFCLKPER` field (bits 31:22) = `0x34` = `52` ✓
- `GFLADJ.REFCLK_LPM_SEL` (bit 23) = `1` ✓
- `GFLADJ.30MHZ_MASK` (bits 5:0) = `0x20` = `32` ✓
   (matches our `snps,quirk-frame-length-adjustment = <0x20>`)

But the data-path symptom is unchanged. Across this boot:

- 0 `is_devspec=0` events (zero endpoint events, ever)
- DCFG = `0x00e00800` always (DevAddr field forever 0)
- TRB ctrl = `0x00000c23` always (HWO=1; controller never consumes)
- ep0_trb_addr = `0x8283e000` (lower DRAM bank, identity-mapped, fine)
- 216 RESET + 216 CONDONE + 52 EOPF cycles, no SETUP framing

GFLADJ refclk programming is exonerated as a cause of the
SETUP-delivery failure. Cumulative ruled-out list now spans:

1. PHY HS-init register sequence (mainline AND AOSP CAL graft, identical
   symptom)
2. dwc3 controller state (RUN_STOP=1, EP0 OUT/IN enabled, TRB armed
   correctly)
3. EP0 RX/TX FIFO sizing (GRXFIFO0=0x413 = 1043 dwords, plenty)
4. DEPSTRTXFER address propagation (PAR0/PAR1 match
   `dwc->ep0_trb_addr` exactly)
5. DMA buffer location (lower DRAM bank, where bootloader fastboot operates)
6. S2MPU permission gating
7. Embedded SS PHY CR-port (RXDET_MEAS_TIME poke executed)
8. GUCTL.REFCLKPER + GFLADJ programming for ITP/SOF timing
9. HSPPARACON tune values (mainline applies them via PTS_UTMI_POSTINIT)
10. xhci_dma reserved-memory carveout
11. HSP_EN_UTMISUSPEND / HSP_COMMONONN bits (both polarities tested)
12. LINKCTRL_FORCE_QACT (load-bearing for link-state events but doesn't
    fix data-layer)

Empirical fingerprint: dwc3 fires link-state events (RESET / CONDONE)
and clock-driven heartbeat (EOPF), but **zero byte-stream events**.
The PHY → MAC byte forwarding pipeline is broken at a level we cannot
poke from any register-write candidate we've found. Possibilities at
this depth:

a. **PHY HS RX analog frontend** decoding chirp K/J (low-freq level
   signaling) but failing on HS NRZI bytes (high-freq). Some calibration
   we haven't found, possibly outside the AOSP CAL.
b. **UTMI bus** between PHY and controller is partially dead (link-state
   pins working, data pins not). Pin-mux, sub-clock, or sub-PD issue.
c. **Some block we haven't powered up** — e.g. a sub_pd_hsi0 child PD
   that gates the UTMI byte-fetcher.
d. The mainline dwc3 driver has a quirk path we haven't enabled that
   gs201 silicon needs.

The AOSP-vs-mainline diff hunting has reached diminishing returns.
Next step (Phase G.12) should be **diagnostic-by-instrumentation** —
read controller-internal "RX byte counter" / "PHY status" registers to
distinguish (a) from (b/c/d), rather than continue shotgun-testing
register writes.
2. **An HSI0 NOC bus clock or APB clock** the kernel doesn't
   explicitly enable. AOSP's dwc3 outer wrapper has three
   clocks: `aclk`, `sclk`, `bus` (the third is
   `VDOUT_CLK_TOP_HSI0_NOC`). Mainline gs101 drvdata declares
   four different clocks (`bus_early`, `susp_clk`, `link_aclk`,
   `link_pclk`). The AOSP `bus`/NOC clock is in CMU_TOP, not
   CMU_HSI0; mainline has no CMU_TOP NOC clock framework yet.
   If this clock gates off mid-handover or isn't running at the
   right rate, the AXI fabric between dwc3 and the PHY may not
   carry SETUP bytes promptly enough.
3. **`sub_pd_hsi0` sub-power-domain** (AOSP gs201.dtsi:833,
   `compatible = "exynos-pd-hsi0"`). Different from `pd_hsi0`.
   Mainline DT references `pd_hsi0` but no sub-PD. If this
   sub-block contains the dwc3's RX FIFO power gate or the EP0
   buffer fetcher, an unconfigured sub-PD could leave the RX
   path in a held-reset state.
4. **A specific dwc3-exynos.c AOSP register write we haven't
   reproduced** — the AOSP driver is 1500+ lines vs mainline's
   285. We've already added the SOFITPSYNC + DWC31 180A
   workaround block. The OTG state machine (~700 lines) is
   irrelevant for peripheral mode. But there may be an
   HSI0-specific PMU/CMU init in the AOSP probe path that
   mainline + dwc3-of-simple skip.

The graft itself stays on `feature/usb-graft` as scaffolding the
S2MPU / sub-PD investigation can build on. Reverting the felix.dts
compatible to `google,gs201-usb31drd-phy` rolls back to the mainline
init path with no other changes — they are A/B sides of the same
harness.

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

