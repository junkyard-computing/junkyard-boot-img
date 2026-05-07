# typec

- **AOSP path**: `private/google-modules/typec/` (**empty** — only a `.git` symlink, no checked-out content)
- **Mainline counterpart**: `drivers/usb/typec/tcpm/tcpci_maxim_core.c` and `maxim_contaminant.c` (the upstream Pixel/Maxim TCPC driver)
- **Status**: N/A — the AOSP repo is empty in this checkout
- **Boot-relevance score**: 2/10

## What it does

In the AOSP backup tree this directory is just `.git -> ../../../.repo/projects/private/google-modules/typec.git`
with no source files actually synced. Historically (per the public Pixel kernel branches)
the contents would be a Google-extended TCPC + USB-PD driver for the Maxim PMIC on Pixel
phones — handling CC line negotiation, Source/Sink role, alt-mode (DisplayPort over Type-C),
contaminant detection, and the Google-specific moisture-detection state machine. On felix
this would manage the single USB-C port shared with charging.

## Mainline equivalent

Upstream has the Maxim TCPC family covered: `drivers/usb/typec/tcpm/tcpci_maxim_core.c`
plus `maxim_contaminant.c` were upstreamed from a Pixel branch (Badhri Jagan Sridharan,
Google), so a meaningful chunk of the Pixel typec story already exists in mainline. The
generic TCPM state machine (`tcpm.c`), TCPCI register layer (`tcpci.c`), and PD policy
engine are also upstream and well-maintained.

## Differences vs AOSP / what's missing

Without the AOSP source synced into this checkout, this is a guess based on the public
Pixel branches: missing relative to mainline is likely the alt-mode policy chooser,
the moisture-detection orchestration, the bond with `bms`'s charge-policy voter, and any
TBT/USB4 retimer integration (felix uses standard USB-3.x DP alt-mode, no TBT). Mainline
would surface a working CC orientation + PD contract + charging-port detection out of
the box if the felix DT just instantiates `tcpci-maxim` on the right I2C bus with the
right interrupt — which it currently does not.

## Boot-relevance reasoning

USB-C / PD doesn't gate boot. The kernel will mount root from UFS without any typec
driver loaded; PD only matters when you want >5V charging or alt-mode DisplayPort. Score 2
because (a) it's a post-boot peripheral, (b) felix already boots end-to-end without it,
(c) mainline covers the silicon adequately if/when someone wires up the DT node. Zero
relationship to the (now-resolved) UFS HS-Rate-B blocker.

**However: 8/10 for the Phase B (full DRD) USB gadget bring-up task.** felix
uses MAX77759 as TCPC and Phase A is hard-pinned to `dr_mode = "peripheral"`
exactly because no TCPC means no role-switch. The MAX77759 TCPC subfunction
(distinct from the charger half — see [bms.md](bms.md)) has no mainline
path and must be ported from AOSP. Phase B's deliverable: instantiate
`tcpci-maxim` (or a felix-specific `tcpci_max77759`) on the right I2C bus
with the right interrupt + a Type-C connector + USB-role-switch wiring +
flip `dr_mode` to `"otg"`.

## 7.1 rebase impact

`drivers/usb/typec/tcpm/tcpci_maxim_core.c` and `maxim_contaminant.c` were
upstreamed by Google itself; if 7.1 includes any churn there (new variant
support, refactors), we'll inherit it. The MAX77759 TCPC subfunction
specifically still needs porting from AOSP — that situation is unchanged
between 7.0 and 7.1 per the
`reference_mainline_gs201_status.md` snapshot.
