# gs-regulator

- **AOSP path**: `private/google-modules/soc/gs/drivers/regulator/`
- **Mainline counterpart**: partial (`slg51000-regulator.c`, `rt6160-regulator.c`, `max77826-regulator.c` exist; nothing for s2mpgXX)
- **Status**: not-ported (s2mpgXX); ported (slg51000, rt6160, max77826 with downstream tweaks)
- **Boot-relevance score**: 8/10

## What it does

The big one: regulator drivers + powermeter sub-blocks for every felix PMIC rail.
- `s2mpg10/11/12/13/14/15-regulator.c` — main regulator drivers; s2mpg12 (main) + s2mpg13 (sub) cover **gs201/felix**
- `s2mpg10/11/12/13/14/15-powermeter.c` — per-rail current/voltage ADC subblocks (8–14 channels each)
- `pmic_class.c` — sysfs class for shared regulator controls
- `max77826-gs-regulator.c` — vendored fork of MAX77826
- `rt6160-regulator.c` — Richtek RT6160 buck-boost
- `slg51000-regulator.c` / `slg51002-regulator.c` — Dialog secondary LDOs (camera, display)

Together they let the kernel actually change voltages on every rail of the SoC.

## Mainline equivalent

- `s2mpgXX`: nothing. Mainline knows about Exynos-era `s2mpa01.c` / `s2mps11.c` but the s2mpg series is a different chip/register layout.
- `slg51000`: mainline has it; minor tweaks vs AOSP.
- `rt6160`: mainline has it.
- `max77826`: mainline has it.

## Differences vs AOSP / what's missing

100% of s2mpg12/13 (felix-relevant). 100% of s2mpg14/15 (Zuma). The slg51002 driver (felix uses it for camera LDOs) is missing from mainline. The PMIC powermeter subdrivers (`POWERMETER_S2MPG*`) — used for IPA/thermals — are completely absent.

## Boot-relevance reasoning

**Score 8**: see [gs-mfd.md](gs-mfd.md) — same reasoning. The kernel cannot adjust any of the SoC-internal rails today; we inherit whatever the bootloader programmed. UFS analog supplies (`vcc`, `vccq`, `vccq2`) come from s2mpg12 LDOs. Without a working regulator driver, mainline `ufs-exynos.c` cannot:
- bump VCCQ slightly higher during HS gear training (some quirks need this)
- set the regulator load mode (high-current PWM vs low-current PFM) when crossing gears
- query the actual rail voltage to validate against the spec

This is plausibly a contributor to HS-Rate-A/B wedge — at least it deserves to be ruled in or out. But it's secondary to the clock controller (see [gs-clk.md](gs-clk.md)) which is more directly suspect.
