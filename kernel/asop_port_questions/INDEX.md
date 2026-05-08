# AOSP-vs-Mainline Module Port Audit

This directory holds one markdown file per AOSP kernel module from
[kernel/source.aosp-backup/](../source.aosp-backup/). Each file:

- describes what the module does,
- identifies the mainline counterpart (if any),
- summarizes the gap between AOSP and our [kernel/source/](../source/),
- scores 1–10 how likely closing that gap would help our **active partial
  bring-ups** (originally calibrated against UFS HS, fixed 2026-05-06; now
  the active task is the USB gadget HS RX path).

## Current boot blockers (the scoring lens)

As of 2026-05-06 the device boots fully on mainline: UART login works
bidirectionally, UFS reaches HS-G4 Rate-B with both lanes locked, ext4 rootfs
mounts, kmscon comes up, ethernet brings DHCP, and `ssh.service` is listening.
There is no longer a hard boot blocker.

Active partial bring-ups (the new scoring lens):

1. **USB gadget mode (Phase A)** — `dwc3-exynos` + `phy-exynos5-usbdrd` probe
   with the gs201-specific PHY init wrapper, the UDC `11210000.usb` registers,
   configfs gadget binds (CDC-NCM + CDC-ACM), and the host enumerates a HS
   device. **But no SETUP packet ever lands on dwc3's EP0 OUT TRB**: line-state
   events fire (RESET + CONNECT_DONE in the hundreds), zero endpoint events.
   Empirical 2026-05-07: link-layer reception (RESET/CONDONE) requires
   `LINKCTRL_FORCE_QACT=1` (mainline gets that right); data-layer reception
   (SETUP delivery) is broken at a separate stage. Five PHY-side hypotheses
   tested (PMA, FORCE_QACT, OTP, ENBLSLPM, HSPPARACON tune) — all negative or
   regressions. **Active investigation pivoted to the dwc3-exynos layer**:
   AOSP's `dwc3_core_config()` does ~180 lines of register writes (GSBUSCFG0
   request-info / cache-attrs, GUCTL_USBHSTINAUTORETRYEN, GUSB3PIPECTL
   quirks) that mainline opts out of by default. See [gs-phy.md](gs-phy.md)
   for the PHY hypothesis log and [gs-usb.md](gs-usb.md) for the dwc3 walk
   plan. Phase B is the MAX77759 TCPC port for full DRD; Phase B.5 is the
   gs201 SS PHY tune table. See the **"USB Gadget Bring-up"** section below.
2. **`sudo reboot` hangs** — Linux never reaches the bootloader's reset path.
   Workaround: `./flash.sh` re-flash from fastboot. Tracked under the Phase R
   set of TODOs (capture UART, fix root cause, write a BCB
   `bootonce-bootloader` helper).

History — solved boot-blockers (kept for context):

- **UFS HS gear** (was PRIMARY blocker through 2026-05-05). Fixed by upstream
  patches 0010 (three missing cal-if writes on the 38.4 MHz refclk path) and
  0011 (FMPSECURITY0.DESCTYPE pinning). HS-G4 Rate-B both lanes now locked.
- **UART RX silent on mainline** (was a multi-day debug detour). Fixed by
  switching the gs201 UART DT compat from `samsung,exynos850-uart`
  (`UPIO_MEM`, 8-bit access) to `google,gs101-uart` (`UPIO_MEM32`, 32-bit
  access). Patch 0015. AOC firmware retry-loop was the **AOSP-side** UART RX
  issue — on mainline AOC stays dormant (no driver bound, no IRQ claimed) so
  it does not actually starve UART RX; the binding-doc trap was the real bug.
  `/vendor/firmware` is still installed by the build pipeline as a precaution
  but is not on mainline's critical path.

Everything else (display, GPU, audio, sensors, fingerprint, NFC, BT/WLAN, etc.)
is post-boot peripheral.

## Score legend

| Score | Meaning |
|-------|---------|
| 10 | Direct lead on the active partial bring-up (USB gadget HS RX path) |
| 8–9 | Boot-critical infrastructure (clocks, regulators, pinctrl, PMIC, IOMMU) |
| 6–7 | Important subsystem affecting stability / performance / security |
| 4–5 | Useful but boot succeeds without it |
| 2–3 | Post-boot peripheral |
| 1 | Unrelated to boot |

(Scores were last calibrated against the UFS-HS blocker, fixed 2026-05-06. They
have not yet been wholesale re-rated against the new "USB gadget HS RX" lens —
the per-file boot-relevance reasoning still reads as if UFS-HS were the
top-of-mind question. Treat the per-file scores as historic; the **"USB Gadget
Bring-up"** section below is the new map of what matters for the active task.)

---

## Tier 1 — Primary leads (10/10)

| Module | Status | Why it scores 10 |
|--------|--------|------------------|
| [gs-ufs.md](gs-ufs.md) | mostly-ported | **Was the primary blocker through 2026-05-05.** Now fixed: HS-G4 Rate-B both lanes locked. Patches 0010 (three missing cal-if writes on the 38.4 MHz refclk path) and 0011 (FMPSECURITY0.DESCTYPE pin) were the resolution. Score 10 reflects historical weight; new work on this module is upstream cleanup, not boot bring-up. |
| [gs201-arch.md](gs201-arch.md) | partially-ported | Umbrella for our SoC — compounds every other gap. CMU coverage thin, no ACPM, no PMIC, no SPMI. (PD_HSI0 turned out to be a USB power-island driver, not a UFS one.) Still a 10 because it is the platform we're booting. |

## Tier 2 — Boot-critical infrastructure (8–9/10)

| Module | Score | Status | Note |
|--------|-------|--------|------|
| [gs-mfd.md](gs-mfd.md) | 8/10 | not-ported | s2mpg12/13 PMIC absent in mainline. |
| [gs-regulator.md](gs-regulator.md) | 8/10 | mixed (slg51000/rt6160/max77826 partial; s2mpg* not-ported) | All 8 USB PHY/dwc3 supplies routed through a fixed-1V8 stub — adequate for Phase A but not upstream-quality. UFS analog rails (vcc/vccq/vccq2) turned out not to matter for HS-G4 lock (felix's UFS vcc is a GPIO-fixed regulator; patches 0010+0011 fixed HS without touching PMIC code). |

## Tier 3 — Important subsystems (5–7/10)

| Module | Score | Status | Note |
|--------|-------|--------|------|
| [gs-pinctrl.md](gs-pinctrl.md) | 7/10 | ported | Driver is mainline; check pin configs match. |
| [gs-spmi.md](gs-spmi.md) | 6/10 | not-ported | Gates any future PMIC work (Tier 2 mfd/regulator). |
| [gs-cpufreq.md](gs-cpufreq.md) | 6/10 | not-ported | CPU pinned at single rate without it; intersects with pKVM CMU-unlock requirement. |
| [gs-thermal.md](gs-thermal.md) | 6/10 | partially-ported (TMU mismatched, cooling not ported) | No critical-temp shutdown — hardware-protection liability. |
| [felix-device.md](felix-device.md) | 6/10 | partially-ported (boardfile only) | Device tree + felix-specific bits. |
| [aoc.md](aoc.md) | 6/10 | not-ported | Always-On Compute coprocessor. Doesn't gate boot once `/vendor/firmware/*` is installed. Gateway to mics, sensors, hotword, low-power audio. |
| [aoc-ipc.md](aoc-ipc.md) | 6/10 | not-ported | Tied to AOC; on-the-wire service descriptor library. |
| [gs-soc.md](gs-soc.md) — note: now 2/10, was placed here historically | 2/10 | mostly not-ported | Originally 9/10. C1+C2 ruled out clk; D2 (2026-05-02) ruled out EXYNOS_PD_HSI0 specifically — verification before porting confirmed AOSP's own felix UFS DT doesn't use pd_hsi0 either (it manages USB regulators, not UFS). |

## Tier 4 — Low boot relevance (4–5/10)

| Module | Score | Status | Note |
|--------|-------|--------|------|
| [gs-phy.md](gs-phy.md) | 5/10 | partially-ported (UFS PHY ported; USB DRD not; MIPI partial) | UFS PHY caveats already tracked in `gs-ufs.md`. |
| [gs-i2c.md](gs-i2c.md) | 5/10 | partially-ported | ACPM-I2C absence is the keystone gating PMIC/regulator/ODPM/PMIC-thermal work. |
| [gs101-arch.md](gs101-arch.md) | 5/10 | partially-ported | Sibling to gs201 arch; less relevant for felix. |
| [gs-iommu.md](gs-iommu.md) | 5/10 | not-ported | Required for non-coherent DMA peripherals. |
| [gs-devfreq.md](gs-devfreq.md) | 5/10 | not-ported | Limits I/O perf once UFS HS works. |
| [gs-clocksource.md](gs-clocksource.md) | 4/10 | partial (v3 MCT not ported) | Generic timers usable. |
| [gs-watchdog.md](gs-watchdog.md) | 4/10 | ported | |
| [gs-tty.md](gs-tty.md) | 4/10 | ported | UART works. |
| [gs-pci.md](gs-pci.md) | 4/10 | partially-ported (DWC glue only; per-SoC PHY CAL missing) | |
| [gs-usb.md](gs-usb.md) | 4/10 | partially-ported | |
| [gs-rtc.md](gs-rtc.md) | 4/10 | not-ported | |
| [gs-devfreq-whi.md](gs-devfreq-whi.md) | 4/10 | not-ported | |

## Tier 5 — Post-boot peripherals (1–3/10)

Roll-up — see individual files for details. None of these are on the boot path.

| Module | Score | Status |
|--------|-------|--------|
| [gs-clk.md](gs-clk.md) | 3/10 | partially-ported | Downgraded from 10 — C1+C2 CMU probes (2026-05-02) confirmed hardware never touches HSI2 dividers across PMC and the fixed-clock stub rates exactly match measured hardware rates. CCF wiring remains a reasonable long-term cleanup but is not on the critical path. |
| [gs-dma.md](gs-dma.md) | 3/10 | ported (pl330) + small Samsung shim missing |
| [gs-spi.md](gs-spi.md) | 3/10 | ported |
| [power.md](power.md) | 3/10 | not-ported |
| [gs-video.md](gs-video.md) | 3/10 | not-ported |
| [gs-power.md](gs-power.md) | 3/10 | not-ported |
| [gs-performance.md](gs-performance.md) | 3/10 | not-ported |
| [gs-bts.md](gs-bts.md) | 3/10 | not-ported |
| [gs-gpu.md](gs-gpu.md) | 3/10 | not-ported (analysis caveats — see file) |
| [gs-pwm.md](gs-pwm.md) | 2/10 | ported |
| [touch.md](touch.md) | 2/10 | partial (silicon upstream, Google glue out-of-tree) |
| [gs-media.md](gs-media.md) | 2/10 | partial (older MFC only) |
| [gs-dma-buf.md](gs-dma-buf.md) | 2/10 | partially-ported |
| [gs-char.md](gs-char.md) | 2/10 | partially-ported |
| [bluetooth.md](bluetooth.md) | 2/10 | partial (`btbcm`/`hci_bcm` upstream; `goog,nitrous` glue missing) |
| [amplifiers.md](amplifiers.md) | 2/10 | partial (cs35l4x, wm_adsp upstream; cs40l25/26, drv2624, tas256x not) |
| [video.md](video.md) | 2/10 | not-ported |
| [trusty.md](trusty.md) | 2/10 | not-ported (Android-only TEE driver) |
| [wlan.md](wlan.md) | 2/10 | not-ported (BCM4389 unsupported by mainline `brcmfmac`) |
| [radio.md](radio.md) | 2/10 | not-ported |
| [gs-input.md](gs-input.md) | 2/10 | not-ported |
| [misc.md](misc.md) | 2/10 | not-ported |
| [gpu.md](gpu.md) | 2/10 | not-ported (mainline `panthor` supports the GPU model but no gs201 platform glue) |
| [gs-iio.md](gs-iio.md) | 2/10 | not-ported |
| [nfc.md](nfc.md) | 2/10 | not-ported (felix ST21NFC variant + ST54 ESE not in mainline) |
| [display.md](display.md) | 2/10 | not-ported |
| [bms.md](bms.md) | 2/10 | not-ported |
| [typec.md](typec.md) | 2/10 | N/A — AOSP repo empty in this checkout |
| [gs-block.md](gs-block.md) | 1/10 | partial (zram upstream; Emerald Hill HW compressor hooks not) |
| [uwb.md](uwb.md) | 1/10 | not-ported |
| [lwis.md](lwis.md) | 1/10 | not-ported (Google-proprietary) |
| [hdcp.md](hdcp.md) | 1/10 | not-ported |
| [gxp.md](gxp.md) | 1/10 | not-ported (Google-proprietary ML) |
| [gps.md](gps.md) | 1/10 | not-ported |
| [fingerprint.md](fingerprint.md) | 1/10 | not-ported (Trusty-dependent anyway) |
| [edgetpu.md](edgetpu.md) | 1/10 | not-ported (Google-proprietary ML) |
| [sensors.md](sensors.md) | 1/10 | not-ported (only a Hall-effect lid switch — replaceable by `gpio_keys`) |
| [perf.md](perf.md) | 1/10 | N/A — AOSP repo empty in this checkout |

---

## Headline takeaways for UFS bring-up (HISTORICAL — fixed 2026-05-06)

The UFS-HS bring-up succeeded; the section below is preserved as a record of
what was ruled out before the actual fix landed (patches 0010 + 0011). New
readers should jump to **"USB Gadget Bring-up"** below.

1. **The clk hypothesis was RULED OUT** (was the headline lead, no longer).
   C1+C2 CMU probes on 2026-05-02 confirmed: HSI2 CMU is untouched across PMC
   in both PWM and HS, and the fixed-clock stub rates (`ufs_unipro` 177.664 MHz,
   `ufs_aclk` 267 MHz) exactly match measured hardware rates. Mainline's
   `ufshcd_set_clk_freq()` is only called from devfreq and never during PMC
   anyway. AOSP also doesn't touch HSI2 at PMC. See [gs-clk.md](gs-clk.md).

2. **The actual fix.** Patch 0010 added three missing register writes on the
   38.4 MHz refclk path that the AOSP cal-if walk does and mainline's
   open-coded tables didn't (single writes in `tensor_gs101_pre_init_cfg`,
   `gs101_ufs_pre_link`, and `gs201_ufs_post_link`). Patch 0011 pins
   `FMPSECURITY0.DESCTYPE = 0` so the controller doesn't speak the wrong PRDT
   geometry — without it every multi-PRD read or write hangs at PWM and HS
   alike. The AOSP `ufs30_cal_wait_cdr_lock` PMA-byte-0x888 kick was a red
   herring; M-PHY CDR locks first iteration once the cal-if writes from
   patch 0010 are present.

3. **EXYNOS_PD_HSI0 was a misread, also ruled out.** Originally suggested
   as a 5/10 lead. D2 verification (2026-05-02) before starting the port
   confirmed: AOSP's own `gs201-ufs.dtsi` uses `vcc-supply = <&ufs_fixed_vcc>`
   (GPIO-fixed regulator) just like our mainline. `exynos-pd_hsi0.c` actually
   manages USB PHY rails (`vdd30/vdd18/vdd085`) and calls
   `eusb_repeater_update_usb_state()` — the "HSI0" name refers to the USB
   power island. Felix has zero `vccq` / `pd_hsi` references in its DT.
   Porting would only help USB, not UFS. See [gs-soc.md](gs-soc.md). Note:
   this finding now matters for the USB gadget bring-up task too — see below.

4. **PMIC port is probably NOT the answer for UFS specifically.** Per [bms.md](bms.md),
   felix's UFS vcc rail is a fixed-regulator on a GPIO (`gpp0-1`), not a PMIC rail.
   So [gs-mfd.md](gs-mfd.md)/[gs-regulator.md](gs-regulator.md) work would not move
   the needle on UFS bring-up. Reserve for other workloads.

5. **Almost everything else here is a post-boot peripheral.** Resist the urge to
   port modules just because AOSP has them. The boot-blocker delta is small.

---

## USB Gadget Bring-up — what is important

This section indicates which AOSP modules are load-bearing for the **active
partial bring-up**: gs201 USB peripheral mode (`dr_mode = "peripheral"`,
HS-only, configfs CDC-NCM + CDC-ACM gadget). Phase A covers HS gadget; Phase B
covers MAX77759 TCPC for full DRD; Phase B.5 covers the gs201 SS PHY tune
table.

**State as of 2026-05-08 (Phase G walks complete; G.11 fix in flight).**
6 PHY hypotheses, 6 dwc3 hypotheses, dma-ranges, S2MPU stub, and CR-port
force-write all NEGATIVE. Phase G.11 walk through AOSP
`dwc3_exynos_core_init()` found a major divergence at the GFLADJ
programming for DWC31 180A-190A: AOSP hardcodes 19.2 MHz values
(DECR=0xc, PLS1=1, REFCLK_LPM_SEL=1, FLADJ=0); mainline computes from
`clk_get_rate(dwc->ref_clk)`. **Instrumentation showed the rate
returned is 614,400,000 Hz (= 32 × 19.2 MHz, the upstream PLL rate
not the divided dwc3 reference)**, so mainline programs period=1ns
instead of 52ns and GFLADJ ends up completely miscalibrated. HS
chirp/handshake (link-state) survives this, but byte-level NRZI
decode + ITP/SOF spacing don't — exactly matching the SETUP-no-show
symptom we've been chasing. Phase G.11c fix dropped the inner dwc3
node's `clocks/clock-names = "ref"` so `dwc->ref_clk = NULL` and the
`snps,ref-clock-period-ns = <52>` override takes effect; result of
that test is the next data point.

Authoritative AOSP references for any porting decision:

- **`private/google-modules/soc/gs/drivers/phy/samsung/phy-exynos-usb3p1.c`**
  (~2500 lines, Samsung CAL-based). Canonical reference for gs201 USB PHY
  register sequences, equivalent in role to the cal-if SFR table for the CMU
  layouts. Mainline `phy-exynos5-usbdrd.c` only carries a fraction of these
  writes. See [gs-phy.md](gs-phy.md).
- **`private/devices/google/gs201/dts/gs201.dtsi`** — source of truth for the
  gs201 USB hardware addresses (controller `0x11210000`, PHY `0x11200000`,
  PCS `0x110f0000`, PMA `0x11100000` size `0x2800`, IRQ 379). Mainline gs101
  reg/IRQ values do **not** apply on gs201; an early version of our port used
  them and SError'd on first MMIO. See [felix-device.md](felix-device.md).
- **`private/devices/google/felix/dts/gs201-felix-usb.dtsi`** — felix-side
  USB tune table (`&usb_hs_tune` properties) and TCPC node definitions. The
  HSPPARACON tune block on mainline (`gs201_tunes_utmi_postinit`) is a direct
  translation of the AOSP `&usb_hs_tune` values.

### Tier 1 — Primary leads for the EP0 RX silence (10/10)

| Module | Status | Why it's primary |
|--------|--------|------------------|
| [gs-usb.md](gs-usb.md) | partially-ported, **active investigation** | AOSP `dwc3_core_config()` runs unconditional register writes mainline opts out of: `GSBUSCFG0` request-info bits (cache attrs for descriptor/data DMA), `GUCTL.USBHSTINAUTORETRYEN`, `GUSB3PIPECTL` quirks. The cache-attrs candidate matches the symptom (controller fires events, gadget never sees them). 5 ranked test candidates documented in gs-usb.md — none tested yet. |
| [gs-phy.md](gs-phy.md) | partially-ported (Phase A wrapper landed, HS RX path apparently complete) | Was the headline lead through 2026-05-07 morning. Five hypotheses tested at the wrapper level (PMA, FORCE_QACT, OTP, ENBLSLPM, HSPPARACON tune); the only useful learning is that mainline's `LINKCTRL_FORCE_QACT=1` is load-bearing. None of the in-wrapper register tweaks closed the data-layer gap, so the PHY layer is plausibly **not** where the missing step lives. |

### Tier 2 — Boot-supporting infrastructure for USB (8–9/10)

| Module | Score | Status | Note |
|-------|-------|--------|------|
| [gs-soc.md](gs-soc.md) | 8/10 (was 2/10 for UFS) | not-ported | `exynos-pd_hsi0.c` is the **HSI0 power-island driver**: it manages `vdd_hsi/vdd30/vdd18/vdd085` (USB PHY rails) and calls `eusb_repeater_update_usb_state()`. The "HSI0" name was the source of the earlier UFS confusion — it's actually the USB island. Mainline relies on whatever PD state BL31 left HSI0 in, which has worked so far for HS but may matter when bringing the SS PMA online. |
| [gs-clk.md](gs-clk.md) | **9/10** (was 3/10 for UFS, 8/10 pre-G.11) | partially-ported | gs201 cmu_hsi0 is in mainline but the USB ref-clock chain misreports the rate. **Two distinct knock-on effects on mainline USB**: (1) PHY-side, the user-mux returns ~614 MHz, tripping phy-exynos5-usbdrd's strict-rate check — workaround was a 26 MHz fixed-clock stub for `phy_ref`. (2) dwc3-side (Phase G.11, 2026-05-08), `clk_get_rate(dwc->ref_clk)` on `CLK_GOUT_HSI0_USB31DRD_I_USB31DRD_REF_CLK_40` also returns 614,400,000 Hz, causing dwc3 core to program GUCTL.REFCLKPER + GFLADJ with completely wrong values (period=1ns, fladj=78450, decr=0). Workaround: drop `clocks/clock-names="ref"` from inner dwc3 + `snps,ref-clock-period-ns = <52>;` override. **Both workarounds replaceable by fixing the gs101 clk driver's USB31DRD chain to expose the actual 19.2 MHz feed** (the clock name "REF_CLK_40" itself misleadingly suggests 40 MHz). |
| [gs-mfd.md](gs-mfd.md) / [gs-regulator.md](gs-regulator.md) | 8/10 | not-ported (s2mpg12/13) | All 6 PHY supplies + 2 dwc3-exynos supplies are routed through a single fixed-1V8 always-on stub (`reg_placeholder`) because S2MPG12/13 PMIC drivers don't exist mainline. **For Phase A this is fine** — the rails are powered by the bootloader, the consumer paths don't reprogram them. For longer-term USB power management (suspend/resume, OTG VBUS control on a TCPC), the real PMIC stack matters. |

### Tier 3 — Type-C / DRD (Phase B)

| Module | Score | Status | Note |
|-------|-------|--------|------|
| [typec.md](typec.md) | 8/10 for Phase B | N/A in this AOSP checkout (empty repo); silicon is in mainline | felix uses MAX77759 as TCPC. Mainline `tcpci_maxim_core.c` + `maxim_contaminant.c` cover the silicon. The MAX77759 TCPC subfunction (specifically — the chip is multi-function: TCPC + charger; bms has the charger half) has no mainline path that wires up the felix-specific I2C topology + interrupt + role-switch. Phase B = port the AOSP `tcpci_max77759` driver, add the DT node + Type-C connector + USB-role-switch wiring, flip `dr_mode` to `"otg"`. |
| [bms.md](bms.md) | 5/10 for Phase B (charger half of MAX77759) | not-ported | Same chip. Boot doesn't need it but full PD policy (>5V charging, alt-mode DP) does. |

### Tier 4 — Adjacent infrastructure that "works on mainline" but worth knowing

| Module | Score | Status | Note |
|-------|-------|--------|------|
| [gs-pinctrl.md](gs-pinctrl.md) | 7/10 (boot-critical, already works) | ported | USB-C orientation switch + role-switch GPIOs all live behind `google,gs201-pinctrl`. Mainline already enumerates all 9 pinctrl instances. |
| [gs-iommu.md](gs-iommu.md) | 5/10 | not-ported (v8/v9 SysMMU) | DWC3 on gs201 does not appear to sit behind a SysMMU on the data path. The IOMMU gap matters for DPU/codecs/GPU/ISP, not USB. Score 5 means "USB doesn't need it; other things do." |
| [gs-i2c.md](gs-i2c.md) | 5/10 | partially-ported | The MAX77759 TCPC sits on a USI-driven I2C bus. Mainline I2C works for non-ACPM masters; ACPM-I2C is a separate concern that doesn't apply here. |

### Tier 5 — Not on the USB path (lowest relevance for this task)

| Module | Score | Status | Note |
|-------|-------|--------|------|
| [gs-ufs.md](gs-ufs.md) | 1/10 for USB (was 10/10 for itself) | mostly-ported | UFS HS-G4 lock was the previous primary; now resolved. No interaction with USB gadget. |
| [aoc.md](aoc.md) / [aoc-ipc.md](aoc-ipc.md) | 1/10 for USB | not-ported | AOC's USB-audio-offload path is irrelevant for plain CDC-NCM/CDC-ACM gadget — userspace gadget functions are the entire path; AOC isn't on it. |
| [gs-cpufreq.md](gs-cpufreq.md), [gs-thermal.md](gs-thermal.md), [gs-devfreq.md](gs-devfreq.md) | 1/10 for USB | not-ported | Performance/safety concerns, but USB throughput is not the bottleneck for our HS-only gadget. |

### Quick-reference checklist for what we currently rely on (and the AOSP files that justified each)

- **DT remap from gs101 to gs201 USB hardware addresses.** AOSP source: `private/devices/google/gs201/dts/gs201.dtsi`. Mainline result: `arch/arm64/boot/dts/exynos/google/gs201.dtsi` updated.
- **`google,gs201-usb31drd-phy` compat with `phy_cfg_gs201`.** AOSP source: `phy-exynos-usb3p1.c` (UTMI initialisation flow plus the PIPE3 register set we don't yet apply). Mainline result: `drivers/phy/samsung/phy-exynos5-usbdrd.c` extended with `exynos5_usbdrd_gs201_utmi_init` + the G2PHY_CNTL0/CNTL1 power-stable handshake + felix-specific HSPPARACON tune.
- **dwc3-exynos `SOFITPSYNC = 1` when `dis_u2_freeclk_exists_quirk` is set.** AOSP source: AOSP `dwc3-exynos.c` sets it unconditionally; we narrowed to the quirk path. Mainline result: a hunk in `drivers/usb/dwc3/core.c`.
- **Fixed-1V8 always-on stub for all 8 USB supplies (`reg_placeholder`).** AOSP source: gs201-felix-pmic.dtsi (s2mpg12/13 LDOs). Mainline result: `gs201-felix.dts`.
- **26 MHz fixed-clock stub for `phy_ref`.** AOSP source: cal-if cmu_hsi0 USB ref clock. Mainline result: same dtsi.
- **`google,gs201-uart` compat (UPIO_MEM32) — required for UART login while USB gadget is being brought up.** AOSP source: bootloader earlycon uses `mmio32`; AOSP samsung_tty downstream uses UPIO_MEM32 on these compats. Mainline result: `samsung_tty.c` of_match table extended (patch 0015).

### Files impacted by rebasing on Linux 7.1

We're currently submodule-pinned at `v7.0-15-g3f9dc7716d0e` (v7.0 RTM + 15 of
our local commits). The next rebase target is mainline 7.1. Per the
`reference_mainline_gs201_status.md` memory snapshot (7.1-rc2, May 2026),
the deltas that will flow in from mainline are:

| Mainline 7.1 delta | Files that should be re-checked / updated |
|---|---|
| **gs101 DPU / cmu_dpu work landed.** Recent activity in `clk-gs101.c` for the DPU domain plus DRM scaffolding for the gs101 display path. Template for any gs201 DPU port. | [display.md](display.md), [gs-clk.md](gs-clk.md) (cmu_dpu coverage will improve), [gs-phy.md](gs-phy.md) (MIPI D-PHY may pick up gs101 compats), [gs101-arch.md](gs101-arch.md) (de-risked further) |
| **S2MPG11 ACPM PMIC scaffold (Feb 2026) merged.** First in-tree code path for an ACPM-mediated Samsung PMIC. Template for S2MPG12/13 (gs201 main + sub) when we port them. | [gs-mfd.md](gs-mfd.md), [gs-regulator.md](gs-regulator.md), [gs-soc.md](gs-soc.md) (ACPM IPC story is now slightly less "no template at all"), [bms.md](bms.md) (PMIC-side wiring is the same shape), [aoc.md](aoc.md) (AOC port also wants ACPM long-term) |
| **gs101 USB DT + clock controller now full upstream.** Includes the gs101 USB31DRD compat work and cmu_hsi0 entries. Relevant because our gs201 USB Phase A wrapper extends `phy-exynos5-usbdrd.c` directly and any 7.1 driver changes there will need to be merged through. | [gs-usb.md](gs-usb.md), [gs-phy.md](gs-phy.md) (the gs201 wrapper sits on top of whatever mainline gs101 PHY driver is at 7.1), [gs-clk.md](gs-clk.md) (cmu_hsi0 user-mux behaviour may change) |
| **MAX77759 TCPC has no mainline path** (still). Must port from AOSP for DRD; Phase B is unaffected by the rebase except for general TCPM framework churn. | [typec.md](typec.md), [bms.md](bms.md) (charger half of MAX77759) |
| **gs201 mainline coverage is still ~zero** beyond what we've upstreamed. Our 15 in-flight patches (UFS 0001–0012, clk/UART 0013–0015) are not in 7.1. | [gs201-arch.md](gs201-arch.md), [gs-ufs.md](gs-ufs.md), [gs-tty.md](gs-tty.md), [gs-clk.md](gs-clk.md) |
| **Mainline UFS PHY framework changes** (if any in 7.1). The two PMA register-transcription fixes (patch 0004, 0007, 0009) and the three cal-if writes (patch 0010) live in `phy-gs101-ufs.c`; rebasing may surface conflicts if upstream re-touched the same arrays. | [gs-ufs.md](gs-ufs.md), [gs-phy.md](gs-phy.md) |

Files that should be **safe** under a 7.1 rebase (no delta expected in
mainline that touches them, or status is "not-ported, nothing to merge"):
[fingerprint.md](fingerprint.md), [edgetpu.md](edgetpu.md),
[gxp.md](gxp.md), [lwis.md](lwis.md), [hdcp.md](hdcp.md),
[gps.md](gps.md), [uwb.md](uwb.md), [trusty.md](trusty.md),
[wlan.md](wlan.md), [radio.md](radio.md), [nfc.md](nfc.md),
[sensors.md](sensors.md), [touch.md](touch.md),
[fingerprint.md](fingerprint.md), [perf.md](perf.md),
[gs-iio.md](gs-iio.md), [gs-pwm.md](gs-pwm.md),
[gs-rtc.md](gs-rtc.md), [gs-spi.md](gs-spi.md),
[gs-input.md](gs-input.md), [gs-watchdog.md](gs-watchdog.md),
[gs-pinctrl.md](gs-pinctrl.md) (already complete),
[gs-block.md](gs-block.md), [gs-char.md](gs-char.md),
[gs-dma.md](gs-dma.md), [gs-dma-buf.md](gs-dma-buf.md),
[gs-media.md](gs-media.md), [gs-iommu.md](gs-iommu.md) (no v8/v9 mainline
work expected), [gs-spmi.md](gs-spmi.md), [gs-i2c.md](gs-i2c.md).

If 7.1 lands additional gs101 work between now and rebase, re-grep this
table and update the per-file status lines.

### What "important" excludes

The framing here is "what gets us from current state to a host that sees
`/dev/ttyACM0` + `usb0`". It is **not** "what gets gadget bring-up to be
cleanly upstreamable" — that's a strict superset and includes (a) replacing
`reg_placeholder` with real S2MPG12/13 regulator handles, (b) replacing
`phy_ref` fixed-clock with a real cmu_hsi0 entry, (c) finding the gs201 SS PMA
register set so PIPE3 init can be more than a stub, (d) reverse-engineering
the gs201 PHY's HS-RX-enable sequence so EP0 SETUP actually lands. (d) is the
single open blocker; (a)–(c) are upstream-quality concerns, not bring-up
concerns.
