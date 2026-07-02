# Existing on-device tools `benchctl` drives — DO NOT rebuild; call them

These already exist as complete repos (`junkyard-computing/pixel-bootctl`,
`junkyard-computing/pixel-ota`) with their own READMEs. Re-speccing them risks a divergent
copy. Consume them. This file is the contract a host orchestrator codes against.

## pixel-bootctl  (static aarch64 musl binary, runs as root on the device's Debian)

```
status                     Read A/B slot flags from devinfo.
set-active-slot <a|b>      Switch slot = write the UFS boot-LUN sysfs node (the REAL switch on
                           Tensor: /sys/.../pixel/boot_lun_enabled, "1"=A "2"=B) + update
                           devinfo flags. Reboot to apply.
mark-successful            Mark the RUNNING slot successful (retry=7) in devinfo ONLY — does not
                           touch the boot LUN. Keeps the bootloader retry counter from
                           exhausting (and dropping to fastboot). Run from a post-boot unit.
```

- The slot switch is **keyless** — no fastboot, GSA, signing, or Trusty needed.
- `super` (rootfs) is **NOT** A/B — it's a single shared partition.

## pixel-ota  (static aarch64 musl binary, root; needs pixel-bootctl on PATH)

```
update <dir> [--no-switch] [--slot a|b] [--dry-run]
    Flash the INACTIVE slot's boot chain from <dir>/*.img — known partitions only:
    boot, init_boot, vendor_boot, vendor_kernel_boot, dtbo, vbmeta, vbmeta_system,
    vbmeta_vendor, pvmfw. Fits-check each; REFUSES to flash the active slot. Then calls
    pixel-bootctl set-active-slot to switch, ROLLBACK-SAFE (target active, NOT successful):
    if it never boots, the bootloader burns its retry budget and falls back. --no-switch
    flashes without switching. No reboot.
confirm
    Commit the current slot (-> pixel-bootctl mark-successful). On the deployed image a
    post-boot service does this automatically after a good boot. Until committed, a failed
    boot rolls back.
flash-rootfs <img> [--staged] [--no-reboot]
    In-place reflash of the single shared `super` via systemd's shutdown initramfs.
    DESTRUCTIVE, ROLLBACK-FREE, RAM-staged, and historically FLAKY on felix (the
    shutdown-pivot path). AVOID for iteration — only for a deliberate full-image swap.
```

## Build / install

Both: `nix build` → `result/bin/<tool>` (static `aarch64-unknown-linux-musl`).
Install: `scp result/bin/<tool> <device>:/usr/local/bin/`. In this repo the Makefile
cross-builds both into `rootfs/overlay/usr/local/bin/` (`.build_pixel_bootctl` /
`.build_pixel_ota`); `flash-ssh.sh` scp+installs whichever is missing.

## VERIFY ON HARDWARE (load-bearing)

The two READMEs disagree on whether `set-active-slot` marks the target **successful**
(pixel-bootctl says "active+successful retry 7"; pixel-ota relies on "active, NOT successful"
for rollback). Rollback safety depends on the experiment slot being **active-but-NOT-successful**,
so always assert via `pixel-bootctl status` after staging and before rebooting. A slot
mistakenly marked successful gives **no auto-rollback** (this has bitten before).
