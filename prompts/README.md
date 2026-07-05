# prompts/

Build prompts and contracts for the **autonomous kernel-iteration substrate** — the
tooling that lets an AI agent flash, boot, observe, and recover a felix (Pixel Fold,
gs201) device on a bench **without a human touching it**, so mainline kernel bring-up
can iterate hands-free.

## The problem these solve

An AI agent works in discrete tool-call turns; it can't hold a serial port open or watch
a real-time stream between turns. And during a mainline experiment the phone has **no
network** (USB is exactly what's under development) — its only output is the UART console,
and on failure it must return itself to a known-good state. So we need:

1. A way to turn the live UART stream into a **poll-able request/response resource**.
2. A host-side loop that **flashes an experiment, boots it, captures UART, and guarantees
   return to a working slot** — using rollback or a power-cycle, never fastboot.

## The two loops

- **Inner loop** — drive the experiment kernel live over the UART shell (`devmem` register
  pokes, sysfs, module reloads, re-running tests). Many experiments per boot, no reflash.
  This is what USB Phase A bring-up actually is.
- **Outer loop** — reflash a new kernel/DT (the only changes that must be compiled in),
  pushed over the network in the working slot, relying on auto-rollback to come back.

## Files

| file | what | status |
|---|---|---|
| [`uartd.md`](uartd.md) | Build prompt: buffered UART console daemon + CLI for AI-driven serial control (the inner-loop transport + capture). | new tool |
| [`benchctl.md`](benchctl.md) | Build prompt: host orchestrator for flash → boot → UART-capture → recover (the outer loop). | new tool |
| [`existing-tools-contract.md`](existing-tools-contract.md) | Contract for `pixel-bootctl` / `pixel-ota` — the on-device slot/flash primitives benchctl drives. **Already built — consume, don't rebuild.** | reference |

## How it sits on what already exists

- `pixel-bootctl` (repo) = A/B slot switch primitive (UFS boot-LUN + devinfo). Keyless.
- `pixel-ota` (repo) = update_engine analog: flash inactive slot's boot chain, rollback-safe switch.
- `flash-ssh.sh` (this repo) = one-shot full-image deploy over SSH (boot chain + destructive
  rootfs reflash, no recovery loop). **`benchctl` is its iterate-safe successor**: reuse its
  pixel-ota/pixel-bootctl calls + preflight, drop the rootfs reflash (shared `super` stays put),
  add rollback-wait + UART capture + power backstop.
- `capture-uart.sh` (this repo) = the human-facing UART capture; `uartd` is the agent-facing
  version (persistent daemon + drain buffer + expect/wait).

## Hardware constraints baked into these (the non-obvious ones)

- **`super` (rootfs) is single/shared, not A/B.** Only `boot`/`vendor_boot`/`dtbo` are slotted.
  Per-iteration we flash boot-chain only; the experiment kernel must boot on the shared rootfs.
- **No fastboot in the loop** — it doesn't work through the bench USB hub. Flash from the booted
  home base over SSH; recover via A/B rollback or a network power switch.
- **UART rides USB-C "Debug Accessory Mode" (CC pins).** It coexists with USB only via a hub
  (PD mediation) or when the phone is the USB host (dongle). Device-mode USB drops UART in the
  bootloader. UART can't transport images (~11 KB/s) — it's console/control only.

## Biggest unvalidated assumption

That felix reliably **auto-rolls-back to a marked-good slot** (vs. dropping to fastboot) when the
experiment slot's retry budget exhausts. The power-cycle backstop covers the failure, but test
the rollback behavior deliberately on hardware early (flash a knowingly-bad boot to the inactive
slot, watch what the bootloader does). Also verify the experiment slot ends up
**active-but-not-successful** after `pixel-ota update` — rollback depends on it.
