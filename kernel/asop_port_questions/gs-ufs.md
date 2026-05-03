# ufs

- **AOSP path**: `private/google-modules/soc/gs/drivers/ufs/`
- **Mainline counterpart**: `drivers/ufs/host/ufs-exynos.c` (+ `phy/samsung/phy-gs101-ufs.c`, `phy-samsung-ufs.c`)
- **Status**: partially-ported
- **Boot-relevance score**: 10/10

## What it does

Vendor glue for the Exynos UFSHCI on gs101/gs201/zuma. Wraps the synopsys-derived host controller with PHY isolation/PMU control, per-SoC clock setup, the Pixel "FIPS" crypto path, swkeys, vendor IRQs (AH8 error reporting), debug dumpers and — most critically — the **CAL (calibration) library** under `gs101/`, `gs201/`, `zuma/` that walks per-SoC PMA/PCS/UNIPRO config tables (`calib_of_hs_rate_a`, `calib_of_hs_rate_b`, `calib_of_pwm`, post variants, h8 enter/exit) on every link startup and pwr_change. The CAL layer is the thing that actually negotiates a working HS link — mainline reproduces about 70% of the table contents but uses a different write mechanism for the per-lane PCS attributes and skips a non-trivial number of post-PMC PMA writes.

## Mainline equivalent

`drivers/ufs/host/ufs-exynos.c` (3108 lines, vs AOSP 1805) handles host-controller glue, including a `gs101_ufs_drvs` ops set with `gs101_ufs_pre_link`, `gs101_ufs_pre_pwr_change`, `gs101_ufs_post_pwr_change`. The PHY-side calibration tables live in `drivers/phy/samsung/phy-gs101-ufs.c` and are walked by the generic `phy-samsung-ufs.c` framework via `phy_calibrate(CFG_PRE_PWR_HS|CFG_POST_PWR_HS|...)`. Mainline replaces AOSP's `unipro_writel` + `__set_pcs` mechanism with `ufshcd_dme_set(UIC_ARG_MIB[_SEL])` plus generic phy framework calibration steps.

## Differences vs AOSP / what's missing

The mainline driver has been heavily annotated by the user (`GS201_*` switches, h1..h18 markers in comments) documenting AOSP-vs-mainline divergences hit during HS-Rate-B bringup. Concretely missing or divergent:

- **`__set_pcs` mechanism (h13)** — AOSP brackets every per-lane PHY_PCS_RX/TX write with `unipro_writel(__WSTRB | __SEL_IDX(lane), UNIP_COMP_AXI_AUX_FIELD)` then resets the gate. Mainline uses `ufshcd_dme_set(UIC_ARG_MIB_SEL(addr, lane), val)` which goes through the controller's DME state machine. Plausible the DME path silently no-ops some PCS attributes on gs201 silicon. User has experimentally ported this (`GS201_AOSP_PCS_WRITES`); CDR lock still fails.
- **`exynos_ufs_get_caps_after_link`** — AOSP reads `UNIP_PA_CONNECTEDTXDATALANES` / `UNIP_PA_CONNECTEDRXDATALANES` / `UNIP_PA_MAXRXHSGEAR` directly from the unipro shadow region after link-up and writes them into `cal_param.{connected_tx_lane, connected_rx_lane, max_gear}`. Mainline's `exynos_ufs_post_link` does not populate these fields, so any cal-table walk that gates on `connected_*_lane` or `max_gear` runs with stale defaults.
- **`exynos_ufs_update_active_lanes`** — same idea, called *after* pwr_change to refresh `active_rx_lane` / `active_tx_lane` from `UNIP_PA_ACTIVE{RX,TX}DATALENS`. Mainline never sets these post-pwr_change. The AOSP cal tables use `active_rx_lane` to decide whether to skip per-lane CDR-wait entries (`do_cal_config_uic`'s `skip_rx_lane` clause) — without it, mainline either over- or under-iterates.
- **`exynos_ufs_init_pmc_req` math** — AOSP clamps the requested gear/lane against `pwr_max` from the controller using `min_t(u8, pwr_max->gear_rx, req_pmd->gear)` and writes both `act_pmd` (kept inside ufs) and `pwr_req` (returned to ufshcd). Mainline's pre_pwr_change does not maintain a separate `req_pmd_parm`/`act_pmd_parm` pair, so the cal layer doesn't see a clamped target.
- **`ufs_cal_pre_pmc` / `ufs_cal_post_pmc`** — user has ported pre_pmc semantics behind `GS201_AOSP_PRE_PMC` (mask `PA_ERROR_IND_RECEIVED`, raw `unipro_writel` UserData/L2 timers in AOSP order). Confirmed `PA_TxHsAdaptType=1` causes pwr_change failure with `upmcrs:0x5` regardless of write mechanism — left disabled. post_pmc port (`GS201_AOSP_POST_PMC`) drives the PHY state machine through PRE_PWR_HS → POST_PWR_HS even at PWM so `tensor_gs101_post_pwr_hs_config` PMA writes (0x222=0x08 TRSV @ byte 0x888, 0x246=0x01 TRSV @ byte 0x918, 0x20=0x60 COMN) actually run.
- **`ufs30_cal_wait_cdr_lock` kick-start writes (byte 0x888)** — AOSP polls `TRSV_REG339` for CDR-lock and on each iteration kicks the PHY by writing `0x10` then `0x18` to `PHY_PMA_TRSV_ADDR(0x888, lane)` (= byte offset 0x888 in the per-lane PMA window). Mainline's CDR-wait in `phy-samsung-ufs.c` doesn't do this kick. **This is the highest-suspicion missing piece** — the user has confirmed `TRSV_REG339` bit 3 never sets at HS-Rate-A or HS-Rate-B regardless of pre/post-PMC table content.
- **`tensor_gs101_pre_pwr_hs_config` / `tensor_gs101_post_pwr_hs_config`** in `phy-gs101-ufs.c` — already largely ported but with two transcription typos found (0x25D should be 0x27D, 0x29E should be 0x2BE — see `upstream-patches/0004-phy-samsung-gs101-ufs-fix-two-PMA-register-transcrip.patch`). Fix is correct but does not unblock HS by itself.
- **gs201 IOCC bits in `samsung,sysreg-phandle`** — AOSP `exynos_ufs_config_externals` does `regmap_update_bits` over the IOCC sysreg with the bootloader-set value preserved. Mainline at one point clobbered them; fixed in `upstream-patches/0001-ufs-exynos-don-t-clobber-bootloader-IOCC-bits-when-d.patch`.
- **`UFSHCD_QUIRK_PRDT_BYTE_GRAN`** — AOSP unconditionally sets it; gs201 mainline driver had it inappropriately on, see `upstream-patches/0002-ufs-exynos-drop-UFSHCD_QUIRK_PRDT_BYTE_GRAN-from-gs2.patch`. Mainline now matches AOSP.
- **`UFSHCD_QUIRK_BROKEN_AUTO_HIBERN8`** — AOSP sets this; mainline gs101 ops do not (only sets it conditionally). Worth verifying.
- **TX-PRDT prefetch on HCI_TXPRDT_ENTRY_SIZE** — AOSP unconditionally writes `PRDT_PREFECT_EN | PRDT_SET_SIZE(12)`. Mainline only sets `PRDT_PREFETCH_EN` when `hba->caps & UFSHCD_CAP_CRYPTO`. User has restored the AOSP behavior behind `GS201_PRDT_PREFETCH` — strong candidate for the back-to-back-READ_10 wedge but does not affect link bringup itself.

The CAL infrastructure (`gs201/ufs-cal-if.c`) is **not** ported as a self-contained library; mainline open-codes equivalent (and partially divergent) tables in `phy-gs101-ufs.c`'s `tensor_gs101_*_config` arrays.

## Boot-relevance reasoning

10/10. UFS HS gear is the single open boot blocker — system is stuck at PWM 5–10 MB/s, dl_err 0x80000002 (TCx_REPLAY_TIMER_EXPIRED) on the first frame after pwr_change at every HS gear and both rates. The `ufs30_cal_wait_cdr_lock` kick-start writes to PMA byte 0x888 are the most plausible single missing piece (CDR-lock never advances on mainline; AOSP's wait-loop literally pokes the PHY between polls). `exynos_ufs_get_caps_after_link` + `exynos_ufs_update_active_lanes` are required to make any cal-table walk that gates on `connected_*_lane`/`active_*_lane`/`max_gear` apply the right entries — these are cheap to port and a prerequisite for any further cal-faithfulness work. This module is the entire ballgame for the active blocker.

