# perf

- **AOSP path**: `private/google-modules/perf/` (**empty** — only a `.git` symlink, no checked-out content)
- **Mainline counterpart**: in-tree `kernel/events/`, plus per-arch PMU drivers under `drivers/perf/` (`arm_pmu*`, `arm_dsu_pmu`, etc.) and `arch/arm64/kernel/perf_*`
- **Status**: N/A — the AOSP repo is empty in this checkout
- **Boot-relevance score**: 1/10

## What it does

Like `typec/`, this directory contains only `.git -> ../../../.repo/projects/private/google-modules/perf.git`
with no synced source. From the public Pixel branches the contents are a thin grab-bag of
Google-private perf-counter / profiling helpers — typically things like an MPAM-style
cluster-PMU exporter, an SLC (system-level cache) PMU driver for the gs101/gs201 mesh
fabric, or a debug interface for the Tensor's CMU/BPU performance counters. None of it is
required to *use* the kernel — it's all observability instrumentation for the Pixel
performance team.

## Mainline equivalent

The arm64 mandatory PMU bits (CPU PMU, SPE, DSU PMU, generic ARM perf events) are all
upstream and load fine on gs201 today. What isn't upstream is any gs201-specific bus-fabric
or SLC-cache PMU; the Tensor mesh interconnect doesn't expose its counters to mainline
because there's no driver wired up.

## Differences vs AOSP / what's missing

Unknown without source, but historically: SoC-fabric PMU bindings, CMU performance counter
exposure, custom tracepoints. None of which we have any way to tell the difference about
in this checkout.

## Boot-relevance reasoning

Profiling is a debug feature. The kernel boots, mounts UFS HS-G4 Rate-B
ext4, and runs userspace independent of whether perf counters are
exported. Score 1 — completely orthogonal to the active partial bring-up
(USB gadget HS RX path).
