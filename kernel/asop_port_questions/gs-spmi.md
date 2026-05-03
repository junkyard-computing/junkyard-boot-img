# gs-spmi

- **AOSP path**: `private/google-modules/soc/gs/drivers/spmi/`
- **Mainline counterpart**: NONE (the bit-bang variant); mainline has generic SPMI infra but no controller driver for the gs101/gs201 SPMI master
- **Status**: not-ported
- **Boot-relevance score**: 6/10

## What it does

`spmi_bit_bang.c` (`SPMI_BITBANG`) — a bit-bang SPMI controller used as a fallback / debug path to talk to PMICs over GPIO when the hardware SPMI master isn't available or trusted. Exposes itself as a standard SPMI controller so PMIC drivers (s2mpg14/15 on Zuma; on gs201 the s2mpg12/13 talk over Speedy and SPMI both depending on rev) can sit underneath.

## Mainline equivalent

Mainline has the SPMI core (`drivers/spmi/spmi.c`) and several controllers (Qualcomm pmic-arb, MTK PMIF, Apple, Hisi). No bit-bang driver. No dedicated gs101/gs201 SPMI master driver either — mainline expects the SPMI controller to be a real hardware block but the gs101/gs201 SoC has no exposed SPMI master IP that's been described to mainline.

## Differences vs AOSP / what's missing

The bit-bang controller and any DT bindings are absent. More importantly the actual hardware SPMI master inside gs201 (on the S5M-side of the AP) is undocumented in the mainline tree.

## Boot-relevance reasoning

**Score 6**: SPMI is the bus the gs201 PMIC subsystem (s2mpg12/13) communicates over. Without an SPMI master driver in the kernel **the kernel cannot talk to the PMIC at all**, even if the s2mpg drivers were ported. This is a transitive blocker: porting the regulator/MFD stack is gated on first having a working SPMI controller. The bit-bang driver is the easiest path (you only need GPIO + timing), but it's slow and not great. Score 6 because it's a transitive blocker for power management, not directly UFS-related, but PMIC == regulator == UFS analog rails.
