# devfreq

- **AOSP path**: `private/google-modules/soc/gs/drivers/devfreq/google/`
- **Mainline counterpart**: `drivers/devfreq/exynos-bus.c` (partial; covers exynos5/exynos7 buses only)
- **Status**: not-ported
- **Boot-relevance score**: 5/10

## What it does

DDR/MIF/INT/BCI/DSU bus frequency-scaling stack for gs101/gs201/zuma:
- `gs-devfreq.c` — the gs/zuma platform devfreq driver. Builds devfreq domains from DT, talks to ACPM IPC (`acpm_dvfs.h`) to set DDR/INT/BCI rates, integrates with PM-QoS, BTS (Bus Traffic Shaper), and ECT.
- `governor_simpleinteractive.c` — Samsung's simple-interactive devfreq governor with ALT-DVFS (Active Load Tracing) — uses memory-bus activity counters from `gs-ppc.c` (Performance Profiling Counter) to decide whether to scale up.
- `governor_memlat.c` + `arm-memlat-mon.c` + `memlat-devfreq.c` — ARM CPU memory-latency-bound governor: uses ARM PMU stall counters to detect when the CPU is bound on DRAM and votes higher MIF frequency.
- `governor_dsulat.c` + `dsulat-devfreq.c` — DSU (DynamIQ Shared Unit) latency governor; same idea but for the L3-cache fabric.

## Mainline equivalent

`drivers/devfreq/exynos-bus.c` — generic Exynos5/Exynos7 DEVFREQ-bus driver. Covers older Exynos buses; **no gs101/gs201/zuma compatibles**. Mainline has `governor_simpleondemand`, `governor_performance`, `governor_userspace` but no memlat/dsulat governors.

## Differences vs AOSP / what's missing

Entire vendor stack. Without it: DDR runs at whatever rate BL31/the bootloader left it at, INT/BCI similarly. There's no automatic scale-up under memory-bus pressure, no PM-QoS-driven holds.

## Boot-relevance reasoning

5/10. Boot succeeds with DDR pinned to a single rate. **Now that UFS
HS-G4 Rate-B works** (fixed 2026-05-06), the devfreq absence is the next
real perf bottleneck for I/O-bound workloads — DDR/MIF/INT all stay at
boot rate while UFS could push significantly more bandwidth. Score 5
because (a) doesn't block boot, (b) memlat/dsulat governors have nothing
equivalent in mainline, (c) any port depends on ACPM IPC being available
to drive MIF DVFS — see [gs-soc.md](gs-soc.md).

