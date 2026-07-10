# Raising thermal shutdown thresholds (AOSP kernel)

felix runs hot as a fanless bring-up board, and on the **AOSP/GKI kernel** it can
hit a thermal shutdown that's more aggressive than you want during development.
This doc explains where those thresholds live, which are safe to move, and how to
change them **live on-device** with [`thermal-thresholds`](../rootfs/overlay/usr/local/sbin/thermal-thresholds)
(shipped in every image at `/usr/local/sbin/thermal-thresholds`).

> This is the **AOSP-track** story. The mainline gs201 kernel has a different,
> much thinner thermal setup — see the `feature/linux-kernel` notes. On AOSP the
> full thermal-zone + cooling stack is present and the trips below are real.

## Two layers of thermal protection

The felix DT defines two independent kinds of thermal zone, each enforced by a
different driver:

### 1. Junction zones — `BIG` / `MID` / `LITTLE` / `G3D` / `TPU` / `ISP`

On-die TMU sensors, defined in the base SoC DT
([`kernel/.../devices/google/gs201/dts/gs201-b0.dts`](../kernel/source/private/devices/google/gs201/dts/gs201-b0.dts)),
driven by `gs_tmu_v3`. The `BIG` (CPU big cluster) ladder, for example:

| trip | temp | type | effect |
|------|------|------|--------|
| `big_control_temp` | 100 °C | passive | `cooling-map` → cpufreq throttle |
| `big_dfs` | 110 °C | active | emergency freq scaling |
| `big_hot` | **120 °C** | **hot** | **junction shutdown** |

Enforcement: `gs_tmu_v3` reads the DT trips and pushes them into the **ACPM**
firmware via `exynos_acpm_tmu_set_threshold()`. So the "hot" shutdown temperature
is the DT value handed to ACPM — not a hardcoded firmware constant.

**Do not raise the 120 °C junction `hot` trip.** That is the silicon's safe
limit; it's what actually protects the die. If you want the SoC to clock harder
for longer before throttling, relax the *passive/control* trip (100 °C) instead
— but understand you're trading skin/junction headroom for performance.

### 2. Skin backstop — `skin_therm`

An external NTC thermistor on the S2MPG13 sub-PMIC, defined in
[`kernel/.../devices/google/felix/dts/gs201-felix-thermal.dtsi`](../kernel/source/private/devices/google/felix/dts/gs201-felix-thermal.dtsi)
(included by `gs201-felix-common.dtsi`, so it flows into every felix `dtbo`),
driven by `s2mpg13-spmic-thermal`:

| trip | temp | type | effect |
|------|------|------|--------|
| `trip_config2` | 55.5 °C | passive | throttle hint (userspace HAL) |
| `backup_shutdown_sw` | **56.5 °C** | **critical** | Linux core `orderly_poweroff` |
| `backup_shutdown_hw` | **58.5 °C** | **hot** | S2MPG13 PMIC `NTC_OT_FAULT` hardware shutdown |

This is a **backstop**. On stock Android the thermal HAL throttles the SoC long
before *skin* reaches 56.5 °C, so it never fires. Under our Debian userspace it
can trip as a nuisance shutdown — and 56.5 °C skin is low.

**This is the safe knob.** Raising the skin backstop does not remove die
protection: the junction zones (100 °C throttle / 120 °C shutdown) still stand
below it. Raising it just stops the *skin* thermistor from cutting power early.

## How the on-device change works

The AOSP kernel is built with `CONFIG_THERMAL_WRITABLE_TRIPS=y`, so each trip is
exposed writable at:

```
/sys/class/thermal/thermal_zone<N>/trip_point_<M>_temp   (millicelsius)
```

Writing it (see `drivers/thermal/thermal_sysfs.c: trip_point_temp_store`) does
**two** things at once:

1. Calls the zone's `->set_trip_temp`, reprogramming the **hardware**:
   - junction zones → ACPM (`exynos_acpm_tmu_set_threshold`);
   - `skin_therm` "hot" → the S2MPG13 `NTC_OT_FAULT` register.
2. Persists `tz->trips[trip].temperature`, so the Linux core's own `critical`
   → `orderly_poweroff` threshold moves as well.

So a sysfs write is a complete, immediate change — no rebuild, no flash.

> **Volatile.** The DT values are reloaded on every boot. A sysfs change lasts
> until the next reboot. To make it durable, re-apply at boot (see
> [Making it durable](#making-it-durable-persist-across-reboots)).

## Using `thermal-thresholds`

Inspect first (no root needed):

```console
$ thermal-thresholds --show
skin_therm       (thermal_zone0)  now=52.0 C
    trip 0   passive     55.5 C  [writable]
    trip 1   critical    56.5 C  [writable]
    trip 2   hot         58.5 C  [writable]
BIG              (thermal_zone3)  now=61.0 C
    trip 0   passive    100.0 C  [writable]
    ...
```

The zone name in the first column (`skin_therm`, `BIG`, `G3D`, …) is the DT node
name and is exactly what `--zone` expects — copy it from `--show`.

Raise the skin backstop (the recommended knob). This sets the zone's
passive → `C-1`, critical → `C`, hot → `C+2`, preserving the stock spacing:

```console
# thermal-thresholds --skin 72
Raising skin_therm backstop to 72 C (passive 71.0/critical 72/hot 74.0):
    thermal_zone0: trip 0 (passive)  -> 71.0 C
    thermal_zone0: trip 1 (critical) -> 72.0 C
    thermal_zone0: trip 2 (hot)      -> 74.0 C
```

Preview without changing anything:

```console
$ thermal-thresholds --skin 72 --dry-run
```

Advanced — operate on any zone/trip explicitly (you must scope with `--type`
and/or `--trip` so you can't blindly rewrite a whole zone):

```console
# relax the BIG cluster throttle onset from 100 C to 105 C
# thermal-thresholds --zone BIG --type passive --temp 105

# bump every "hot" trip on the GPU zone by 3 degrees
# thermal-thresholds --zone G3D --type hot --offset 3
```

Guardrails: writes above **125 °C** (silicon cap) are refused unless you pass
`--force`; skin targets above 85 °C warn (PMIC NTC range). Values accept one
decimal (e.g. `56.5`). Run `thermal-thresholds --help` for the full reference.

## Making it durable (persist across reboots)

sysfs writes revert on reboot. To re-apply automatically, drop a oneshot unit
into the overlay. Create
`rootfs/overlay/etc/systemd/system/thermal-thresholds.service`:

```ini
[Unit]
Description=Raise thermal backstop for fanless bring-up
DefaultDependencies=no
After=sysinit.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thermal-thresholds --skin 72
RemainAfterExit=yes

[Install]
WantedBy=basic.target
```

Then enable it in the same `.install_packages` nspawn step that enables the
other overlay units (`systemctl enable thermal-thresholds.service`). It applies
early each boot, after the thermal drivers have registered their zones.

> If you prefer not to ship this by default, run `thermal-thresholds --skin …`
> by hand over SSH after each boot instead — the change takes effect instantly.

## The permanent (DT) alternative

If you want the higher backstop baked into the image rather than re-applied at
runtime, edit the trip temperatures directly in
[`gs201-felix-thermal.dtsi`](../kernel/source/private/devices/google/felix/dts/gs201-felix-thermal.dtsi)
(`backup_shutdown_sw` / `backup_shutdown_hw`), then rebuild and reflash the dtbo:

```console
just build_kernel                                   # rebuilds .../out/felix/dist/dtbo.img
fastboot flash dtbo kernel/source/out/felix/dist/dtbo.img
```

This is heavier (a kernel/dtbo rebuild) and survives reboots without a unit, but
the runtime script is the fast path for iterating during bring-up. Note the DT
route only reaches the device via `dtbo` — the skin zone lives in the felix
overlay, not the base `vendor_boot` dtb.

## Summary

- **Safe knob:** raise `skin_therm` (56.5/58.5 °C stock) with
  `thermal-thresholds --skin <C>`; junction throttling still protects the die.
- **Don't** raise the 120 °C junction `hot` trip — that's the silicon limit.
- Changes are **live but volatile**; persist with a boot-time systemd oneshot
  (above) or bake into the felix thermal dtsi + reflash `dtbo`.
