# sensors

- **AOSP path**: `private/google-modules/sensors/` (only one driver: `hall_sensor/`)
- **Mainline counterpart**: NONE for this specific driver, but `drivers/input/misc/gpio_keys.c` covers the same use case for free
- **Status**: not-ported (and arguably no port needed)
- **Boot-relevance score**: 1/10

## What it does

Despite the directory name suggesting a forest of IMU/ALS/magnetometer drivers, the only
thing under `sensors/` is `hall_sensor.c` — a 200-LOC platform driver that reads a single
GPIO (the lid Hall-effect sensor for the Fold's hinge), debounces it, and emits an
`EV_SW`/`SW_LID` evdev event on transitions. That's it. No IMU, no ALS, no mag, no
proximity, no actual sensor-hub plumbing. The other AOSP sensor stacks live under
`amplifiers/` (audio amps, also out of scope) or as platform-specific blobs the Pixel
chrooted hardware composer talks to in userspace.

## Mainline equivalent

There is no upstream `google,hall-sensor` driver. Mainline already handles this exact
use case via `gpio_keys` configured with `linux,input-type = <EV_SW>` and
`linux,code = <SW_LID>` — that's how laptops, Chromebooks, and other foldables expose
lid switches today. So the "port" is a 10-line DT change, not a driver port.

## Differences vs AOSP / what's missing

The AOSP module adds a sysctl knob to enable/disable IRQ wake from the Hall sensor and
manages its own input device. Mainline's `gpio_keys` does both via the standard
`wakeup-source` and `gpio-key` properties.

## Boot-relevance reasoning

A lid switch has zero impact on whether the kernel boots, mounts root, or brings up UFS.
The only Fold-specific behavior that depends on it is logind's lid-switch handling,
which the rootfs overlay already neuters via `etc/systemd/logind.conf.d/10-ignore-lid.conf`.
Score 1 — completely unrelated to current boot issues.
