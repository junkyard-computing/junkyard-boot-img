# gs-char

- **AOSP path**: `private/google-modules/soc/gs/drivers/char/hw_random/`
- **Mainline counterpart**: [`drivers/char/hw_random/exynos-trng.c`](kernel/source/drivers/char/hw_random/exynos-trng.c)
- **Status**: partially-ported (different driver lineage)
- **Boot-relevance score**: 2/10

## What it does

`exyswd-rng.c` (`HW_RANDOM_EXYNOS_SWD`) — TRNG access via SMC into BL31's secure-world RNG. Builds as `exynos-rng.ko`. One file, ~200 lines.

## Mainline equivalent

Mainline ships `exynos-trng.c` which talks to a directly-mapped TRNG block (Exynos5 / Exynos850 / GS101). It does not use SMC; it pokes the TRNG registers itself (because on those SoCs the TRNG isn't behind the secure firewall). For SoCs whose TRNG only answers to S-EL3, mainline has `arm_smccc_trng.c` which does an `ARM_SMCCC_TRNG_RND64` SMC — but that requires PSCI-style TRNG support in BL31, not the gs vendor SMC ID this driver uses.

## Differences vs AOSP / what's missing

The vendor SMC interface (its specific function ID / arg layout) is not implemented in either mainline driver. Net effect on a stock felix BL31: no in-kernel hwrng device unless you wire up the SMC call. The kernel still has `getrandom()` / RDRAND-equivalents from the CPU and entropy pools.

## Boot-relevance reasoning

**Score 2**: A missing hwrng slows initial entropy collection on systemd boot, which can stretch first-boot time before crng-init by a few seconds, but the system still boots. UFS bring-up doesn't touch hwrng. Not a blocker; not worth porting unless cryptd/TLS startup latency becomes a measurable problem.
