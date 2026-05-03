# GSA mailbox shim + CDR-lock re-frame (2026-05-03)

Day's net: a working **GSA KDN mailbox bypass** ported as ~100 inline LoC
without porting the rest of the GSA driver. Confirms the AOSP-vs-mainline
KDN_CTRL_MONITOR delta. **Does NOT fix dl_err 0x80000002.** The wedge
proximate cause is M-PHY CDR not locking on RX, not AXI-coherency. KDN
MKE bit was a real delta but a red herring for the wedge.

## What the shim is

Polling-based GSA mailbox client, inline in
[`ufs-exynos.c gs201_gsa_kdn_set_op_mode()`](../kernel/source/drivers/ufs/host/ufs-exynos.c).
Issues `GSA_MB_CMD_KDN_SET_OP_MODE = 75` to the GSA security processor at
HSI2 mailbox `0x17c90000`, with `KDN_SW_KDF_MODE = 2` and
`KDN_UFS_DESCR_TYPE_PRDT = 0`. Wire protocol matches AOSP's
`exec_mbox_cmd_sync_locked` byte-for-byte:

```
SR0(0x80) = 75   (cmd)
SR1(0x84) = 2    (argc)
SR2(0x88) = 2    (mode)
SR3(0x8c) = 0    (descr)
INTGR1(0x40) = 0x1  (doorbell)
poll INTMSR0(0x30) bit 0 for response
read SR0 (expect 0x8000004b = cmd | 0x80000000)
read SR1 (expect 0x0 = GSA_MB_OK)
clear INTCR0(0x24) bit 0
```

No IRQ wiring — polling for ~10ms ceiling is sufficient since this is
one-shot at probe and KDN response time is sub-millisecond.

No Trusty handshake required — `gsa_kdn_set_operating_mode` does not
go through the `gsa_tz` Trusty-IPC client (that path is only for AOC,
TPU, DSP `hwmgr` services). KDN goes through bare mailbox MMIO.

## Empirical validation

Test cycle (2026-05-03_020247.log, post-power-cycle):

| stage | @0x710 IOCC | @0x400 KDN_CTRL_MON |
|---|---|---|
| before-iocc-write | 0x13 | 0x4 (RDY only, MKE=0) |
| after-iocc-write | 0x13 | 0x4 (no change from IOCC write) |
| **after-kdn-mbox-cmd** | **0x13** | **0x5 (MKE=1)** ← matches AOSP |

Before the shim ran, direct `regmap_update_bits(@0x400, BIT(0), BIT(0))`
**silently NOPs** — write returns success but readback unchanged. KDN
ownership of the register confirmed. Mailbox is the only path.

Pre-shim/post-shim wedge behavior is **identical**: dl_err 0x80000002
fires at ~1910ms after PMC, UPIU RSP slots stamped `abababab`. So
KDN MKE is necessary-not-sufficient for whatever AOSP's full setup
provides — and likely irrelevant to the dl_err cause.

## Why it's still upstream-worth

Independent of the dl_err investigation, the shim is shippable:

1. Demonstrates that gs201's KDN can be programmed without porting the
   600+ LoC GSA driver, the 200+ LoC `gsa_tz` Trusty client, the 5k+
   LoC out-of-tree Trusty IPC bus driver, or any userspace component.
2. Same approach applies to other gs201 GSA mailbox commands (key
   programming, key restore, FIPS self-test, debug dump).
3. Refactoring shape: extract from `ufs-exynos.c` into
   `drivers/soc/samsung/exynos-gsa-mbox.c` with a small public API
   (`exynos_gsa_kdn_set_op_mode(struct device *)`); add
   `gsa@17c90000` DT node with `compatible = "google,gs201-gsa-mbox"`,
   `reg = <0 0x17c90000 0 0x1000>`, `interrupts = <GIC_SPI 363
   IRQ_TYPE_LEVEL_HIGH>`; consumers like UFS pick up via phandle.
4. Sub-binding hasn't been proposed upstream yet — would need to clear
   with samsung-soc maintainers.

## What today's tests rule out

* **Hypothesis: "AOSP has a missing sideband shareability write"** —
  killed by [iocc-coherency-diff.md](iocc-coherency-diff.md). Both
  AOSP and mainline write exactly one register: sysreg+0x710 mask=0x3
  val=0x3, where bit 0 = RD-Sharable and bit 1 = WR-Sharable. No second
  AXI write register exists.
* **Hypothesis: "KDN MKE bit is the wedge gate"** — killed by today's
  shim test. KDN_CTRL_MON now matches AOSP byte-for-byte; wedge persists
  at the same timing.
* **Hypothesis: "iocc bits 0:1 are no-op"** — killed by the falsification
  probe. With iocc_val=0 the wedge fires ~6s earlier with a different
  failure path (no dl_err, faster abort, same 0xab stamp). So
  sysreg+0x710 IS load-bearing for *something* downstream of link-up
  but earlier than dl_err.
* **Hypothesis: "the bug is AXI-coherency layer"** — refined. The 0xab
  stamp does indicate "controller's response-slot AXI write didn't
  land" but the cause is one layer up: the controller never received
  a valid response from the device because RX CDR didn't lock
  (R339=0x00 across the 8ms polling window). With no decoded response
  to write, the controller never issues the AXI write that would
  overwrite the 0xab pre-fill.

## Re-framed wedge cause: M-PHY CDR-lock failure on RX

Per same UART log:

```
[1.811] cdr-instr lane=0 entry: R338(CAL_DONE)=0x9f R222(OVRD)=0x08
                                R336=0x00 R337=0xa1 R33A=0xff R33B=0x00
[1.834] failed to get cdr lock (lane=0, TRSV_REG339 first=0x00 last=0x00)
[8.13]  dl_err[0] = 0x80000002 at 1910337 us  (TC0_REPLAY_TIMER_EXPIRED)
[8.34]  UPIU RSP: ... 00000000: abababab abababab abababab abababab
```

R339 (CDR_FLD_CK_MODE_DONE) stays at 0x00 across the entire 8ms poll
window — same signal the project memory notes from 2026-04-26.
Whatever the actual missing write or sequence is, it should make R339
flip to a non-zero CDR-locked state.

## Highest-EV next experiment

Re-flash AOSP, devmem the PHY register window:

```
sudo busybox devmem 0x14704CE0 32   # R338 CAL_DONE
sudo busybox devmem 0x14704CE4 32   # R339 CDR-lock done
sudo busybox devmem 0x14704CE8 32   # R33A
sudo busybox devmem 0x14704CEC 32   # R33B
```

If on AOSP we see R339 set to a non-zero value when CDR has locked, we
know the lever is reachable from cal-if writes (refine candidate list).
If R339 is also 0x00 on AOSP and lock-success is signalled elsewhere,
we've been mis-instrumenting and need a different test point.

## State of the experimental code

* `kernel/source` (felix branch) HEAD: `4b716ee17603` (END_UFS_PHY_CFG
  terminator fix). Working tree is dirty with the GSA shim,
  `gs201_dump_sysreg_hsi2_iocc()` extended to also dump @0x400, and
  the `kdn-shim:` log lines in `gs201_ufs_drv_init()`. About 130 LoC
  added.
* The iocc=0 falsification block has been reverted (left as a comment
  block referencing the test result).
* The `regmap_update_bits(@0x400, ...)` direct-write probe was replaced
  with the actual mailbox call.
