# gs201 SoC power-domain gating + deeper CPUIdle — scoping

**Goal:** cut felix **idle heat** (autonomy Blocker #2). The idle-heat root causes we
identified are (1) no SoC power-domain gating — `gs201.dtsi` defines **zero** power
domains, so idle SoC blocks never gate off — and (2) **core-only CPUIdle** — the CPUs
power-gate per-core but the cluster/SoC never drops into deeper idle. This doc scopes
both. (DVFS half of idle heat is already done + shipped: ACPM cpufreq + MIF devfreq on
`felix-7.2-rc3`.)

## Current mainline state (felix-7.2-rc3)

- **Power domains: none.** `gs201.dtsi` has only TODO comments ("add power-domains once
  a GS201 pmdomain driver exists"; "ACPM/EL3 pd_dpu power-on"). No genpd, no `pd_*`
  nodes, no consumer `power-domains=` links.
- **GPU is already implicitly gated:** the `gpu@28000000` node is powered by enabling
  its **ACPM DVFS clock** (`&acpm_ipc GS201_CLK_ACPM_DVFS_G3D`); ACPM drops the g3d
  domain when the clock is disabled. So `pd_g3d` needs no genpd — clock gating covers it.
- **CPUIdle: core-only PSCI.** Each CPU has one `cpu-idle-states` (`ananke_cpu_sleep` /
  `hercules_cpu_sleep` / `hera_cpu_sleep`), `entry-method="arm,psci"`. No cluster-power-
  down or system-idle (SICD) states.
- Mainline `drivers/pmdomain/samsung/exynos-pm-domains.c` exists but is **unusable here**:
  it pokes PMU registers directly (`writel(base)`, poll `base+0x4`, compat exynos4210/
  5433-pd). Tensor doesn't gate domains that way.

## Mechanism (from AOSP reference)

AOSP gs201 has **22 power domains** (`private/devices/google/gs201/dts/
gs201-pm-domains.dtsi`): pd_aoc, pd_eh, pd_g3d, pd_embedded_g3d, pd_hsi0, pd_hsi2,
pd_disp, pd_dpu, pd_g2d, pd_mfc, pd_csis, pd_pdp, pd_g3aa, pd_ipp, pd_itp, pd_dns,
pd_bo, pd_tnr, … Each node carries `cal_id` (e.g. g3d `0xB1380007`) and `need_smc`
(e.g. g3d `0x27F10204`).

Control path: `exynos-pd.c` genpd (`genpd_power_on/off`) → `cal_pd_control(cal_pdid,on)`
→ `pmucal_local_enable/disable(index)`, which:
1. runs a **pmucal/FlexPMU register sequence** (`pmucal_rae_handle_seq`) — the actual
   power on/off register pokes (tables in `cal-if/gs201/flexpmu_cal_*_gs201.h`);
2. if `need_smc`, issues a **DTZPC EL3 SMC** (`exynos_pd_tz_restore(need_smc)`) — only to
   restore TrustZone/DTZPC secure-access config after the block powers on;
3. runs a register restore sequence.

So it is **register-sequence-driven (pmucal/FlexPMU), not ACPM-message-driven and not
pure-SMC.** And the PMU registers those sequences touch are **EL3/pKVM-gated** (same wall
as our CMU-unlock finding — BL31 only opens CMU/PMU when EL2 is pKVM; we already boot
`kvm-arm.mode=protected`, so this *should* be reachable, but it's unverified for the PD
register block at 0x18061xxx/0x18062xxx).

## Port weight

Faithful AOSP port = heavy: the FlexPMU cal tables (`cal-if/gs201/flexpmu_cal_local_
gs201.h` + `_p2vmap_` + `_define_`), the pmucal RAE engine (`pmucal-rae.c`),
`pmucal_local.c` (277 lines), `cal-if.c`, the DTZPC SMC path, `exynos-pd.c` genpd, and
the 22-domain DT. That's the whole cal-if/pmucal stack — the same stack the ACPM clock
work already partially leans on, so some scaffolding may exist to reuse.

## Diagnose FIRST (do before writing any code — needs `.138` up)

The port only pays off if unused blocks are actually **ON at idle** on mainline. With no
genpd, each domain sits in whatever state the bootloader/FlexPMU left it. Check on the
running mainline:
- Read PD status registers (STATUS bits in the 0x18061xxx/0x18062xxx block via
  `/dev/mem`/devmem if EL-accessible, or the FlexPMU status path) for the **compute-
  irrelevant** domains: **pd_csis, pd_pdp, pd_ipp, pd_itp, pd_dns, pd_g3aa, pd_mfc,
  pd_g2d, pd_bo, pd_tnr** (camera/imaging/video — a headless compute felix never uses).
- Compare idle rail power against the `.108` AOSP ODPM oracle (memory:
  no ODPM on mainline, so `.108` is the reference for how much these blocks draw).
- If those domains are OFF already → power-domain gating buys ~nothing for idle heat;
  pivot effort to CPUIdle. If ON → they're pure idle waste and gating is the win.

## Two levers, recommended order

**Lever B first — deeper CPUIdle (lighter, DT-mostly):** add cluster-power-down + SICD
idle-state nodes with the AOSP gs201 PSCI `arm,psci-suspend-param` values, wire
`cpu-idle-states` to include them. Relies on stock BL31/PSCI already implementing those
states (AOSP uses them). Risk: wrong suspend-param → idle-entry hang/instability →
needs careful validation on a thermally-fragile, sometimes-wedging device (keep tests
short). Payoff: SoC/cluster drops to low-power when all cores idle — directly targets
idle heat, and no secure-register porting.

**Lever A — power-domain gating (bigger, heavier):** don't port all 22 domains or full
dynamic genpd first. Minimal high-value slice = **power OFF the never-used imaging/video
domains once at boot**. Two ways:
  1. small init that runs the pmucal *off* sequence + DTZPC SMC for those ~8-10 domains
     (still needs their FlexPMU off-tables + RAE), or
  2. full `exynos-pd` genpd for those domains only — genpd auto-powers-off domains with
     no consumers at late_initcall, which is exactly the "turn off unused blocks"
     behavior, and scales cleanly if we later add consumers (dpu/disp for display).
  Option 2 is more code up front but is the idiomatic, upstreamable path.

## Open risks / unknowns
- PD register block (0x18061xxx/0x18062xxx) reachability under our pKVM boot — unverified.
- Whether FlexPMU firmware on stock felix BL/PMU accepts the sequences identically on
  mainline (it should — same silicon/firmware — but untested).
- Deeper-CPUIdle suspend-params must exactly match what BL31 implements, or idle wedges.
- Device is DOWN (needs power-cycle); all HW validation blocked until it's back, and it
  wedges under sustained load — keep every validation pass short.

## DIAGNOSIS RESULT (2026-07-14, felix .138 @ 7.2.0-rc3)

**Every power domain is ON at idle.** Read the PD STATUS registers directly via
`busybox devmem` (STRICT_DEVMEM is off; PMU at 0x18060000-0x1806ffff; status reg =
domain `reg` base + 0x4, bit0=1 => ON — offsets cross-checked against AOSP
`flexpmu_cal_local_gs201.h` `*_status[]` sequences). All 20 domains read `0x1`:

  eh, g3d, embedded_g3d, hsi0, disp, dpu, g2d, **mfc, csis, pdp, dns, g3aa, ipp,
  itp, mcsc, gdc, tnr, bo, tpu, aur** — the 11+ bolded imaging/video + TPU + AUR
  blocks are never used on a headless compute felix.

So the "unused blocks are wasting power at idle" premise is **confirmed** — with no
genpd, whatever FlexPMU/the bootloader left on stays on forever. Lever A has a real
target. (g3d also reads ON at idle despite the "ACPM clock-gates g3d" assumption in
the mainline-state section above — ACPM leaves the *domain* on and only gates clocks;
worth revisiting, but g3d is used, so it's not the idle-waste story. Focus is the
camera/video/TPU/AUR cluster.)

### Measurement gap found — on-die TMU can't see the gating win
Wired the two spare on-die TMU sensors as diagnostic thermal-zones (ISP=4, TPU=5;
commit "wire ISP + TPU on-die TMU thermal-zones"). Both come up (~42 C idle) but read
*cooler* than the CPU clusters (46-47 C) — a powered-but-clock-gated block produces no
local hotspot, so its die sensor just tracks ambient. **Conclusion: the gating win is
leakage power, which shows up in total-device power / skin temp, NOT in a local die
zone.** To quantify it we need one of:
  - **battery-discharge current** (maxfg) — but only meaningful *off* wall power; on the
    9V PD sink the pack current reads ~0, so a measurement pass must briefly unplug, or
  - **s2mpg13 ODPM** per-rail meter — works on wall power but needs the sub-PMIC port.

### s2mpg13 sub-PMIC = the keystone (also owns skin_therm + inner-panel rails)
The felix skin/battery/usb/display NTC thermal-zones (AOSP `gs201-felix-thermal.dtsi`,
8 channels incl. the critical **skin_therm** 55.5/56.5/58.5 C backstop) all hang off
`google,s2mpg13-spmic-thermal` reading the s2mpg13 sub-PMIC ADC. Mainline has **no**
s2mpg13 support at all (no MFD/regulator/ADC/meter — battery telemetry comes from the
separate max77759/maxfg chips). The same s2mpg13 also gates the inner-panel rails
(s_ldo28/s_ldo4, currently worked around by the gpa7-1 gpio-hog) and carries the ODPM
meter. One port unlocks: skin diagnostics + per-rail power measurement + proper
inner-panel power-down.

## Next actions (updated)
1. ✅ Diagnose PD idle state — DONE: **all domains ON** (above). SoC-TMU zone coverage
   completed (ISP+TPU wired).
2. **Decide the measurement instrument before the genpd lever**, since on-die TMU
   can't see it: either (a) accept brief battery-discharge measurement passes, or
   (b) port the s2mpg13 sub-PMIC first (bigger, but yields ODPM + skin_therm + a clean
   way to kill the inner-panel rails). (b) is the higher-leverage keystone.
3. Stand up `exynos-pd` genpd for the never-used camera/video/TPU/AUR domains (reuse the
   cal-if scaffolding the ACPM clock work brought in); genpd auto-offs consumerless
   domains at late_initcall. Measure the idle-power delta with the instrument from (2).
4. Lighter parallel lever: deeper CPUIdle (cluster/SICD idle-states from AOSP gs201 DT).
