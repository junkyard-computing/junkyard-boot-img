# s2mpg13 sub-PMIC port (gs201) — the thermal/power keystone

**Why:** the s2mpg13 sub-PMIC is the single chip that owns three things mainline felix
needs, none of which have any mainline support today:
1. **skin_therm** (+7 other NTC thermal-zones incl. the 55.5/56.5/58.5 °C skin safety
   backstop) — the board-surface "warm to touch" temperature, our missing idle-heat
   diagnostic.
2. **ODPM** per-rail power meter — the only way to measure idle-power on mainline while
   on wall power (battery FG reads ~0 on the 9V PD sink). Unblocks quantifying the
   power-domain-gating win (all 20 domains are ON at idle — see
   gs201-power-domains-scoping.md).
3. **inner-panel LDO rails** (s_ldo28 = vci, s_ldo4 = vddi) — currently blanked by the
   gpa7-1 gpio-hog hack; real rail-off is cleaner and provably kills the panel's draw.

## What mainline already has (the leverage)

This is a **variant extension**, not a from-scratch port. Mainline (André Draszik's
gs101 series, merged by v7.2) has the whole s2mpg **family** for the previous-gen gs101
PMICs s2mpg10 (main) / s2mpg11 (sub):
- MFD core: `drivers/mfd/sec-acpm.c` + `sec-common.c` (ACPM-transport regmap, per-device
  `device_type`, mfd_cell lists). `enum sec_device_type` at
  `include/linux/mfd/samsung/core.h:38` (`S2MPG10, S2MPG11`).
- Regulator: `drivers/regulator/s2mps11.c` handles the family via id_table
  (`s2mpg10-regulator`/`s2mpg11-regulator`, descriptor tables `s2mpg10_regulators[]`
  @925, `s2mpg11_regulators[]` @1207, device_type switches @462/484/543).
- Headers: `include/linux/mfd/samsung/s2mpg10.h` (478L) / `s2mpg11.h` (434L) — clone
  template. dt-bindings `dt-bindings/regulator/samsung,s2mpg10-regulator.h`.
- DT template: `gs101-pixel-common.dtsi` `&acpm_ipc { pmic-1 { compatible =
  "samsung,s2mpg10-pmic"; ... } }` (main) + the sub node.
- **NOT upstream:** the `*-meter` (ODPM) leaf driver (mfd cell is registered but unbound)
  and any spmic-thermal driver. Those are ported from AOSP.

On gs101 the main + sub PMICs probe as **independent** acpm nodes, so **s2mpg13 (sub)
can be brought up alone** — and both priority payoffs (skin NTC + panel LDOs) live on the
sub. s2mpg12 (main, has the CPU/GPU/MIF bucks + RTC) is deferred; we do NOT need it and
must NOT casually expose its bucks (disabling a CPU/MIF buck = instant death).

## AOSP source (transcription source of truth)

Under `private/google-modules/soc/gs/` in the AOSP tree
(`../junkyard-boot-img/kernel/source`):
- `drivers/mfd/s2mpg13-core.c`, `include/linux/mfd/samsung/s2mpg13-register.h`,
  `s2mpg13.h`, `s2mpg13-meter.h`
- `drivers/regulator/s2mpg13-regulator.c`, `s2mpg13-powermeter.c`
- `drivers/thermal/google/s2mpg13_spmic_thermal.c`

### Register access model
ACPM transport, **channel 1**, 12-bit addr = `(sub_addr << 8) | reg`. Banks (sub_addr):
COMMON 0x00, PMIC 0x01, METER 0x0A, WLWP 0x0B, GPIO 0x0C, MT_TRIM 0x0E, TRIM 0x0F.
CHIPID at COMMON 0x00B (low 3 bits = rev; **no magic-ID compare** — probe only fails if
the ACPM read fails). regmap valid ranges (reg_bits=12, max 0xC14): 0x000-0x029 common,
0x100-0x1D7 PM, 0xA00-0xAE5 meter(+NTC), 0xC05-0xC14 gpio.

### Panel LDOs (payoff #3) — the only two rails Phase 1 must expose
- **s_ldo4** (vddi): enable_reg = vsel_reg = PM `L4S_CTRL` = 0x2F → full **0x12F**;
  enable bit = **BIT(7)**; vsel_mask 0x3F; group 6 (min 700000 µV, step 25000).
  Force off = clear bit7 of 0x12F.
- **s_ldo28** (vci): enable_reg = vsel_reg = PM `L28S_CTRL` = 0x47 → full **0x147**;
  enable bit = **BIT(7)**; vsel_mask 0x3F; group 7 (min 1800000 µV, step 25000).
  Force off = clear bit7 of 0x147.
(LDOs 1,23,24,25,26 share enable bits in LDO_CTRL1=0x48/LDO_CTRL2=0x49 — not these two,
which are the simple self-contained case.)

### skin NTC read (payoff #1) — self-contained, independent of ODPM
spmic-thermal (`google,s2mpg13-spmic-thermal`, 8 channels) reads NTC **directly from the
METER bank**, not via the powermeter driver:
- NTC data: METER `LPF_DATA_NTC0_1` = 0xD4 → full **0xAD4**, 2 bytes/channel (NTC_BUF=2),
  channel N at `0xAD4 + 2*N`. raw = `data[0] | ((data[1] & 0xf) << 8)` (12-bit).
- adc_chan is 1:1 with NTC index; skin_therm is channel 2 (per AOSP felix thermal DT:
  neutral=0, quiet=1, skin=2, usb=3/4, inner_disp=5, outer_disp=6, gnss=7).
- Channel enable: METER `CTRL3` = 0xA0A bitmask (bit i = ch i); enable dance (b/200582715):
  toggle MT_TRIM `COMMON2` 0x0E34 0x00→0x80→(CTRL3=0)→0x00→0x80, write CTRL3=chan_mask,
  sleep 50ms, re-enable meter (`METER_CTRL1 |= METER_EN`). Sample rate: METER CTRL1
  NTC_SAMP_RATE field (shift 5, 0x7) = NTC_0P15625HZ(1).
- **volt→millidegC = 32-point lookup + linear interpolation** (the single load-bearing
  constant; transcribe verbatim from `s2mpg13_spmic_thermal.c:77-89`, `s2mpg13_adc_map[]`,
  descending code / ascending mdeg; clamp to endpoints, `mult_frac` interpolate).
- Optional trips: per-channel OT_WARN 0xA3D+ch, UT_WARN 0xA4D+ch, OT_FAULT 0xA45+ch
  (HW shutdown); threshold raw = `map_temp_volt(temp) >> 4 & 0xFF` (top 8 bits).

### ODPM meter (payoff #2) — deferred to Phase 3
12 channels, MUXSEL0..11 = 0x11..0x1C pick the rail; LPF (instant) `LPF_DATA_CH0_1`=0xAE..
CH11 0xCF (3 B/ch); ACC (accumulated) `ACC_DATA_CH0_1`=0x63.. (6 B/ch) + ACC_COUNT
0xAB-0xAD. Same METER bank + shared CTRL1/CTRL3 as NTC (why thermal re-enables meter after
reprogramming NTC). NTC and ODPM are independent consumers of the same block.

### MFD cells (AOSP s2mpg13_devs[])
regulator, meter, gpio, **spmic-thermal** (`google,s2mpg13-spmic-thermal`). No RTC (main
only). MFD DT compatible `samsung,s2mpg13mfd`; six i2c sub-clients (pmic/meter/wlwp/gpio/
mt_trim/trim); IRQ via notifier (`irq_alloc_descs ... S2MPG13_IRQ_NR`).

## Phased plan

**Phase 1 — s2mpg13 MFD + panel LDOs (variant extension; payoff #3 + prereq for all).**
1. `core.h`: `enum sec_device_type` += `S2MPG12, S2MPG13`.
2. `include/linux/mfd/samsung/s2mpg13.h` — **minimal**: COMMON CHIPID, PM L4S_CTRL(0x2F)/
   L28S_CTRL(0x47) + regulator id enum for LDO4/LDO28, METER CTRL1/CTRL3 + NTC data +
   warn/fault, MT_TRIM COMMON2, enable-mask BIT(7), group6/7 min/step. (Full 450-line
   transcription not needed for the panel+skin milestone.)
3. `dt-bindings/regulator/samsung,s2mpg13-regulator.h` — LDO4/LDO28 ids (extend later).
4. `sec-acpm.c`: s2mpg13 regmap ranges (common/pmic/meter) + `sec_pmic_acpm_data` for
   `S2MPG13` (clone the s2mpg11 sub entry; confirm ACPM channel — AOSP uses ch1).
5. `sec-common.c`: `s2mpg13_devs[]` mfd_cells (regulator + spmic-thermal; meter+gpio
   optional) + device dispatch.
6. `s2mps11.c`: `s2mpg13_regulators[]` with **only** LDO4 + LDO28 to start (safe — no
   bucks) + `S2MPG13` cases + id_table entry `{ "s2mpg13-regulator", S2MPG13 }`.
7. DT: gs201 `&acpm_ipc { s2mpg13: pmic-2 { compatible = "samsung,s2mpg13-pmic"; ... }
   regulators { s_ldo4 { ... }; s_ldo28 { ... }; } }`. Do NOT mark the panel LDOs
   always-on → framework's unused-regulator cleanup turns them off (= inner panel off,
   replacing the gpio-hog). Cross-check the hog can then be dropped.
   *Milestone:* s2mpg13 MFD probes; `/sys/class/regulator` shows s_ldo4/s_ldo28; inner
   panel dark without the gpio-hog.

**Phase 2 — spmic-thermal (payoff #1, skin_therm).** Port a minimal
`s2mpg13-spmic-thermal` reading the meter regmap NTC regs + the 32-pt table; register 8
`devm_thermal_of_zone`s. DT: 8 thermal-zones referencing `<&s2mpg13_tm N>` (clone AOSP
`gs201-felix-thermal.dtsi`; skin=ch2). *Milestone:* skin_therm zone reads real board temp;
now we can watch idle heat at the surface.

**Phase 3 — ODPM meter (payoff #2).** Port `s2mpg13-powermeter` (LPF + ACC), expose per-
rail power (iio or hwmon). *Milestone:* per-rail idle power on wall power → measure the
power-domain-gating win.

## Risks / notes
- PMIC bring-up can misbehave; a bad probe/regmap could need a physical power-cycle.
  **Flash Phase 1 with the user present near the power button**, not unattended.
- Only expose sub-PMIC LDOs in Phase 1 — never the main-PMIC bucks (CPU/MIF/GPU rails).
- Confirm the mainline sec-acpm ACPM channel matches what gs201 s2mpg13 expects (AOSP=1).
- Kernel Image rebuild required (driver change) → reflash boot.img; DT change → reflash
  vendor_boot.img (recipes: this session's ISP/TPU flow, and
  [[project_thermal_stability_detour]]).
- Building: `nix develop` shell (cross = aarch64-unknown-linux-gnu-), `DTC_FLAGS=-@` for
  the dtb (see gitlog: the __symbols__ requirement).
