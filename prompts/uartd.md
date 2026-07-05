# Build: `uartd` — a buffered UART console daemon + CLI for AI-driven serial control

## Why this exists

I'm an AI coding agent that drives hardware over a UART serial console (a Pixel
phone running Linux, reached at 115200 8N1 on a USB-serial adapter like
`/dev/ttyUSB0`). The problem: I operate in **discrete request/response turns** —
between my turns nothing of mine is listening, so I can't hold a serial port
open and watch a real-time stream. I need the stream turned into a **poll-able
resource**: a daemon that owns the port and captures continuously, plus a CLI I
call per-turn to read what's new and to send input.

Build that. Optimize the ergonomics for a machine caller (me), not a human at a
terminal.

## Architecture

- **`uartd` (daemon):** opens and *exclusively owns* the serial port, configures
  it (`stty`/termios), and captures everything continuously. Exposes a control
  channel (Unix domain socket is preferred) for the CLI. Runs in the background,
  survives across many CLI invocations.
- **`uart` (CLI):** a thin client that talks to the daemon over the socket. This
  is what I invoke each turn. Must have stable, scriptable output and meaningful
  exit codes.

Single owner of the port (the daemon); the CLI never touches the device
directly. This also solves permissions — the daemon opens the port once.

## CLI commands (core)

- `uart read` — return all bytes captured **since the last `read`**, then clear
  that buffer ("what's new since I last looked"). This is my main polling call.
- `uart peek` — same as `read` but **non-destructive** (don't clear).
- `uart send "<text>"` — write input to the device. Append a newline by default
  (`--no-newline` to suppress). **Must be flow-control-safe** (see Hardware).
- `uart send "<cmd>" --expect "<regex>" --timeout <sec>` — send, then block until
  the regex matches in the incoming stream (typically a shell prompt or a marker
  line) or timeout; return everything received in between. This is how I run a
  command and reliably get its output. Exit non-zero on timeout.
- `uart wait "<regex>" --timeout <sec>` — block until the regex appears in the
  stream (no send); return the matched context. For waiting on `login:`, a
  dmesg line, a boot stage, etc.
- `uart log` — print the path to the full forensic log file (see below).
- `uart status` — daemon up/down, port, baud, connected/disconnected, buffer
  size, uptime. Start/stop: `uart start` / `uart stop` (CLI should give a clear
  error, not hang, if the daemon isn't running).

Add a global `--json` option that emits structured output (with line timestamps)
for `read`/`peek`/`wait`/`send --expect`, so I can parse reliably.

## Buffering & logging (important — don't simplify these away)

- **Two sinks, always:** (1) the **drain buffer** behind `read` (cleared on
  read), and (2) a **full append-only log file** with per-line timestamps that is
  *never* cleared. Rationale: `read` is lossy by design ("new since last look"),
  so if I drain too eagerly I must still be able to `grep` the complete history
  from the log. The log is the forensic record; the buffer is the live feed.
- **Timestamp every line** (monotonic + wall-clock). Timing carries real signal
  in hardware bring-up (e.g. how long after a reset an event fires).

## Hardware realities to handle (this is where naive implementations fail)

- **No flow control.** The target UART has no RTS/CTS and silently drops bytes if
  you blast input at it. `send` must pace output: write one line at a time with a
  small inter-line delay, and consider a small inter-character delay. Never dump a
  multi-line block at once.
- **The device reboots constantly**, and the serial port itself can disappear and
  reappear (USB re-enumeration, the phone's debug-console mode dropping). The
  daemon must **auto-reconnect**: when the port vanishes, keep retrying open;
  when it returns, resume capture seamlessly and log a clear reconnect marker.
  Never crash on a port drop.
- **Optional auto-login:** watch for a `login:` prompt and, if configured with a
  username/password, log in automatically so a shell is ready when I poll.
  Make it opt-in via config.

## Config

- Port, baud (default 115200), data/parity/stop (default 8N1), log directory,
  socket path, optional auto-login creds, pacing delays. Config file +
  env-var/flag overrides. Sensible defaults so `uartd --port /dev/ttyUSB0` just
  works.

## Tech & packaging

- Python 3 + `pyserial` + a Unix-socket control protocol is a fine, simple choice
  (use whatever you think is cleanest — keep dependencies minimal). The host is
  NixOS, so a `flake.nix` exposing the daemon + CLI as runnable packages and a
  dev shell is appreciated, but a `pyproject.toml` is acceptable.
- Keep it robust over clever: this has to run unattended for hours while a flaky
  device reboots under it.

## Acceptance criteria

1. Start `uartd` against a real (or `socat`-emulated) serial port; `uart status`
   shows it connected.
2. Device prints lines → `uart read` returns them with timestamps and clears;
   a second immediate `uart read` returns empty; the full log file still has them.
3. `uart send "echo hello" --expect '\$ ' --timeout 5` returns output containing
   `hello`. Sending a 20-line block does **not** drop characters.
4. Yank and reconnect the port (or restart the emulator) mid-run → the daemon
   reconnects automatically, logs a marker, and capture resumes with no crash.
5. `uart wait 'login:' --timeout 30` blocks and returns when the prompt appears;
   with auto-login configured, a shell prompt is reachable afterward.

## Deliverables

Working `uartd` + `uart`, a README with the rationale above and usage examples,
config sample, the flake/pyproject, and a test (using a pty/`socat` loopback so
it runs without hardware in CI).
