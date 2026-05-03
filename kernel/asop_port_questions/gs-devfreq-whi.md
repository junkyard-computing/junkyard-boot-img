# devfreq-whi

- **AOSP path**: `private/google-modules/soc/gs/drivers/devfreq-whi/google/`
- **Mainline counterpart**: same as `gs-devfreq.md` — **NONE** (mainline `drivers/devfreq/exynos-bus.c` covers Exynos5/7 only)
- **Status**: not-ported
- **Boot-relevance score**: 4/10

## What it does

A **near-identical sibling** of `devfreq/google/` — same files (`gs-devfreq.c`, `gs-ppc.c`, `governor_simpleinteractive.c`, `governor_memlat.c`, `arm-memlat-mon.c`, `memlat-devfreq.c`) minus the DSU-latency governor (`governor_dsulat*`, `dsulat-devfreq.c`) and minus `governor_dsulat_trace.h`. "WHI" almost certainly stands for **"WhiteIron"** or similar codename — it's a Pixel internal product variant naming scheme. The AOSP vendor build of one or more devices is configured to consume the WHI variant instead of the full `devfreq/google/` tree, presumably because that hardware has no separate DSU clock domain (the older 4-core gs101 designs are like this — DSU rides at CPU rate).

## Mainline equivalent

Same as `gs-devfreq` — none.

## Differences vs AOSP / what's missing

Same gap as `gs-devfreq.md`. The only real diff between this dir and `devfreq/` is the absence of the DSU governor.

## Boot-relevance reasoning

4/10. Strict subset of `gs-devfreq` for older/simpler Pixel SoCs. Same reasoning as that module but slightly lower because if we ever port the devfreq stack we'd port the full version (`devfreq/google/`), not this stripped flavor. Listing for completeness; functionally redundant with the parent.

