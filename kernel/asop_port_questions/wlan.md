# wlan

- **AOSP path**: `private/google-modules/wlan/` (subdirs: `bcm4383`, `bcm4389`, `bcm4390`, `bcm4398`, `dhd43752p`, `wcn6740`, `wlan_ptracker`)
- **Mainline counterpart**: `drivers/net/wireless/broadcom/brcm80211/brcmfmac/` (FullMAC driver) — but **NOT** the same protocol family
- **Status**: not-ported (the AOSP DHD driver is not in mainline, and the mainline `brcmfmac` driver does not support BCM4389)
- **Boot-relevance score**: 2/10

## What it does

The vendor-supplied "DHD" (Dongle Host Driver) for Broadcom FullMAC Wi-Fi chipsets — the proprietary Broadcom code path that has historically shipped out-of-tree as `bcmdhd`. Felix uses **`bcm4389`** (Broadcom BCM4389 Wi-Fi 6E + BT combo). Other subdirs are the same driver family forked per chip generation: `bcm4383` (Wi-Fi 7), `bcm4390`, `bcm4398`, `dhd43752p`. `wcn6740/` is the parallel Qualcomm Snapdragon-Connectivity WLAN driver shipped for Qualcomm-radio Pixels (qcacld-3.0 + cnss2 + mhi + qrtr — large, separate). `wlan_ptracker/` is a Google packet-tracker overlay for diagnostics.

The BCM4389 directory alone contains hundreds of files: the full `dhd_*` core (linux glue, PCIe bus, SDIO bus, debug rings, packet logging, IP-flow filters, custom-CIS NVRAM handling — `dhd_custom_google.c`, `dhd_custom_cis.c`), the WL driver (`wl_cfg80211*`, `wl_iw.c`), bcm utility libs (`bcmutils`, `bcmevent`, `bcmwifi_channels`), and a copy of the `brcmf`-style firmware-event plumbing. It's a complete cfg80211 driver, just not the upstream one.

## Mainline equivalent

`drivers/net/wireless/broadcom/brcm80211/` ships the FOSS Broadcom drivers:
- `brcmfmac/` — FullMAC driver, the mainline analogue of bcmdhd. Supports older BCM43xx-series Wi-Fi 5 generation (BCM43430, BCM4356, BCM4359, etc.), more recent additions, and BCM4378/BCM4377 (Apple parts).
- `brcmsmac/` — older softmac driver.
- `b43`, `b43legacy` — even older PCI/PCIe softmac.

**`brcmfmac` does not currently support BCM4389.** Apple's BCM4378 is the closest supported relative; its firmware loading and chip-init paths are similar but not identical, and PCIe/SDIO board glue differs.

## Differences vs AOSP / what's missing

Two reasonable port paths:
1. **Lift the AOSP bcmdhd-bcm4389 driver verbatim** as an out-of-tree module. This is what the felix CLAUDE.md captures as the current expectation — note `bcmdhd4389` is in the *blacklist* (`/etc/modprobe.d/blacklist.conf`) and is also sed'd out of `module_order.txt` so dracut doesn't try to force-load it before userspace blacklisting takes effect. So even when present, the build is configured to keep it offline.
2. **Extend mainline `brcmfmac` to support BCM4389** — much more work, would need a chip ID table entry, firmware filename mapping, PCIe board-glue entries, and reverse-engineering or vendor cooperation on any chip-init / PHY-init quirks. No one is doing this upstream today.

The `wcn6740/` Qualcomm tree is irrelevant for felix.

## Boot-relevance reasoning

Score 2/10. Wi-Fi is a post-boot peripheral. Felix's boot path is wired ethernet (USB-C) and does not need WLAN. The blacklist treatment makes the intent explicit: even if the bcmdhd module is present, we deliberately keep it from loading in early-boot because it has historically been a source of long probe stalls, panics with stale firmware, and IRQ storms when the chip's regulator sequencing isn't honored. Score is 2 (post-boot peripheral, deliberately not loaded). Future networking work might change this, but it does not gate boot today.
