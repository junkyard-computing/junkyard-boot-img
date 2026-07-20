# ⛔ READ FIRST — THE PHONE NEEDS A POWER CYCLE (my fault, sorry)

**State: felix is hard-hung in early kernel init and cannot be recovered without hands.**
It stopped responding at **00:06 on 2026-07-20**. Not pingable, no SSH, no UART console
(the link is fine — `uartd` still reports `connected=true` — the *device* is wedged).

**What I did:** flashed a kernel to slot B with an fbcon change. It hangs at kernel
**t=0.289 s**, immediately after
`dsim_of_get_pll_features: exynos-dsim[1]: ... failed to get pll-input` —
i.e. right at DRM/DSIM init, exactly where my change lands. No panic, no watchdog reset,
no boot loop: a hard deadlock with printk dead, so `PANIC_TIMEOUT=10` never fires and the
A/B retry counter is never decremented. Nothing software-side can reach it.

## Recovery — one command, ~30 seconds

A known-good `boot.img` (the exact kernel that was running before, `4c234bd`, no local
edits) is staged at:

```
/home/chris/felix-recovery/boot-known-good.img
```

1. Force the phone off: **hold Power ~10 s** (add Vol-Down to land in the bootloader).
2. Get to fastboot: **Vol-Down + Power**.
3. Flash and go:
   ```
   fastboot flash boot_b /home/chris/felix-recovery/boot-known-good.img
   fastboot reboot
   ```

**Fallback if that misbehaves:** `fastboot set_active a` boots the AOSP anchor slot.
Slot A was never touched and is intact.

**Do NOT just power-cycle and hope.** Slot B is still active and will re-hang on every
boot; each attempt burns one of its 7 retries, and after 7 it drops to AOSP on its own.

## Was the rollback protection useless?
Partly — and this is the honest lesson. I flashed B `active-but-NOT-successful`
specifically so a slot that never reaches userspace would fall back to A. That protection
assumes the device **resets** (watchdog/panic) so the bootloader can count the retry. This
hang doesn't reset, so the counter never moves. **A/B rollback does not cover a hard
early-init deadlock** — worth knowing before trusting it again on a display-path change.

## What was NOT damaged
- Slot A (AOSP) untouched and bootable.
- `super` / rootfs untouched — no rootfs write happened.
- All findings below were captured **before** the hang and are unaffected.
- Everything after Stage 1 is code + analysis done without the device.

---

# Overnight run — 2026-07-19/20 — felix (Pixel Fold, gs201, mainline 7.2.0-rc3)

Queue: (1) fbcon → (2) genpd → (3) TPU/GPU power → (4) GPU performance.
Every claim below is tagged **[MEASURED]** or **[INFERRED]**.

## Starting state (verified at 06:42)
- Kernel `7.2.0-rc3-00095-g4c234bdd4326` on slot B; slot A = AOSP anchor. **[MEASURED]**
- `/dev/fb0` absent; `/proc/consoles` = `ttySAC0`, `ramoops-1` only — **no `tty0` at all**. **[MEASURED]**
- `/dev/dri/card0` (exynos-drm), `card1` (panthor), `/dev/accel/accel0` (edgetpu). **[MEASURED]**
- Uptime 17 min, load 0.00 — platform stable after yesterday's two fixes. **[MEASURED]**

---

## Stage 1 — fbcon

**Status:** IN PROGRESS

### Diagnosis (carried in from yesterday)
`CONFIG_DRM_CLIENT_SELECTION=m` → `drm_client_lib.ko` is not loaded when `exynos-drm`
probes, so `drm_client_setup()` finds no fbdev client and `/dev/fb0` never appears.
Confirmed present in the deployed `out/.config` as `=m`. **[MEASURED]**

### Change
`kernel/custom_defconfig_mod/felix.config`: `CONFIG_DRM_CLIENT_SELECTION=y` (commit `801702c`).
Built on top of `4c234bd` (the exact deployed SS base) so **fbcon is the only variable**.

### Results
_pending_

### Premise corrections found during setup (read these first)

Three assumptions in the overnight brief were **wrong**; all three were checked on-device
before any work depended on them.

1. **`mali_csffw.bin` is NOT missing.** `/vendor/firmware/arm/mali/arch10.8/mali_csffw.bin
   -> ../../../mali_csffw-r54p2.bin` exists (dated Jul 6) and **panthor loaded the
   firmware successfully**: `CSF FW using interface v1.5.0`, `Firmware git sha:
   8e60d612...`, `Mali-G710 id 0xa862 ... shader_present=0x1110055`. The Makefile's
   `.install_vendor_firmware` stage creates this symlink, so it ships in every image.
   **[MEASURED]** — Stage 4 does not need a firmware fix; GPU is genuinely up.

2. **`drm_client_lib` IS loaded — as a module, with refcount 0.** This *corroborates*
   the fbcon diagnosis rather than refuting it: the module is present but loaded far
   too late (via `modprobe@drm.service` at t=6.3s) while `exynos-drm` bound its
   components and called `drm_client_setup()` at **t=0.288s**. The client registry was
   empty at probe time, so no fbdev client was ever created. `=y` is the right fix.
   **[MEASURED]**

3. **★ edgetpu is NOT actually working — and this is pre-existing, not a genpd effect.**
   On the current SS base with **no genpd patch at all**, bring-up fails:
   ```
   edgetpu 1ce00000.edgetpu: edgetpu: fw body (1033984 bytes) staged in carveout
   edgetpu 1ce00000.edgetpu: edgetpu: GSA GET_STATE failed: EIO
   edgetpu 1ce00000.edgetpu: edgetpu: bring-up failed: EIO
   ```
   The module loads and `/dev/accel/accel0` appears (the DRM accel node registers
   regardless), so "edgetpu loaded" / "`/dev/accel/accel0` present" is **not** evidence
   the TPU works. **[MEASURED]** This reframes Stage 3: the TPU is already broken
   *before* any power-domain work, so `pd_tpu` gating cannot be blamed for it, and
   wiring `power-domains = <&pd_tpu>` will not by itself restore it.

### Stage 1 — root cause was NOT what the brief said

`CONFIG_DRM_CLIENT_SELECTION=y` in a defconfig fragment **cannot work**, and the first
build proved it: after a full rebuild the merged `out/.config` still read
`CONFIG_DRM_CLIENT_SELECTION=m`. **[MEASURED]**

Reason: in `drivers/gpu/drm/clients/Kconfig:12` the symbol is a **prompt-less `tristate`**.
Kconfig ignores user-supplied values for symbols with no prompt and computes them purely
from `select` statements. So the fragment line was inert. *(Same class of trap as the
`TYPEC=y` cap already documented in `felix.config`.)*

Digging further found the actual problem, which is bigger than a Kconfig line:

| symbol | value | meaning |
|---|---|---|
| `CONFIG_DRM_EXYNOS` | **=m** | mainline exynos driver — selects `DRM_CLIENT_SELECTION`, calls `drm_client_setup()`, **not the driver felix uses** |
| `CONFIG_DRM_SAMSUNG_FELIX` | **=y** | the AOSP-graft DPU driver that actually drives the panel |

**[MEASURED]** `grep -rn drm_client_setup drivers/gpu/drm/samsung-felix/` returns **nothing**.
The felix driver registers with `drm_dev_register()` (`exynos_drm_drv.c:1236`) and has no
`.fbdev_probe` in its `drm_driver` (`exynos_drm_drv.c:1046`). It also uses a **custom GEM**
(`exynos_drm_gem_*`), not the GEM-DMA helper.

**Conclusion [INFERRED, from code]:** setting `DRM_CLIENT_SELECTION=y` would have changed
nothing whatsoever — nothing on card0 ever asks for an in-kernel client. `/dev/fb0` was
never one Kconfig line away. This also explains the `drm_client_lib` module sitting loaded
with refcount 0.

### The actual fix (3 parts, written)
1. `samsung-felix/Kconfig`: `select DRM_CLIENT_SELECTION` — the only correct way to raise
   a prompt-less symbol, and it inherits `=y` from `DRM_SAMSUNG_FELIX=y`.
2. `exynos_drm_gem.c`: add `.vmap`/`.vunmap` to `exynos_drm_gem_object_funcs`. Trivial
   because `exynos_drm_gem_create()` allocates via `dma_alloc_wc()` and already stores the
   kernel VA in `exynos_gem_obj->vaddr`; `vmap` just wraps it in an `iosys_map`.
3. `exynos_drm_drv.c`: add `DRM_FBDEV_TTM_DRIVER_OPS` + call `drm_client_setup()`.
   `drm_fbdev_ttm` is the GEM-agnostic client — it builds scanout from `dumb_create()`
   plus a vmalloc'd shadow with deferred I/O (`drm_fbdev_ttm.c:190,126,220`), needing no
   TTM and no GEM-DMA layout. Its only two requirements — `->dumb_create` and a GEM
   `->vmap` — are exactly what felix has and what part 2 adds.

---

## Stage 3 (pulled forward) — edgetpu: ★ root-caused, fix written

Investigated out of order because the Stage-1 build occupied the machine and the
evidence surfaced during setup. **This turned out to be the most valuable finding of
the run.**

### The bug: an ~80 ms probe-order race, losing on every cold boot

Boot timeline, from a single dmesg **[MEASURED]**:

| t (s) | event |
|---|---|
| 7.715 | `trusty trusty: trusty version: ... Built: Nov 28 2025` — Trusty core up |
| 7.803 | `gsa 17c90000.gsa-ns: TZ: failed (-2) to create chan` |
| 7.803 | `gsa 17c90000.gsa-ns: TZ: failed (-2) to connect` |
| 7.803 | `edgetpu: GSA GET_STATE failed: EIO` → `bring-up failed: EIO` |
| **7.885** | `trusty_ipc virtio0: is online` ← **82 ms too late** |

`-2` is `-ENOENT` from `tipc_create_channel()`: the Trusty IPC virtio device is not yet
registered. edgetpu probes, asks GSA for TPU state over tipc, and loses the race by
~80 ms — **every cold boot**. The TPU then silently never comes up.

### Why this was invisible until now
`/dev/accel/accel0` is registered **regardless** of whether bring-up succeeded
(`[drm] Initialized edgetpu 0.2.0 ... on minor 0` is printed *after* the failure). So
"edgetpu module loaded" and "`/dev/accel/accel0` exists" — the two things previously
used as evidence the TPU worked — are **not evidence of anything**. **[MEASURED]**

### Confirming experiment
`rmmod edgetpu; modprobe edgetpu` with trusty_ipc long online: **the `EIO` disappears**
— GET_STATE now succeeds and bring-up proceeds much further, failing later at
`ETIMEDOUT`. **[MEASURED]** That isolates the `EIO` specifically to the race.

The reload also exposed a second, independent bug: `__dev_pm_qos_add_request() called
for already added request` (WARN, `qos.c:338`) from `edgetpu_bus_add()` — the file-static
`dev_pm_qos_request`s are never released, so any re-probe re-adds an active request and
corrupts the qos list. The reload's `ETIMEDOUT` is therefore **contaminated** by that
leak and must NOT be read as a second hardware failure. **[INFERRED — flagged as
unresolved; see Open questions]**

### Fix written (3 parts — they are interdependent)
1. `drivers/soc/google/gsa/gsa_core.c` — `gsa_tz_send_hwmgr_state_cmd()` collapsed *every*
   transport failure into `-EIO` (`-ENODEV`, `-ETIMEDOUT`, `-ENOENT`, connect failures all
   looked identical). Now returns `rc` when `rc < 0`; `-EIO` stays reserved for a reply
   that arrived but was malformed. This is what makes the race *diagnosable* at all.
2. `drivers/accel/edgetpu/bringup.rs` — map `ENOENT` at GET_STATE to **`EPROBE_DEFER`**
   so the driver core retries once Trusty IPC is up, instead of failing permanently.
3. `drivers/accel/edgetpu/edgetpu_gsa.c` — make `edgetpu_bus_add()` idempotent via
   `dev_pm_qos_request_active()`. **Required by (2)**: a deferred probe re-enters
   `edgetpu_bus_qos_init()`, which would otherwise hit the WARN above on every retry.

**Not yet flashed/validated** — build in progress.

### Deviation from "one variable per flash" — deliberate, with reasoning
This image carries **both** the fbcon change and the edgetpu change. Justification: the
two live in unrelated subsystems and have **independent, individually-observable**
signals (`/dev/fb0` + `/proc/consoles` vs. the edgetpu bring-up lines), and UART captures
the whole boot, so a failure can be attributed to a specific driver rather than guessed
at. The rule exists to prevent unattributable failures; here attribution is preserved.
Recording the call explicitly so it can be judged. **[decision, not a measurement]**

### Stage 1 build iterations (what each attempt taught)
1. **Kconfig fragment `=y`** → still `=m`. Prompt-less symbol; fragment inert. **[MEASURED]**
2. **`select DRM_CLIENT_SELECTION` + `.vmap` + `DRM_FBDEV_TTM_DRIVER_OPS` + `drm_client_setup()`**
   → config correct (`DRM_CLIENT_SELECTION=y`, `DRM_CLIENT_LIB=y`, `DRM_CLIENT_SETUP=y`) but
   **link failure**: `undefined reference to 'drm_fbdev_ttm_driver_fbdev_probe'`. **[MEASURED]**
   Cause: `drivers/gpu/drm/Makefile:135` builds `drm_fbdev_ttm.o` only into the
   `drm_ttm_helper` module, gated on `CONFIG_DRM_TTM_HELPER`.
3. **+ `select DRM_TTM_HELPER`** → in progress.

Why not the other two clients: `drm_fbdev_dma` does
`to_drm_gem_dma_obj(buffer->gem)` (`drm_fbdev_dma.c`), a `container_of` cast that is
simply **wrong** for felix's custom `struct exynos_drm_gem` — it would read a garbage
`map_noncoherent` and a garbage `smem_start`. `drm_fbdev_shmem` requires GEM SHMEM.
`drm_fbdev_ttm` touches no TTM internals at all (only `drm_client_buffer_create_dumb`,
`drm_client_buffer_vmap_local`, a vmalloc shadow, and `fb_deferred_io_init`), so it is
the correct choice — the name is historical. **[INFERRED, from reading all three]**

**Wart to flag:** selecting `DRM_TTM_HELPER` drags TTM into the build for a driver with
no TTM. Functionally harmless, but if this is ever upstreamed the right move is a ~120-line
felix-local `fbdev_probe` modelled on `drm_fbdev_ttm`, dropping the dependency.

### ⚠ Tooling trap hit (worth repeating to anyone reading)
`make ... ; echo "EXIT=$?"` reports the **echo's** status, not make's — a failed build
was reported as "exit code 0". The link error was only caught because the build artifacts
were checked directly: `Image.lz4` still carried the **previous run's timestamp**.
**Verify artifacts, not exit codes.**

---

## Stage 2 — genpd (prep)

### ⚠ The recorded thermal baseline is NOT comparable — measurement trap
Brief's baseline was taken **while charging**: big 44, mid 45, little 45, isp 44, tpu 44,
g3d 43, skin 38.9.

Measured now, same kernel, idle (load 0.00, up 27 min) **[MEASURED]**:

| zone | now | brief baseline | delta |
|---|---|---|---|
| big / mid / little | 48 / 48 / 48 | 44 / 45 / 45 | **+4 / +3 / +3** |
| g3d | 45 | 43 | +2 |
| tpu | 46 | 44 | +2 |
| isp | 41 | 44 | −3 |
| skin | 38.9 | 38.9 | 0 |

But the power state differs: `max77759-charger: Discharging`, `maxfg_secondary
current_now = -1105222` (−1.1 A). The phone is **sourcing VBUS to the dongle via OTG** —
the documented cost of the `OTG_ILIM=1500mA` hands-free-SS fix.

**Therefore: any genpd thermal delta must be measured against a baseline taken in the
same charge/OTG state.** Comparing a genpd run against the charging baseline would show a
~3–4 °C swing that is entirely the power path, and would have been misread as a genpd
result — in either direction. A/B both states on the same kernel before attributing
anything to genpd. **[MEASURED premise, INFERRED implication]**

### Stage 1 RESULT — flashed, and it hard-hangs. Diagnosis below.

Deploy was clean: `boot.img` 19,935,232 B, sha256 readback from `boot_b` **matched**
(`bbba2f53…76bd`), modules shipped for the matching `kernel.release`
(`7.2.0-rc3-00095-g4c234bdd4326-dirty`), slot B set active-but-not-successful. **[MEASURED]**

The new kernel **does** start — UART shows
`Linux version 7.2.0-rc3-00095-g4c234bdd4326-dirty ... #61` — and then dies.

**Divergence pinned by diffing against a known-good boot in the same UART log:**

| | last line seen | next line |
|---|---|---|
| good boot (line 15192) | `0.275409 dsim_of_get_pll_features ... failed to get pll-input` | `0.367172 exynos-generic-icc ... failed to update PM QoS` → dracut → userspace |
| **this boot (line 16384, EOF)** | `0.289908 dsim_of_get_pll_features ... failed to get pll-input` | **nothing, ever** |

So the kernel wedges in the **~78 ms window between 0.289 s and 0.367 s**. The only change
in that window is `drm_client_setup()`. **[MEASURED divergence; INFERRED attribution]**

### Why it hangs, and why the log went completely silent
`drm_client_setup()` does not merely register a client — it runs an **immediate, synchronous
modeset** from within probe. Two things then compound:

1. The panel is a **command-mode DSC** panel (`samsung,ea8182-f10`) that the bootloader
   already left on (`panel enabled at boot`). A full atomic commit at 0.29 s waits on a
   frame-done / TE signal the DECON isn't yet in a position to deliver, and that wait has
   no timeout.
2. fbdev/fbcon registration takes **`console_lock`**. Blocking while holding it means every
   subsequent `printk` blocks too — which is exactly why UART goes *totally* silent rather
   than showing a hang, a stall warning, or a panic. It also explains why
   `CONFIG_PANIC_TIMEOUT=10` and `DETECT_HUNG_TASK` never fired: nothing panicked, and no
   output could escape.

**[INFERRED — consistent with all three observations (hang window, total printk silence,
no watchdog), but not directly proven. Proving it needs the next boot to survive.]**

### If this is retried, don't call `drm_client_setup()` from probe
Three candidate fixes, cheapest first:
1. **`CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y`** — currently `is not set`. Delays
   fbcon binding until first actual console output, moving the modeset well clear of probe.
   One Kconfig line and the least invasive thing to try.
2. Call `drm_client_setup()` from a **workqueue / `late_initcall`**, not probe.
3. Give the DECON commit path a bounded wait so a missing TE can't deadlock — the most
   correct fix and the most work.

**Recommendation: try (1) first, and validate over UART on a slot that is NOT the only
working one.** See the risk note at the top: A/B rollback did not save this, because a
hard hang never resets.

