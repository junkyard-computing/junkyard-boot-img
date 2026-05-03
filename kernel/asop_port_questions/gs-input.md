# input

- **AOSP path**: `private/google-modules/soc/gs/drivers/input/`
- **Mainline counterpart**: partial — generic input core + some PMIC-key drivers
- **Status**: not-ported (Pixel-specific bits)
- **Boot-relevance score**: 2/10

## What it does

Grab-bag of Pixel input glue:
- `keyboard/s2mpg12-key.c`, `keyboard/s2mpg14-key.c` — power-button / volume-key driver hanging off the s2mpg12/14 PMICs. Generates KEY_POWER, KEY_VOLUMEUP, KEY_VOLUMEDOWN events.
- `keycombo.c`, `keydebug-core.c` — combo-key handler that triggers debug actions (sysrq, panic, etc.) on long-press of specific key combinations.
- `fingerprint/` — `gf_spi.c` is a Goodix fingerprint sensor over SPI (used by felix's side-mounted fingerprint reader).
- `misc/vl53l1/` — STMicro VL53L1 time-of-flight ranging sensor (ambient light/proximity replacement).

## Mainline equivalent

- s2mpg key drivers: not in mainline (s2mpg PMIC family itself isn't in mainline).
- keycombo / keydebug: out-of-tree concept; mainline has generic sysrq.
- Goodix fingerprint: not in mainline.
- VL53L1: there's `drivers/iio/proximity/vl53l1x-core.c` in mainline (different ABI but same hardware). Different from this AOSP driver which exposes a Pixel-specific char-dev rather than IIO.

## Differences vs AOSP / what's missing

Everything is Pixel-userspace-specific. Power button on felix would not work without porting the s2mpg PMIC key driver — but that depends on s2mpg PMIC core being in mainline (which depends on ACPM-I2C). On felix today we soft-power-off via `poweroff` userspace; physical buttons are dead.

## Boot-relevance reasoning

2/10. Boot completes without any of this. Power-button-not-working is annoying but not a blocker (the user has working console + ssh paths). Fingerprint and ToF are post-boot peripherals.

