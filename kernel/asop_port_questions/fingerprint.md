# fingerprint

- **AOSP path**: `private/google-modules/fingerprint/` (subdirs: `fpc/`, `goodix/fps_touch_handler/`, `qcom/qfs4008/`)
- **Mainline counterpart**: NONE — fingerprint sensor drivers for these specific parts are not upstream
- **Status**: not-ported
- **Boot-relevance score**: 1/10

## What it does

Three vendor-specific fingerprint stubs, all of which are deliberately thin "platform-glue"
drivers — they expose GPIOs, regulators, IRQs, and a chardev/sysfs surface to userspace,
but they explicitly do **not** talk SPI/I2C protocol to the sensor. The protocol is driven
from a TEE (Trusty/QSEE) blob on the AP side. Specifically:

- `fpc/fpc1020_platform_tee.c` — Fingerprint Cards 1020 platform shim. Comment says
  "This driver will NOT send any commands to the sensor it only controls the electrical
  parts." Manages reset/IRQ GPIOs and regulators; the actual matching happens in TEE.
- `goodix/fps_touch_handler/` — a small bridge between the Goodix optical/under-display
  fingerprint sensor and the Goog touch-interface driver (`GOOG_TOUCH_INTERFACE`), so the
  fingerprint area can mask out touchscreen input while finger-down. No sensor protocol.
- `qcom/qfs4008/` — Qualcomm's QSEE fingerprint platform shim (also "no protocol",
  TEE-driven). Not used on a Tensor-G2 device anyway.

## Mainline equivalent

None upstream for any of these specific parts. There's `drivers/input/keyboard/fpc-1020-keys.c`
(an ancient unrelated FPC keypad), no `fpc1020`, no Goodix fingerprint, no QSEE shim.
The TEE-driven model is structurally incompatible with mainline policy anyway: upstream
prefers an in-kernel SPI/I2C driver that exposes a libfprint-friendly chardev, not a
GPIO-only stub that delegates protocol to a binary TEE.

## Differences vs AOSP / what's missing

Everything. And porting the AOSP shim alone is useless — without the Trusty TEE driver
plus a matching Trusty TA + the Pixel HAL talking to it, the sensor stays dark. The
"working fingerprint on mainline" path would require a from-scratch in-kernel protocol
driver for the specific Pixel Fold sensor (which is a Goodix UDFPS part, IIRC), and I'm
not aware of one existing.

## Boot-relevance reasoning

Fingerprint is a lock-screen unlock peripheral. It has no role in kernel boot, rootfs
mount, or any rail used by UFS. Score 1 — purely a post-boot user-feature concern,
and not one this build aims to solve.
