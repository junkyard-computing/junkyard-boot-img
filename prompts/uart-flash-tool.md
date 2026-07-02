# Build a UART delta-flash tool (`uartfs`) — phone-side agent + technician-side CLI

## Purpose / context

We're bringing up a mainline Linux kernel on a Pixel Fold (felix / gs201). The device
runs Debian on the `super` partition and we iterate on the kernel by reflashing the
`boot_a` / `vendor_boot_a` partitions.

The hard constraint: **on the mainline kernel there is no working networking yet** — the
serial **UART console is the only reliable persistent channel** to the booted device.
Fastboot exists but **shares the USB-C port with UART, so it's mutually exclusive** —
using fastboot requires a human to physically swap the cable every iteration. We want to
avoid that and iterate autonomously.

Key enabling facts:
- The device boots with a **writable rootfs**, and the boot partitions are ordinary block
  devices (`/dev/disk/by-partlabel/boot_a`, `vendor_boot_a`, …). So we can reflash with
  `dd` **from the running system — fastboot is not actually required**, we just need to get
  the new bytes onto the device.
- **The payloads are mostly deltas.** `vendor_boot_a` is ~34 MB but ~99% identical between
  iterations (the dracut initramfs never changes); only the ~150 KB **dtb** changes, and
  between tweaks only a few nodes move. Kernel changes can usually be shipped as small
  `.ko` modules rather than a whole new Image. So per-iteration we need to move **KB, not MB**.

The problem this tool solves: **the UART has no flow control and drops characters on any
sizable transfer, and the same line also carries the interactive console + kernel printk.**
We need a reliable, compressed, delta-aware file/flash transport over that lossy channel.

## Architecture — two sides

1. **Technician side (host CLI):** what the operator/automation drives. Computes
   compression + binary deltas host-side, frames and streams them over the serial line,
   waits for acks, retransmits, and issues apply-actions. Must be **scriptable / non-interactive**
   so an automated build→push→reflash→reboot→verify loop can drive it.

2. **Phone side (on-device agent):** a small, dependency-light receiver that runs on the
   phone's shell. Reads framed input from the console, reconstructs/decompresses/patches
   files, verifies integrity, and applies them (write to partition, install module, exec).
   Must run with **only what a minimal Debian/busybox userspace has** (`dd`, `cat`, `printf`,
   `base64`, `sha256sum`/`md5sum`, `gzip`); anything heavier (`zstd`, `bspatch`, a compiled
   agent) must be **pushable by the tool itself** before use. Root via `sudo` for partition writes.

The two talk over the **existing serial console owned by `uartd`** (a daemon that holds
`/dev/ttyUSB0` @ 115200 8N1 and exposes a `uart` CLI: `read`/`peek`/`send`/`wait`/`status`/`log`
over a unix socket). The new tool should **build on / coordinate with uartd** (extend it with a
binary-framed channel, or talk through its socket) — it must NOT fight uartd for the port.

## Transport requirements (the core)

- **Framed, chunked protocol** that survives a lossy, no-flow-control 8N1 line **interleaved
  with console noise** (login prompt, shell echo, async `dmesg`/printk). Frames need a
  preamble/sentinel + length + sequence number + checksum so the receiver can resync and
  ignore non-frame bytes.
- **Per-chunk integrity + ACK/NAK + selective retransmit.** Assume every chunk may be
  corrupted or dropped; never trust a byte you didn't checksum.
- **End-to-end verify:** sha256 of the full reconstructed payload before it's used.
- **Resumable:** if interrupted (e.g., the device reboots mid-bring-up), resume from the last
  acked chunk rather than restarting.
- **Throughput-aware:** maximize bytes/sec on 115200 with no flow control — tune chunk size to
  the drop rate, prefer raw 8-bit if the path is binary-clean, else base64/base85; show
  progress + ETA. (Realistically this is a slow channel; the whole design goal is to make the
  *per-iteration* bytes tiny so slowness doesn't matter.)
- **Compression:** compress every payload before transit (gzip always available; zstd/xz when
  pushed). Decompress on the phone. This stacks with deltas.

## Delta / patch support (the efficiency win)

- Compute a **binary diff host-side** (bsdiff / xdelta3 / `zstd --patch-from`) of the new
  artifact against a **base that already exists on the phone** — ideally the *current content
  of the target partition itself* (e.g., diff new `vendor_boot.img` against the live
  `vendor_boot_a`). Push only the patch; reconstruct on-device.
- The agent applies the patch against the on-device base (partition or file) to produce the new
  image, verifies its sha256 against an expected value, then writes it.
- Support a **`pull`** of an on-device file/partition region so the host can snapshot the
  current base for diffing (and to confirm what's actually there).

## Operations the technician CLI must expose (scriptable)

- `push <local-file> <remote-path>` — compressed, chunked, verified file copy.
- `pull <remote-path|partlabel[:off:len]> <local-file>` — read back for diff-base / verification.
- `flash <local-image> <partlabel>` — if a base is available on-device, **diff against the live
  partition** and send only the delta; reconstruct, **verify sha256, then `dd` to the partition
  and read-back-verify** the written region. Refuse to write on hash mismatch. `--dry-run`.
- `patch <local-base> <local-new> <remote-base> <remote-out>` — host computes delta, agent applies.
- `install-module <local.ko> [--depmod]` — push to `/lib/modules/<uname-r>/…`, `depmod`, or `insmod`.
- `run <cmd>` — exec on the phone, return **stdout/stderr/exit-code** over the framed channel
  (reliable, so automation can read probe results like `dmesg | grep`, `ip -br link`, etc.).
- `bootstrap` — install/upgrade the phone-side agent over the bare console (see below).

## Bootstrapping the phone agent (chicken-and-egg)

The agent must be installable over the same console from nothing. Minimal path: the host pastes
a tiny pure-shell receiver via `cat > /tmp/recv.sh` (base64-framed, hand-verifiable), which can
then receive a fuller agent / static helpers (`zstd`, `bspatch`) the same way. **Don't assume
python, zstd, or bspatch exist** — detect, and push static builds if missing. Assume only
coreutils/busybox basics are present.

## Environment specifics (felix)

- Serial: **115200 8N1, no HW/SW flow control**; the line also carries `console=ttySAC0` printk
  and a `serial-getty` login. Pasting multiple lines / large blocks **silently drops characters**.
- Phone shell: normal Debian login (`kalm`, passwordless `sudo`). Use `sudo` for `dd`/partition
  writes/`depmod`.
- Targets: `boot_a` (kernel, ~18 MB — changes only when the Image is rebuilt; prefer modules to
  avoid that), `vendor_boot_a` (dtb + 34 MB initramfs — **only the dtb changes per iteration**).
- The rootfs is the AOSP-track image (kernel-version mismatch vs the mainline kernel, so its
  `/lib/modules` doesn't match — module installs must target the running `uname -r` and match vermagic).
- Recovery if a bad write bricks a boot: the slot is rollback-safe (boots the other slot after a
  few failed tries), and fastboot is always available as the human fallback — but the tool should
  hash-verify before writing so it never knowingly flashes garbage.

## Success criterion

An automated loop on the host can: build a new `boot`/`vendor_boot` → compute the delta vs the
live partition → push only the delta over UART (compressed, verified) → reconstruct + `dd` +
read-back-verify on-device → `reboot` → `run` a probe command and read the result — **with zero
fastboot and zero cable swaps**, per-iteration transfer in the low-KB range.

## Non-goals

- No GUI; CLI/scriptable only.
- Not a general fileserver — it's a reliable transport + on-device apply primitives.
- Doesn't need to be fast in absolute terms; it needs to be **reliable** and **delta/compression-
  efficient** so the per-iteration payload is tiny.
