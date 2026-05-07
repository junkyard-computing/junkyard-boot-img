# aoc

- **AOSP path**: `private/google-modules/aoc/`
- **Mainline counterpart**: **NONE**
- **Status**: not-ported
- **Boot-relevance score**: 6/10

## What it does

AOC ("Always-On Compute") is a Google-designed Cortex-A32 + Cortex-M coprocessor cluster baked into the Whitechapel SoCs (gs101 / gs201 / Zuma) that handles always-on workloads — low-power audio decode and DSP, microphone capture / hotword detection (Pixel "Hey Google"), low-power sensor fusion (CHRE — Context Hub Runtime Environment), USB audio offload, and miscellaneous TBN/UWB service plumbing. The driver tree at `private/google-modules/aoc/` is the AP-side firmware loader, IPC fabric, mailbox glue (`mailbox-wc.c`, the "Whitechapel" mailbox that's distinct from upstream `exynos-mailbox.c`), shared-DRAM/SRAM management with IOMMU + S2MPU programming, GSA-mediated firmware authentication (`gsa_aoc.h`), an `aoc` device bus that fans services out to character devices (`aoc_char_dev`, `aoc_channel_dev`, `aoc_control_dev`, `aoc_tbn_service_dev`, `aoc_uwb_service_dev`), and a complete ALSA card under `alsa/` (15+ files: PCM, compress, voice, VoIP, in-call, USB-offload paths). It also owns the AOC ramdump / SSCD crash-restart machinery and the watchdog IRQ handler. Roughly 2800 lines in `aoc.c` alone, ~3600 LoC across the core, with another ~5000 LoC of ALSA on top.

## Mainline equivalent

Nothing. AOC is Google-proprietary silicon glued onto Exynos via a custom mailbox (`mailbox-wc.c`, compatible `google,mailbox-whi-channel`), GSA-authenticated firmware, S2MPU-walled reserved DRAM, and a bespoke service-discovery IPC layout (`aoc_ipc_core` — see the sibling `aoc-ipc.md`). The closest analogue in upstream-spirit terms would be the Qualcomm remoteproc + APR + qcom_q6v5 stack, or the MediaTek SCP / DSP remoteproc drivers — but no code can be shared, only the architectural pattern. The mainline `drivers/mailbox/exynos-mailbox.c` driver targets the conventional Exynos mailbox IP and does not match the WC mailbox register layout. Some `aoc*` hits in mainline (`drivers/clk/meson/*-aoclk*`, `clock/g12a-aoclkc.h`) are Amlogic always-on clock controllers and entirely unrelated.

## Differences vs AOSP / what's missing

Everything is missing. There is no mainline AOC driver, no AOC device-tree binding (`google,aoc`), no Whitechapel mailbox driver, no `gsa_aoc` GSA authentication API, no `ion_physical_heap` style carveout helper, no `aoc_ipc_core` service descriptor library. Any port would need: (1) a mailbox controller for the WC mailbox IP, (2) a remoteproc-style firmware loader that handles GSA handoff (or stubs GSA out — but on a locked bootloader you cannot bypass it, so a working port has to talk to the trusted GSA service), (3) an IPC bus type that fans services out to char/ALSA devices, (4) the ALSA machine driver and dozens of PCM front-ends, (5) the IOMMU group + S2MPU programming sequence so AOC's DMA stays inside the carveout. Realistically this is a multi-month subsystem effort.

## Boot-relevance reasoning

Score 6/10. The system already boots without a kernel-side AOC driver because
mainline never tries to boot AOC, never claims its IRQ, and never reads/writes
its mailbox.

History note: there was a brief period where we suspected an "AOC starves UART
RX" failure mode and tried to mitigate it by dropping `/vendor/firmware/*`
blobs into the rootfs (with `firmware_class.path=/vendor/firmware` on the
cmdline). That was the **AOSP-side** UART RX issue, not the mainline one. On
mainline, AOC never spins up because no driver is bound, so it doesn't
actually retry-loop on missing firmware and doesn't actually starve UART RX.
The real mainline UART RX bug was a binding-doc trap in `samsung_tty`
(`samsung,exynos850-uart` selects 8-bit MMIO; gs201's UART block needs 32-bit
access). Switching the DT compat to `google,gs101-uart` (UPIO_MEM32) fixed
RX. The `/vendor/firmware` install is kept as belt-and-suspenders, not as a
real fix — see [gs-tty.md](gs-tty.md).

So for the literal "does it POST and reach a login prompt" question the
answer is "no porting needed." However, AOC is the gateway to a huge swath of
the Pixel's interesting hardware: the on-die microphones, the low-power
sensor hub, hotword detection, USB audio offload, and low-power audio
playback all funnel through AOC services. Without this driver, none of that
hardware is reachable from Linux. The score would be 9-10 if AOC's absence
broke boot, but it doesn't — so 6 reflects "important subsystem, big
future-work flag, post-boot value only." This is the highest-value but also
the hardest-to-port AOSP module in the tree.
