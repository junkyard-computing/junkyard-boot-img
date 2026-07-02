# benchctl updates — adapt to the real felix mainline bring-up loop

This is a change spec for the existing `benchctl` orchestrator (SSHDevice + bootctl/ota +
orchestrator `stage`/`boot_experiment`/`recover`/`iterate` + power backend + uart companion +
TOML config). A full bring-up session surfaced several places where benchctl's model doesn't
match reality. Apply these without breaking the existing safety invariants (home base never
clobbered; experiment slot always rollback-safe / never auto-marked-successful).

## What we learned (the deltas from benchctl's current assumptions)

1. **The experiment slot has NO network.** benchctl assumes both slots are SSH-reachable (home
   base = stock SSH image; experiment = other slot). On felix the experiment slot runs the
   *mainline* kernel, which has **no working networking** — it's reachable **only over UART**.
   SSH/pixel-bootctl/pixel-ota do **not** work there.

2. **Flashing the experiment slot is done from the home base, OR over UART.** The home base
   (AOSP) has SSH + the pixel UFS sysfs, so it can `pixel-ota`-flash the *other* slot (existing
   model — keep it). But there's now a second path: a **UART delta-flash tool (`uartfs`)** that
   reflashes `boot_a`/`vendor_boot_a` **in place from the running experiment slot** via `dd`,
   no network and no slot round-trip. See `uart-flash-tool.md`.

3. **You cannot switch slots from the experiment (mainline) side.** `pixel-bootctl set-active-slot`
   fails on mainline ("boot_lun_enabled not found under …/pixel/") — the AOSP UFS pixel sysfs
   doesn't exist. So **A→B (back to home base) is only achievable by exhausting the experiment
   slot's boot-retry counter** (≈6 reboots → bootloader auto-rolls back), or via fastboot
   `--set-active`. Also `mark-slot-successful` fails on mainline (no `androidboot.slot_suffix`),
   so the experiment slot never self-commits — good for rollback-safety, but means "boot N times
   → rollback" is the recovery primitive, not a single rollback or a power cycle.

4. **There is no power backend.** This is a **battery-only** device that **cannot be charged
   while rigged for UART**, and the mainline kernel exposes **no battery readout** (no fuel-gauge
   driver). benchctl's recover path currently leans on a power relay; here there is none.

5. **Fastboot exists but is mutually exclusive with UART** (shared USB-C port). It's the cleanest
   flash/slot/recovery path (`fastboot flash <part>_a`, `--set-active=a`, `getvar battery-voltage`,
   `erase`, `reboot`) but **requires a human cable swap**, so it can't be used autonomously
   interleaved with UART.

## Required changes

### A. Transport abstraction: add UART + fastboot device backends
- Generalize the `Device` interface so the home base (SSHDevice) and the **experiment slot
  (UartDevice)** are both first-class. `UartDevice` talks via the `uart` CLI / uartd socket:
  `run(cmd) -> (stdout, rc)` (framed/verified — reuse the `uartfs run` primitive), plus
  `read_console`/`wait(regex)` for boot classification.
- Add a `FastbootDevice` backend: `flash`, `erase`, `set_active`, `getvar`, `reboot`. Mark it
  **interactive-by-default** (prompt/pause for the operator to swap UART↔fastboot, or gate behind
  an explicit `--fastboot` flag / `allow_cable_swap=true`). Never assume it coexists with UART.

### B. Flash backends: pixel-ota (from home base) **and** uartfs (in place)
- Keep the existing `stage(images)` → pixel-ota-on-home-base → reboot-to-experiment flow.
- Add a `uartfs` flash backend: from the **running experiment slot**, delta-flash
  `boot_a`/`vendor_boot_a` over UART (`uartfs flash <img> <partlabel>`, which diffs against the
  live partition, verifies sha256, `dd`s, read-back-verifies). This is the **preferred iterate
  path** because it skips the home-base round-trip *and* the slot dance entirely:
  `experiment up → uartfs flash → reboot → still experiment`.
- A `iterate` mode that uses uartfs should loop **without ever returning to the home base**.

### C. Slot mechanics: model the felix A/B reality
- Encode that `set-active-slot`/LUN-flip is **home-base-only** (works on AOSP, fails on mainline).
- `recover()` to home base from a failed/expended experiment must support the
  **retry-exhaustion path**: reboot the experiment slot up to N times (config `rollback_reboots`,
  default ~7) until the bootloader rolls back, detecting home base via UART boot signature — not
  via a power cycle. Keep the existing rollback/power paths as alternatives, but make them optional.
- Surface `slot-retry-count` (via fastboot when available) so the loop knows how many experiment
  boots remain before an involuntary rollback.

### D. Make the power backend optional; add a battery-budget model
- `power` backend becomes **optional** (`backend = "none"`). When absent, `recover()` must not
  require it.
- Add battery awareness: read voltage via `fastboot getvar battery-voltage` when in fastboot,
  map to an approximate % (single-cell Li-ion curve; subtract charge offset). Expose a
  **reboot budget**: each A→B dance is ~6 reboots and there's no charging on UART — benchctl
  should **count reboots, warn below a configurable battery floor, and refuse to start an
  iteration that can't safely complete** (the device went flat mid-session once doing ~30 reboots).
- Treat fastboot as the only place to both read battery *and* charge (the device charges in
  fastboot), so "park in fastboot to charge" is a supported state.

### E. Classification: UART-first
- Boot success/fail classification should be drivable purely from **UART log patterns** (the
  experiment slot has no SSH). Keep the SSH-probe classifier for the home base. Provide felix
  defaults: success = reached `multi-user.target`/login banner; fail = `Kernel panic` /
  `No working init` / `Ramdisk copy error` / APC watchdog / `failed to boot android`.

### F. Config additions (TOML)
- `[experiment] transport = "uart" | "ssh"`, `[flash] backend = "uartfs" | "pixel-ota" | "fastboot"`.
- `[power] backend = "none"` allowed; `[battery] floor_voltage`, `reboot_budget`.
- `[slots] rollback_via = "retry-exhaustion" | "power" | "fastboot"`, `rollback_reboots = 7`.
- `[uart] socket`, plus the `uartfs` invocation.

## Keep / don't break
- Home base is sacred: never flash the home-base slot; never auto-mark the experiment successful.
- All existing refusal invariants (won't run on an unhealthy home base, etc.) stay.
- Everything scriptable / non-interactive except the explicitly-gated fastboot cable-swap step.

## Success criterion
benchctl can run an autonomous iterate loop on felix: experiment slot up on UART →
`uartfs` delta-flash a new kernel/dtb → reboot → classify via UART → repeat — with **no SSH on
the experiment slot, no power backend, no fastboot, and no cable swaps**, while tracking the
reboot/battery budget and falling back to retry-exhaustion rollback (or a prompted fastboot
recovery) only when needed.
