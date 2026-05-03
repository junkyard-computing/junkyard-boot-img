# trusty

- **AOSP path**: `private/google-modules/trusty/`
- **Mainline counterpart**: **NONE** — Trusty is an Android-only TEE driver and has never been upstreamed
- **Status**: not-ported
- **Boot-relevance score**: 2/10

## What it does

Trusty is Google's open-source TEE kernel that runs alongside Linux in EL1-secure (or
behind ARM FF-A on newer SoCs), and this module is the Linux-side IPC driver. Major
pieces:

- `trusty.c` / `trusty-smc-arm64.S` — the SMC dispatch core, issues `SMC_FC_*` calls into
  the secure world via `smc #0` (or `hvc #0` under FF-A).
- `trusty-irq.c` — forwards Linux IRQs the secure world has registered for back into
  Trusty so it can service its own peripherals (e.g. dedicated crypto, secure storage).
- `trusty-virtio.c` + `trusty-ipc.c` — exposes per-service Trusty connections as virtio
  devices, with a chardev + UAPI (`include/uapi/linux/trusty/ipc.h`) that Android's
  `libtrusty` uses to talk to TAs (gatekeeper, keymaster, fingerprint, DRM widevine, etc.).
- `trusty-log.c` — drains the secure-world log ring and prints it to dmesg.
- `trusty-mem.c` / FF-A shared-memory helpers — DMA-buf transfers across the EL1-S boundary.
- `trusty-sched-share.c` — secure/non-secure scheduling hint coordination.

## Mainline equivalent

None — Trusty as a TEE OS is open source, but the Linux kernel-side driver has never been
proposed for upstream (Google has historically kept it as a vendor module). The closest
upstream analog is `drivers/tee/optee/`, which talks to OP-TEE via the same SMC/FF-A
mechanisms but with a different protocol (GlobalPlatform TEE Client API). gs201 ships
Trusty in its bootloader's BL32 slot, so OP-TEE wouldn't bind to it.

## Differences vs AOSP / what's missing

Everything. Mainline literally cannot speak Trusty's SMC ABI. Without the driver,
userspace can't reach gatekeeper/keymaster/widevine/etc., which means no Android-style
verified boot, no hardware-keystore-backed credentials, no DRM playback, no Pixel
fingerprint TA. For a Debian rootfs that only wants a console + ssh, none of this
matters.

## Boot-relevance reasoning

Trusty IPC isn't required for boot — the secure world runs autonomously in EL1-S/EL3
regardless of whether Linux ever talks to it, and Linux doesn't depend on Trusty for
anything in its boot path. (BL31's protected-KVM gate is a *separate* concern handled
by `kvm-arm.mode=protected` on the cmdline, per the project memory.) Score 2 — not
boot-blocking, not in the UFS path, not even needed for a working Debian system. Useful
later if we ever want to reach the secure-element-backed credentials, but irrelevant to
the current bring-up.
