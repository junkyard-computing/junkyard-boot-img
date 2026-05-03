# performance

- **AOSP path**: `private/google-modules/soc/gs/drivers/performance/`
- **Mainline counterpart**: **NONE**
- **Status**: not-ported
- **Boot-relevance score**: 3/10

## What it does

Two related modules sharing a common goal of "high-resolution CPU monitoring + memory-latency governors":
- `gs_perf_mon/` — Google CPU Performance Monitor. Allocates ARM PMU + AMU counters and hooks CPU state-change functions (cpuhotplug, cpufreq notifier) to provide fine-grained per-CPU PMU samples to other in-kernel clients. Notes in Kconfig: "this monitor allocates PMU counters so it can conflict with other profiling tools."
- `lat_governors/` — `gs_governor_memlat.c` (memory latency) and `gs_governor_dsulat.c` (DSU latency). These compute target MIF/BCI/DSU frequencies from `gs_perf_mon` data and feed the devfreq driver. They're a **rewrite** of the older `governor_memlat.c` / `governor_dsulat.c` in `devfreq/google/` — newer Pixel SoCs (zuma+) use `lat_governors/` driven by `gs_perf_mon`, older ones use the original `arm-memlat-mon.c`-based versions in `devfreq/`.

## Mainline equivalent

None. Mainline has `drivers/perf/` ARM PMU drivers and the perf subsystem, but no equivalent in-kernel-client framework that provides PMU samples to devfreq governors.

## Differences vs AOSP / what's missing

Entire stack. Without it, even if we ported `gs-devfreq`, the memlat/dsulat governors would have no data source.

## Boot-relevance reasoning

3/10. This is a tier above the devfreq governors in the dependency chain, and depends on devfreq + ACPM-I2C. Until those are ported, this is dead code. Boot is unaffected. Useful eventually for fine-grained DVFS but not in critical path.

