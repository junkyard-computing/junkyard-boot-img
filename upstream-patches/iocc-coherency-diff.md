# IOCC / Coherency Diff: AOSP vendor driver vs. mainline gs201 port

Empirical signal: UPIU response slot reads back `abababab abababab ...`
(the 0xab stuck-stamp). Controller's AXI write to coherent DRAM is not
landing. Both AOSP-source (`source.aosp-backup`) and mainline
(`source/drivers/ufs/host/ufs-exynos.c`) drivers reproduce the wedge,
even though both program `sysreg_hsi2 + 0x710` mask=0x3 val=0x3.

## TL;DR — what the diff actually shows

**There is no missing sideband coherency / shareability register write
in the mainline port.** AOSP and mainline both touch exactly one
sysreg word at probe time (`sysreg_hsi2 + 0x710`, mask=0x3, val=0x3),
both via `regmap_update_bits` on the same syscon phandle. There is no
separate "AXI write shareability" register on this SoC — `0x710` is a
single 2-bit field where bit0 = RD-Sharable, bit1 = WR-Sharable
(`UFS_GS101_RD_SHARABLE | UFS_GS101_WR_SHARABLE` mainline,
`ufs-iocc { val = <0x3> }` AOSP). The hypothesis "AOSP writes both an
AXI-RD and an AXI-WR register and we only do RD" is **falsified by
the source** — `0x3` is the full pair.

So the wedge cause is *not* a missed coherency MMIO write. It's
something else (CMU clock state, BL31-fenced UFSP region, IOCC
shareability fence at a layer above sysreg, or — most likely — the
sideband path the AOSP setup relies on but that mainline doesn't trip:
the unique post-link `WLU_EN` write timing, or the `pixel_init` GSA
KDN-mode call, or the AOSP `ufs-pixel.c` vendor-hooks path).

The rest of this doc enumerates every difference systematically so
the next round of diff is on solid ground.

## 1. Coherency / shareability register writes at probe time

### AOSP

Single `regmap_update_bits` in the entire `drivers/ufs/` tree
(`ufs-exynos.c:499`):

```
regmap_update_bits(regmap_sys, 0x710, 0x3, 0x3);
```

Driven from DT child node `ufs-iocc { offset=0x710; mask=0x3; val=0x3; }`
parsed in `__ufs_populate_dt_extern` and stored in `cxt_iocc`. The
phandle source is `samsung,sysreg-phandle = <&sysreg_hsi2_system_controller>`
(AOSP `gs201-ufs.dtsi:73`). One regmap_read in `ufs-exynos-crypto.c:64`
to `HSI2_KDN_CONTROL_MONITOR (0x400)` is read-only sanity-check only.

### Mainline

`exynos_ufs_shareability` (line 507):

```
regmap_update_bits(ufs->sysreg, ufs->iocc_offset=0x710,
                   iocc_mask=UFS_GS101_SHARABLE=0x3, iocc_val=0x3);
```

Driven from `samsung,sysreg = <&sysreg_hsi2 0x710>;` in `gs201.dtsi:747`,
plus `iocc_mask = UFS_GS101_SHARABLE = 0x3` in
`gs201_ufs_drvs.iocc_mask`, and `iocc_val = iocc_mask` because
`dma-coherent` is set in DT.

### Verdict

**Identical.** Same phandle target (HSI2 syscon at 0x14420000), same
offset (0x710), same mask (0x3), same value (0x3). Mainline already
prints "before-iocc-write" / "after-iocc-write" reads of @0x710 in
`gs201_dump_sysreg_hsi2_iocc` — if the value reads back as `0x3` after
the write but the stuck-stamp still appears, **the bug is not at
sysreg+0x710**.

## 2. ext_blks enum count (your hypothesis: AOSP has 2, mainline has 1)

**Both AOSP and mainline have exactly 1 entry.** AOSP
(`ufs-exynos-gs.h:55-59`):

```c
enum exynos_ufs_ext_blks {
    EXT_SYSREG = 0,
    EXT_BLK_MAX,
#define EXT_BLK_MAX 1
};
```

`ufs_ext_blks[EXT_BLK_MAX][2] = { {"samsung,sysreg-phandle","ufs-iocc"} };`

There is no second sideband register block. The only "second" lookup
path in AOSP is the PMU phy-iso write (`ufs_pmu_token = "ufs-phy-iso"`
→ `exynos_pmu_update(0x3ec8, 0x1, 0x1)`), which is mainline-equivalent
to the `samsung,pmu-syscon` phandle handed to `phy-gs101-ufs.c` (does
the same `0x3ec8` write through the SMC-routed PMU regmap).

## 3. DT subnodes the AOSP UFS node has that mainline lacks

AOSP `gs201-ufs.dtsi` UFS-node children:

| node | role | mainline equivalent |
|---|---|---|
| `ufs-phy-iso` | PMU+0x3ec8 mask=0x1 val=0x1 (phy isolation un-bypass) | handled by phy-gs101-ufs.c via `samsung,pmu-syscon` |
| `ufs-iocc` | sysreg+0x710 mask=0x3 val=0x3 | encoded directly in `samsung,sysreg = <... 0x710>` + drv_data->iocc_mask |
| `ufs-perf` | softirq-throttled performance heuristic | none, irrelevant to coherency |
| `ufs-pm-qos` | PM QoS BUS freq vote | none, no coherency role |

AOSP top-level UFS-node properties not in mainline:

| property | AOSP value | role |
|---|---|---|
| `samsung,sysreg-phandle` | `<&sysreg_hsi2_…>` | replaced by mainline `samsung,sysreg = <&sysreg_hsi2 0x710>` |
| `fmp-id` | `<0>` | only consumed in AOSP for FMP / KDN keyring; mainline drops UFSPR_SECURE so unused |
| `smu-id` | `<0>` | same — FMP/SMU index |
| `gsa-device` | `<&gsa>` | **AOSP-only**: phandle to GSA (Google Security Anchor) device for KDN key programming. Mainline has no GSA driver — `pixel_ufs_crypto_configure_hw` calls `gsa_kdn_set_operating_mode(MKE=1, DT=0, KE=0)` on AOSP. **Not a coherency knob, but is a system-bus side effect** (BL31 mediates KDN through HSI2 plumbing). Worth examining whether the GSA call indirectly programs the same coherency fabric. |
| `fixed-prdt-req_list-ocs` | (boolean) | clears 4 quirks; not coherency-related |
| `evt-ver`, `brd-for-cal` | `0`, `1` | passed to cal-if; PHY only |

There is **no** `samsung,clkaon-syscon`, **no** `ufs-pad-retention`,
**no** `ufs-vs-iocc` (your speculation list), **no** other
samsung,*-phandle. AOSP has only `samsung,sysreg-phandle`. The
`exynos-pm-qos` and `idle-ip` calls go through soc/google APIs not
through DT.

## 4. SMC / PSCI / firmware calls

AOSP probe path SMCs (all in `ufs-exynos-crypto.c` /
`ufs-exynos-swkeys.c`, gated by `CONFIG_SCSI_UFS_CRYPTO`):

- `SMC_CMD_FMP_SECURITY(0, SMU_EMBEDDED, CFG_DESCTYPE_3=3)`
- `SMC_CMD_SMU(SMU_INIT=0, SMU_EMBEDDED=0, 0)`
- `SMC_CMD_FMP_SMU_RESUME(0, SMU_EMBEDDED, 0)` — resume only
- `SMC_CMD_FMP_USE_OTP_KEY(0, SMU_EMBEDDED, 1/0)` — FIPS self-test only
- `SMC_CMD_FMP_SMU_DUMP` — debug dump

Plus `exynos_pmu_update(0x3ec8, 0x1, 0x1)` for phy isolation
(SMC-routed via exynos-pmu.c on this SoC).

Mainline `gs201_ufs_smu_init` (line 766) issues:

- `SMC_CMD_FMP_SECURITY(0, 0, desctype=0..3)` — sweeps all four desctypes
- `SMC_CMD_SMU(SMU_INIT=0, SMU_EMBEDDED=0, 0)`
- `SMC_CMD_FMP_SMU_RESUME(0, SMU_EMBEDDED, 0)`
- `SMC_CMD_FMP_SMU_DUMP(0, SMU_EMBEDDED, 0)`

PHY isolation goes through `phy-gs101-ufs.c` writing
`PMU_ALIVE+0x3ec8` via the SMC-routed PMU regmap installed by
`exynos-pmu.c`.

### Verdict

**Mainline is a strict superset.** It calls every SMC AOSP probe-path
calls (and then some — sweeps DESCTYPE 0..3, calls FMP_SMU_DUMP). The
only AOSP-only firmware-mediated thing at probe time is
`gsa_kdn_set_operating_mode` — *not* an SMC, but a function call
through the GSA driver, which on the Pixel platform routes via
trusty/IPC to a separate security processor.

## 5. Probe-time HCI / AXI master register writes (delta only)

AOSP `exynos_ufs_config_host` runs at `hce_enable_notify(PRE_CHANGE)`
after HCI_SW_RST. Mainline splits these across `exynos_ufs_post_link`
and `gs101_ufs_post_link`. Final values:

| reg | AOSP | mainline final | match? |
|---|---|---|---|
| HCI_DATA_REORDER (0x60) | `0xa` | `0xa` | yes |
| HCI_TXPRDT_ENTRY_SIZE (0x00) | `PRDT_PREFECT_EN \| PRDT_SET_SIZE(12)` | `ilog2(4096)=0xc` only; PRDT_PREFETCH_EN only under CRYPTO or `GS201_PRDT_PREFETCH` define | conditional |
| HCI_RXPRDT_ENTRY_SIZE (0x04) | `PRDT_SET_SIZE(12)` | `ilog2(4096)=0xc` | depends on macro — verify in `ufs-vs-regs.h` |
| HCI_AXIDMA_RWDATA_BURST_LEN (0x6C) | `WLU_EN \| BURST_LEN(3)` | post_link writes `0xf` then `gs101_ufs_post_link` clobbers with `WLU_EN \| WLU_BURST_LEN(3)` | yes (final) |
| HCI_UTRL/UTMRL_NEXUS_TYPE | `0xFFFFFFFF` | `BIT(nutrs)-1` / `BIT(nutmrs)-1` | narrower in mainline, equivalent for slots in use |
| HCI_IOP_ACG_DISABLE (0x100) | clear bit0 | clear bit0 (gs101_ufs_drv_init:531) | yes |
| HCI_VENDOR_SPECIFIC_IE | `AH8_ERR_REPORT_UE` (AH8 only) | not written | AH8 disabled on gs201 |

The PRDT_SET_SIZE macro is worth a second look (verify in
`ufs-vs-regs.h`). Not the 0xab stamp cause — that's a write-not-
landing pattern, not a wrong-offset pattern (`PRDT_BYTE_GRAN` quirk
already handled the latter).

## 6. AOSP-only probe-time work that has no mainline equivalent

Listed in approximate order of "could plausibly affect coherency":

1. **`gsa_kdn_set_operating_mode` via GSA device** — AOSP-only,
   programs KDN(MKE=1,DT=0) at the security-processor level. The KDN
   sits between UFS HCI and the AXI fabric on Tensor SoCs. If KDN
   isn't initialized, it's plausible the controller's AXI master is
   left in a state where writes are routed through KDN-bypass that
   doesn't honor sysreg+0x710 shareability. **This is the highest-EV
   thing to investigate next.** Source: `ufs-exynos-crypto.c:103`,
   `ufs-pixel-crypto.c:242` parses `gsa-device` phandle from DT.
2. **`pixel_init` / `pixel_ufs_register_*` android_vh hooks** — AOSP
   wires several android_vh trace hooks at probe (fill_prdt,
   check_int_errors). Not coherency-relevant on first inspection.
3. `exynos_pm_qos_add_request(PM_QOS_DEVICE_THROUGHPUT)` — votes on a
   bus throughput floor. If gs201's BUS NoC defaults to a floor below
   what the UFS AXI master needs to flush its write buffer, this
   *could* manifest as posted-write absorption. Long shot, but cheap
   to test (mainline could drop a `interconnect-names = "ufs-bus"`
   bandwidth vote in DT).
4. `__sicd_ctrl(ufs, true)` — disables system idle on this IP. Not
   coherency-relevant; only matters during runtime suspend.
5. `exynos_get_idle_ip_index(...)` — same as above, idle bookkeeping.
6. `ufs->cal_param.handle = &ufs->handle; ufs_cal_init(...)` runs the
   PHY/UNIPRO calibration tables. Already diffed (see
   `cal-if-pma-diff.md`).

## Recommended next probes (ordered, smallest first)

1. **Read sysreg_hsi2+0x710 right before the controller's first DMA
   transaction** (i.e. just before `ufshcd_send_uic_cmd` or NOP_OUT).
   Mainline already dumps it before/after the IOCC write at probe;
   add a third dump from `exynos_ufs_pre_link` POST_CHANGE and
   `link_startup_notify` POST. If it reads `0x3` consistently and the
   stamp still appears, sysreg+0x710 is genuinely not the path.
2. **Read `HSI2_KDN_CONTROL_MONITOR` (sysreg+0x400)** the same way
   AOSP's `exynos_check_crypto_hw` does. If MKE / RDY bits aren't
   what they should be, KDN may be in a state that gates AXI writes.
3. **Check the parent NoC / interconnect** — gs201's HSI2 NoC has
   QoS programming in `cmu-hsi2.c` that AOSP exercises but mainline
   does not. Specifically dump CMU_HSI2 ACLK/UNIPRO/FMP gate state
   at probe and again at first-DMA — already done in
   `gs201_dump_cmu_hsi2_ufs_gates`, but worth correlating with the
   stamp pattern.
4. **As a falsification probe, try setting iocc_val = 0x0** at probe
   and observe whether the stamp pattern *changes* (different
   symptom = different memory type). If iocc=0x3 and iocc=0x0 produce
   identical stuck-stamp behavior, sysreg+0x710 has no effect on this
   path at all on gs201, and the coherency knob is somewhere else
   entirely (e.g. the controller's own internal memory-type register,
   or a TBU/SMMU stage above).
