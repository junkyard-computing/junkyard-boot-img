# pty-owning console front-end — the reliable serial channel (uartfs agent extension)

## Purpose / context

The lossy UART console is the only channel to mainline felix, and patching it per-command
(echo-verify, self-checking one-liners) only ever makes *explicit one-shot `run` calls* safe —
login, interactive tools, and raw output are still at the mercy of dropped characters. The real
fix is to stop treating the serial line as a dumb tty and put a **device-side binary that owns
the serial fd and frames + checksums every byte on the line, uniformly** — login, commands,
output, interactive sessions, all of it. Then the lossy-UART problem disappears once, for
everything, instead of being managed call-by-call.

Build this as a **persistent-session extension of the uartfs agent** (which already does
validate-then-run), not a separate program.

## Architecture
- **Owns the serial console.** Replaces / wraps `serial-getty@ttySAC0` (a systemd unit, or
  launched from init) so the front-end — not a getty — is what sits on `/dev/ttySAC0`. Every
  byte in and out of the serial fd passes through it.
- **Framed + checksummed transport for everything.** Reuse uartfs framing (sentinel + length +
  seq + checksum, resync on garbage; see `uart-flash-tool.md`). All traffic — command requests,
  stdout/stderr, exit codes, login, interactive keystrokes/redraws — is framed. The host side
  validates each frame; corruption → NAK/retransmit. The channel is reliable by construction,
  not by heuristic.
- **Shell runs as a child on its own pty.** The front-end `forkpty()`s the shell (or a login)
  as a child and sets that pty to **`-echo` / raw**, so it cleanly separates input from output
  and **frames back exactly what it chooses** — no echo to guess, no readline redisplay to
  parse, no `COLUMNS`/`TERM`/PS1 heuristics. This is the structural reason it succeeds where
  echo-verify can't.
- **Validate before it acts.** Each framed command's checksum is checked, then either run and
  framed back (stdout/stderr/exit-code), or — the new capability — bridged to an interactive
  attach.

## Two service modes over the one framed channel
1. **Exec** (the uartfs `run` semantics, now over the persistent owned console): receive framed
   command → validate → run on the child → frame back stdout/stderr/exit-code. Same contract as
   today's agent, but the agent now persists and owns the line.
2. **Interactive attach** (new): bridge a framed interactive session to the child pty for the
   things `sh -c` can't do — a `sudo` password prompt, `vim` / `menuconfig` / `top`, a live
   console. Host keystrokes are framed → child pty; child output is framed → host. Both
   directions checksummed, so interactivity is finally *reliable* on this line. Support
   window-size (`TIOCSWINSZ`) and signal (Ctrl-C) pass-through, and a clean detach.

## Lifecycle & bootstrap
- **Persists and survives reboots** — installed as the console service so it comes back every
  boot. It IS the console; there is no separate getty fighting it.
- **Bootstrapped and recovered by the floor.** The agentless `uart run` (see
  `uartd-reliable-run.md`) is what pushes/installs/launches this front-end from a bare shell,
  and is the fallback whenever it's down (fresh boot before the service starts, pre-init, a
  panicked kernel). Front-end up → use it for everything; front-end down → drop to the floor,
  which can bring it back.

## Host side
- uartd still owns the host serial port; it learns the front-end's framed protocol (exec +
  attach) and multiplexes it with the floor and with uartfs file-transfer over the one port.
- CLI: `uart attach` (interactive session), `uart run` routes through the front-end when it's up
  (and transparently falls back to the agentless floor when it isn't).

## Why this is the right destination
It's the only option that makes the channel reliable for **everything, including interactivity**
— not just for explicit one-shot commands. Echo-verify and the self-checking floor manage the
symptom per-call; owning the pty retires the lossy-console problem at the transport layer, once.

## Success criteria
- Login, arbitrary commands, full output, and interactive tools (`sudo`, `vim`,
  `menuconfig`, `top`) all work over the serial line with **no dropped-character corruption** —
  every byte framed and validated end-to-end.
- The front-end survives reboots and is reachable as the console; when it's down, the agentless
  floor reaches the device and can reinstall/relaunch it.
- Replaces the current "raw `uart send` for logins/probes" entirely; that path's silent
  corruption is gone.

## Non-goals
- Not a flashing path (uartfs file-transfer stays).
- Not a replacement for the bootstrap floor — they're complementary tiers (this one needs to be
  installed and running; the floor covers the gaps).
- Doesn't need to emulate a full terminal beyond faithfully bridging the child pty.
