# AOSP-vs-Mainline Module Port Audit

This directory holds one markdown file per AOSP kernel module from
[kernel/source.aosp-backup/](../source.aosp-backup/). Each file:

- describes what the module does,
- identifies the mainline counterpart (if any),
- summarizes the gap between AOSP and our [kernel/source/](../source/),
- scores 1–10 how likely closing that gap would help our **current boot blockers**.

## Current boot blockers (the scoring lens)

1. **UFS storage wedges at HS gear** — only PWM works (5–10 MB/s). HS-Rate-A and
   HS-Rate-B both wedge with `dl_err 0x80000002` on first frame after PMC. **PRIMARY blocker.**
2. **AOC firmware needed for UART input** — already solved by installing
   `/vendor/firmware` blobs. Listed for completeness; not an active blocker.

Everything else (display, GPU, audio, sensors, fingerprint, NFC, BT/WLAN, etc.)
is post-boot peripheral. The system already boots to a kmscon login on serial
console with wired ethernet up.

## Score legend

| Score | Meaning |
|-------|---------|
| 10 | Direct lead on UFS HS bring-up or another active blocker |
| 8–9 | Boot-critical infrastructure (clocks, regulators, pinctrl, PMIC, IOMMU) |
| 6–7 | Important subsystem affecting stability / performance / security |
| 4–5 | Useful but boot succeeds without it |
| 2–3 | Post-boot peripheral |
| 1 | Unrelated to boot |

---

## Tier 1 — Primary leads (10/10)

| Module | Status | Why it scores 10 |
|--------|--------|------------------|
| [gs-ufs.md](gs-ufs.md) | partially-ported | Direct active blocker. Documents missing `__set_pcs`, `exynos_ufs_get_caps_after_link`, `exynos_ufs_update_active_lanes`, `exynos_ufs_init_pmc_req` math, `ufs_cal_pre_pmc`/`ufs_cal_post_pmc`, and the highest-suspicion `ufs30_cal_wait_cdr_lock` PMA byte-0x888 kick-start writes. |
| [gs201-arch.md](gs201-arch.md) | partially-ported | Umbrella for our SoC — compounds every other gap. CMU coverage thin, no PD_HSI0, no ACPM, no PMIC, no SPMI. |

## Tier 2 — Boot-critical infrastructure (8–9/10)

| Module | Score | Status | Note |
|--------|-------|--------|------|
| [gs-mfd.md](gs-mfd.md) | 8/10 | not-ported | s2mpg12/13 PMIC absent in mainline. |
| [gs-regulator.md](gs-regulator.md) | 8/10 | mixed (slg51000/rt6160/max77826 partial; s2mpg* not-ported) | UFS analog rails (vcc/vccq/vccq2) can't be tweaked from kernel-side without this. NOTE: see [bms.md](bms.md) — felix's UFS rail is actually a fixed-regulator on a GPIO, not a PMIC rail, so this may matter less than expected for the UFS blocker specifically. |

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

## Headline takeaways for UFS bring-up

1. **The clk hypothesis is RULED OUT** (was the headline lead, no longer).
   C1+C2 CMU probes on 2026-05-02 confirmed: HSI2 CMU is untouched across PMC
   in both PWM and HS, and the fixed-clock stub rates (`ufs_unipro` 177.664 MHz,
   `ufs_aclk` 267 MHz) exactly match measured hardware rates. Mainline's
   `ufshcd_set_clk_freq()` is only called from devfreq and never during PMC
   anyway. AOSP also doesn't touch HSI2 at PMC. See [gs-clk.md](gs-clk.md).

2. **The smoking-gun PHY work is in [gs-ufs.md](gs-ufs.md)** — the AOSP
   `ufs30_cal_wait_cdr_lock` writes 0x4 to PMA byte 0x888 to kick-start CDR.
   Mainline doesn't do this. Confirmed missing; matches the failure signature.

3. **EXYNOS_PD_HSI0 was a misread, also ruled out.** Originally suggested
   as a 5/10 lead. D2 verification (2026-05-02) before starting the port
   confirmed: AOSP's own `gs201-ufs.dtsi` uses `vcc-supply = <&ufs_fixed_vcc>`
   (GPIO-fixed regulator) just like our mainline. `exynos-pd_hsi0.c` actually
   manages USB PHY rails (`vdd30/vdd18/vdd085`) and calls
   `eusb_repeater_update_usb_state()` — the "HSI0" name refers to the USB
   power island. Felix has zero `vccq` / `pd_hsi` references in its DT.
   Porting would only help USB, not UFS. See [gs-soc.md](gs-soc.md).

4. **PMIC port is probably NOT the answer for UFS specifically.** Per [bms.md](bms.md),
   felix's UFS vcc rail is a fixed-regulator on a GPIO (`gpp0-1`), not a PMIC rail.
   So [gs-mfd.md](gs-mfd.md)/[gs-regulator.md](gs-regulator.md) work would not move
   the needle on UFS bring-up. Reserve for other workloads.

5. **Almost everything else here is a post-boot peripheral.** Resist the urge to
   port modules just because AOSP has them. The boot-blocker delta is small.
