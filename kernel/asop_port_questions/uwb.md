# uwb

- **AOSP path**: `private/google-modules/uwb/qorvo/{dw3000,qm35}/`
- **Mainline counterpart**: **NONE** (only the `net/ieee802154` framework exists; no DW3000 driver upstream)
- **Status**: not-ported
- **Boot-relevance score**: 1/10

## What it does

Qorvo (formerly Decawave) Ultra-Wide-Band ranging radio drivers, used for precision indoor positioning, Nearby Share / Find-My-Device-style proximity, and digital car keys (CCC):

- `dw3000/` — Driver for the Qorvo DW3000 series UWB transceiver. SPI-attached. Subdirs: `kernel/` (the Linux SPI/IRQ driver and chardev/IOCTL interface), `mac/` (IEEE 802.15.4 / FiRa MAC layer implementation), `tools/` (userspace helpers).
- `qm35/qm35s/` — Driver for the Qorvo QM35 successor chip (HSSPI transport: `hsspi.c`, `hsspi_coredump.c`, `hsspi_log.c`, plus `debug_qmrom.c` for the ROM-mode debugger). felix is shipped with the DW3000-series part; QM35 is for newer Pixels.

These drivers do not use the in-kernel `nl802154` netlink interface; they expose Qorvo-style char-device ioctls so the userspace UWB stack (Google's UCI service / FiRa / CCC stack) can drive them.

## Mainline equivalent

None for the Qorvo parts. Mainline has:
- `net/ieee802154/` and `drivers/net/ieee802154/` — the generic 802.15.4 framework plus a handful of supported transceivers (Atmel AT86RF230, MRF24J40, CC2520, etc.). This is what an *upstream-shaped* port would target.

There is no upstream DW3000 or QM35 driver, and the `bindings/net/ieee802154` directory has no Qorvo entry.

## Differences vs AOSP / what's missing

100% missing in mainline. A port would have to lift the AOSP source as out-of-tree modules. There has been some out-of-tree-but-public DW1000/DW3000 work for hobbyist use that could potentially serve as a starting point, but none of it is in `linux-next`.

## Boot-relevance reasoning

Score 1/10. UWB has zero boot relevance. The chip sits on a SPI bus that can be left powered down; no boot-path code touches it; felix boots fine without it. Same tier as GPS — purely an end-user feature, no debug or tooling reason to bring it up early.
