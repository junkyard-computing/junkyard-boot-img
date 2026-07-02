# Build `felixprobe` — a unified, register-map-aware on-device probe tool

## Purpose / context

Bringing up mainline Linux on a Pixel Fold (felix / gs201) means constant low-level poking of
the device: i2c registers (MAX77759 PMIC/charger/TCPC), GPIOs, SoC MMIO (CMU/PHY), clocks, USB
port state. Today each poke means **cross-compiling a one-off C program** (`otg.c`, `maxq.c`,
`i2cd.c`), patchelf'ing its interpreter to Debian's, and pushing it over UART — for *every*
register. That's absurd overhead, and the values come back as raw bytes that have to be decoded
against datasheets by hand.

Build **one static aarch64 binary** (`felixprobe`), pushed to the device once, that does all of
it — and decodes/encodes registers by **name** from bundled register maps.

## Build / runtime constraints
- **Static aarch64-musl** (`pkgsStatic` / musl), so it runs on the Debian rootfs with no
  interpreter or glibc-version issues (avoids the `patchelf --set-interpreter` dance entirely).
- Pushed once via `uartfs push`; driven via `uart run` / `uartfs run`. Small, single binary,
  no runtime deps.
- Read-only by default; writes require `--write` (and dangerous ones a `--force`), and every
  write is logged (old→new) to stderr.

## Capabilities (subcommands)
- `i2c read|write|dump|detect <bus> <addr> [reg] [val] [count]` — combined-xfer reads (proper
  repeated-start), block dumps, a real address scan.
- `gpio get|set <chip|name> <line> [val]`, `gpio list` — any gpiochip/line, resolve by label.
- `mmio peek|poke <phys-addr> [val] [--w 8|16|32|64]` — /dev/mem with width; named SoC regions.
- `regmap read|write|dump <name> <reg> [val]` — via debugfs `regmap/` when a driver exposes it.
- `clk dump|get|set <name> [rate]` — parse `clk_summary`, show parent/rate/enable, set rate/parent.
- `usb ports` — decode every xhci PORTSC (CCS/PED/PLS/PP/speed) into words, per root hub.
- `maxq <opcode> [bytes…]` — the MAX77759 **MAXQ mailbox** as a first-class verb (write
  AP_DATAOUT, trigger, poll APCMDRESI, read AP_DATAIN) so GPIO/UIC commands are one-liners.
- `psy` — power-supply / fuel-gauge readout if present.

## Register-map awareness (the differentiator)
- Bundle per-chip register maps (a simple TOML/JSON: reg name→offset, field name→bit-range,
  enum value→name). Ship maps for **MAX77759** (charger/maxq/pmic), **TCPCI** (the 0x25 TCPC),
  **dwc3**, and the **gs201 CMU/PHY MMIO** blocks.
- Generate the maps mostly automatically from the kernel headers (`include/linux/mfd/max77759.h`
  etc.) and standard specs, with a small hand-curated overlay.
- With a map, reads print decoded: `CHG_CNFG_00 = 0x0a {MODE=OTG_BOOST_ON}` instead of `0x0a`,
  and writes take names: `felixprobe i2c write chg CHG_CNFG_00.MODE=OTG_BOOST_ON`. This turns
  datasheet-by-hand into self-documenting one-liners.

## Experiment/scripting mode (folds in the "register-experiment, no reflash" idea)
- `felixprobe run <experiment.toml>` — a declarative bring-up experiment: a list of steps
  (set reg/gpio/clk, sleep, read+assert, capture), run in one invocation, printing a pass/fail
  + the captured values. So a hypothesis ("set TCPC role=host + orientation, then read PORTSC")
  is one file, no kernel rebuild, seconds per iteration. Steps are the same primitives as above.

## Success criteria
Everything I did by hand this session becomes a felixprobe one-liner with no compilation:
- `felixprobe i2c write chg CHG_CNFG_00.MODE=OTG_BOOST_ON` (the OTG boost)
- `felixprobe maxq GPIO_CONTROL_WRITE …` (the in-switch GPIO5)
- `felixprobe i2c dump tcpc 0x00 0x21` decoded (the TCPC state)
- `felixprobe usb ports` (PORTSC decoded)
…and a bring-up experiment runs from a single TOML over the uartfs loop.

## Non-goals
- Not a flashing/file-transfer tool (that's uartfs).
- Not a daemon — a one-shot CLI invoked per call.
- Maps don't need to be exhaustive; cover the felix bring-up chips first, extend as needed.
