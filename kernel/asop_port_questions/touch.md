# touch

- **AOSP path**: `private/google-modules/touch/` (subdirs: `common/`, `goodix/`, `focaltech/`, `fts/`, `novatek/`, `sec/`, `synaptics/`)
- **Mainline counterpart**: `drivers/input/touchscreen/goodix_berlin_{core,i2c,spi}.c` for the silicon felix actually uses
- **Status**: partially-ported (silicon driver upstream; Google glue out-of-tree)
- **Boot-relevance score**: 2/10

## What it does

A vendor-driver collection plus a Google "common" layer that wraps them all. The common
pieces are:

- `common/goog_touch_interface.{c,h}` (`GOOG_TOUCH_INTERFACE`) — a unifying API the vendor
  drivers register against. Provides power management, panel-suspend coordination, gesture
  arbitration, palm-rejection hooks, fingerprint-area exclusion (talks to the fingerprint
  module), and a heatmap chardev.
- `common/touch_bus_negotiator.{c,h}` (`TOUCHSCREEN_TBN`) — coordinates SPI/I2C bus
  ownership between the AP and the AOC sensor DSP, so AOC can keep doing low-power gesture
  detection while the AP is suspended.
- `common/touch_offload.{c,h}` (`TOUCHSCREEN_OFFLOAD`) — exports raw touch frames to
  userspace for an off-tree algorithm chain.
- `common/heatmap.{c,h}` — videobuf2-vmalloc heatmap export.

The vendor drivers (`goodix/goodix_brl_*`, `sec/sec_ts*`, etc.) are full silicon drivers
for Goodix Berlin, Samsung S6SY761, FTS, Novatek, Synaptics — felix specifically ships a
Goodix Berlin part wired via SPI.

## Mainline equivalent

Goodix Berlin has been upstream since ~6.6 in `drivers/input/touchscreen/goodix_berlin_core.c`
plus `goodix_berlin_i2c.c`/`goodix_berlin_spi.c`. The S6SY761 is at `drivers/input/touchscreen/sec_ts.c`.
What's *not* upstream is anything in `common/` — no GOOG_TOUCH_INTERFACE, no TBN, no
touch_offload, no heatmap. Mainline drivers register a normal evdev input device and stop.

## Differences vs AOSP / what's missing

The mainline Goodix Berlin driver covers the chip protocol but nothing else. Missing
relative to AOSP: the heatmap export, the AOC bus-negotiation handshake (so low-power
gesture wake-from-suspend won't work), the Google touch-interface unification layer, and
the offload chardev. For a basic functional touchscreen — finger reports an event, evdev
sees it — the upstream driver is enough; the felix DT just needs a `goodix-berlin-spi`
child node on the right SPI controller with the right reset/IRQ GPIOs.

## Boot-relevance reasoning

Touch is a userspace input peripheral, totally absent from the boot path. Doesn't touch
UFS, doesn't touch any shared regulator or clock that UFS depends on. Score 2 (instead
of 1) only because a working touchscreen will eventually matter for using the device
as a real device, but it has zero bearing on the current UFS-HS bring-up problem.
