To: peter.griffin@linaro.org
Cc: <PIXEL TEAM CONTACT>
Subject: gs201 UFS bring-up — AOSP-vs-mainline diff (PMU PHY-isolation parity gap;
         dl_err 0x80000002 still open)

Hi Peter (cc'ing the Pixel team thread),

Follow-up to the gs201 bring-up thread. I had a hypothesis I wanted to
test before sending — that the `dl_err 0x80000002` wedge mainline hits
at HS-Rate was caused by missing a PMU PHY-isolation release that
AOSP's vendor driver does at probe. **Result is negative.** Documenting
it here because the parity gap is still real and the test settled one
of the BL31-firewalling questions on the Pixel-team side.

## TL;DR

A vendor-driver graft on a v7.0-rc4 + felix-platform-port mainline
kernel reaches `UFS link start-up passes` at HS-G4 dual-lane on Pixel
Fold (gs201) where mainline's `drivers/ufs/host/ufs-exynos.c gs101_ufs_*`
path wedges with `dl_err 0x80000002` on the first frame after PMC. So
the gap is real — there's something AOSP does that mainline doesn't.

I traced one concrete piece: AOSP's `exynos_ufs_ctrl_phy_pwr()` writes
PMU offset 0x3ec8 bit 0 (the `ufs-phy-iso` DT subnode triple) at the
top of `exynos_ufs_config_externals()`. Mainline's gs101 path never
touches the PMU. I built a single-write verification patch (helper at
the top of `gs101_ufs_drv_init` + `samsung,pmu-syscon = <&pmu_alive>`
on the UFS DT node) and tested it on Pixel Fold:

  [    1.677] PMU PHY-isolation released (offset 0x3ec8 bit 0)
  [    1.891] Power mode changed to : FAST series_B G_4 L_2
  [    8.073] ufshcd_abort: Device abort task at tag 0
  [    8.127] dl_err[0] = 0x80000002 at 1928150 us

So the write reaches the register (good news for one of the questions
below), but `dl_err 0x80000002` still fires 37 ms after PMC just like
without the patch. The bit is doing *something* on AOSP — it's not a
no-op or a binding wart — but it's not what gates the HS data path.

## What this confirms / rules out

* **The PMU register at offset 0x3ec8 is reachable from EL1** with
  `kvm-arm.mode=protected` set (which we have for the unrelated CMU
  unlock per `project_pkvm_cmu_unlock.md`). So the `samsung,pmu-syscon`
  + regmap_update_bits path works end-to-end. That answers question
  (C) from my draft pre-test cover letter — 0x3ec8 isn't BL31-firewalled
  the way CMU is.

* **The bit is not on the HS data-path critical chain.** Whatever
  gates the M-PHY's analog TX in mainline-shape gs101, it's not this.
  Hypothesis "PMU isolation is the gate" is dead.

* **The gap between mainline and AOSP's vendor driver is real and
  empirically reproducible** — same hardware, same v7.0-rc4 base, same
  bootloader handoff, same `kvm-arm.mode=protected`. Only the host
  driver differs. AOSP's gets past dl_err; mainline's doesn't.

## What I'm now investigating

Top remaining candidates, in rough order of plausibility:

1. **Cal-if `pre_pmc` / `post_pmc` PMA register sequences.** AOSP's
   `gs201/ufs-cal-if.c` writes a set of PMA bytes (notably a 0x888
   kick-start write flagged in our parent project's
   `project_ufs_bringup_state.md` memory) that mainline's
   `tensor_gs101_pre_init_cfg` table doesn't. Some of those writes
   apply at the post-PMC window. Mainline's structural choice to put
   the post-PMC PMA logic in `drivers/phy/samsung/phy-gs101-ufs.c`
   (called via `phy_calibrate()`) instead of inline in the controller
   driver may also affect the timing window.

2. **AOSP's `__set_pcs` mechanism.** The vendor driver writes a per-
   lane PCS calibration via a dedicated mechanism mainline doesn't
   replicate; reaches different MIB attributes on the path.

3. **`gs101_ufs_post_link` differences.** AOSP's per-SoC post_link
   writes a few HCI knobs (PRDT_PREFETCH_EN at TXPRDT_ENTRY_SIZE
   regardless of crypto, etc.) that mainline only does conditionally.
   Some of these are already covered by my prior 0005 / 0006 drafts;
   the question is whether a *combination* of those fixes plus
   something else clears dl_err.

The empirical evidence (AOSP graft works on the same hardware) means
something in this list (or a combination) is the actual fix. I want to
land them one-at-a-time as bisect-style verifications rather than
shotgun a multi-patch series.

## What I'm still asking

For Peter:

1. Have you seen `dl_err 0x80000002` before in your gs101 work? If so,
   was the diagnosis different? Anything in the back of your head from
   the original gs101 port that screams "I had to do something specific
   at the controller / PHY boundary that didn't make it into the public
   patch"?

2. The PMU PHY-isolation write (now confirmed reachable, not the wedge
   fix, but parity with AOSP) — would you take a patch landing it as a
   parity-with-AOSP completeness fix even though it doesn't change
   observable behavior under the current dl_err wedge? My instinct is
   yes (AOSP wouldn't ship the write for nothing), but I'd rather not
   send single-axis non-fixing-anything patches without a thumbs up on
   framing.

For the Pixel team:

A. **What does `pmu_alive + 0x3ec8 bit 0` actually control on
   gs101/gs201?** Empirically it's reachable from EL1 and AOSP writes
   it once at probe, but our experiment shows it's not the gate on the
   M-PHY analog TX. Is it a different power-domain release (e.g., for
   the UFS protector / FMP / UNIPRO clock domain) that we wouldn't see
   the effect of in our boot path because we don't exercise those
   paths? Or is the bit actually a dead one that AOSP keeps writing for
   historical reasons?

B. **Where in the AOSP chain is the M-PHY analog TX gated such that
   `dl_err 0x80000002` wouldn't fire?** Mainline gets to FAST_MODE PMC
   negotiation, device acks the power-mode change, host PA reports
   FAST/FAST and 2 lanes active on both directions — and then the
   first data frame doesn't come out. That's M-PHY signal-integrity-
   level. Anything in `cal-if/gs201/` or the AOSP-side post-PMC
   sequence that you'd flag as "this is what makes HS work"?

C. The 0x888 PMA byte writes (from cal-if's `post_calib_of_hs_rate_b`
   for gs201) — is there an entry there that the mainline `gs101_ufs_*`
   path is missing because of the binding split between
   `phy-gs101-ufs.c` (PHY framework calibrate path) and `ufs-exynos.c`
   (controller path)?

The discovery doc (with the negative-result update) is in our repo at
`upstream-patches/discovery-phy-isolation-bypass.md`. The verification
patch I tested is at
`upstream-patches/verification-0007-ufs-exynos-gs101-release-PHY-isolation-via-PMU.patch`.

Thanks,
Chris
