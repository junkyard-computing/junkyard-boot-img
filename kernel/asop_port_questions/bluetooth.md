# bluetooth

- **AOSP path**: `private/google-modules/bluetooth/`
- **Mainline counterpart**: `drivers/bluetooth/btbcm.c`, `drivers/bluetooth/hci_bcm.c`, plus the generic `hci_uart` line discipline and rfkill core
- **Status**: partially-ported
- **Boot-relevance score**: 2/10

## What it does

Two subdirectories, both *power-management* glue around an HCI controller — neither implements an HCI transport itself:

- `broadcom/nitrous.c` — "Nitrous" BT power management driver (`compatible = "goog,nitrous"`). Drives the BT controller's power-enable GPIO, host-wake / dev-wake GPIOs (with configurable polarity), exposes an rfkill node, hooks into the serial core via PM-runtime callbacks so the UART gets powered up on TX, and listens on host-wake to wake the UART on incoming data. Targets a Broadcom BT chip on UART (likely BCM4389 combo BT, given the felix WLAN choice).
- `qcom/btpower.c` — Qualcomm equivalent for the WCN6740 combo, present in the tree because the same source tree builds for newer Pixels with QCA radios; not relevant for felix.

The actual HCI protocol stack (commands, ACL/SCO data, vendor-specific firmware patch RAM upload) is provided by upstream `hci_uart` + `btbcm`, which the AOSP build also pulls in.

## Mainline equivalent

The HCI-level driver for Broadcom BT controllers — `drivers/bluetooth/btbcm.c` (vendor patches, firmware download) and `drivers/bluetooth/hci_bcm.c` (UART transport with the BCM-specific 3-wire/H4 + autobaud / hardware-flow handling) — already exists in mainline and is generally complete. What is **missing** in mainline is the `goog,nitrous` board-glue PM layer: GPIO power sequencing, the `host-wake-gpio`/`dev-wake-gpio` low-power protocol, and the rfkill node binding. There is no `goog,nitrous` device-tree binding upstream.

## Differences vs AOSP / what's missing

For a port: either lift `nitrous.c` verbatim (it's small, self-contained, and only uses standard kernel APIs — GPIO consumer, pinctrl, PM runtime, rfkill, plus an `exynos-cpupm` notifier that would have to be stubbed or replaced) or replace the GPIO sequencing with the equivalent device-tree bindings that `hci_bcm` already understands (`shutdown-gpios`, `device-wakeup-gpios`, `host-wakeup-gpios`). The latter is cleaner. The HCI layer itself does not need any porting work.

## Boot-relevance reasoning

Score 2/10. Bluetooth is a post-boot peripheral. Felix boots end-to-end and runs a usable Debian userspace without BT loaded. The only ways BT could break boot are: (a) a buggy probe blocks the UART subsystem (not happening — we don't probe `nitrous` at all on mainline), (b) GPIO/regulator contention (not observed). The vendor-firmware blob set we install for AOC also happens to include the BT firmware patch RAM, which would matter once we actually want to bring up BT, but it doesn't affect boot today.
