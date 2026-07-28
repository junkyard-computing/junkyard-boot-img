# TODO: orientation-agnostic SuperSpeed on gs201/felix (dwc3 USB-C host)

**Status:** open / research. Shipped fallback works; the general fix is unsolved.

## Goal

Make the USB-C SuperSpeed link train regardless of which way the Type-C
connector is plugged in (CC1/normal *and* CC2/reverse). Today only one
orientation works.

## What already works (shipped, `fix/max77759-vbus-transitions` @ 8b9e282, kernel 00127)

Three fixes got SS working *for the reverse (CC2) plug*, which is how the
bench dongle is always inserted:

1. `power: supply: max77759_charger` — sequence BUCK<->OTG through OFF
   (`2e37193d`). Fixes the charger `-EINVAL` wedge on PD/dongle plug/unplug.
2. `arm64: dts: gs201-felix` — `maximum-speed = "super-speed-plus"`
   (`47507c94`). The DT had it capped to `high-speed`, so SS was never
   negotiated.
3. `phy: exynos5-usbdrd: gs201-felix` — `used_phy_port = 1` (`8b9e282`).
   The AOSP-graft PMA init hardcoded the SS lane mux to CC1 (port 0), but the
   dongle plugs CC2. Static flip to port 1 → RTL8153 enumerates **direct at
   SuperSpeed 5 Gbps, no PD**. Confirmed on device (`usb 2-1: new SuperSpeed`).

## The root cause of the *general* problem

`used_phy_port` (which SS differential pair the lanes are muxed onto) is baked
in at `phy_init`, which runs at boot (~0.32 s) **long before the TCPC reports
orientation** (`phy_drd->orientation == NONE` then). `phy_init` is
PHY-framework-refcounted, so dwc3 re-inits never re-run it
(`phy_exynos_usbdp_g2_v4_enable` appears exactly once in dmesg). So the lane
mux is stuck on whatever the boot code guessed, and a dongle on the other
orientation trains SS on the wrong pair and never enumerates (doesn't even
fall back to USB2 — it hangs retrying SS).

The felix author's comment in `phy-exynos5-usbdrd.c` (~line 2943) documents
this and points at the fix: re-apply the mux when the live orientation arrives
in `exynos5_usbdrd_orien_sw_set()` (AOSP reads extcon `TYPEC_POLARITY` and
re-inits).

## What was TRIED and FAILED (see branch `wip/ss-orientation-remux`)

Both attempts added a `drvdata ->orien_reinit` hook called from
`exynos5_usbdrd_orien_sw_set()` once the TCPC reports orientation:

- **Attempt 1 (`5189e2b`)** — re-run the full `gs201_aosp_utmi_init` /
  `phy_exynos_usbdp_g2_v4_enable` with the port derived from live orientation.
  → **Re-initializing the whole PHY on a live controller killed the USB2/HS
  path.** Booted, but no dongle enumerated, no network, SSH dead. Fastboot
  recovery.

- **Attempt 2 (`1e5261f`)** — surgical: point `->orien_reinit` at only
  `exynos5_usbdrd_usbdp_g2_v4_pma_lane_mux_sel` (writes just `CMN_REG00B8`
  @0x02e0 + the LN1/LN3 TRSV overrides — byte-identical to the CAL's port
  branches, touches nothing on UTMI/USB2). Boot default port 1.
  → Reverse/boot case fine (idempotent re-write of port 1). But **flipping the
  cable to normal — a lane-mux value that actually *changes* on the running
  PMA — HARD-WEDGED the whole SoC** (even USB2 died; power-cycle required).

**Conclusion: you cannot re-mux the SS lanes on a live, running PMA at all —
neither a full re-enable nor a bare lane-mux register write. A no-op re-write
(same port) is harmless; an actual re-route hangs the PHY.**

## Viable directions (not yet attempted)

1. **Controlled re-init sequence.** On orientation change: proper PHY
   power-down (CAL `..._disable`) → reconfigure lane mux for the new port →
   power-up (`..._enable`) → PLL/CDR re-lock. i.e. a *real* re-init with the
   controller quiesced, not live register pokes. Needs coordination with dwc3
   (the SS link/roothub) so it doesn't fault mid-operation.

2. **Defer the first SS enable.** Skip the SS PMA enable at boot `phy_init`
   (orientation unknown) and do it exactly once when the first orientation
   arrives — init-once-correct, never re-muxed live. Risk: dwc3/xhci expects
   the PHY up at probe; needs verifying the SS roothub still comes up.

Reference AOSP's `dwc3-exynos` + extcon `TYPEC_POLARITY` flow — its dwc3 waits
for orientation before powering the PHY, which is why it doesn't hit this.

## Test/recovery notes

- Instrument to disk (survives the dongle — the sole NIC — dropping): the
  `usbcap`/`dmesgcap` fsync'd capture services + charger regmap + `i2cget`
  TCPC `USBSW_CTRL`@0x93 reads. See session memory
  `project_usb_typec_hostmode_coldreset`.
- Always keep a host-side backup of the last-good boot images before flashing
  an experimental PHY build; **fastboot is the only recovery when a bad build
  kills the dongle.** Slot A (00124) is the base rollback anchor.
