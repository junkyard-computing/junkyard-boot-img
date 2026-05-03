# gps

- **AOSP path**: `private/google-modules/gps/broadcom/bcm47765/`
- **Mainline counterpart**: **NONE**
- **Status**: not-ported
- **Boot-relevance score**: 1/10

## What it does

Broadcom BCM47765 GNSS receiver driver, SPI-attached. Two main pieces:

- `bcm_gps_spi.c` / `bcm_gps_regs.c` — SPI master client driver for the BCM47765 chip (`CONFIG_BCM_GPS_SPI_DRIVER`). Handles register I/O, IRQ-driven RX, GPIO-based reset / power / mcu-req lines, and the chip-specific framing.
- `bbd.c` / `bbd_pps_gpio.c` — "Broadcom Bridge Driver" (BBD), a misc-device char interface (`/dev/bbd_*`) that pipes raw SSI/UART-encapsulated GNSS data + control messages between the kernel and userspace `gpsd`-equivalent (the Broadcom HAL / `gpsd-bcm` daemon). Includes a GPIO-driven 1-PPS interface for time-pulse capture.

Userspace contract is a pile of `/dev/bbd_*` character devices that the proprietary Google/Broadcom GNSS HAL consumes; nothing in the kernel speaks the actual GNSS positioning protocol, that's all userspace.

## Mainline equivalent

None — and there's almost no precedent for in-kernel GNSS drivers. The closest thing in upstream is `drivers/gnss/` (a tiny GNSS subsystem that wraps SiRFstar / U-blox / MediaTek receivers behind a serdev tty), but there is no BCM47765 driver there. The conventional upstream pattern for a SPI-attached GNSS chip is to expose it via `spidev` or to write a slim `drivers/gnss/` driver that funnels NMEA/UBX up to userspace; the BBD-style char-device mux is non-idiomatic upstream.

## Differences vs AOSP / what's missing

Everything is missing. A port would either (a) write a proper `drivers/gnss/` driver for the BCM47765 (which means reverse-engineering the SPI framing if Broadcom won't share docs), or (b) lift `bcm_gps_spi.c` + `bbd.c` verbatim. Either way a userspace HAL is also required, which Google does not ship as open source.

## Boot-relevance reasoning

Score 1/10. GPS has zero involvement in boot. The chip sits on a SPI bus the AP can leave entirely powered down. Felix boots fine without it. Listed at "1" rather than "2" because unlike Bluetooth/NFC/WLAN there isn't even a debug or tooling reason to want this driver early — it's purely an end-user feature.
