# gs-spi

- **AOSP path**: `private/google-modules/soc/gs/drivers/spi/`
- **Mainline counterpart**: [`drivers/spi/spi-s3c64xx.c`](kernel/source/drivers/spi/spi-s3c64xx.c)
- **Status**: ported
- **Boot-relevance score**: 3/10

## What it does

`spi-s3c64xx.c` (`SPI_S3C64XX_GS`) — vendored copy of the standard Samsung S3C64XX SPI controller driver. Used for any peripheral SPI lines (GNSS, fingerprint, eSE, sometimes ToF sensors).

## Mainline equivalent

Mainline `drivers/spi/spi-s3c64xx.c` is the upstream of the same driver and supports current Exynos SoCs through the USI (Universal Serial Interface) wrapper that gs101/gs201 use.

## Differences vs AOSP / what's missing

Mostly nil. Downstream may have minor tweaks (per-USI quirks, TX/RX FIFO threshold tuning) but nothing structural.

## Boot-relevance reasoning

**Score 3**: SPI is needed for fingerprint/GNSS/secure-element/etc. — none of which are on the Linux boot path. Not relevant to UFS.
