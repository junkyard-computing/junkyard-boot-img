# power

- **AOSP path**: `private/google-modules/power/` (subdirs: `mitigation/`, `reset/`)
- **Mainline counterpart**: NONE for either subdir (the BCL is a Google invention; the reboot driver is Pixel/Samsung-bespoke)
- **Status**: not-ported
- **Boot-relevance score**: 3/10

## What it does

Two unrelated subsystems live here:

1. `mitigation/google_bcl_*` — the Google **Battery Current Limiter**: monitors the
   PMIC's brownout/OCP/UVLO/SMPL IRQs (S2MPG10/11 on gs101, S2MPG12/13 on gs201, S2MPG14/15
   on Zuma) plus the max77759/max77779 charger's vdroop signals, and reacts by throttling
   CPU/GPU/modem via thermal-zone and PM-QoS hooks to keep the rail above brownout. It's
   tightly coupled to the Samsung `s2mpgXX` MFD/regulator drivers and a Google-private
   `odpm-whi` (on-device power monitor) telemetry layer.
2. `reset/pixel-gs{101,201}-reboot.c` and `pixel-zuma-reboot.c` — a `register_restart_handler`
   that translates `reboot bootloader/recovery/fastboot/...` strings into the bootloader's
   reboot-cmd word in `EXYNOS_PMU_SYSIP_DAT0`, *and* persists the same value in the BMS
   EEPROM via `gbms_storage` so a thermal-shutdown reason survives a battery-pull reset.

## Mainline equivalent

Neither subdir has an upstream counterpart. The BCL stack depends on the never-upstreamed
S2MPG12/13 PMIC drivers and the `odpm-whi`/`exynos-cpupm`/`exynos-pm` SoC plumbing. The
reboot driver ties the PMU restart-cmd path to the proprietary `gbms_storage` EEPROM API.

## Differences vs AOSP / what's missing

Everything. Mainline gs201 has no S2MPG12/13 regulator support at all (the `s2mps11`
upstream driver covers earlier Exynos PMICs only), so the BCL has nothing to bind to.
The reboot driver could in principle be reduced to a small `syscon-reboot-mode` shim
hitting `EXYNOS_PMU_SYSIP_DAT0`, but that path isn't wired up in mainline either.

## Boot-relevance reasoning

Despite the name, **none of this is on the boot path**. The BCL is a thermal/throttling
policy that runs after userspace is up, and it has no responsibility for bringing rails
up at probe — that's the regulator framework's job, which on felix is satisfied by a
fixed-regulator stub for UFS-VCC and whatever the bootloader left enabled for everything
else (ufs-phy supplies are not in DT, hence not under Linux's control today). The reboot
driver only matters when you `reboot recovery` etc. and want the bootloader to honor the
mode — irrelevant to first-boot success.

Score nudged to 3 (instead of 1) only because the *reason* mainline doesn't do
fine-grained regulator control on gs201 is the missing S2MPG12/13 driver, and porting
that — separate work, not in this directory — would unblock proper voltage/EN sequencing
that *might* matter for UFS PHY rails (`vdd_85_pcie/ufs`, etc., visible in AOSP DT but
not exposed as Linux regulators today). The BCL itself is unrelated to that effort.
