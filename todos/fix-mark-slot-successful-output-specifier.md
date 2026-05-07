# Fix `mark-slot-successful.service` output specifiers

## What's broken

On boot, systemd rejects two lines in the unit file:

```
systemd[1]: /etc/systemd/system/mark-slot-successful.service:14: Failed to parse output specifier, ignoring: journal+kmsg
systemd[1]: /etc/systemd/system/mark-slot-successful.service:15: Failed to parse output specifier, ignoring: journal+kmsg
```

The unit file lives at [rootfs/overlay/etc/systemd/system/mark-slot-successful.service](rootfs/overlay/etc/systemd/system/mark-slot-successful.service). Lines 14–15 are:

```
StandardOutput=journal+kmsg
StandardError=journal+kmsg
```

`journal+kmsg` is not a valid value for `StandardOutput=` / `StandardError=`. Systemd's accepted compound values are `journal+console` (and `inherit`, `null`, `tty`, `journal`, `kmsg`, `file:…`, `socket`, `fd:…`). See `man systemd.exec` under "StandardOutput=".

The intent was to get the service's stdout/stderr to both the journal and the kernel ring buffer (so the slot-marking action shows up in `dmesg` alongside the [BEACON] lines). With the current invalid value, systemd drops the directive and falls back to the default (`journal` only), so the BCB write succeeds silently — there's no kmsg trace confirming it ran.

## What to do

Replace `journal+kmsg` with `journal+console` on both lines. That gets output to the journal *and* the active console (which on this device is kmscon on tty1 + serial-getty on ttySAC0), which is the closest valid equivalent to the original intent.

If the goal really was to land in `dmesg` specifically (not just the console), the alternative is to leave `StandardOutput=journal` and have the `pixel-devinfo` binary itself write a one-line summary to `/dev/kmsg` on success — but that's a code change in the vendored tool, not a unit file fix. Default to the `journal+console` change unless asked otherwise.

## Verification

After editing the overlay, the change propagates through:

1. Edit [rootfs/overlay/etc/systemd/system/mark-slot-successful.service](rootfs/overlay/etc/systemd/system/mark-slot-successful.service) — overlay files are tracked as Makefile deps of `.install_packages` (via `$(shell find rootfs/overlay -type f)`), so editing one re-triggers the package + initramfs + boot stages.
2. Run `just all` to rebuild. `.install_packages` → `.install_initramfs` → `.build_boot` will fire.
3. `./flash.sh` to flash the new images.
4. Boot and check: `journalctl -u mark-slot-successful.service -b` should show the unit ran without the parse-error warning, and `dmesg | grep -i devinfo` (or whatever pixel-devinfo prints) should show its output if it writes to stdout.

## Why this matters

The `mark-slot-successful` service is the fix for the A/B slot retry counter exhaustion bug — without it (or with it broken/silent), the bootloader drops to fastboot after 3–7 boots because Debian never marks the slot successful, and recovery requires `./flash.sh`. The service is currently *running* (boot log shows `svc: mark-slot-successful.service = active`), so the BCB write is probably happening — but the broken output config means there's no log evidence to confirm it on each boot. Fixing the specifier closes the observability gap so the next "stuck in fastboot" incident (if any) can be diagnosed from logs instead of guessed at.

## Context references

- Memory: [project_ab_slot_retry_counter.md](/home/chris/.claude/projects/-home-chris-Repos-school-krg-junkyard-junkyard-boot-img/memory/project_ab_slot_retry_counter.md)
- Boot log evidence: lines `[42.420641]` and `[42.422333]` of the `dmesg` captured 2026-05-03.
