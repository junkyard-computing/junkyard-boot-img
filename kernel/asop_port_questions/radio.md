# radio

- **AOSP path**: `private/google-modules/radio/samsung/{s5300,s5400}/`
- **Mainline counterpart**: **NONE**
- **Status**: not-ported
- **Boot-relevance score**: 2/10

## What it does

The Samsung "ExynosModemIF" / CPIF (CP InterFace) stack — the AP-side driver for the Shannon cellular modem CP that Tensor G2 (s5300) and Tensor G3 (s5400) integrate. It is a sprawling subsystem: SHM (shared-memory) and PCIe link devices for AP↔CP IPC, MCU mailbox IPC (`MCU_IPC` — the 16-IRQ / 256-byte mailbox between AP and CP), CP secure boot via PMUCAL, packet processor (PKTPROC) for hardware UL/DL accel, DIT (Direct Internet Packet Transfer) accelerator, packet IO via `ipc_io_device` / `bootdump_io_device`, IOSM-style link control, page recycling for skb pools, CLAT and LRO offload, BTL (Back-Trace-Log), CP thermal-zone reporting, vendor hooks into the Android networking path, and a CP UART switch driven by PMU. The Kconfig (`Kconfig` in `s5300/`) gives a sense of scope: 60+ tristate options.

Felix (gs201) uses `s5300` (built around `SEC_MODEM_S5000AP` — shared-memory link, SHM_IPC, MCU_IPC, CP_PMUCAL, CP_SECURE_BOOT). Hard-depends on the out-of-tree `GOOGLE_MODEMCTL` driver from `private/google-modules/misc` (or wherever modemctl lives) for boot/reset/power sequencing.

## Mainline equivalent

Nothing in mainline drives the Shannon CP. There is no upstream `samsung,shannon-modem` binding, no upstream `MCU_IPC` mailbox driver, no upstream CP-PMUCAL secure-boot path. The closest spirit-equivalent is again `drivers/remoteproc/qcom_q6v5*` for Qualcomm modems plus `drivers/net/wwan/iosm/*` for Intel IOSM modems — but no shared code. Mainline `drivers/net/wwan/` exists as the framework slot a future Shannon driver could plug into, but no Shannon driver lives there.

## Differences vs AOSP / what's missing

100% missing. A real port would need: the MCU_IPC mailbox driver, the CP secure-boot loader (which has to talk to Samsung's BL31 / EL3 services and is locked-bootloader-coupled), the SHM link device with its descriptor rings, a wwan-framework netdev binding to surface the data path, and pktproc / DIT accelerator drivers. This is an even larger effort than porting AOC.

## Boot-relevance reasoning

Score 2/10. The cellular modem is not on the boot path — felix boots, mounts rootfs, and runs a Debian shell over USB-C ethernet without ever waking the CP. Modem absence costs cellular data and SMS but nothing the AP needs. There is one possible footgun: if mainline's exynos PMU / PCIe code happens to power-gate a domain the bootloader-launched CP firmware was using, the CP can crash and (depending on shared-resource arbitration) kick stray IRQs or do something noisy on shared memory — but in practice we have not observed any such failure; the boot is clean. Score is 2 (post-boot peripheral, not-needed-for-boot).
