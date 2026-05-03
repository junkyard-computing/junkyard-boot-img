# video

- **AOSP path**: `private/google-modules/soc/gs/drivers/video/backlight/`
- **Mainline counterpart**: **NONE** for RT4539; generic backlight subsystem exists
- **Status**: not-ported
- **Boot-relevance score**: 3/10

## What it does

Single driver: `rt4539_bl.c` — Richtek RT4539 backlight LED driver. Speaks I2C; controls the gs201 device's display backlight brightness (PWM duty + LED current). Registers as a `BACKLIGHT_CLASS_DEVICE` so userspace can write /sys/class/backlight/*/brightness.

## Mainline equivalent

Mainline `drivers/video/backlight/` has many similar Richtek drivers (`rt4831-backlight.c` etc.) but **no rt4539 driver**.

## Differences vs AOSP / what's missing

The whole driver. Without it the panel backlight cannot be programmed via Linux — it sits at whatever the bootloader left it at. On felix today **kmscon comes up because the bootloader leaves the panel + backlight on at handoff** (we see the kmscon framebuffer rendered into the bootloader-prepared simpledrm region with the bootloader-set backlight level).

## Boot-relevance reasoning

3/10. Boot succeeds without it because the bootloader's panel/backlight state persists. If the kernel panic-reboots and the bootloader's panel init changes, we could lose the screen. Real risk is suspend/resume — without backlight control the panel can't be dimmed/turned off cleanly. Score 3 because no immediate blocker but the panel is visibly working only "by accident" of bootloader state.

