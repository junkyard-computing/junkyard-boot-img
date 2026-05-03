# display

- **AOSP path**: `private/google-modules/display/`
- **Mainline counterpart**: `drivers/gpu/drm/exynos/` (partial; legacy Exynos generations only)
- **Status**: not-ported
- **Boot-relevance score**: 2/10

## What it does

Google's out-of-tree DRM/KMS driver stack for the Exynos/gs SoC display pipeline. Three subdirectories: `samsung/` is the Samsung-derived `exynosdrm` driver (DECON CRTC, DPP planes, MIPI-DSI host, DisplayPort, write-back, hibernation, partial update, recovery, TUI, plus per-IP `cal_98xx` "common abstraction layer" register banks for 9820/9845/9855/9865); `common/` is Google's `gs_drm` + `gs_panel` framework that sits on top and provides the multi-panel/foldable plumbing, panel test harness, and the connector glue used by HWC; `panels/caimito/` and `panels/tegu/` are the per-product panel drivers (s6e3hc4-style command-mode AMOLED, etc.). felix's foldable inner+cover panels are wired through this stack. Together this is what drives the on-device LCD; without it, only serial console / kmscon-on-tty works.

## Mainline equivalent

`drivers/gpu/drm/exynos/` exists but only covers Exynos 4/5/7 era IP (decon5433, decon7, FIMD, FIMC, MIC, HDMI/mixer, G2D, GSC, rotator). There is no DECON driver for gs101/gs201/zuma in mainline, no `cal_9865`-style register layer, no DSI host that knows about the gs MIPI-DSIM v2, and no panel driver for the felix foldable inner display. `drivers/gpu/drm/panel/` has `panel-samsung-s6e3fc3.c` and `panel-samsung-s6e3ha8.c` but nothing matching felix's specific panel(s).

## Differences vs AOSP / what's missing

Effectively everything: DECON for gs201, DPP for gs201, MIPI-DSIM register set for gs201, write-back, partial-update, the gs_panel framework, and the felix-specific panel drivers. Google's stack also carries Pixel-specific bits (HBM, AOD, LHBM, multi-refresh-rate switching, TUI handoff) that don't exist anywhere upstream. A clean port is a multi-month subsystem-level effort, not a driver port.

## Boot-relevance reasoning

The kernel boots, mounts root, and runs systemd/kmscon entirely over the serial UART today; the panel is dark and the user has explicitly accepted that. Display has zero impact on the active boot blockers (UFS HS-gear wedge, AOC firmware loading). Score is 2 rather than 1 only because in the long run a real display would be nice to have; in the short run it is pure post-boot peripheral work and competes for attention with UFS.
