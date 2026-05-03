# GSA / KDN porting feasibility for mainline gs201

**Bottom-line estimate.** The KDN call is **not** an SMC. It is a synchronous
exchange over a Samsung-style 16-shared-register MMIO mailbox at `0x17c90000`
talking to a separate on-die security processor (the GSA). There is no
TF-A/SMCCC shortcut: BL31 on gs201 does not export a KDN service, and AOSP's
own driver does not call any SMC for KDN ops — it just writes the mailbox
shared registers and waits for an IRQ. The realistic options are therefore
"port the mailbox half of the GSA driver" (no Trusty needed for KDN), or "skip
this and confirm mainline UFS coherency really needs it." Best case is roughly
**~150–250 lines** of new kernel code (a tiny in-tree platform driver + DT node
+ five-line UFS hookup): mailbox MMIO, IRQ handler, one synchronous
`exec_mbox_cmd_sync_locked()` clone, and a single
`GSA_MB_CMD_KDN_SET_OP_MODE` (cmd `75`) issuance with two args
(`mode=2 KDN_SW_KDF_MODE`, `descr=0 KDN_UFS_DESCR_TYPE_PRDT`). Middle case
(in-tree GSA shim that exposes the same API surface for any future caller):
~3 small files, ~600 lines total. Worst case (the GSA firmware on felix has
been re-locked or no longer accepts mailbox commands until Trusty has shaken
hands with it through `gsa_tz`) — solvable but unattractive: it pulls in
Google's out-of-tree Trusty IPC bus driver (~5k lines), which is **not** in
mainline. Recommendation: try the mailbox-only shim first, and only as a
**falsification probe** — given the strong inference that the call merely
toggles KDN-mode bits in the HSI2 controller (visible at
`HSI2_KDN_CONTROL_MONITOR + 0x400`), a faster experiment is to (a) read
`HSI2_KDN_CONTROL_MONITOR` early to see whether MKE/RDY are already set by
the bootloader, and (b) try setting `MKE_MONITOR | DT=0` directly via sysreg
write (if the register is in fact writable from EL2/NS) before investing in
the mailbox port.

---

## 1. What the call actually does

`gsa_kdn_set_operating_mode(MKE=1, DT=0)` in the AOSP driver
(`gsa_core.c:376`) ends up in `gsa_send_cmd()` →
`gsa_send_mbox_cmd_locked()` → `exec_mbox_cmd_sync_locked()` in
`gsa_mbox.c:255`. That last function is just MMIO:

```
writel(75 /*GSA_MB_CMD_KDN_SET_OP_MODE*/, base + 0x80);  // SR0 = cmd
writel(2,                                base + 0x84);  // SR1 = argc
writel(2 /*KDN_SW_KDF_MODE*/,            base + 0x88);  // SR2 = mode
writel(0 /*KDN_UFS_DESCR_TYPE_PRDT*/,    base + 0x8c);  // SR3 = descr
writel(BIT(0),                           base + 0x40);  // INTGR1: raise req
/* wait on IRQ -> SR0 == cmd | (1<<31), SR1 == GSA_MB_OK (0) */
```

Mailbox base for `gs201`: `reg = <0 0x17c90000 0x1000>` (`gs201-gsa.dtsi:9`).
IRQ line: `IRQ_MAILBOX_GSA2NONTZ_GSA` (Google internal symbol; numerical
SPI not in tree, would need to be discovered from BL31 or by reading the GIC
distributor). Register layout:

| reg | offset | role |
|---|---|---|
| `MBOX_INTGR1` | `0x40` | host→GSA "request raised" doorbell, `BIT(0)` |
| `MBOX_INTMR0` / `INTCR0` / `INTMSR0` | `0x28` / `0x24` / `0x30` | GSA→host response IRQ mask/clear/status, `BIT(0)` |
| `MBOX_SR_REG(0..15)` | `0x80..0xbc` | shared regs: SR0=cmd, SR1=argc, SR2..=args; on response SR0=cmd\|(1<<31), SR1=err, SR2=argc, SR3..=rsp args |

The GSA-side action is opaque to the AP — it's firmware that reads the
SRs and pokes the HSI2 KDN controller's mode bits, which the AOSP driver
can subsequently *verify* by reading `HSI2_KDN_CONTROL_MONITOR` at
sysreg+`0x400` (`ufs-exynos-crypto.c:64`). The bits visible there
(`MKE_MONITOR=BIT(0)`, `DT_MONITOR=BIT(1)`, `RDY_MONITOR=BIT(2)`) are the
entire observable side effect on the AP side. **Whether KDN-mode also
unblocks the controller's coherent AXI write path is the open hypothesis;
nothing in the GSA driver itself is AXI-related.**

Could we shortcut with a single SMC or MMIO write?
- **SMC**: no, BL31 on this SoC has no KDN entrypoint. The AOSP path
  doesn't issue an SMC; checking the TF-A repo we shipped (`tools/`
  list, plus AOSP tree grep) confirms the only crypto-adjacent SMCs are
  the FMP/SMU set (`SMC_CMD_FMP_SECURITY`, `SMC_CMD_SMU`,
  `SMC_CMD_FMP_SMU_RESUME`, `SMC_CMD_FMP_SMU_DUMP`,
  `SMC_CMD_FMP_USE_OTP_KEY`) — and mainline already issues the relevant
  ones (`gs201_ufs_smu_init`).
- **MMIO**: maybe. If the HSI2 KDN_CONTROL register at sysreg+0x400 is
  writable from NS-EL1/EL2 (not just *readable* as the monitor view
  suggests), we can directly poke `MKE | (DT<<1)` and skip GSA entirely.
  The naming (`*_MONITOR`) and the AOSP driver's choice to *only* read
  it suggest the actual control register is GSA-owned, but this is
  worth confirming with a single `regmap_write` experiment in mainline
  before any porting effort. If GSA secured the register (S2MPU / TZ
  Prot), the write will silently NOP or trap.

## 2. GSA driver size and dependency surface

`drivers/soc/google/gsa/`:

| file | lines | role | needed for KDN? |
|---|---|---|---|
| `gsa_mbox.c` / `.h` | 599 / 212 | mailbox MMIO + sync send | **yes** |
| `gsa_core.c` | 918 | platform driver, KDN/AOC/TPU/DSP/SJTAG wrappers, cdev | partial; only KDN path + probe |
| `gsa_log.c` / `.h` | 137 / 14 | reads GSA log from reserved-mem | optional |
| `gsa_tz.c` / `.h` | 236 / 35 | Trusty TIPC client, used **only** for AOC/TPU/DSP `hwmgr` | **no** for KDN |
| `gsa_gsc.c` | 470 | GSC (Cr50) proxy chrdev | no |
| `tzprot.c` / `tzprot-ipc.h` | 100 / 50 | independent module | no |
| `hwmgr-ipc.h` | 40 | Trusty port names + structs | no |
| `gsa_priv.h` | 20 | internal helpers | yes (5 lines) |

Dependency surface for the **KDN-only** subset:
- Standard kernel APIs (platform/of/dma/irq/regmap/completion). All in mainline.
- A coherent DMA bounce buffer (`dmam_alloc_coherent`, PAGE_SIZE) for KDN
  data commands — but `KDN_SET_OP_MODE` is *not* a data-xfer command
  (`is_data_xfer()` in `gsa_mbox.c:435` does not list it), so the bounce
  buffer is not required for our specific call. Skip it for the bypass.
- `pkvm-s2mpu` (`CONFIG_GSA_PKVM`): only needed for data-xfer paths, again
  irrelevant to `KDN_SET_OP_MODE`.
- `linux/trusty/trusty_ipc.h`: pulled in via `gsa_tz.h`, but `gsa_tz.c` is
  only instantiated by `gsa_probe()` for AOC/TPU/DSP service channels.
  A KDN-only port can simply omit `gsa_tz.o` from the build and stub
  out the three `gsa_tz_chan_ctx_init()` calls in `gsa_probe()`. **No
  Trusty needed.**

So for our specific call the dependency cone is essentially: a Samsung-style
mailbox driver + one platform device. That is small and self-contained.

## 3. TF-A exposure

Verdict: **none for KDN**. The AOSP driver does not invoke any SMC for KDN
operations. There is no `SMC_FC_KDN_*` or SiP function ID. The mailbox is a
direct AP↔GSA hardware peripheral; BL31 is not in the path. The few
crypto-adjacent SMCs in the AOSP probe path (`SMC_CMD_FMP_SECURITY` /
`SMC_CMD_SMU` / `SMC_CMD_FMP_SMU_RESUME`) are already issued by mainline
`gs201_ufs_smu_init` (see `iocc-coherency-diff.md` §4 — "mainline is a
strict superset"). Therefore a five-line "issue an SMC and forget about
GSA" patch is **not** available; if we want the KDN side effect we have to
either drive the mailbox or write the HSI2 KDN_CONTROL register directly.

## 4. DT plumbing

AOSP `gs201-gsa.dtsi`:

```
gsa: gsa-ns {
    compatible = "google,gs101-gsa-v1";
    #address-cells = <2>;
    #size-cells = <1>;
    reg = <0 0x17c90000 0x1000>;          /* NS mailbox */
    interrupts = <GIC_SPI IRQ_MAILBOX_GSA2NONTZ_GSA IRQ_TYPE_LEVEL_HIGH>;
    s2mpu = <&s2mpu_gsa>;                  /* only used under CONFIG_GSA_PKVM */
};
```

UFS consumer side: `gs201-ufs.dtsi:79`: `gsa-device = <&gsa>;`.

Mainline status: `arch/arm64/boot/dts/exynos/google/gs201.dtsi` and
`gs101.dtsi` already reserve a memory region (`gsa_reserved_protected:
gsa@90200000`) but **do not declare a GSA mailbox node**. The mailbox
peripheral at `0x17c90000` is unbound. The `IRQ_MAILBOX_GSA2NONTZ_GSA`
SPI number is a Google-internal symbol; we'd need to dump it from the
factory dtb (or from the felix dtbo overlays) — straightforward,
~5 minutes with `fdtdump`.

Mainline also has the corresponding peripheral neighbours
(`pinctrl_gsacore`, `pinctrl_gsactrl`, `gsa_reserved_protected`), so
the SoC-level plumbing is partly there and adding a single
`gsa@17c90000` node plus a `gsa-device` phandle on `&ufs_0` is small.

## 5. One-paragraph estimate by bucket

- **Best case (mailbox-only shim, KDN_SET_OP_MODE only)**: a single
  `drivers/soc/samsung/exynos-gsa-mbox.c` (~200 LoC) plus
  `arch/arm64/boot/dts/exynos/google/gs201.dtsi` node (~10 LoC) plus
  ~10 LoC in `drivers/ufs/host/ufs-exynos.c` to look up the phandle and
  invoke the shim once at probe. Total **~220 LoC**, no out-of-tree
  dependencies. Acceptable as a *non-upstreamable* hack. Not
  upstreamable as-is because a mainline binding for "google,gs101-gsa"
  hasn't been proposed; but acceptable for our local tree.

- **Middle case (general GSA shim under `drivers/soc/google/`)**: port
  `gsa_mbox.[ch]`, slim `gsa_core.c` to the KDN/SJTAG paths only, drop
  `gsa_tz.[ch]`, `gsa_gsc.c`, `gsa_log.c`, `tzprot.c`, the cdev, and
  `CONFIG_GSA_PKVM`. ~3 files, ~600 LoC. Adds the `kdn_program_key` /
  `kdn_restore_keys` / `kdn_derive_raw_secret` API for free, so the
  same shim later supports inline-encryption. Still no Trusty. Plausible
  to upstream eventually if Google would sign off on the binding.

- **Worst case (Trusty IPC required, e.g. felix GSA firmware has been
  hardened to refuse KDN mailbox commands until a Trusty handshake
  completes)**: pulls in `private/google-modules/trusty/` (several
  thousand LoC, out-of-tree, depends on `linux/trusty/`, on a smc-based
  RPC bus, and on a userspace Trusty stack we don't ship). **Not
  achievable in a public-tree mainline kernel** without lifting the
  whole Trusty IPC bus driver, which is itself an undertaking on the
  order of "port one full Android subsystem." If we hit this, the
  practical answer is: don't port it — instead, falsify the KDN-coherency
  hypothesis some other way (direct sysreg+0x400 write probe, or
  HSI2 NoC QoS dump per `iocc-coherency-diff.md` §6.3, or interconnect
  bandwidth vote).

## 6. Cheaper falsification probes to run before any porting

These are all 1–10-line changes in our existing mainline UFS driver and
should happen *before* the porting work above:

1. **Read `sysreg_hsi2 + 0x400` (HSI2_KDN_CONTROL_MONITOR) at probe**,
   before and after our IOCC write, and again right before the first
   UIC command. Existing mainline `gs201_dump_sysreg_hsi2_iocc`
   already does the @0x710 dump; add @0x400 the same way. If MKE=1 is
   already set by the bootloader, GSA porting is moot.
2. **Try writing `BIT(0)` to `sysreg_hsi2 + 0x400`** directly. If the
   register accepts the write (readback shows MKE=1), we have a
   five-line patch and zero porting required. If it silently NOPs, the
   register is GSA-owned and we need the mailbox.
3. **Boot under `kvm-arm.mode=protected`** and check whether HSI2 NoC
   CMU gates differ (per `MEMORY.md project_pkvm_cmu_unlock`). pKVM
   may also affect S2MPU which gates GSA's view of DRAM — orthogonal
   but worth correlating.

If none of those move the 0xab stuck-stamp, then the mailbox-shim port
in §5 best-case becomes the next experiment.
