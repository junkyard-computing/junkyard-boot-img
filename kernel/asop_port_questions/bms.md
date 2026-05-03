# bms

- **AOSP path**: `private/google-modules/bms/`
- **Mainline counterpart**: `drivers/power/supply/` (partial — generic Maxim FG/charger drivers exist; the Google-proprietary glue does not)
- **Status**: not-ported
- **Boot-relevance score**: 2/10

## What it does

This is the entire battery / charger / fuel-gauge stack for Pixel devices. It bundles the
Google-authored layered policy (`google_battery`, `google_charger`, `google_cpm` charge-policy
manager, `google_ttf` time-to-full, `google_dock`, `google_ccd`, EEPROM (`google_eeprom*`),
`gbms_storage`, `pmic-voter`) on top of a thicket of vendor chip drivers: Maxim
`max77729`/`max77759`/`max77779` PMIC+charger+FG families, `max1720x` fuel gauge, `max20339`
OVP, `p9221` wireless RX, `pca9468`/`ln8411`/`hl7132` direct-charge pumps, and `rt9471`. The
Google layer adds multi-step CC/CV charge tables driven by battery temp/voltage, EEPROM-backed
lifetime stats, and a charger-policy "voter" arbitration layer. Felix specifically uses a
Maxim PMIC + max77759 charger + max1720x FG combo (per AOSP `gs201-felix-charging.dtsi`).

## Mainline equivalent

`drivers/power/supply/` ships the upstream `max1720x_battery.c` and `max1721x_battery.c`
(generic ModelGauge m5 fuel gauges), plus older `max77693_charger.c` and `max77705_charger.c`.
`max77759` and `max77779` have no upstream charger drivers at all. `max20339` (OVP), `p9221`
(IDT/Renesas wireless RX), `pca9468`/`ln8411`/`hl7132` (DC/DC charge pumps) — none of these
have upstream drivers. The Google `gbms_*` policy layer (multi-step charging, charge
tables, voter arbitration, charge-pump orchestration) is wholly out-of-tree and uses a
custom power-supply API extension (`gbms_power_supply.h`).

## Differences vs AOSP / what's missing

Mainline has only the lowest-level fuel-gauge silicon support, and even there only for older
parts. The entire policy layer (`google_charger` CC/CV stepping, CPM multi-charger
arbitration, dual-battery gauging used by felix's two-cell pack, EEPROM lifetime tracking)
plus all the post-2021 Maxim silicon (`max77759`, `max77779` and the associated
`maxq`/`vimon`/`scratchpad`/`fwupdate`/`pmic-irq`/`pmic-pinctrl`/`pmic-sgpio` companion
drivers) and all the third-party DC chargers (`pca9468`, `ln8411`, `hl7132`, `rt9471`,
`p9221` wireless) are missing. The mainline `gs201-felix.dts` doesn't reference any of these
at all — there's no battery node, no charger node, nothing on the charging I2C bus.

## Boot-relevance reasoning

Felix's UFS rail (`ufs_fixed_vcc`) is a GPIO-controlled fixed regulator off `gpp0-1` —
not a PMIC rail. The kernel boot path doesn't touch the charger or fuel gauge to get a
mounted rootfs. With a charged battery (or USB power supplied) the SoC just runs; without
any battery driver the kernel will assume AC-powered and proceed. Score 2 because (a) it
has zero relationship to UFS HS-Rate-B (the only real blocker), and (b) the absence of a
charger driver only becomes painful for sustained operation (no charge management → battery
drains, but boot completes). Bumped from 1 only because long-running kernel-hacking
sessions on the device benefit from working charging.
