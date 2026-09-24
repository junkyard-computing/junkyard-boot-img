# felix "0xcfcd UVLO" is a DECON hard-lockup caused by a reaped SoC rail

**Status (2026-09-24): ROOT CAUSE FOUND AND FIXED.** Kernel commit **`c055c18c`**
(`arm64: dts: gs201-felix: keep S1S_VDD_CAM (buck1s) always-on`), on
`fix/gs201-bringup-power`. Validated 11/11 under a forced-late modeset that previously
failed 6/6. Track: mainline gs201/felix.

## TL;DR — read this first

- **The cause:** our DT let `regulator_init_complete()` reap the S2MPG13 **buck1s**
  (`S1S_VDD_CAM`) rail **~30 s into boot**, to save ~62 mW. AOSP keeps that rail
  `regulator-always-on` (`gs201-pmic.dtsi` BUCK1S, `subsys-name "Multimedia"`) — and the
  display pipe depends on it despite the CAM name. After the reap, the first DECON SFR
  access of any modeset **bus-stalls the CPU forever** → hard lockup → buddy-watchdog
  panic → software reset → bootloader prints **`0xcfcd - UVLO (IF-PMIC)`**.
- **The fix:** `regulator-always-on` on `buck1s` (`c055c18c`). Costs the ~62 mW the reap
  used to save. Don't take it back without finding the rail's real display-side consumer.
- **Why it hid for weeks:** the reboot reason says "UVLO", which sent effort after the
  charger/OTG/battery; then the stall *looked* like a clock idle-gate, which sent two weeks
  after CMU_DISP/CMU_TOP clock gating. It *is* a power problem — a SoC rail, not the cell,
  which is why the battery never drooped.
- **The one pattern that gave it away:** a modeset landing at **t15–25 always completed**,
  one at **t31+ always hung**. The reap fires ~t30. On UART there's no DHCP, so
  `NetworkManager-wait-online` pushes kmscon's modeset past the reap; with the dongle it
  usually lands before — hence "UART boots hang, dongle boots mostly don't".
- The runtime lockup (~t130–210, DRM self-refresh churn on the unclaimed inner panel) was
  fixed separately and earlier by disabling self-refresh (see below). It is very likely the
  same rail — every one of those commits came after the reap — but that fix predates this
  one and was not re-tested with self-refresh restored.

### Evidence

Modeset forced late with a 35 s `ExecStartPre=/bin/sleep 35` drop-in on
`kmsconvt@.service` (a **deterministic reproduction** — use this, not boot-luck):

| DTB | clock changes | late modesets | result |
|---|---|---|---|
| buck1s reaped | on (`#66`) | t31.7, t41 ×3, t61, t102 | **0/6** — all hard LOCKUP |
| buck1s always-on | on (`#66`) | t51.6, t60.9, t60.2, t122.8, t61.2, t121.8 | **6/6** |
| buck1s always-on | **off** (`#67`) | t61.3, t60.8, t61.4, t59.9, t60.1 | **5/5** |

The last row is the isolation: with `force_manual_clock_gate` and the CMU_TOP per-gate
exemption both switched off (log shows `force_manual=0`, no `manual gate` line), the rail
alone fixes it. Tell-tale log line when it's broken: `s2mpg13_buck1s_vdd_cam: disabling`
at ~t31, then any later `decon_enable +` never reaches `DECONDBG F`.

### What this means for the rest of this document

Everything below is the investigation that got here. Its **clock theories are superseded**:
the bootloader really does leave CMU_DISP global auto-gating armed (`CONTROLLER_OPTION
0xf1000000`, bit 28 set) and CMU_TOP's DISP branch really is under auto mode, and both
facts are real — but fixing them changed nothing, and fixing the rail alone fixes
everything. The experimental clock-gating kernel changes are **not committed**; a backup of
that WIP is at `kernel-wip-20260924.patch.bak`. The DTB/`vendor_boot` lesson, the
diagnosis playbook, and the rig notes all still apply.

Open question worth one experiment: `d1ef1531` (the CMU_DISP clock driver, committed) was
present in all 11 passing runs. It has not been shown to be necessary *or* unnecessary.

## How to recognise it

- Reboot-reason via `fastboot oem dmesg` shows `0xcfcd - UVLO (IF-PMIC)` **with
  `RST_STAT: 0x80 - SYSTEM_SWRESET_SYSTEM`** (a *software* reset). A real brownout shows
  `RST_STAT: 0xc0000 - PIN_RESET | PO_RESET`. The DSS block also shows all cores
  `(No Lockup)` and `linux debug info is not valid` because the cores lost time in a
  bus-stall, not a captured panic.
- On UART you see, live: `watchdog: CPUx: Watchdog detected hard LOCKUP on cpu y`, then
  `After 10 seconds, these CPUS still haven't responded to the NMI: y` (y is stuck below
  EL1 — the bus-stalled `readl`), then `Kernel panic - not syncing: Hard LOCKUP`.
- The wedged CPU varies (0/4/5/7). Modules loaded: panthor, edgetpu_gsa, gsa, trusty.

## Root cause

The DECON display-controller's register-access clocks live in **CMU_DISP**, which the
hardware **idle-gates via the Q-channel**. A DECON `readl` issued while that clock is
gated **stalls on the AXI bus forever** (the read transaction never completes; the CPU is
frozen inside the instruction with IRQs disabled → no NMI response → hard-lockup).

`clk/samsung` commit `d1ef1531` ("add CMU_DISP block to hold DECON clocks live") tries to
defeat this by exposing the CMU_DISP gates + the QCH `CLOCK_REQ` (bit 1) as
`CLK_IS_CRITICAL` with `auto_clock_gate=false`. **It reduces but does not eliminate** the
stalls — the block still idle-gates intermittently (~1 in many boots, and every
self-refresh cycle at runtime).

### ⚠ FIRST: d1ef1531 was INERT ON HARDWARE for two weeks (found 2026-09-12)

Before believing anything about the clock fixes below, check that the **DTB on the device
actually has the node**. It did not.

`d1ef1531` added `cmu_disp: clock-controller@1c200000` to `gs201.dtsi`. The DTB rides
**`vendor_boot.img`**, not `boot.img` — and `boot/vendor_boot.img` was dated **2026-08-26**,
five days *before* that commit. Every debug cycle flashed only `boot.img`, so the kernel and
the device tree drifted two weeks apart. Proof, three independent ways:

- `grep -a -c gs201-cmu-disp` on the unpacked on-device `vendor_boot` dtb → **0** (new one → 1).
- on the running device, `ls -d /proc/device-tree/clock-controller@*` → only `@10800000`,
  `@10c00000`, `@11000000`, `@14400000`, `@1e080000`. No `@1c200000`.
- instrumented `exynos_arm64_init_clocks()` printed **5** CMUs with the old DTB and **13**
  with the new one.

So the CMU_DISP driver never bound, `CLK_IS_CRITICAL` never held anything, and the only
thing keeping the DISP clock alive was DECON actively streaming. **Lesson: a DT-dependent
kernel fix is unverifiable until `vendor_boot` is reflashed; a kernel-only flash silently
tests nothing.** After flashing the new `vendor_boot`, the CMU_DISP markers appeared
immediately.

### Why d1ef1531 leaked — ROOT-CAUSED 2026-09-12, then CONFIRMED ON HARDWARE

Two facts in the generic samsung clk code, which together defeat it:

1. **Global CMU auto mode overrides every per-register HWACG bit.** This is stated in
   `drivers/clk/samsung/clk-exynos-arm64.c` at the `CMU_OPT_GLOBAL_EN_AUTO_GATING` write:
   *"This overrides the individual HWACG bits in each of the individual gate, mux and qch
   registers."* So holding `CLOCK_REQ` has **no effect** while global auto mode is armed.
2. **`auto_clock_gate = false` does not disarm it — it only declines to arm it.** Nothing
   ever *clears* `CONTROLLER_OPTION`, so CMU_DISP keeps whatever the **bootloader** left
   there, and the bootloader leaves global auto mode **on**.

There is a partial escape hatch: with `!init_auto`, `exynos_arm64_init_clocks()` sets
`GATE_MANUAL` (bit 20) on each register in `clk_regs`, which the in-tree comment notes
*does* override global auto mode. But it is guarded by `is_gate_reg()`, i.e.
`GATE_OFF_START..GATE_OFF_END` = **0x2000–0x2fff** — and the gs201 CMU_DISP **QCH_CON
registers live at 0x3008–0x3020**, outside that window. So:

- the DECON **gate** bits (0x2010 `AD_APB_DECON_MAIN` PCLKM, 0x2014 `DPUB` ACLK_DECON) *were*
  genuinely held — which is why `d1ef1531` could read back a live 399 MHz DECON clock;
- the DECON **Q-channel** (0x300c `QCH_CON_DPUB_QCH`) was **never** taken out of auto mode,
  so the hardware idle-gated DPUB anyway.

That is the whole discrepancy between "the clock reads 399 MHz and the bits are held" and
"a late modeset still AXI-hangs". **A register read-back proving a bit is set is not proof
the hardware honours it** — an overriding mode elsewhere can make a held bit inert.

**Fix:** new `samsung_cmu_info.force_manual_clock_gate` flag, set for CMU_DISP. It (a)
*clears* `OPT_EN_AUTO_GATING` et al. in `CONTROLLER_OPTION` instead of merely not setting
them, and (b) extends the `GATE_MANUAL` override to the QCH window (new `is_qch_reg()`,
0x3000–0x3fff), gated on the flag so no other platform's QCH behaviour changes. It logs the
pre-existing `CONTROLLER_OPTION` value, which confirms what the bootloader left.

**Measured on hardware once the DTB was fixed — the explanation is CONFIRMED:**

```
clock-controller@1c200000: CONTROLLER_OPTION 0xf1000000 -> 0x00000000
                           (forcing manual clock gating; auto_gating bit28 was SET)
clock-controller@1c200000: QCH +0x300c 0x003f0002 -> 0x003f0002
```

`0xf1000000` is exactly `CMU_OPT_GLOBAL_EN_AUTO_GATING` (bits 31/30/29/28/24) — the
bootloader really does leave global auto mode armed, so it really was overriding the held
bits. The QCH writes are correctly no-ops: `0x003f0002` already has `GATE_MANUAL` (bit 20)
set and `GATE_ENABLE_HWACG` (bit 28) clear.

**…and it is still NOT sufficient.** With CMU_DISP's auto mode provably cleared, a modeset at
t31.7 still hard-locked at the same instruction. So clearing it was necessary-but-not-enough.

### Next suspect: the same trap one level up, in CMU_TOP (UNTESTED)

CMU_DISP is fed by CMU_TOP's `CLK_DOUT_CMU_DISP_BUS`, and `exynos_arm64_enable_bus_clk()`
does `clk_prepare_enable()` on it — so the gate bit is held. But **CMU_TOP runs with
`auto_clock_gate = true`** (deliberately, for the ~407 mW idle win), which means:

- its global auto mode overrides its own per-gate HWACG bits, exactly as in CMU_DISP; and
- the `GATE_MANUAL` escape hatch is skipped for *all* of CMU_TOP, because the generic loop is
  guarded by `is_gate_reg(off) && !init_auto`.

So the DISP distribution branch (`CLK_CON_GAT_GATE_CLKCMU_DISP_BUS`, **0x2070**, bit 21,
flags 0) can be idle-gated by CMU_TOP no matter what CMU_DISP does. This also explains why
the hang predates the new DTB: CMU_TOP's auto mode was already armed.

Candidate fix, implemented but **not yet validated**: `samsung_cmu_info.manual_gate_regs[]`,
a per-gate exemption list applied unconditionally (so it reaches a CMU that *is* in auto
mode), set to `{ CLK_CON_GAT_GATE_CLKCMU_DISP_BUS }` for `top_cmu_info_gs201`. Surgical on
purpose: CMU_TOP keeps HWACG on every other branch, so the idle-power win survives.

## The two triggers

### Runtime (FIXED)

The inner ana6707 panel is **command-mode and unclaimed** — no DRM/fbdev client modesets
it, so at t≈21 s the driver logs `no modeset claimed the panel 20000ms after handoff;
blanking it`. Because it's command-mode, `panel-samsung-drv.c` sets
`connector_state->self_refresh_aware = true`, so the generic **`drm_self_refresh_helper`**
cycles it: periodic **plane-less atomic commits** → DECON register access → CMU_DISP
idle-gate stall → hard-lockup at ~t130–210 s.

**Fix applied:** force `connector_state->self_refresh_aware = false` in
`panel-samsung-drv.c` (see `exynos_drm_connector_atomic_check`, the line
`connector_state->self_refresh_aware = !is_video_mode;`). With self-refresh off,
`plane-less update` count drops to **0** and the device runs clean through the entire
former hang window (validated to 300 s+). This is a **workaround** (it disables a
power-saving feature); the durable fix is to actually drive the inner panel with a DRM
client (fbdev), or to fully defeat the CMU_DISP idle-gate.

### Boot (root-caused 2026-09-12; fix built, awaiting hardware validation)

At boot, the bootloader hands DECON0 off running (`DECON_STATE_INIT`); the kernel stops it
before re-enabling. `decon_enable` → (INIT branch) `_decon_stop_locked` → `decon_reg_stop`
→ `decon_reg_stop_perframe_dsi` issues a `readl` on DECON regs **under `spin_lock_irqsave`
(IRQs off)**. Intermittently that `readl` hits the idle-gated block and hard-locks the CPU.
Pinned with instrumentation to exactly between markers **`DECONDBG D2 stop_locked (INIT)`**
and **`DECONDBG E pre _decon_enable_locked`**; with finer markers, to the
`decon_reg_set_win_enable` read-modify-write at the head of `_decon_reinit_locked`.

**Timing threshold (the key evidence).** A modeset at **t15–25 s completes**; one at
**t40–83 s stalls**. On UART there is no network, so kmscon waits on
`NetworkManager-wait-online` and the modeset always lands t40+ — which is why *UART* boots
hang near-deterministically while dongle boots are intermittent.

**What makes t40 different from t20 — and it is not elapsed time.** At t≈20 s the panel
handoff timer fires (`no modeset claimed the panel 20000ms after handoff; blanking it`) and
asserts the panel **reset** gpio. The inner ana6707 is a **command-mode** panel, so DECON0's
frame start is driven by the panel's **TE** signal. Killing the panel stops TE → DECON0
stops issuing frames → DECON0's `QACTIVE` to CMU_DISP deasserts → the DISP clock idle-gates
→ the next DECON SFR access bus-stalls. Before the blank, DECON0 is still streaming from
the bootloader handoff, holds QACTIVE high, and the clock cannot gate. That predicts
exactly the observed t15–25-OK / t40+-hang split.

**The TE/QACTIVE theory above is FALSIFIED — do not re-chase it.** Bumping
`EXYNOS_PANEL_HANDOFF_TIMEOUT_MS` to 120000 did produce one clean boot under the
previously-hanging condition, which looked like confirmation. It was the coin flip. Two
follow-ups killed it:

- that same boot **hard-locked ~8 minutes later** when the blank finally fired, and
- a build that **never arms the blank at all** (`if (false && …)`, no `blanking it` in the
  log) still hard-locked at t41, at the identical instruction.

So asserting the panel reset is not what gates the clock. If anything quiesces DECON it is
more likely the panel/DSIM driver probe around t21 reconfiguring the link. **One clean boot
is not evidence here** — this bug has now produced three false positives (pKVM, handoff-120s,
and an un-drained UART buffer that replayed a previous boot's success as if it were current).

### The timing threshold, measured

| modeset at | outcome |
|---|---|
| t15.8 | completes (`DECONDBG E → 01…12 → F → decon_enable -`) |
| t23.7 | completes |
| t25.3 | completes |
| t31.7 | **hard lockup** |
| t41.1 / t41.5 / t102 | **hard lockup** |

The boundary sits around **t25–31**, and it is the single best predictor of a hung boot. On
UART there is no DHCP, so `NetworkManager-wait-online` pushes the modeset past it almost
every time; with the dongle in, boots land in the safe window and succeed.

## Ruled out (do not re-chase)

- **Charger / OTG-boost inrush / VSYS / S2MPG13 / cell-droop** — all chased for weeks
  against the `0xcfcd` reboot-reason. It's a mislabel; measured cell holds ~4.16–4.28 V,
  reset is `SYSTEM_SWRESET` (software). The OTG-boost soft-start fixes in HEAD may still be
  valid for a *separate* real OTG UVLO, but the residual "UVLO" is this hard-lockup.
- **pKVM (`kvm-arm.mode=protected`)** — hypothesis was that `nvhe` leaves BL31's CMU lock
  on so the d1ef1531 clock-hold is ineffective. **Tested and disproven:** under pKVM the
  boot `decon_reg_stop` hang still fires (first boot cleared it by luck; the very next
  reboot hung at the identical spot). pKVM also appears to break the edgetpu GSA firmware
  bring-up. Stay on `nvhe`.
- **TPU / pd_tpu genpd gating** — re-enabling `pd_tpu` (status=okay + edgetpu phandle)
  causes a *different* hard-lockup at the late_initcall reap; the DT deliberately keeps
  pd_tpu out of genpd. Unrelated to this bug.
- **DECON's own internal auto-CG (gate #1)** — `decon_reg_set_clkgate_mode(id, 0)`
  (`CLOCK_CON` AUTO_CG/QACTIVE). Called at `decon_probe`, at `decon_reg_stop`, and at the top
  of `_decon_reinit_locked`; the hang persists at the *identical* spot every time. It cannot
  work, and the reason is instructive: the `clkgate_mode` write is **posted**, so it returns
  and its marker prints, while the very next *read*-modify-write (`decon_reg_set_win_enable`)
  stalls. No DECON-side register write can fix a clock gated *externally* by CMU_DISP.
  Distinguish carefully: **gate #1** = DECON's internal auto-CG (ruled out), **gate #2** =
  the CMU_DISP block clock idle-gate (the actual cause).
- **Making the modeset earlier via the kernel cmdline** —
  `systemd.mask=NetworkManager-wait-online.service` appended to the boot cmdline. Tested
  2026-09-12: still hung, same `RST_STAT 0x80`. Masking the wait does not move the modeset
  early enough to beat the t20 panel blank.

## Diagnosis playbook (how this was found, how to reproduce)

- **Transport:** `uartd` on the host FTDI (`/dev/ttyUSB0 @ 115200`); felix AP-UART must be
  enabled first with `fastboot oem uart enable` (NB: `fastboot oem uart list` WEDGES the
  bootloader — never run it). `uart login --user kalm --password 0000`, then `uart run`.
- **Instrumented kernel:** add `DECONDBG` prints through `decon_enable` /
  `decon_reg_init` / `decon_disable` (and `UFSDBG` in the UFS err-handler). Build the
  built-in DRM (`DRM_SAMSUNG_FELIX=y`) — the driver is a `.ko` composite linked into
  vmlinux, so it rides `boot.img`; verify markers landed with **`grep -a` on `out/vmlinux`**
  (`strings` is NOT in the nix dev shell — it silently returns 0 and misleads you). The
  markers are `pr_info`/`decon_info` (level ≥ 4, so filtered by the cmdline `loglevel=4`);
  they still appear because the watchdog panic does `console_verbose()` +
  `console_flush_on_panic()` and dumps the ring buffer. To see them live, set
  `kernel.printk=8` early (a `/etc/sysctl.d` drop-in applies at ~t8, before the ~t20 decon).
- **Signature:** the last DECONDBG marker before the `Watchdog detected hard LOCKUP`
  pins the exact stalling sub-call.
- **Operational hazard:** repeated hangs decrement the A/B retry counter and the device
  **parks in fastboot** (retry-park safety) — on the UART rig that means it's unreachable
  (fastboot = USB) until the cable is moved and `fastboot set_active <slot>` resets it.
  Do **NOT** `pixel-bootctl mark-successful` on an untended, no-charge (UART) unit — that
  defeats the park and a hang-loop drains it to death. (Lost a unit to this once.)

## Next steps

1. **Validate `force_manual_clock_gate` on hardware.** Flash, boot on USB with no network
   (the reliably-hanging condition), and check the console/`dmesg` for
   `CONTROLLER_OPTION=0x…  -> forcing manual clock gating`. The logged value is itself the
   proof of what the bootloader left armed: if `OPT_EN_AUTO_GATING` (bit 28) is **set** in
   it, the leak explanation is confirmed outright.
2. **Soak it.** One boot proves nothing here — this bug is a coin flip and two clean boots
   have misled us before. Run ≥10 reboots.
3. **Durable runtime fix** — drive the inner panel with a DRM/fbdev client so it isn't
   left unclaimed, which removes the self-refresh churn *and* keeps DECON's QACTIVE
   asserted, addressing both triggers at the source. No `feature/mainline-fbcon-*` branch
   survives; rebuild per memory `project_fbcon_hangs_felix` (select `DRM_CLIENT_SELECTION`
   + `DRM_TTM_HELPER`, GEM `->vmap`, `DRM_FBDEV_TTM_DRIVER_OPS`, **deferred**
   `drm_client_setup()`, `cma=128M`, `.dirty = drm_atomic_helper_dirtyfb`).
4. Consider reverting `0aa178ed` ("hold VSYS in BUCK … [UNVALIDATED]") — written under the
   now-disproven power framing.

### Host-rig notes worth keeping

- **`lsusb` is not on this host's `$PATH`** (same class of trap as `strings` missing in the
  nix shell — it silently broke a boot-detection harness into never reporting success).
  Enumerate `/sys/bus/usb/devices/*/idVendor` instead.
- **Boot success can be classified with no console at all**, which matters because UART and
  USB are mutually exclusive and UART cannot charge: reboot from fastboot, then watch for
  USB gadget `18d1:d001` in sysfs (⇒ userspace reached) versus the device reappearing in
  fastboot (⇒ panic loop burned its A/B retries). This runs on USB, so the battery
  **charges** throughout — prefer it over UART for rate-measurement soaks.
- **SSH over the USB-Ethernet dongle is the best channel by far** — and the device is at
  **192.168.1.139**, reachable with the **`~/.ssh/junkyard-fleet`** key (the default keys are
  rejected). ⚠ `192.168.1.138` is **this build host's own wifi address** — an older note
  claiming ".138 = mainline" is stale, and probing it yields a misleading "alive" + a
  "Permission denied (publickey)" from the host itself. Always check
  `ip -br addr | grep <ip>` before trusting a remembered address.
- With that shell, partitions can be written **straight over the network**, which removes the
  whole fastboot cable dance (UART ⊥ USB means each fastboot flash otherwise costs two cable
  moves):
  `cat boot.img | ssh … 'sudo dd of=/dev/disk/by-partlabel/boot_a bs=1M conv=fsync'`
  then verify with a length-limited readback:
  `sudo dd if=… bs=1M count=<bytes> iflag=count_bytes | sha256sum`.
  `boot_a` = `/dev/sda10`, `vendor_boot_a` = `/dev/sda12`, both 64 MiB.
- **The rootfs is 100 % full** (3.8 G, with `/usr` alone 3.2 G — 2.6 G of `/usr/lib` plus
  `/opt/mesa-g710`). Not a runaway log: the image simply outgrew the partition. It means no
  room to stage an image on `/`, and `journalctl --vacuum` frees nothing (journal is in
  `/run`). Stream to the partition instead, and consider bumping `SIZE`.
- Earlier claim that the phone's `dnsmasq` "isn't serving" on the gadget was **wrong** — the
  mainline image does ship `usb_gadget` enabled with `--dhcp-range=10.42.0.10,10.42.0.100`.
  The gadget link had no address because nothing on the *host* ran a DHCP client on it (the
  interface never even appeared in `nmcli device`) and the phone only stayed up ~50 s.
- ⚠ **Reseating the UART adapter invalidates uartd's file descriptor.** The FT232R
  re-enumerates (`/dev/ttyUSB0` gets a new mtime) and uartd keeps reporting
  `connected=true` while reading nothing, forever. **Restart uartd after any replug.**
  Launch it with `setsid nohup ./target/release/uartd --config run/uartd-felix.toml … &
  disown` — a plain backgrounded launch from the tool shell gets killed with it (exit 144).
- ⚠ **`buffer=0B` and a failed ping do not mean the device is dark.** An idle device at a
  login prompt emits nothing. Probe positively (`uart run`, or bootloader output across a
  reboot — that one is unconditional when the mux is armed).
- **Reboot experiments with `sync; echo b > /proc/sysrq-trigger`**, not `systemctl
  reboot`. With the rail bug present, the DRM teardown in a normal shutdown could hit the
  same stall and wedge the device with no reset and no output (it did, twice); sysrq-b
  skips teardown. Enable first with `echo 1 > /proc/sys/kernel/sysrq`.
- ⚠ **Drain the uartd buffer before a reboot you intend to measure.** `uart read` returns
  everything since the last read, so a capture started after issuing the reboot replays the
  *previous* boot — which once made a stale success look like the new kernel's. Anchor on a
  fresh `Booting Linux`, and confirm the `#<build>` in the live `Linux version` line.
- `netcheck-recover` commits the slot on a good boot (`network proven — slot committed`),
  which **disarms the retry-park** that is the only automatic route back to fastboot. For
  experiments: `touch /etc/netcheck-recover.disable`, and re-arm with
  `pixel-bootctl set-active-slot a` (marks active, NOT successful, retry 7).

See also memory notes: `project_felix_uvlo_is_decon_hardlockup`,
`project_felix_decon_enable_boot_loop`, `project_pkvm_cmu_unlock`.
