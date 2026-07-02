# Build `hwdiff` — differential hardware-state RE (copy AOSP's answers)

## Purpose / context

For felix bring-up we have a **working reference** (the stock AOSP image, which fully drives the
USB-C, PMIC, OTG, etc.) and a **broken target** (mainline) on the *same silicon*. The most
powerful bring-up technique is therefore **differential**: capture the hardware state AOSP sets
up, capture mainline's, and diff — the difference *is* the to-do list. This session I derived
the OTG register, the in-switch GPIO, the i2c clock parent, and (next) the TCPC role/orientation
by hand from datasheets — when AOSP already programs all of them correctly. `hwdiff` makes the
machine answer "what does AOSP do that I don't."

Builds on `felixprobe` (it's the capture engine) + `uartd`/`uartfs` (transport).

## Modes

### 1. Snapshot
Capture *everything* into one structured, register-map-decoded file:
- every reachable i2c device's full register space (MAX77759 @0x25/0x36/0x66/0x69, …),
- all GPIO states (every gpiochip/line, with labels),
- `clk_summary` (rates/parents/enables),
- the dwc3 / USB DRD PHY / CMU MMIO blocks (named regions, via felixprobe mmio),
- xhci PORTSC, regulators, power-supply.
Run it on **AOSP** and on **mainline** (over their respective consoles — AOSP has SSH+UART,
mainline UART-only).

### 2. Diff
Register-map-aware structured diff of two snapshots — show **decoded field-level** deltas, not
byte noise:
`TCPC.ROLE_CONTROL: AOSP=0x0a {Rp, DRP=0, host} vs mainline=0x00 {open}` ,
`MAX77759.CHG_CNFG_00.MODE: AOSP=OTG_BOOST_ON vs mainline=OFF`,
`clk mout_peric1_usi13_usi_user: AOSP=400MHz vs mainline=0`.
Filterable by subsystem (usb / pmic / clk / gpio). Ignore-lists for known-volatile regs.

### 3. Trace (the "busgrab" idea — capture the *sequence*, not just the end state)
Capture the ordered activity AOSP performs **during an event** (USB-C attach, OTG enable, dongle
plug): via kernel tracepoints (`i2c`, `regmap`, `gpio`, `dwc3`) on the AOSP device, or
high-rate snapshot-on-change. Output: "on plug, AOSP did: write TCPC 0x19=0x0a; set gpioX=1;
write CHG_CNFG_00=0x0a; …" — the sequence-dependent recipe a static snapshot can't show.

### 4. Replay
Emit a diff or trace **as `felixprobe` commands / an experiment.toml**, so the AOSP-derived
setup can be applied to mainline directly and re-checked.

### 5. Live / shadow (the two-device-rig idea)
With both phones connected at once, treat AOSP as a **live oracle**: `hwdiff oracle "what do you
do when I plug the dongle"` snapshots/traces AOSP on demand while you iterate mainline.

## Success criteria
The host-mode USB-C answers that took most of a session to reverse-engineer fall out of a single
`hwdiff diff aosp.snap mainline.snap --subsystem usb,pmic`: it directly shows the TCPC role,
orientation, in-switch GPIO, and OTG mode AOSP sets and mainline doesn't — and `hwdiff replay`
hands back the felixprobe sequence to apply.

## Non-goals
- Not a substitute for understanding — it surfaces deltas; a human still decides which matter.
- Doesn't bridge the AOSP-vs-mainline *representation* gap for clocks/DT (that's `dtdiff`); for
  registers/GPIO/MMIO the hardware addresses are identical so the diff is direct.
- Capture breadth is best-effort over a lossy UART on the mainline side — prioritize the
  subsystem under bring-up.
