# Build a power harness — externally power the phone so bring-up isn't gated on the battery

## Purpose / context

The single biggest tempo-killer in felix bring-up: the test phone **can't charge over UART**
(USB-C is busy with the UART/console), has **no battery readout on mainline** (no fuel-gauge
driver up), and **OTG mode makes it worse** — when the phone sources VBUS to a hub it actively
*drains* the battery. This session the device went flat mid-iteration, partly because OTG was
left on. Iteration shouldn't be gated on a battery you can't see or refill.

Build a harness that **powers the phone externally and manages charge/telemetry automatically**,
so a multi-hour bring-up loop never goes dark. This is a hardware+software tool; the spec covers
the software control plane and the hardware it assumes.

## Hardware it drives (pick one, make the software backend-agnostic)
- A **programmable bench PSU** (SCPI/USB/serial) feeding the phone's charge path or battery
  terminals — toggleable, with voltage/current set + readback. (Cleanest: powers the phone
  independent of USB-C so UART/OTG stay free.)
- or a **smart AC plug** (Tasmota/Shelly — already used by benchctl) driving a normal charger
  into a charge path that doesn't conflict with the UART rig.
- or `uhubctl`-style port power for a charge port.
Define a small `PowerSource` interface (`on/off`, `set_voltage/current`, `read_v/i`) so any of
these drops in.

## Battery telemetry (read it however you can, this session proved it's hard)
- In **fastboot**: `fastboot getvar battery-voltage` (mV) → a Li-ion voltage→% curve.
- On **AOSP**: the fuel gauge over SSH (`/sys/class/power_supply/...`).
- On **mainline**: via `felixprobe psy` if a fuel-gauge driver is up, else fall back to the PSU's
  own current/voltage readback (if externally powered) or "unknown".
Expose a single `battery()` that returns `{volts, pct, source}` with the best available reading.

## Control policy (the point)
- **Auto-charge/pause loop:** when battery < `floor`, pause the bring-up loop, switch the device
  into a charging state (or just hold external power), wait until > `target`, resume. Integrate
  with benchctl's battery/reboot budget hooks (already drafted).
- **OTG-aware:** treat OTG-on as a high-drain state — time-box OTG enumeration tests and ensure
  the harness can recharge between bursts; warn if OTG is left on idle.
- **Keep-alive:** between test bursts, hold the phone in a charging/idle state (fastboot charges)
  so it tops up instead of draining.
- **Hard floor / refuse:** never start an iteration the budget says can't finish before the floor.

## Integration
- A backend behind benchctl's `power` + `battery` config (so `power.backend = "psu"` /
  `"tasmota"` / `"none"` all work), and usable standalone (`power on|off|status|charge-to 80`).
- Coexists with uartd/uartfs (UART stays the console; the harness only touches power).

## Success criteria
A bring-up session like this one runs for hours — many flash/reboot/OTG cycles — and the device
**never goes flat**: the harness keeps it charged, time-boxes OTG drain, and auto-pauses to
recharge when needed, all without a human babysitting the battery. Battery state is always
queryable from whatever mode the device is in.

## Non-goals
- Not a substitute for a proper mainline fuel-gauge driver (that's separate bring-up); this works
  around its absence.
- Doesn't need closed-loop precision — "keep it above X%, recharge to Y%" is enough.
- The USB-traffic side (analyzer) is out of scope — this is purely power/charge/telemetry.
