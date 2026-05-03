To: peter.griffin@linaro.org
Cc: <PIXEL TEAM CONTACT>
Subject: gs201 UFS HS dl_err 0x80000002 — likely cause is missing PMU PHY-isolation
         release (follow-up to bring-up thread)

Hi Peter (cc'ing the Pixel team thread),

Follow-up to the gs201 bring-up thread with a new finding I think is
upstream-eligible on its own. TL;DR: the `dl_err 0x80000002` wedge that
hit on every HS-Rate attempt in mainline appears to be caused by
mainline never lifting a PMU PHY-isolation bit that the AOSP vendor
driver lifts before link startup. The evidence is empirical (running
AOSP's UFS driver unmodified on an otherwise mainline-shape v7.0-rc4
kernel makes HS-G4 dual-lane link startup pass on the same hardware),
but the bit's exact semantics are insider knowledge, hence the cc to
the Pixel team.

## What I did

I grafted AOSP's vendor UFS driver
(`private/google-modules/soc/gs/drivers/ufs/`) wholesale into a
v7.0-rc4-based mainline kernel — separate driver at
`drivers/ufs/host/exynos-gs/`, gated by a new `SCSI_UFS_EXYNOS_GS`
Kconfig, mainline's `SCSI_UFS_EXYNOS` disabled. The intent wasn't
upstreaming the graft itself — it was a controlled experiment to find
out what AOSP does in the link-startup path that mainline doesn't.

The graft's only source-level edits to AOSP code are upstream-API drift
fixes (const on `pwr_change_notify`'s `desired_pmd`, `hrtimer_init` →
`hrtimer_setup`, `ufshcd_hold` 1-arg form, `ufshcd_shutdown` removal,
`platform_driver.remove` returning void, `<asm/unaligned.h>` →
`<linux/unaligned.h>`, vendor-hook stubs because mainline doesn't carry
ANDROID_VENDOR_HOOKS). None of those touch the link-startup path.

DT-side changes are equally minimal: add the AOSP-shape sub-nodes
(`ufs-phy-iso`, `ufs-iocc`) and the missing reg entries (PHY MMIO at
0x14704000+0x3000 and CPORT at 0x14708000+0x804) to felix's UFS node so
the AOSP driver's expected ioremap loop completes, and disable the
mainline-shape standalone `phy@14704000` node so it doesn't claim
the PHY MMIO range with -EBUSY.

## What happened

Same hardware (Pixel Fold, gs201), same bootloader handoff, same kernel
base v7.0-rc4 + post-rc4 merges, same `kvm-arm.mode=protected`,
same `dma-coherent` + `samsung,sysreg` references — only the UFS host
driver swapped in.

UART:

  [    1.613655] exynos-ufs 14700000.ufs: PA_ActiveTxDataLanes(2), PA_ActiveRxDataLanes(2)
  [    1.613797] exynos-ufs 14700000.ufs: max_gear(4), PA_MaxRxHSGear(4)
  [    1.613916] exynos-ufs 14700000.ufs: UFS link start-up passes

i.e. UIC link startup completes at HS-G4 dual-lane *and* commands then
dispatch (UTRD ring fires, controller posts UTRCS). The follow-on
"Invalid device management cmd response: ab" is unrelated — it's the
IOCC sharability bug we already knew about (same `0xAB` magic stamp
issue) and isn't caused by the new graft path.

The upshot is: with AOSP's driver, the HS data path actually transmits
frames. That's the wedge mainline couldn't get past after weeks of
investigation (D1, D2, S1, C1, C2, h14, h15* in our prior notes — every
mainline-side hypothesis was ruled out). So *something* in AOSP's
configure path is releasing whatever was gating the M-PHY TX in
mainline.

## Where I think it is

AOSP's `exynos_ufs_config_externals()` (called once at probe before link
startup):

  static int exynos_ufs_config_externals(struct exynos_ufs *ufs)
  {
      /* PHY isolation bypass */
      exynos_ufs_ctrl_phy_pwr(ufs, true);

      /* Set for UFS iocc */
      for (...) {
          regmap_update_bits(*p, q->offset, q->mask, q->val);
      }
  }

`exynos_ufs_ctrl_phy_pwr(ufs, true)` reads the `ufs-phy-iso` DT
sub-node and writes its `{offset, mask, val}` triple into the PMU via
`exynos_pmu_update`. For gs201 this is:

  ufs-phy-iso {
      offset = <0x3ec8>;
      mask = <0x1>;
      val = <0x1>;
  };

Plain English: write 1 to bit 0 at `pmu_alive + 0x3ec8` before link
startup.

Mainline's `phy-gs101-ufs.c` does not touch the PMU at all — only the
PMA at 0x14704000. Mainline's `drivers/ufs/host/ufs-exynos.c gs101_ufs_*`
(tensor_gs101_pre_init_cfg, gs101_ufs_pre_link, gs101_ufs_post_link)
also doesn't touch the PMU. The `samsung,pmu-syscon = <&pmu_alive>`
phandle in mainline's `phy@14704000` DT node is present but unused by
any code path I can find — it looks prophylactic.

## Hypothesized mechanism

Bit 0 at `pmu_alive + 0x3ec8` gates the M-PHY's analog/transmission path
on the HSI2 power island. With it cleared (presumed default at
bootloader handoff), the controller can negotiate PMC (which is just
attribute exchange at the UIC layer) but the PHY won't actually drive
the differential pairs in HS-Rate mode. PWM tolerates this (lower-rate,
analog more forgiving, partial bootloader state may be enough); HS does
not.

That matches the asymmetry we see in mainline: `host PA reports: device
supports HS-G4, both lanes negotiated, both lanes active, both
directions in FAST_MODE. Exactly what mainline requested. Device fully
acknowledged the mode change.` — and then the *first frame* dies with
`dl_err 0x80000002`. PMC wins, frames don't.

If this hypothesis is right, mainline gs101 UFS has *never* actually
brought the PHY out of isolation for HS link-up. PWM has been working
in spite of, not because of, the PHY power state.

## What I'm asking

For Peter:

1. Does the framing make sense? If yes, the upstream patch is pretty
   surgical: an optional pre-link callback in `gs101_ufs_drvs` that
   walks an optional `samsung,phy-isolation-pmu-syscon` + offset/mask/val
   triple (or the AOSP-shape `ufs-phy-iso` subnode) and lifts the bit.
   I can write it and post it; would prefer to follow your review style
   for the binding choice rather than guess.

2. Have you seen `dl_err 0x80000002` before in your gs101 work? If so,
   was the diagnosis different?

3. Verification step before sending: I plan to apply *only* this PMU
   write to mainline's `gs101_ufs_pre_link` (no other graft changes,
   reverting our DT and driver to fully mainline shape) and check that
   `dl_err 0x80000002` clears at HS-G4. That's the unambiguous test —
   if it works, it's a clean one-line "mainline doesn't lift this PMU
   bit; it should" patch. Sound right?

For the Pixel team:

A. Is `pmu_alive + 0x3ec8 bit 0` a UFS PHY isolation / power-domain
   release control on gs201 (and gs101)? AOSP's helper is named
   `exynos_ufs_ctrl_phy_pwr` and the DT node is `ufs-phy-iso`, so the
   external evidence points that way, but the actual bit semantics are
   yours.

B. Is the bootloader supposed to lift this, or is the kernel supposed
   to? AOSP's behaviour is "kernel lifts it at probe." If the
   bootloader is supposed to lift it on production AOSP boots and the
   kernel write is just defensive, then there might be something
   different about our boot chain that leaves the bit cleared at
   handoff. (We're running ABL → BL31 → our kernel directly, not the
   AOSP boot.img stack — could be relevant.)

C. Is `0x3ec8` reachable from EL1, or does BL31 firewall it the way it
   firewalls CMU? Per a parallel thread, gs201 BL31 only opens CMU
   register access when EL2 is in pKVM mode (workaround: boot with
   `kvm-arm.mode=protected`, which we have). If 0x3ec8 has the same
   protection, AOSP's write would silently be no-op'd unless the same
   pKVM unlock is in place — and our test had pKVM enabled, so we
   wouldn't see the firewall. Confirming it's reachable from
   non-pKVM EL1 would matter for upstream because not every gs101/201
   distro will boot pKVM.

The doc with the full discovery writeup, evidence, and proposed patch
shape is in our repo at `upstream-patches/discovery-phy-isolation-bypass.md`
(I can attach if you'd rather have it as a file).

Thanks,
Chris
