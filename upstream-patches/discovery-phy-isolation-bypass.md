# Discovery: gs101/gs201 UFS HS data path requires PMU PHY-isolation bypass

**Status:** Empirically observed via vendor-driver graft on Pixel Fold (gs201,
Tensor G2). Upstream patch not yet written — this document describes the
finding, evidence, and shape of the fix so it can be turned into a real
patch + cover letter.

**Source tree where this was found:** `mainline-graft` branch of
junkyard-boot-img, kernel at `kernel/source/` (junkyard-computing/linux,
branch `felix-vendor-graft`, based on `felix~1` ≈ v7.0-rc4 + post-rc4
upstream merges + felix gs201 platform port from
[https://github.com/junkyard-computing/junkyard-boot-img/tree/feature/linux-kernel](https://github.com/junkyard-computing/junkyard-boot-img/tree/feature/linux-kernel)).

The vendor UFS driver itself was grafted in at
[drivers/ufs/host/exynos-gs/](../kernel/source/drivers/ufs/host/exynos-gs/),
ported wholesale from AOSP
`private/google-modules/soc/gs/drivers/ufs/`. The graft is "AOSP code on
mainline kernel," not piecewise upstreaming.

## TL;DR

Mainline's `drivers/ufs/host/ufs-exynos.c` gs101 path wedges with
`dl_err 0x80000002` on the first data frame after PMC at HS-Rate. AOSP's
vendor driver — running unmodified against the same hardware on the same
v7.0-rc4 base — completes UIC link startup at HS-G4 dual-lane *and*
successfully transmits frames (UTRD ring fires, controller posts UTRCS,
dispatched commands actually reach the device).

The semantically meaningful gap that AOSP carries and mainline doesn't
appears to be **a PMU register write that releases PHY-side isolation
before link startup**. AOSP issues this via its `exynos_ufs_ctrl_phy_pwr()`
helper at the start of `exynos_ufs_config_externals()`; mainline's
gs101/gs201 code path has no equivalent.

If correct, this means mainline gs101 UFS has *never* been actually
running with the PHY un-isolated for its HS link-up sequence. PWM works
because PWM transmission tolerates the residual gating; HS does not.

## Evidence

### 1. Vendor driver gets to "link start-up passes" at HS-G4 on identical hardware

UART excerpt from `uart-logs/2026-05-02_230227.log` (vendor graft, this
branch's kernel build):

```
[    1.613655] exynos-ufs 14700000.ufs: PA_ActiveTxDataLanes(2), PA_ActiveRxDataLanes(2)
[    1.613797] exynos-ufs 14700000.ufs: max_gear(4), PA_MaxRxHSGear(4)
[    1.613916] exynos-ufs 14700000.ufs: UFS link start-up passes
[    1.614664] exynos-ufs 14700000.ufs: ufshcd_dev_cmd_completion: Invalid device management cmd response: ab (dev_cmd.type=0)
```

The `0xAB` response-stamp issue at the end is unrelated — it's the IOCC
sharability bug already understood from prior gs201 work (controller's
AXI writes don't reach CPU-coherent DRAM); the AOSP driver's
`regmap_update_bits` to HSI2 sysreg+0x710 evidently isn't taking effect
either, but that's separate from the link-startup observation.

### 2. Mainline path with the same hardware wedges with `dl_err 0x80000002`

From the parent project's UFS bring-up memory:

> HS-Rate-A and HS-Rate-B both wedge with `dl_err 0x80000002` on first
> frame after PMC. host PA reports: device supports HS-G4, both lanes
> negotiated, both lanes active, both directions in FAST_MODE. Exactly
> what mainline requested. Device fully acknowledged the mode change.

So mainline reaches `FAST_MODE` and gets the PMC handshake from the
device, but the *first frame* after PMC fails. Same SoC, same device,
same DT (modulo our graft additions which don't touch the PHY init
path).

The character of the failure — PMC succeeds, then frames don't
transmit — matches "PHY TX path gated" rather than mode-negotiation or
controller-internal handshake mismatch.

### 3. AOSP's pre-link sequence writes PMU offset 0x3ec8 bit 0

In AOSP source (mirrored at
`kernel/source.aosp-backup/private/google-modules/soc/gs/drivers/ufs/ufs-exynos.c`),
the sequence at probe time is:

```c
static int exynos_ufs_config_externals(struct exynos_ufs *ufs)
{
    /* PHY isolation bypass */
    exynos_ufs_ctrl_phy_pwr(ufs, true);
    ...
    regmap_update_bits(*p, q->offset, q->mask, q->val);   /* IOCC */
}
```

`exynos_ufs_ctrl_phy_pwr(ufs, true)` walks the `ufs-phy-iso` DT subnode
and writes its `{offset, mask, val}` triple via `exynos_pmu_update()` —
i.e., a write to the PMU IP, not to the UFS controller or PHY directly.

For gs201, the AOSP DT
([../kernel/source.aosp-backup/private/devices/google/gs201/dts/gs201-ufs.dtsi](../kernel/source.aosp-backup/private/devices/google/gs201/dts/gs201-ufs.dtsi)):

```
ufs-phy-iso {
    offset = <0x3ec8>;
    mask = <0x1>;
    val = <0x1>;
};
```

So: write 1 to bit 0 at `pmu_alive + 0x3ec8`. This is invoked *before*
link startup. Setting bit 0 = "release isolation" / "power up PHY"
(AOSP's helper is named `_ctrl_phy_pwr`, not _isolation_, suggesting
it's understood as a power-domain or isolation-release control).

### 4. Mainline phy-gs101-ufs.c does not write to the PMU

Reading
[../kernel/source/drivers/phy/samsung/phy-gs101-ufs.c](../kernel/source/drivers/phy/samsung/phy-gs101-ufs.c):
the PHY driver writes only to its own MMIO region (the PMA at 0x14704000
for gs201; equivalent for gs101). There is no PMU access path. The
companion `drivers/ufs/host/ufs-exynos.c` gs101 path
(`gs101_ufs_pre_link`, `gs101_ufs_post_link`, `tensor_gs101_pre_link` in
the gs101 drvdata) similarly doesn't touch `pmu_alive`.

The `samsung,pmu-syscon = <&pmu_alive>` phandle in mainline's
`phy@14704000` DT node *is* present, but no driver code consumes it for
the isolation-release write. It looks like it was put in DT
prophylactically and never wired up.

## Hypothesized mechanism

`pmu_alive + 0x3ec8` bit 0 corresponds to a PHY isolation / power-domain
gate on the HSI2 power island. With the bit cleared (default state out
of bootloader), the PHY's analog/transmission path is power-isolated
from the controller. Effects:

* **PWM tolerates this.** PWM is low-rate, the analog path is more
  forgiving, and the bootloader stage's HS handoff state may be enough
  to drive PWM transactions even under partial isolation. Empirically,
  mainline gets working IO at PWM gear (with the back-to-back-READ_10
  caveat documented elsewhere).
* **HS doesn't.** HS-Rate-A/B require the analog TX path actually
  driving the M-PHY differential pairs. With isolation in place, the
  device sees no TX activity → the controller's link layer reports
  `dl_err 0x80000002` on the first frame.

This matches the observed asymmetry: mainline's PMC succeeds (because
PMC is a UIC-layer attribute exchange, not data), but the frame
following PMC dies.

## Proposed upstream patch

```
scsi: ufs: exynos: gs101: release PHY isolation via PMU before link startup

The Tensor G1 (gs101) and G2 (gs201) PHY's analog TX path is held in
isolation by a power-management gate at PMU offset 0x3ec8 bit 0. Without
releasing it, the controller's PMC handshake succeeds (the device
acknowledges mode change in attribute exchange), but the first data
frame at HS-Rate fires dl_err 0x80000002 because the differential pairs
are not actually being driven.

Add a pre-link callback to gs101 drvdata that walks an optional
samsung,pmu-syscon + offset/mask/val triple and lifts the gate. The
binding mirrors AOSP's `ufs-phy-iso` subnode shape; for gs101 and gs201
the value is { 0x3ec8, 0x1, 0x1 }.

Verified on Pixel Fold (gs201) — HS-G4 dual-lane link startup completes
where it previously wedged with dl_err 0x80000002.

Fixes: e9faf66e22a8 ("phy: samsung: phy-gs101-ufs: Add new driver")  (or earlier)
```

(Need to double-check Fixes: target — gs101 UFS support has been merged
in incremental pieces.)

## Verification path

Before sending upstream:

1. Apply *only* the PHY-isolation-bypass write to mainline's
   `drivers/ufs/host/ufs-exynos.c gs101_ufs_pre_link` (no other
   AOSP-graft changes), boot, see if `dl_err 0x80000002` clears at
   HS-G4. This is the unambiguous test — same as current
   `feature/linux-kernel` branch with one new write.

2. Confirm the write target by reading PMU+0x3ec8 before the write and
   after (should change from 0 → 1).

3. Test on gs101 (Pixel 6) too if a board is available — the AOSP
   gs101-ufs.dtsi has the same `ufs-phy-iso { offset = 0x3ec8; ...}`,
   so the binding is shared.

## Caveats / things to double-check

- **The bit may be lifted by ATF/BL31 in some configurations.** Per
  the parent project's `project_pkvm_cmu_unlock.md` memory, gs201 BL31
  firewalls some PMU registers and only opens them when EL2 is in
  pKVM mode. Verify whether 0x3ec8 specifically is reachable from EL1
  without `kvm-arm.mode=protected`, and whether the bootloader maybe
  already lifts it (in which case our hypothesis is wrong and HS works
  for some other reason in AOSP).

- **The IOCC bug is independent.** Once HS link is up, the response-
  slot writeback issue (`0xAB` magic stamp) is a separate AXI
  shareability problem already understood in the parent project's
  prior work — the existing
  `0001-ufs-exynos-don-t-clobber-bootloader-IOCC-bits-when-d.patch`
  on `feature/linux-kernel` addresses one half of this; the AOSP
  driver's regmap_update_bits to sysreg+0x710 in
  `exynos_ufs_config_externals` may need to land at different timing
  to be effective.

- **Scope of the binding.** Whether to use the AOSP-shape `ufs-phy-iso`
  subnode (with offset/mask/val children) or a flatter property like
  `samsung,phy-isolation-pmu-offset` is a binding-design call for
  upstream review.
