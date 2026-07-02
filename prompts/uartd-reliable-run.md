# uart run — device-self-verifying agentless command floor (bootstrap + fallback tier)

## Where this sits (read first)

This is **tier 1 of two**. It is the **zero-prerequisite floor**: a reliable way to run a
command against a *bare shell* over a lossy UART using nothing but stock coreutils — no
on-device software installed. Its job is **not** to be the everyday path. Its job is:
1. reliably **bring up the real channel** (the pty-owning console front-end — see
   `console-frontend.md`), and
2. be the **fallback** for every window where that front-end isn't up: fresh boot, pre-init,
   a panicked kernel dropping to a recovery shell, or before it's been pushed.

Once the front-end is up, use it. This floor is the thing you can always fall back to.

## Trust model: verify on the device, ignore the echo

Earlier drafts leaned on **echo-verification** (read the tty's echo, compare to what we sent).
That is unsound at an interactive shell and must NOT be the basis of trust:
- **Passwords**: echo is off — no receipt at all.
- **readline (interactive bash)**: the line you get back is a *redisplay* in raw mode (`\b`,
  `ESC[C/D`, `ESC[K`, history-search repaints, autosuggestion plugins printing ahead of the
  cursor then erasing) — not a mirror of the bytes sent.
- **Line wrap**: crossing the terminal width triggers cursor moves/redraw that uartd can't
  predict without the device's real `COLUMNS`/`TERM` (serial defaults are usually wrong).
- **It fails intermittently** — short commands look like a clean mirror, long/plugged-in ones
  diverge — so it gets trusted and then bites.

So **uartd ignores the echo entirely.** Integrity is established **on the device**: the command
carries its own checksum and refuses to run if corrupted; the reply carries its own checksum so
the host knows it received the output intact. Corruption anywhere → the check fails → retry.

## Mechanism (`uart run "<cmd>"`)
Enter a single self-checking one-liner, bracketed by **random per-call nonces**, that relies
only on `printf`, `base64`, `sha256sum` (or `md5sum`), `sh`, `cut`, `test`:

1. Host builds: `D` = base64(cmd), `H` = sha256(D), fresh nonce `N`.
2. Host sends a line equivalent to:
   `D=<D>; H=<H>; printf '<<S:N>>\n'; if [ "$(printf %s "$D"|sha256sum|cut -c1-64)" = "$H" ]; then OUT=$(printf %s "$D"|base64 -d|sh 2>&1); rc=$?; else OUT='cmd-corrupt'; rc=251; fi; B=$(printf %s "$OUT"|base64 -w0); printf '<<E:N>>:%d:%s:%s\n' "$rc" "$(printf %s "$B"|sha256sum|cut -c1-64)" "$B"`
3. Host **ignores the echo**, waits for `<<E:N>>:`. Then it verifies the **output checksum**
   against the received base64 (`B`) and base64-decodes it.
4. Failure modes all collapse to "retry": command corrupted in transit → on-device sha
   mismatch → `rc=251`; reply corrupted in transit → host-side output-sha mismatch; line
   structurally mangled → no end-nonce → timeout. None of them can be mistaken for success,
   because success requires the end-nonce **and** a matching output checksum.

(Encode the command base64 so arbitrary/multiline/quoted commands survive verbatim; nonces are
random and length-checked so they can't collide with the command or prior console output.)

## The one place echo is legitimately used: getty login
A **getty** login prompt is a dumb, cooked-mode line — there echo *is* a faithful copy, so it's
fine to use it. `uart login --user U --password P`: echo-verify the username (sound at a dumb
line), send the password **blind** (echo off), confirm success by the resulting shell prompt /
a trivial `uart run` afterward. This is the only echo-based step, and only at the dumb getty
line — never at an interactive shell.

## Resync / robustness
- Before each call, resync: `Ctrl-U` then newline, wait for *any* prompt, so a prior partial
  line can't corrupt the next.
- Bounded retries on no-end-nonce / mismatch, then fail loudly with the diagnosis.
- Tolerate interleaved kernel `printk` on the line (anchor on the nonces, not contiguity).
- Stream/cap very large output; note truncation.

## CLI surface
- `uart run "<cmd>" [--timeout T]` — device-self-verifying exec; returns stdout + exit code.
- `uart login --user --password` — the dumb-line login flow above.
- Keep raw `read`/`send`/`peek`/`wait` untouched.

## Success criteria
A few hundred `uart run` calls against a bare shell on the real felix line return correct
stdout + exit codes with **zero silently-wrong results** — every call either runs the exact
intended command and returns verified output, or detects corruption (on device or on host) and
retries/fails explicitly. And it can reliably push+launch the console front-end from nothing.

## Non-goals
- Not the everyday path, not interactive (no sudo-prompt / vim / top) — that's the front-end.
- Not file-transfer/flashing (uartfs).
- Doesn't depend on echo, `COLUMNS`/`TERM`, or PS1.
