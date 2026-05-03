# felix-device

- **AOSP path**: `private/devices/google/felix/` (display, touch, dts, build files)
- **Mainline counterpart**: [`arch/arm64/boot/dts/exynos/google/gs201-felix.dts`](kernel/source/arch/arm64/boot/dts/exynos/google/gs201-felix.dts) (felix dts only); no upstream display panel or touch drivers
- **Status**: partially-ported (only the boardfile; no peripheral drivers)
- **Boot-relevance score**: 6/10

## What it does

Felix is the codename for the Pixel Fold. This directory carries everything board-specific:

### `dts/` — Device-tree
36 dtsi/dts files including:
- `gs201-felix-mp.dts` (mass-production build target) → includes `gs201-felix-common.dtsi` → includes a sea of per-subsystem dtsis
- `gs201-felix-pmic.dtsi` — s2mpg12/13 PMIC instantiation, all rail definitions, slg51002 secondary
- `gs201-felix-display.dtsi` — dual-panel definitions (inner + outer)
- `gs201-felix-touch.dtsi` / `gs201-felix-outer-touch.dtsi` — dual touch controllers
- `gs201-felix-camera.dtsi` / `gs201-felix-camera-pmic.dtsi` — camera sensors + power
- `gs201-felix-battery.dtsi` / `gs201-felix-charging.dtsi` / `gs201-felix-wcharger.dtsi` — battery + charger + wireless charger
- `gs201-felix-aoc.dtsi` — Always-On Compute coprocessor
- `gs201-felix-thermal.dtsi`, `gs201-felix-fingerprint.dtsi`, `gs201-felix-uwb.dtsi`, `gs201-felix-nfc.dtsi`, `gs201-felix-hall-sensor.dtsi`, `gs201-felix-ldaf.dtsi`, `gs201-felix-usb.dtsi`, `gs201-felix-audio.dtsi`, etc.
- Plus a `gs201/` subdir with all the underlying SoC dtsis (ufs, sysmmu, pmic, mfc, drm-dpu, gpu, ...)

### `display/` — Two MIPI-DSI panel drivers
- `panel-samsung-ana6707-f10.c` — inner foldable panel
- `panel-samsung-ea8182-f10.c` — outer cover panel

Both depend on the AOSP DRM stack and a `panel-samsung-drv.h` framework in another repo.

### `touch/` — Two touchscreen drivers
- `ftm5/` — outer touch (ST FingerTip-FTM5)
- `fst2/` — inner touch (newer ST controller)

### `felix_defconfig`, `BUILD.bazel`, `build_felix.sh`, `Kconfig.ext.felix`, `insmod_cfg`, etc. — AOSP/Bazel build glue. Not relevant under mainline kbuild.

## Mainline equivalent

Mainline has only `gs201-felix.dts` (~93 lines, vs ~3000 lines if you sum the AOSP dtsi tree). It defines `compatible = "google,felix", "google,gs201"` plus a single fixed regulator. It is essentially a stub. No felix-specific peripheral drivers exist upstream: no panels, no touch, no charger, no fingerprint, no AOC firmware loader.

## Differences vs AOSP / what's missing

- **dts**: 95% missing. The mainline boardfile gives you bus enumeration via gs201.dtsi inheritance and that's it. Per-subsystem detail (PMIC rail mapping, panel timings, touch IRQ pin, charger I2C address, etc.) all has to be ported piecemeal as upstream subsystem drivers come online.
- **display panels**: not ported. Would need the `panel-samsung-drv` framework first, which isn't upstream either.
- **touch**: not ported. Mainline has plenty of ST touch drivers but neither FTM5 nor FST2 specifically.
- **build glue**: irrelevant under our pipeline.

## Boot-relevance reasoning

**Score 6**: the *boardfile* part of felix-device is what lets the kernel know it's a felix at all. Without `gs201-felix.dts` we couldn't pick the right DTB at boot. We have it — sparse but functional. Most of the missing dtsi data (display, touch, charger, camera) is post-boot peripheral wiring; without it the device boots to console (which we have) but you can't drive the screen or take input from touch. UFS is independent of felix-specific board data — UFS is wired in `gs201.dtsi`, not in any `felix-*.dtsi` (verified by greping the AOSP tree: only `gs201-sysreg-hsi2` reference appears, no felix-side UFS). So this doesn't affect HS gear bring-up. The score is moderate because expanding the boardfile is the gating step for everything past console (display, touch, audio, battery). For the user's stated focus (UFS), this directory is a 3.
