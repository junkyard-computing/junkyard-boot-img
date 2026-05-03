# hdcp

- **AOSP path**: `private/google-modules/hdcp/samsung/`
- **Mainline counterpart**: `drivers/gpu/drm/display/drm_hdcp_helper.c` + per-driver integration (e.g. i915, amdgpu); HDCP2 PSP/TEE bits live under each driver tree
- **Status**: not-ported
- **Boot-relevance score**: 1/10

## What it does

Samsung/Exynos HDCP 1.3 + HDCP 2.2 authentication driver, primarily for the DisplayPort path (audio + video over DP/USB-C). Implements the cryptographic exchanges (`auth13.c` for HDCP 1.x; `auth22.c`, `auth22-ake.c`, `auth22-lc.c`, `auth22-ske.c`, `auth22-stream.c`, `auth22-repeater.c` for HDCP 2.2), state-machine and control plane (`auth-control.c`, `auth-state.c`), DPCD register access (`dpcd.c`), and a TEE bridge (`teeif.c`) that talks to the TrustZone HDCP TA for the secret-bearing operations. Userspace ioctl surface via miscdevice (`main.c`). Selected via `EXYNOS_HDCP2`; sub-options for DP, errata, function-test, and emulation modes.

## Mainline equivalent

Mainline HDCP support lives as helpers in `drivers/gpu/drm/display/` (HDCP helper for DRM-content-protection property handling, plus DP HDCP helper) and is wired in per-driver — no Exynos integration exists because there's no gs201 DECON/DP driver upstream to wire it into.

## Differences vs AOSP / what's missing

The Samsung driver is custom, talks to a Samsung-specific TZ TA, and predates the modern DRM HDCP property model. To use it upstream you'd first need a working DECON+DP driver upstream and then either rewrite this on top of `drm_hdcp_*` helpers or carry it as-is.

## Boot-relevance reasoning

HDCP is content-protection for protected video output. We have no display driver and no DP output, and even if we did, HDCP failure would just block protected playback — it never blocks boot. Score is 1.
