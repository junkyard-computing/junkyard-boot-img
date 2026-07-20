# ✅ UPDATE (morning 2026-07-20) — RECOVERED + edgetpu fix VALIDATED

The device was recovered (fastboot-flashed `boot_b` with the known-good kernel; back on SSH
in ~16s) and now runs the **validated** edgetpu fix on slot B, marked successful.
**Headline: the Edge TPU firmware reached RUNNING + KCI FW_INFO for the first time on
mainline** — before/after numbers in "Stage 3 — VALIDATION UPDATE" at the bottom. The fbcon
hang mechanism was also corrected: it is NOT the "TE-forever" wait first claimed — see
"fbcon — CORRECTED mechanism" at the bottom. The banner below is the original incident
report, kept for the record.

---

# ⛔ ORIGINAL INCIDENT REPORT — the phone hard-hung (since recovered)

**State at the time: felix hard-hung in early kernel init, unrecoverable without hands.**
It stopped responding at **00:06 on 2026-07-20**. Not pingable, no SSH, no UART console
(the link was fine — `uartd` still reported `connected=true` — the *device* was wedged).

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

---

## Stage 2 — genpd: code-verified, BLOCKED on hardware

Could not be flashed or measured (device down). What was established without it:

**The safety property holds structurally, not just by convention.** On
`feature/mainline-genpd-proven11` the domains that must never be gated —
`hsi0` (USB), `hsi2` (UFS/rootfs), `g3d`, `embedded_g3d`, `aoc`, `eh` — are **not
declared as `google,gs201-pd` nodes at all**. They aren't merely disabled; there is
no provider for them, so `genpd_power_off_unused()` cannot reach them even in
principle. **[MEASURED — grep over the branch's DTS returns nothing]**

16 domain nodes are declared; 5 carry `status = "disabled"`: `dpu` (0x2200),
`disp` (0x2280), `g2d` (0x2300), `bo` (0x2880), `tpu` (0x2900). The remaining
**11 are exactly the proven set**: mfc, csis, pdp, dns, g3aa, ipp, itp, mcsc,
gdc, tnr, aur. Matches the intent. **[MEASURED]**

**Ready to flash as-is once the device is back**, with the thermal-comparison caveat
above: baseline and test must be taken in the same charge/OTG state.

**One thing Stage 3 changes about Stage 2:** `pd_tpu` is currently disabled because
gating it crashed edgetpu. We now know edgetpu **was already failing for an
unrelated reason** (the Trusty race), so the old "gating pd_tpu crash-loops
edgetpu" conclusion was drawn against a driver that never worked. It should be
re-tested on top of the edgetpu fix before `pd_tpu` is written off — the TPU zone
is the single biggest thermal contributor (~6 °C). **[INFERRED]**

---

## Stage 4 — GPU performance: the brief's premise is out of date

No benchmarking possible (device down), but the desk work materially changes the plan.

**The brief names "the clpeak register-light 548-vs-730 gap" as the next lever.
`docs/gpu-perf-investigation.md` already answers it, and the answer is that the
gap is largely a benchmark artifact.** With hand-tuned ILP, panfrost reaches
**637 GFLOPS = 87 % of the closed compiler's 730** on the same silicon at the same
clock. clpeak's 548 simply **under-provisions ILP for Valhall**; it is not
measuring a 25 % compiler deficit. The real residual is **~13–20 %**. **[MEASURED,
previously]**

**And the one remaining lever is now dead.** That doc lists register-pressure-aware
unrolling as "the only non-dead lever, not yet tractable". It has since been
implemented and falsified: it fires correctly but yields **zero speedup**, because
the rolled form is already FMA-saturated. So every identified lever is now closed:

| lever | verdict |
|---|---|
| MIF interconnect coupling | **shipped** |
| `PAN_PRESSURE_UNROLL` | **shipped** (~2× prefill on `[[unroll]]` shaders) |
| gpu_id normalization | **shipped** (without it the open stack doesn't run at all) |
| spiller remat | **shipped** (+1.6 % prefill, token-identical) |
| `PAN_HOIST_LOADS` | dead — throughput-bound, not latency-bound |
| raise unroll limit 32→128 | dead — net loss (prefill −64 %) |
| pressure-aware unrolling | **dead — premise falsified, zero speedup** |

**Honest conclusion for discussion: the open-vs-closed GPU gap is at a
hardware-bounded wall, not a to-do item.** Everything traces to the **64-register
file**: it caps FMA ILP (spill at ~33 accumulators), forces the llama GEMM tile
(128 accumulators) to spill, and makes unroll policy zero-sum. Closing the last
13–20 % means matching the closed compiler's spill/schedule co-design without
access to it — that is a compiler-research programme, not a tuning task.

**Recommendation: stop treating the residual as a bug to fix.** The defensible
framing is "open stack reaches 87 % of proprietary peak and is token-identical on
llama", which is a result worth presenting rather than a gap worth chasing. If GPU
effort continues, the higher-yield direction is PanVK/Vulkan breadth (the
prefill-at-scale hang, issue #30) rather than more FMA tuning. **[INFERRED from
the measured lever table]**

---

# Summary for the PI discussion

## The one-line version
The headline result is **not** fbcon — it's that **the Edge TPU has never actually
booted on this platform**, for a reason that is now root-caused to an ~80 ms
probe-order race and has a written fix. The fbcon detour failed and cost the device
a power-cycle.

## Per stage

| stage | outcome | evidence |
|---|---|---|
| 1. fbcon | **Failed.** Root-caused twice over, patch written, flashed, hard-hangs at t=0.289 s. Device needs fastboot recovery. | UART divergence vs a known-good boot in the same log |
| 2. genpd | **Blocked on hardware.** Branch code-verified: unsafe domains aren't declarable; the 11 gated are the proven set. | grep over branch DTS |
| 3. TPU/GPU power | **★ Root-caused + fixed (unvalidated).** TPU never came up; 3-part fix committed and pushed. | boot timestamps; rmmod/modprobe control |
| 4. GPU perf | **Premise out of date.** The named lever is a benchmark artifact; every identified lever is now closed. | existing measurements re-read |

## Three findings worth presenting

1. **The TPU was never working, and "the device node exists" was never evidence.**
   `/dev/accel/accel0` registers whether or not firmware bring-up succeeds. Every
   previous "TPU is live" claim rested on that node plus a loaded module. The actual
   bring-up fails on every cold boot because edgetpu probes ~80 ms before
   `trusty_ipc` comes online. A contributing cause is a **diagnostic** bug: GSA
   flattened `-ENOENT`, `-ENODEV`, `-ETIMEDOUT` and connect failures all into
   `-EIO`, so the race was indistinguishable from a hardware fault. Fixing the error
   propagation is what made it findable.

2. **A/B rollback does not protect against a hard early-init hang.** Slot B was
   deliberately flashed *active-but-not-successful* so a slot that never reaches
   userspace would fall back to AOSP. That assumes the device **resets** so the
   bootloader can decrement the retry counter. This hang deadlocks with
   `console_lock` held — no panic, no watchdog, no output, no reset — so the counter
   never moves and the protection never engages. **Display-path changes need a
   different safety net than boot-chain changes.**

3. **The open GPU stack is at a hardware wall, not a backlog item.** Panfrost reaches
   87 % of the proprietary compiler's FMA peak on identical silicon; the widely-quoted
   "548 vs 730" understates it because clpeak under-provisions ILP for Valhall. Every
   lever with a plausible mechanism has now been tested and closed, the last one
   (pressure-aware unrolling) falsified outright. The remaining 13–20 % traces to the
   64-register file. This is a result to present, not a gap to chase.

## Method notes (things that cost real time)
- **Verify artifacts, not exit codes.** `make …; echo "EXIT=$?"` reported success for
  a build that failed to link; caught only because `Image.lz4` kept its old timestamp.
- **"Config didn't take" often means the symbol has no prompt.** Two separate
  Kconfig lines in this repo have now been silently overridden this way.
- **Hold the power state constant when comparing thermals.** The recorded baseline was
  taken while charging; the device now idles ~3–4 °C hotter purely because it sources
  VBUS for the dongle. That alone is the size of the effect genpd is meant to produce.
- **Diff a failing boot against a good boot in the same log.** Pinned the fbcon hang to
  a 78 ms window in one step; no bisect needed.

## What I'd do next, in order
1. **Recover the device** (`/home/chris/felix-recovery/RECOVER.sh`, ~30 s).
2. **Validate the edgetpu fix** — highest value, and the change can't affect networking
   or the display, so it's low-risk to flash. If it works, the TPU boots for the first
   time.
3. **Re-test `pd_tpu` gating on top of it** — the old "it crashes edgetpu" verdict was
   measured against a driver that never worked, and the TPU zone is the biggest single
   thermal contributor.
4. **Then genpd proven-11**, with a same-power-state thermal baseline.
5. **fbcon only if it's actually wanted** — try
   `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y` first, and validate on a slot
   that isn't the only working one. kmscon works today; this is a cosmetic win with a
   demonstrated ability to brick.

## Commits (all pushed)
- kernel `feature/mainline-edgetpu-probe-race` @ `11d2bb0e` — the TPU fix.
- kernel `feature/mainline-fbcon-KNOWN-BAD` @ `9ba00eea` — quarantined; **do not flash**.
- boot-img `859a672` — removes the inert Kconfig line, adds this document.
- Deployed branch `feature/mainline-otg-ss` @ `4c234bd` untouched; held WIP untouched.
---

# Stage 3 — VALIDATION UPDATE (morning 2026-07-20, device recovered)

The edgetpu fix is **validated on hardware**. The TPU firmware runs on mainline for the
first time. All **[MEASURED]** from `.138` dmesg.

## Recovery first
Fastboot-flashed `boot_b` with `/home/chris/felix-recovery/boot-known-good.img` (the exact
pre-experiment kernel). Back on SSH in ~16s, 10.2s boot, `running` (not degraded). Battery
in fastboot read **3826 mV / soc-ok** — the 8-hour wedge deep-drained it but did no damage.

## The fix needed a second iteration — validation caught it
- **v1** returned `EPROBE_DEFER` from `firmware_bringup()`. Flashed → **no retry happened**.
  `probe()` swallows bring-up errors (logs, registers the accel node, returns `Ok`), so the
  core never saw a defer. Only `EPROBE_DEFER` from `probe()` *itself* triggers a re-probe.
  This is the same "accel node registers regardless" property that hid the original bug —
  it also hid the fix's failure until it was measured.
- **v2** (shipped) gates on GSA/Trusty reachability as the **first statement of `probe()`**,
  before any resource. Placement is load-bearing: `Clk::prepare_enable()` takes no guard and
  `Clk`'s Drop only `clk_put`s (not `clk_disable_unprepare`, rust/kernel/clk.rs:254), so
  deferring after the clock is enabled would leak an enable-ref per retry.

## Before → after (measured)
| | dmesg |
|---|---|
| **before** (known-good kernel) | `[8.0517] GSA GET_STATE failed: EIO → bring-up failed: EIO` / `[8.0645] trusty_ipc is online` (13 ms too late) |
| **after** (`4bcd83d`) | `[7.8535] deferring probe` → `[7.8555] trusty_ipc online` → `[7.8569] gsa hwmgr.tpu connected` → `[7.8689] TPU firmware RUNNING (state 2)` → `[7.9245] KCI FW_INFO ok fw_flavor=3` → `M2 bring-up complete` |

`/dev/accel/accel0` live; the qos `already added request` WARN count is **0** (idempotency
fix confirmed); slot B **marked successful**. Kernel branch
`feature/mainline-edgetpu-probe-race` @ `4bcd83d`, pushed.

## One unrelated pre-existing WARN found (not mine)
At **t=0.37s**, before edgetpu loads: `WARNING qos.c:415 __dev_pm_qos_update_request`, trace
`exynos_generic_icc_set → icc_node_add → exynos_generic_icc_probe → exynos_bus_probe`. The
Exynos interconnect provider updates a dev_pm_qos request that isn't active yet. Harmless so
far, worth a separate fix. **[MEASURED]**

---

# fbcon — CORRECTED mechanism (earlier "TE-forever" was WRONG)

The Stage-1 write-up above says the commit "waits on a frame-done/TE with no timeout." **That
is disproven by the code.** Every wait in the felix DPU driver is timeout-bounded (fences
250ms, deps 10s, flip-done frame+100ms/10s, framedone `wait_event_timeout`); a `grep` for
untimed waits across decon/crtc/dsim returns nothing. A bounded wait times out and *prints* —
it cannot cause 8 hours of silence.

Actual mechanism (from a full static trace):
1. `drm_client_register()` runs the fbdev hotplug **synchronously, inline** (drm_client.c:143).
2. The initial modeset commits from inside `fbcon_init` → `fb_set_par`, **holding
   `console_lock`** (fbcon.c:3002); felix runs `commit_tail` **inline in that thread**.
3. Because the bootloader left the panel on, DECON is in **`DECON_STATE_HANDOVER`**, so
   `decon_enable` runs `_decon_reinit_locked()` + `_decon_enable_locked()` **under
   `spin_lock_irqsave(&decon->slock)` — IRQs disabled** (decon.c:1655-1665).

So a forced modeset re-inits the display controller from the bootloader handover state at
t=0.289s, with **both IRQs disabled and `console_lock` held**. The wedge is inside that
register sequence (the `cal_9845/9855` CAL layer) — a bus-stuck SFR or a busy-poll — and the
context makes it fatal+silent: IRQs off → watchdog IRQ can't fire (and isn't armed that early)
→ **no reset/rollback**; console_lock held → **no printk escapes**; a stuck bus/poll, not a
timed wait → **no timeout saves it**. kmscon survives because it modesets from userspace
seconds later, after boot settles — same code, very different surrounding state.

**Not fully pinned (needs device):** the exact CAL-layer instruction and what about t=0.289s
differs from kmscon's later modeset. Decide with earlycon writes bisecting the reinit — **not**
netconsole (IRQs are off). Fix direction: never trigger a DECON re-init from IRQ-disabled early
probe; `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y` achieves that incidentally and is the
cheapest thing to try — on a slot that isn't the only working one.
