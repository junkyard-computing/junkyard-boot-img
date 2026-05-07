To: <PIXEL TEAM CONTACT>
Subject: Mainline Linux on Pixel Fold (gs201) — UFS HS-G4 + serial-getty + USB peripheral up to host enumeration, a few questions

Hi <NAME>,

I've been bringing up mainline Linux on a Pixel Fold (felix / Tensor G2).
The end goal is a Debian rootfs from `/dev/disk/by-partlabel/super`,
kernel built straight from Linus's tree (not the AOSP gs201 fork).
Current state on real hardware as of 2026-05-06:

  - UFS reaches HS-G4 Rate-B with both lanes locked, ext4 rootfs mounts.
  - Bidirectional UART works — `serial-getty@ttySAC0` is active and
    I can log in over the serial console as `kalm@fold`.
  - systemd reaches multi-user.target at ~[42 s], `ssh.service` is
    listening.
  - USB peripheral mode: dwc3-exynos + phy-exynos5-usbdrd now probe,
    the UDC `11210000.usb` registers, configfs-gadget binds (CDC-NCM
    + CDC-ACM composite), and the host enumerates a HS device. **But
    no SETUP packet ever reaches dwc3's EP0 OUT TRB**, so EP0 control
    transfers fail (`device descriptor read/64, error -71` on the
    host side). See question E — that's the new blocker on getting
    SSH-over-USB running.

15 upstream-eligible patches have come out of this — the original 6
UFS fixes I started with, plus 6 more UFS/PHY follow-ups discovered
once HS-G4 came up, plus 3 clk/UART patches that landed serial-getty
on real silicon. Before sending anything to LKML I'd love a sanity
check from someone with original gs201 / Tensor UFS context. Quick
summary by area:

UFS / PHY (12 patches):

  0001 - ufs: exynos: preserve bootloader IOCC bits when !dma-coherent
         (mainline actively clears them; gs201 needs them set so
         controller AXI master uses Inner-Shareable transactions)

  0002 - ufs: exynos: drop UFSHCD_QUIRK_PRDT_BYTE_GRAN from gs201
         (gs201 controller follows UFS spec — DWORDS, not BYTES; the
         inherited gs101 quirk caused mainline to write the response
         offset 4× further than the controller expected. Confirmed
         with a magic-byte stamp on the response slot.)

  0003 - ufs: exynos: force 32-bit DMA mask on gs201
         (controller advertises MASK_64_ADDRESSING_SUPPORT but raises
         SYSTEM_BUS_FATAL_ERROR on >4 GB DMA. Matches your downstream
         driver's `static u64 exynos_ufs_dma_mask = DMA_BIT_MASK(32)`.)

  0004 - phy: samsung-gs101-ufs: fix two PMA register transcription
         typos in tensor_gs101_pre_init_cfg (0x974 → 0x9F4,
         0xA78 → 0xAF8; AOSP's gs201 cal-if writes the latter; AOSP's
         gs101/zuma don't write either, so this patch is scoped to
         the gs201-specific path — happy to widen if you remember
         whether gs101 silicon benefits too).

  0005 - ufs: exynos: enable PRDT prefetch on gs201 without crypto
         (AOSP unconditionally sets PRDT_PREFETCH_EN; mainline only
         sets it when UFSHCD_CAP_CRYPTO is enabled, and gs201 can't
         get CRYPTO because BL31 doesn't actually honour the FMP SMC
         pair. Now redundant given 0011 below, but still cleaner.)

  0006 - ufs: exynos: gs101: run PHY post-PMC calibration for non-HS
         (mainline gates phy_calibrate behind ufshcd_is_hs_mode, so
         the PWM-mode entries in tensor_gs101_post_pwr_hs_config never
         run for forced-PWM setups — used to be load-bearing for our
         PWM workaround before HS-G4 came up.)

  0007 - phy: samsung-gs101-ufs: add missing END_UFS_PHY_CFG terminator
         (single-line walker overrun fix — gs101_post_pwr_hs_config[]
         array was missing the end sentinel; mainline reads off the
         end of the table.)

  0008 - ufs: exynos: gs201: KDN_CTRL_MON dump + GSA mailbox shim for
         KDN_SET_OP_MODE (RFC; held back from LKML, mostly diagnostic).

  0009 - phy: samsung-gs101-ufs: drop H8-entry writes from
         post_pwr_hs_config (cargo-cult writes from a draft of 0006
         that turned out to be wrong; clean removal).

  0010 - ufs/phy: gs101/gs201: three missing writes from systematic
         cal-if walk (single write each in tensor_gs101_pre_init_cfg,
         gs101_ufs_pre_link, gs201_ufs_post_link — all on the
         38.4 MHz refclk path. With these, M-PHY CDR locks first
         iteration and link startup completes. Closes the
         "dl_err 0x80000002 wedge" question I'd have asked earlier.)

  0011 - ufs: exynos: gs201: drop DESCTYPE probe loop, set
         FMPSECURITY0.DESCTYPE=0 (the most load-bearing patch in
         the series. Without it every multi-PRD read or write hangs
         on gs201 mainline. See question B.)

  0012 - ufs/phy: gs201: silence debug instrumentation
         (dev_info → dev_dbg). Not upstream-quality yet but tracked.

clk / UART (3 patches, made serial-getty work end-to-end):

  0013 - clk: samsung: gs101: add gs201 (Tensor G2) CMU_TOP and
         CMU_MISC support (skip_ids[] infrastructure + empirical
         register-hole list for gs201 CMU_TOP).

  0014 - clk: samsung: gs101: add gs201 CMU_PERIC0 (USI0_UART chain
         only) — a minimal validated peric0_cmu_info_gs201 with
         gs201-specific register offsets (DIV at 0x1808, GATE at
         0x20c0). gs201 has no PERIC0_TOP1 cluster, so the gs101
         tables can't be reused as-is.

  0015 - tty: serial: samsung: add google,gs201-uart compat
         (UPIO_MEM32). gs201's UART register block requires 32-bit-
         aligned access; samsung,exynos850-uart selects iotype=
         UPIO_MEM (8-bit), which raises an asynchronous SError on
         first console_write. 3-line fix; the actual gating bug.

The 0003 (DMA mask) and 0011 (FMPSECURITY0.DESCTYPE) patches in
particular make me suspect there's institutional knowledge at Google
that just never made it upstream, hence reaching out.

The patches and supporting evidence live in <MY GITHUB OR ATTACH>;
copies of all 15 attached.

## Investigated and ruled out: clock-controller / HSI2 CMU rate gap

For completeness, since I had earlier suspected this and want to save
anyone the time of suggesting it: I investigated whether the
fixed-clock stubs for `ufs_aclk` and `ufs_unipro` in `gs201.dtsi`
(rather than real CCF entries through a `cmu-hsi2` node) could be
causing the HS dl_err. They aren't.

I added a read-only ioremap probe in `ufs-exynos.c` that dumps the
HSI2 CMU dividers, muxes, and gates at three call sites
(post_link, pre_pwr_change, post_pwr_change) for both PWM-G4 boot and
HS-Rate-B G4 attempt. Findings:

- All three sites returned **byte-identical** values, in both runs.
  HSI2 CMU is untouched across PMC.
- Hardware UFS_EMBD divider at `0x18a4` reads `0x02` → /3 →
  SHARED0_DIV4 (532.992 MHz) /3 = **177.664 MHz exactly**. Matches
  the dtsi fixed-clock stub claim.
- Hardware NOC divider at gs201's `0x189c` reads `0x01` → /2 →
  SHARED0_DIV4 /2 = **266.5 MHz**. Matches the `ufs_aclk` stub claim
  of 267 MHz.
- `ufshcd_set_clk_freq()` is only called from `ufshcd_scale_clks()`
  via devfreq, never during PMC. So the kernel was never going to
  reprogram clocks at PMC anyway, and AOSP doesn't either (per code
  review of `private/google-modules/soc/gs/drivers/ufs/ufs-exynos.c`).

So the actual rates the kernel believes are correct, and PMC doesn't
need to touch CMU. (I'd briefly suspected `EXYNOS_PD_HSI0` sequencing
might explain it next, but verification before porting confirmed your
own `gs201-ufs.dtsi` uses `vcc-supply = <&ufs_fixed_vcc>` — a fixed
GPIO regulator — and doesn't tie UFS to `pd_hsi0`; that driver only
manages USB PHY rails on felix. Ruled out as a UFS lead.)

## Questions

A. **Why does the AOSP cal-if treat addresses 0x3348 / 0x334C
   (`PA_*_TActivate`-adjacent) as `UNIPRO_ADAPT_LENGTH`-class
   conditional RMW?** The cal-if branch writes 0x82 if (val & 0x80
   && (val & 0x7F) < 2), else writes (val | 0x3) if ((val + 1) &
   0x3). For a typical reset value of 0x0, that path writes 0x3.
   Mainline previously wrote a literal 0x0. Is this a known
   silicon quirk that should be documented somewhere LKML can see,
   or am I cargo-culting? Either is fine — the patch is verifiable
   either way — but a one-line confirmation helps the cover letter.

B. **Why does the gs201 secure firmware (BL31?) leave
   FMPSECURITY0.DESCTYPE in whatever state the last
   `SMC_CMD_FMP_SECURITY` call set it to?** Specifically, is there
   an expectation that the OS calls `SMC_CMD_FMP_SECURITY(...,
   DESCTYPE)` with the value matching its `sg_entry_size`? Or is
   the bootloader supposed to leave DESCTYPE in a sensible default
   (presumably 0 = standard 16-byte PRDT) for non-FMP boots?
   Asking because the original probe-loop in our
   `gs201_ufs_smu_init` was a hack born of "we don't know what
   DESCTYPE is supposed to be on non-FMP boot" — it'd be nice to
   replace the cargo-cult comment with a real answer.

C. **Is MASK_64_ADDRESSING_SUPPORT in the gs201 caps register
   actually wrong?** The AOSP driver pins `dma_mask` to 32-bit for
   the entire exynos UFS family at probe (`static u64
   exynos_ufs_dma_mask = DMA_BIT_MASK(32)`). On gs201 mainline I
   confirmed the controller advertises 64-bit support but raises
   `SYSTEM_BUS_FATAL_ERROR` on >4 GB DMA, so my patch 0003 narrows
   it to gs201 specifically. Is there a known errata, or was the
   AOSP override added defensively without a specific incident
   behind it? Should the upstream patch apply only to gs201, or is
   gs101 / Zuma affected too? Happy to widen the scope if someone
   can confirm.


D. **Sustained PWM operation wedges the controller silently — second
   of two back-to-back READ_10s never completes, with zero error
   indication.** I forced PWM-G4 SLOWAUTO_MODE as a workaround for
   the HS bug above, and the device successfully enumerates
   (sda/sdb/sdc/sdd attached, GPT scanned, all 31 partitions on sda
   visible). At ~38 s into boot the udev coldplug fires; ~30 s later
   the SCSI mid-layer times out a stuck command and the host is
   re-initialised. The wedge has very specific characteristics:

   - **Trigger**: any second of two READ_10s issued in close
     succession (~10–25 ms apart) at PWM gear. The first command
     completes silently (no logged error); the second one never
     completes.
   - **Independent of**:
     - **Transfer size** — same wedge with `len=65536` (64 KB) and
       `len=32768` (32 KB after clamping `max_hw_sectors`).
     - **LBA region** — wedges on lba=0x3b8b3f0 (near end of disk)
       in one run, lba=0x8 (start of disk) in another. Initial
       hypothesis "high-LBA reads break" was wrong.
     - **Concurrency** — `rd.udev.children-max=1` cmdline serialises
       udev workers; `scsi_change_queue_depth(sdev, 1)` per-LU via a
       new `config_scsi_dev` vops hook strictly serialises commands
       per device. Both leave the wedge intact. Cross-LUN concurrency
       isn't the trigger either; the in-flight wedged command is on
       the same LU as the first (completed) command.
     - **Issuer** — udev-worker, scsi_id, kworker, all wedge identically.
   - **No error indication anywhere**: `saved_err=0x0`,
     `saved_uic_err=0x0`, "No record of pa_err / dl_err / nl_err /
     tl_err / dme_err / fatal_err / auto_hibern8_err / host_reset /
     dev_reset". Just `1 outstanding req` hung indefinitely. The
     SBFES IRQ I originally saw (saved_err=0x20000) was a *symptom*,
     not the cause — masking it via REG_INTERRUPT_ENABLE just shifts
     the failure from "immediate eh_fatal" to "30 s SCSI timeout
     then eh_fatal". Same wedge underneath.
   - **Recovery works, but re-wedges**: full host_reset (h13 pre_link
     re-runs, link comes back up, pwr_change succeeds at PWM-G4
     again) — and then the next udev cycle wedges identically.

   To get to the above, I've ported quite a lot of the AOSP
   `google-modules/soc/gs/drivers/ufs/ufs-exynos.c` and gs201
   `ufs-cal-if.c` into mainline as fork-only experiments to make sure
   I'm not missing a register write AOSP does:

   - `__set_pcs` mechanism for per-lane PCS writes ✓
   - `ufs_cal_pre_pmc` semantics including
     `PA_ERROR_IND_RECEIVED` mask + UserData/L2 timer writes via raw
     `unipro_writel` in AOSP order ✓
   - `ufs_cal_post_pmc` PWM PMA writes (byte 0x20=0x60 COMN,
     byte 0x888=0x08 TRSV, byte 0x918=0x01 TRSV) by adding a
     `gs101_ufs_post_pwr_change` vops hook that drives the Samsung
     PHY framework's state machine through CFG_PRE_PWR_HS →
     CFG_POST_PWR_HS for non-HS gears (mainline gates phy_calibrate
     behind `ufshcd_is_hs_mode`, so these writes are skipped for PWM
     in mainline). The writes do land — TRSV_REG338 CAL_DONE shifted
     from `0x9d` to `0x84` — but the wedge is unchanged.
   - `PRDT_PREFETCH_EN` on `HCI_TXPRDT_ENTRY_SIZE` (AOSP sets this
     unconditionally; mainline only sets it when
     `hba->caps & UFSHCD_CAP_CRYPTO`, and gs201 doesn't get CRYPTO
     because the FMP SMC pair `SMC_CMD_FMP_SECURITY` /
     `SMC_CMD_SMU(SMU_INIT)` aren't actually honoured by BL31 on
     this SoC). Confirmed via UART that
     `HCI_TXPRDT_ENTRY_SIZE = 0x8000000c` after the fork patch; wedge
     unchanged.
   - HCI-level configuration (`HCI_DATA_REORDER = 0xa`,
     `HCI_AXIDMA_RWDATA_BURST_LEN = WLU_EN | BURST_LEN(3)`,
     `HCI_UTRL_NEXUS_TYPE = BIT(nutrs)-1`,
     `HCI_IOP_ACG_DISABLE` cleared) all match AOSP.

   Two of these (the PWM post-PMC writes and the unconditional PRDT
   prefetch) I plan to send upstream as separate patches regardless,
   since they're correct vs your reference driver — but I want to
   wait for your reply first because I don't want to frame them as
   "PWM data-path fixes" when neither actually fixes the wedge.

   The shape of "second back-to-back command wedges silently with no
   error indication" suggests a controller-level race specific to
   PWM gear: maybe the AXI master is in some transient state from the
   first command's completion when the second arrives, or maybe the
   PMA receiver enters a state at PWM that the BUS-FATAL detector
   doesn't notice but the data path can't escape. We've ruled out
   everything we can read from the cal-if file or the host wrapper.

   **The questions:**
   - Is gs201 PWM gear simply not a tested data-path mode? On
     production Pixel Fold the device runs HS-Rate-B; PWM is just a
     transient initial state, so this controller-level race might
     never have been hit at Google.
   - If so, is the right answer "fix HS-Rate-B and forget PWM," or
     is there a setup write / quirk we should be applying for PWM
     that's not in the cal-if file?
   - If you can dump the controller's HCI register state from a
     working AOSP boot at the same point in time we wedge (right
     after a 64 KB READ_10 at PWM gear), I can compare against ours
     to see if any latched state differs.


E. **What configures gs201's HS USB PHY RX path on top of the gs101
   mainline driver?** Mainline `phy-exynos5-usbdrd.c` (gs101 binding)
   and `dwc3-exynos.c` can drive gs201 USB up to the point of host
   HS enumeration, but the EP0 RX path goes silent — line-state
   events fire repeatedly, no actual SETUP packet ever lands. The
   open question is what register sequence is missing.

   **What works (after DT remap and a few mainline patches):**
   - DT: gs201's HSI0 register layout is shifted from gs101 — controller
     wrapper at `0x11210000` (not `0x11110000`), IRQ 379 (not 463),
     PHY base `0x11200000` size 0x200, "pcs" `0x110f0000`, "pma"
     `0x11100000` size 0x2800. Address shifts confirmed against
     AOSP `private/devices/google/gs201/dts/gs201.dtsi`. We pin
     dr_mode = "peripheral" and route all 8 PHY/dwc3 supplies through
     a single fixed-1V8 always-on stub since S2MPG12/13 PMIC drivers
     don't exist mainline yet.
   - PHY ref clock: cmu_hsi0's user-mux reports back the bootloader
     PLL rate (~614 MHz on a Phase A boot) and trips the PHY driver's
     strict-rate check, so we feed `phy_ref` from a 26 MHz fixed-clock
     stub.
   - Driver: a `google,gs201-usb31drd-phy` compat in
     phy-exynos5-usbdrd.c with `phy_cfg_gs201` (UTMI same as gs101,
     PIPE3 a no-op since the gs101 PIPE3 init crashes ep0out DEPCFG
     on gs201 — gs101 PMA register layout doesn't apply) and a
     `gs201_tunes_utmi_postinit` HSPPARACON tune block matching AOSP
     felix's `&usb_hs_tune` (TXVREF=8, TXRES=3, TXPREEMPAMP=1,
     SQRX=2, COMPDIS=7).
   - dwc3 core: SOFITPSYNC=1 when `dis_u2_freeclk_exists_quirk` is
     set (matches AOSP's dwc3-exynos behavior; mainline only set
     SOFITPSYNC for host/OTG via the 210A–250A workaround).

   With the above, we get to: UDC creates, configfs-gadget binds,
   `/dev/ttyGS0` exists, soft-disconnect/connect cycle moves UDC to
   `state=default`, host sees `new high-speed USB device number N
   using xhci_hcd`.

   **Where it breaks:** `device descriptor read/64, error -71`
   (EPROTO) on the host, infinite retry. Instrumented dwc3 with
   `dev_info` patches at `dwc3_gadget_reset_interrupt`,
   `dwc3_gadget_conndone_interrupt`, `dwc3_process_event_entry`, and
   `dwc3_ep0_inspect_setup`, plus a register dump in
   `dwc3_ep0_out_start`. Over a single host enumeration storm we get
   thousands of:

     - `DWC3-DBG: reset_interrupt entry`            (~1500 events)
     - `DWC3-DBG: conndone HIGHSPEED ep0 maxpkt=64` (~1500 events)
     - `event devt_type=6` (SUSPEND/EOPF)            (~330 events)
     - **0** `ep0 inspect_setup` events
     - **0** endpoint events of any kind (no `is_devspec=0` events
       ever appear in the ring — only device-level events)

   So: line-state events fire (PHY analog edge detection works, HS
   chirp completes), the ep0 SETUP TRB is armed exactly once at
   gadget bind (`dwc3_ep0_out_start ret=0`), but no DEPEVT
   XFERCOMPLETE on ep0 OUT after each conndone — meaning host SETUP
   bytes never make it from the PHY into the controller's RX FIFO.

   **Register state at the time of bind, captured by our dump
   patch in `dwc3_ep0_out_start`:**

   ```
   GUSB2PHYCFG=0x00102500  PHYIF=0 (8-bit UTMI), USBTRDTIM=9,
                           ENBLSLPM=1, SUSPHY=0, U2_FREECLK_EXISTS=0
   GCTL=0x30c12404         SOFITPSYNC=1, PRTCAP=2 (device)
   DCTL=0x00f00000         RUN_STOP=0 (set later), KEEP_CONNECT=0
   DSTS=0x00d20204         DEVCTRLHLT=1 (pre-RUN), USBLNKST=0x4
                           (USB3 Disabled — no SS partner, expected),
                           CONNECTSPD=4 (SS — controller default
                           before HS chirp; flips to 0 after CONDONE)
   ```

   **Hypotheses we've tried (each: build, flash, capture UART, plug
   in USB-2 cable, capture host dmesg). None moved the symptom:**

   1. **`G2PHY_CNTL0/CNTL1` ss_cap power-stable handshake** at
      offsets 0x8c / 0x90 (`ANA_PWR_EN | PCS_PWR_STABLE |
      PMA_PWR_STABLE` on CNTL1; `UPCS_PWR_STABLE` set,
      `TEST_POWERDOWN` cleared on CNTL0). Mainline gs101 driver
      doesn't touch these; AOSP's `phy_exynos_usb_v3p1_enable()`
      ss_cap branch does. **No effect** on RX symptom.

   2. **Clear `HSP_EN_UTMISUSPEND` and `HSP_COMMONONN`** after the
      gs101 init sets them. AOSP felix sets `common_block_disable=0`
      in DT, which makes its phy enable fn skip both bits. **No
      effect.**

   3. **PHYIF = 16-bit UTMI** (`phy_type = "utmi_wide";` on the
      dwc3 child). Confirmed via reg dump that the controller now
      programs `PHYIF=1, USBTRDTIM=5`, but symptom unchanged. **No
      effect** — so the PHY-to-controller UTMI width is correct at
      the default 8-bit (which matches HW reset).

   4. **`CLKRST_LINK_PCLK_SEL`** in the SS PHY init. Mainline gs101's
      `usbdp_g2_v4_ctrl_pma_ready()` sets this; our gs201 PIPE3 init
      is a no-op (the rest of `ctrl_pma_ready` crashes ep0out
      DEPCFG). Setting just this single bit also breaks ep0out enable
      with `failed to enable ep0out`. So the link's pipe_pclk source
      genuinely needs the SS PMA to come up — but the SS PMA path
      uses gs101 PMA register offsets that don't apply to gs201, and
      we don't have the gs201 PMA register reference.

   5. The `snps,dis-u2-freeclk-exists-quirk` route — set, then
      cleared, both produce the same EPROTO. (AOSP's gs201 DT
      doesn't set the quirk; mainline behavior depends on whether
      the U2 PHY actually has a free clock, and we can't tell from
      here.)

   **Specific questions for someone with gs201 PHY context:**

   - Is the AOSP gs PHY driver
     `private/google-modules/soc/gs/drivers/phy/samsung/phy-exynos-usb3p1.c`
     (~2500 lines, Samsung CAL-based) the canonical reference for
     gs201 USB PHY register sequences, the same way the cal-if SFR
     table is canonical for the CMU layouts? We've been treating it
     as such, but a confirmation would help — and a pointer to the
     gs201-specific datasheet section that covers the HS RX bring-up
     sequence (if such a doc exists internally) would save a lot of
     empirical bisecting.

   - The pattern "many RESET + many CONNECT_DONE, zero endpoint
     events, EP0 SETUP TRB armed once and never completed" — does
     that ring a bell as a known gs201 silicon quirk? It feels
     specifically like the PHY's HS RX analog block isn't enabled
     (or isn't calibrated) even though chirp/J-K detection works.
     Is there a CAL hook on the AOSP side that runs after CONNECT_DONE
     to enable HS RX, that mainline's `phy_init` lifecycle wouldn't
     hit?

   - If it'd be easier to share an HCI register dump from a working
     AOSP boot at the same point in time we wedge (right after host
     enumeration starts), I can compare ours against it and probably
     find the missing write myself.

   For now we have UART login as a workaround, so this isn't
   blocking the rest of the bring-up — but USB peripheral is the
   last piece between us and an SSH-reachable mainline Debian on
   felix without a UART cable.

F. **Why does the gs201 secure firmware open CMU access only when
   EL2 is in pKVM?** We boot mainline with `kvm-arm.mode=protected`
   and CMU readl/writel work fine. Without that flag, every CMU
   access aborts with synchronous external abort code 0x96000010.
   Empirically discovered, but a one-line "yes, BL31 routes CMU
   through pKVM" or "no, that's a different reason" comment from
   someone in the know would let us upstream a proper note in the
   gs201 binding doc.

G. **gs201 CMU register layout — is there documentation we don't
   have?** Mainline's `clk-gs101.c` advertises `google,gs201-cmu-*`
   compats but reuses gs101's register-offset tables for everything
   except CMU_TOP. Empirically that doesn't fly:

     - CMU_TOP requires a `gs201_top_skip_ids[]` because gs201
       implements fewer SHARED-PLL fan-out dividers than gs101 (only
       SHARED0_DIV2/DIV3; everything from SHARED0_DIV4 onwards plus
       all of SHARED1/2/3 is a register hole). That's already in our
       fork as a partial port and queued upstream as a separate patch.

     - CMU_PERIC0's layout is *substantively* different (not just an
       offset shift): the PERIC0_TOP1 cluster gs101 has — IPCLK_0 /
       PCLK_0 / IPCLK_2 / PCLK_2 sub-bridges feeding the USI
       peripherals — doesn't exist on gs201 at all. Each peripheral
       on gs201 gates from RSTNSYNC directly. The "BUS" path is also
       renamed "NOC" with corresponding offset shifts (e.g.
       DIV_CLKCMU_PERIC0_BUS at 0x18d4 on gs101 → DIV_CLKCMU_PERIC0_NOC
       at 0x18e8 on gs201). For the USI0_UART path specifically:
       `DIV_CLK_PERIC0_USI0_UART` moved 0x1804 → 0x1808 (+4); the
       RSTNSYNC USI0_UART gate moved 0x20bc → 0x20c0 (+4); the user
       mux at 0x620 stayed the same.

     - There appear to be no DBG mirrors at base+0x4000 for gates on
       gs201 (only for muxes at 0x4xxx and dividers at 0x5xxx), which
       trips mainline's `auto_clock_gate=true` path — reading the
       non-existent DBG variant for the USI0_UART gate at 0x60c0
       raises an asynchronous SError that the kernel ultimately
       panics on inside `console_unlock`. We work around this by
       setting `auto_clock_gate=false` on `peric0_cmu_info_gs201`.

   We've been deriving all of this from AOSP cal-if's
   `private/google-modules/soc/gs/drivers/soc/google/cal-if/gs201/
   cmucal-sfr.c`, which appears authoritative for the offsets, but a
   confirmation that the cal-if SFR table is the canonical reference
   would be reassuring (and let us cite it in the binding doc /
   commit messages cleanly). If there's an internal doc that maps
   the gs101 → gs201 register-layout deltas across all CMU domains,
   we'd appreciate a pointer — saves a lot of empirical bisecting on
   each domain (APM, DPU, HSI0, HSI2, PERIC1 still pending).

H. **Does gs201's UART register block officially require
   32-bit-aligned access?** This is the "actual" UART RX blocker
   that gave us a few days of confused debugging. samsung_tty's
   `wr_reg(port, S3C2410_UTXH, ch)` does an 8-bit `writeb_relaxed`
   under `iotype = UPIO_MEM` (which is what `samsung,exynos850-uart`
   selects) but a 32-bit `writel_relaxed` under `iotype = UPIO_MEM32`
   (which is what `google,gs101-uart` selects). On gs201 the 8-bit
   write to the UART register block raises an asynchronous SError
   that surfaces inside `console_unlock`. Our fix: declare gs201's
   UART node with `compatible = "google,gs101-uart"` instead of
   `"samsung,exynos850-uart"`, even though the binding documentation
   has historically associated the latter with all post-Exynos850
   parts. With that change, `serial-getty@ttySAC0` works
   bidirectionally on real felix hardware (we just logged in over
   UART for the first time on a kernel built from upstream Linux).

   Question: should the gs201/gs101 UART binding doc explicitly call
   out the 32-bit-only access requirement? AOSP's bootloader and
   kernel both work because both consistently use 32-bit access
   (bootloader's earlycon uses `mmio32`, AOSP's downstream samsung
   driver presumably uses UPIO_MEM32 on these compats). Mainline
   only trips the trap because the upstream binding docs make
   `samsung,exynos850-uart` look like a viable choice for gs201.

   Patch 0015 above adds `google,gs201-uart` as an alias for
   `gs101_serial_drv_data` in samsung_tty's of_match table so DT
   authors can be explicit. Note for the binding doc: the 32-bit-
   only access requirement also matches what we observed for gs201
   CMU register reads (anything not 32-bit aborts) — feels
   SoC-wide, not UART-specific.

I'm happy to share boot logs, the exact diffs I tried, or hop on a
call. There's no rush — I have a few months to land this and I'd
rather get it right than fast.

Thanks,
Chris
