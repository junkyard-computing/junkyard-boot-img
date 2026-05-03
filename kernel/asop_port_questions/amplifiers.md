# amplifiers

- **AOSP path**: `private/google-modules/amplifiers/`
- **Mainline counterpart**: `sound/soc/codecs/cs35l41*`, `sound/soc/codecs/cs35l45*`, `sound/soc/codecs/cs40l50*`, `sound/soc/codecs/wm_adsp.c`, `drivers/input/misc/cs40l50-vibra.c` (partial coverage)
- **Status**: partially-ported
- **Boot-relevance score**: 2/10

## What it does

Out-of-tree vendor drops for the audio / haptics ICs Google has shipped across the Pixel line:

- `cs35l41`, `cs35l45` — Cirrus Logic boosted Class-D speaker amplifiers with onboard DSP, ASoC codec drivers (I2C + SPI variants).
- `cs40l25`, `cs40l26` — Cirrus Logic boosted haptic drivers (LRA actuator) with integrated DSP and waveform memory; bundled with their own `cl_dsp` firmware-load layer and a debugfs/codec interface.
- `drv2624` — TI DRV2624 ERM/LRA haptic driver.
- `tas256x`, `tas25xx` — TI TAS256x / TAS25xx Smart Amp drivers (out-of-tree TI BSP layout: `algo/`, `physical_layer/`, `logical_layer/`, `os_layer/`).
- `snd_soc_wm_adsp` — Cirrus / Wolfson `wm_adsp` firmware coefficient loader (the ADSP2/Halo runtime that the cs35l41/cs35l45 drivers depend on).
- `audiometrics` — Google sysfs/uAPI shim that exposes per-codec metrics (over-temp, click counters, runtime stats) for telemetry.

These are the vendor-supplied vendor BSP versions, often forked weeks-to-months ahead of (or behind) what Cirrus / TI have upstreamed.

## Mainline equivalent

Reasonable upstream coverage for the Cirrus parts, scattered TI coverage:

- `sound/soc/codecs/cs35l41{.c,-i2c.c,-spi.c,-lib.c,-tables.c}` plus the HDA companion under `sound/hda/codecs/side-codecs/cs35l41_hda*` — full mainline cs35l41 ASoC codec.
- `sound/soc/codecs/cs35l45{.c,-i2c.c,-spi.c,-tables.c}` — full mainline cs35l45 ASoC codec.
- `sound/soc/codecs/cs40l50-codec.c` + `drivers/input/misc/cs40l50-vibra.c` — newer Cirrus haptic part. **No upstream cs40l25 or cs40l26**; those went out-of-tree only.
- `sound/soc/codecs/wm_adsp.{c,h}` — full mainline ADSP2/Halo loader, the dep that backs cs35l4x DSP firmware.
- `sound/soc/codecs/tas2562.c`, `tas2552.c` — older TI Smart Amp parts, **not** the tas256x/tas25xx generation Google ships.
- `drivers/input/misc/drv260x.c`, `drv2665.c`, `drv2667.c` — sibling TI haptic parts, **but no `drv2624`** in mainline.
- `audiometrics` is a Google-private telemetry shim with no upstream analogue.

## Differences vs AOSP / what's missing

The mainline cs35l41 / cs35l45 / wm_adsp drivers will most likely Just Work for the Pixel Fold's speaker amps if a machine driver wires them up, possibly with vendor tunings that have to be re-applied as `cirrus,*` device-tree properties or in a new firmware-coefficient blob. The TI tas256x and the cs40l25/cs40l26/drv2624 haptic stacks have no upstream equivalent — porting them means lifting the AOSP source as out-of-tree modules. `audiometrics` is purely sysfs reporting and would only matter if userspace tooling were being preserved.

## Boot-relevance reasoning

Score 2/10. The system already boots, reaches a login prompt, and runs a usable interactive shell on UART without any speaker or haptic driver loaded. None of these chips sit on the boot path; none of them gate the rootfs, the console, or the network. The only way an audio amp could break boot is via I2C/SPI bus contention or a probe deferral storm — neither is happening on our current build. Score reflects "unrelated to boot, post-boot peripheral" with a +1 for being a fairly straightforward port if/when audio is wanted later.
