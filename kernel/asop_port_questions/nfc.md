# nfc

- **AOSP path**: `private/google-modules/nfc/`
- **Mainline counterpart**: `drivers/nfc/st21nfca/` (related but different controller variant)
- **Status**: not-ported (felix's specific ST21NFC variant + ST54 ESE are not in mainline)
- **Boot-relevance score**: 2/10

## What it does

ST Microelectronics NFC driver stack:

- `st21nfc.c` / `st21nfc.h` (`CONFIG_NFC_ST21NFC`) — kernel driver for the ST21NFC NFC controller, I2C-attached. Exposes a `miscdevice` (`/dev/st21nfc`) that userspace (the Android NFC HAL) opens to send raw NCI frames to the chip. Handles IRQ-driven RX, reset GPIO sequencing, the FW-update mode entry, and an optional no-external-crystal config (`NFC_ST21NFC_NO_CRYSTAL`) for boards using internal RC oscillator timing.
- `ese/` — companion ST54 / ST33 SPI eSE (embedded Secure Element) driver (`CONFIG_ESE_ST54`, `CONFIG_ESE_ST33`). Exposes another miscdevice that the Android Secure Element HAL drives for contactless payments. felix has the ST54 eSE behind the ST21NFC.

Both are Google-tweaked vendor BSP drops of the ST reference drivers; the userspace contract is a raw HCI/NCI byte stream, not the in-kernel `nfc_core` / NCI subsystem.

## Mainline equivalent

`drivers/nfc/st21nfca/` exists and supports the **ST21NFCA** (note the trailing 'A') HCI variant, which is a different (older-generation) SoC from the ST21NFC the AOSP driver targets, despite the very similar name. It binds into the in-kernel `nfc_core` / `nfc_hci` framework rather than exposing a misc char device, so it is fundamentally a different userspace contract — it expects userspace to use libnfc / Linux NFC tools, not the Android NCI HAL.

There is **no upstream driver for the ST21NFC (no 'A')** as a misc-device + NCI passthrough, and **no upstream driver for the ST54 ESE**.

## Differences vs AOSP / what's missing

The mainline `st21nfca` driver almost certainly cannot drive felix's chip without significant rework — different chip ID, different boot/FW protocol, different interrupt semantics. The pragmatic port is to lift `st21nfc.c` + the `ese/` tree verbatim as out-of-tree modules. Both are small (single-file) drivers with no exotic dependencies.

## Boot-relevance reasoning

Score 2/10. NFC and the secure element are entirely off the boot path. The chip sits on I2C/SPI buses the AP can leave idle; felix boots fine without either driver loaded. Standard post-boot-peripheral treatment.
