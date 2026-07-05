# Build: `benchctl` — host orchestrator for autonomous kernel iteration on a Pixel (felix/gs201)

## Role
Host-side controller that flashes an experimental kernel to a felix phone, boots it,
captures the result over UART, and **guarantees return to a known-good slot** —
unattended. It drives existing on-device tools over SSH; it does NOT reimplement
flashing or slot logic.

## On-device primitives it calls over SSH (install if missing — see flash-ssh.sh)
- `pixel-bootctl status | set-active-slot <a|b> | mark-successful` — A/B slot primitive
  (UFS boot-LUN + devinfo).
- `pixel-ota update <dir> [--no-switch] [--slot a|b] [--dry-run]` — flashes the
  **inactive** slot's boot chain from a dir of `*.img`, refuses the active slot,
  switches **rollback-safe (active, NOT successful)**. `pixel-ota confirm` commits.
- `uart read|send|wait|log` (companion daemon) — the only channel during the experiment.

See `existing-tools-contract.md` for the full contract.

## Setup assumed
- A/B slots; `super` (rootfs) is **single/shared, NOT slotted** — never written per iteration.
- **Slot A = home base:** stock image, networks via USB dongle, SSH-reachable, marked
  successful. Push transport + recovery anchor.
- **Experiment slot:** test kernel; **never marked successful** (that arms rollback).
- **Experiment has no network** (USB is under test) → output is UART only → on failure the
  retry counter exhausts and the bootloader rolls back to home base.
- **No fastboot** (broken through the bench hub). All flashing from the booted home base over
  SSH; recovery is rollback or a **network power switch** (power-cycle → bootloader picks the
  marked-good slot).

## Iteration — `benchctl iterate <boot.img> <vendor_boot.img> <dtbo.img>`
1. **Verify home base:** SSH up, on slot A, A successful, power backend reachable. Else refuse.
2. **Stage + switch:** scp images → `pixel-ota update <dir>` (boot chain → inactive slot,
   rollback-safe switch). No reboot yet.
3. **Assert-not-successful:** `pixel-bootctl status` → confirm experiment slot is active but
   **NOT successful**. Abort if successful (rollback would be defeated).
4. **Reboot**, capture the boot via `uart` over the window, classify by success/fail regex.
5. **Recover:** wait for SSH home base to return (rollback). If not within timeout →
   `power cycle` → wait again. Re-verify home base.
6. Return: outcome (rolled-back / wedged-recovered / unrecoverable), UART capture, timings.

## CLI
`status`, `stage <imgs>`, `boot-experiment [--success-regex R --fail-regex R --timeout S]`,
`iterate <imgs>`, `recover`, `power {off|on|cycle}`. Global `--json`. Everything timed; never hangs.

## Safety invariants (enforce in code)
- Home base slot stays successful; never cleared. benchctl never `confirm`s the experiment slot.
- Post-stage, pre-reboot: assert experiment slot active-but-not-successful (step 3).
- Never write `super` without `--include-rootfs` (then loud warning; that path is
  `pixel-ota flash-rootfs`, destructive/rollback-free/flaky on felix — avoid).
- Before any device-losing reboot: home base bootable + power backend reachable, else refuse.

## Backends (pluggable)
- Power: interface `off/on/cycle`; ship Tasmota/Shelly HTTP + `uhubctl` drivers.
- Flash: prefer pixel-ota/pixel-bootctl; raw `dd` + boot-LUN only as fallback if absent.

## Config
SSH host/user/key, slot/partition names, power backend type+addr, `uart` invocation, timeouts.
File + flag/env overrides.

## Tech & packaging
Python 3, minimal deps, robust over clever (runs unattended under a rebooting device).
NixOS host → `flake.nix` (runnable pkg + dev shell) appreciated; `pyproject.toml` ok.

## Acceptance (simulation mode — mock device/power/uart, no hardware)
1. fail-then-rollback: stages, asserts not-successful, boots, captures console, sees rollback,
   confirms home base, returns `rolled-back`.
2. wedge: no rollback in timeout → exactly one power-cycle → home base returns → `wedged-recovered`.
3. Refuses `boot-experiment` if home base unhealthy or power backend unreachable.
4. Aborts if post-stage the experiment slot reads successful.
5. Never writes `super` without `--include-rootfs`; home-base success flag untouched; all
   waits honor timeouts.

## Prior art to read first
`flash-ssh.sh` in the junkyard-boot-img repo: one-shot full deploy over SSH via pixel-ota
(boot chain + destructive rootfs reflash, no recovery loop). `benchctl` is the iterate-safe
successor: reuse its pixel-ota/pixel-bootctl invocations + preflight; drop the rootfs reflash;
add rollback-wait + UART capture + power backstop.

## Deliverables
`benchctl` + README + config sample + backend examples + flake/pyproject + simulation suite.
