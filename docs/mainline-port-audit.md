# Mainline gs201/felix port — state audit

**Date:** 2026-08-01
**Tree audited:** `jboot-mainline` @ `3c8ea0c`, kernel submodule @ `807bd171ff1d`
(`wip/panthor-perf-v5`, = `v7.2-rc5-140`), plus 3 uncommitted files.

Three questions: what is half done, what is a graft rather than upstreamable
work, and what is not of upstream quality. Everything below was read out of the
tree, not recalled.

---

## 0. Shape of the delta

140 commits on top of `v7.2-rc5`: **276 files, +123,752 / −184**.

The insertions split cleanly, and the split is the headline finding:

| | files | +lines | share |
|---|--:|--:|--:|
| **Verbatim grafts** (AOSP/Samsung code dropped in) | ~150 | **~98,300** | 79% |
| **First-party gs201 work** | ~120 | **~25,400** | 21% |

So roughly four fifths of the port is other people's out-of-tree code carried
along, and one fifth is the actual bring-up. That ratio is fine for a bring-up
tree and fatal for an upstream one — the two are not the same artifact, and
right now they are the same branch.

The −184 deletions matter more than their size suggests: they include a
**revert of an upstream commit** and **edits to three shared subsystem cores**
(`drivers/ufs/core/ufshcd.c`, `drivers/clk/samsung/clk.c`,
`drivers/regulator/core.c`).

---

## 1. What is half done

Ordered by how much is blocked behind each one.

### 1.1 The CMU clock tree — the biggest open item

This is the single largest lever in the tree and it is maybe 60% done.

Wired and working: `cmu_top`, `cmu_peric0`, `cmu_peric1`, `cmu_hsi0`,
`cmu_hsi2`. Missing entirely:

- **`cmu_disp` / `cmu_dpu` has no DT node at all** (`grep -c cmu-dpu\|cmu_disp
  gs201.dtsi` → `0`). The display block therefore runs at bootloader-default
  clocks with no gating. Per `docs/gs201-cmu-clock-scoping.md` that is
  **+99 mW** of the measured +407 mW mainline-vs-AOSP idle gap.
- **No `cmu_apm`.**
- **14 `fixed-clock` stubs remain in `gs201.dtsi`** standing in for real clock
  chains. Each one is a place where the kernel believes a rate it cannot
  actually control.

`clk-gs101.c` carries gs201 by reusing gs101's tables plus a `skip_ids[]`
exclusion list — an *empirical* list of registers that fault on gs201 hardware,
not a gs201 register map. `top_cmu_info_gs201` was still SError-ing at probe as
recently as the scoping doc; commits `af004ca8042a` / `f8c5539d3f1d` /
`7baa74b07bba` fixed specific offsets afterwards and `cmu_top` is now
`status = "okay"`. **The scoping doc is stale on this point** and should be
corrected.

Consequence chain: no `cmu_disp` → DPU ungated → the idle/thermal gap that
`docs/thermal-*` and the genpd work are both circling.

### 1.2 SuperSpeed USB only works in one connector orientation

`docs/todo-ss-orientation-agnostic.md` is explicit. `used_phy_port = 1` is
hard-coded (commit `209f3bad1408`) because the bench dongle always goes in
CC2. `phy_init` runs at ~0.32 s, long before the TCPC reports orientation, and
the PHY framework refcount means it never re-runs.

Two attempts to fix it properly both **failed destructively**, on branch
`wip/ss-orientation-remux`:

- full PHY re-init on live orientation → killed the USB2 path, fastboot recovery
- surgical lane-mux rewrite only → **hard-wedged the SoC** when the value
  actually changed (power-cycle required)

Shipped state is a working guess, not a fix. Plug the cable the other way and
there is no SuperSpeed and no fallback — it hangs retrying.

### 1.3 USB-C host-mode cold reset on VBUS transition — unsolved

Branch `fix/max77759-vbus-transitions` is **ahead 1 and unmerged**. The charger
`-EINVAL` wedge and the SS DT cap are fixed; the cold-reset-on-VBUS-transition
behaviour is not. This is the one the user has repeatedly flagged as
"don't write this off as flakiness" — it is still open.

### 1.4 genpd is a hand-curated allowlist, not a domain model

`drivers/pmdomain/samsung/gs201-pm-domains.c` is genuinely good work (200 lines,
clean, correctly re-expressed on the BL31 SMC regmap). The DT around it is not:
17 `google,gs201-pd` nodes, of which a curated subset is live, arrived at by
bisection. The commit trail says it plainly —

```
1805bf776d64 WIP: pmdomain: gs201 genpd provider — domains power off, but boot-loops ~40s in
ae2c70618823 WIP genpd bisect: disable dpu/disp domains (live display), keep imaging+tpu+aur
3757315e560f genpd: drop pd_tpu from the gated set (edgetpu consumer -> crash-loop)
0d1892156431 genpd: gate only the proven-11 set (disable g2d + bo)
```

Two of the four commits still say `WIP` in the subject line. `g3d` must never
be gated (it wedges ACPM), `dpu`/`disp` are off because the display is live,
`g2d`/`bo` were disabled by audit. That is five special cases on a set of
seventeen. It works, and nobody can currently say *why* the excluded ones fail.

### 1.5 UFS works, but still wearing its bring-up scaffolding

The functional result is excellent — 2.0 GB/s, HS-G4 Rate-B, faster than AOSP.
The code is not finished:

- `drivers/ufs/host/ufs-exynos.c` is +1,330 lines with **18 `#if` blocks** and a
  compile-time debug knob, `GS201_MAINLINE_FORCE_PWM_GEAR`, currently `0`, with
  a fallback PWM-G4 path and ~300 lines of commentary maintained around it.
- **`drivers/ufs/core/ufshcd.c` carries +147/−4 of bring-up instrumentation in
  the shared core**, including a `memset(lrbp->ucd_rsp_ptr, 0xAB, sizeof(struct
  utp_upiu_rsp))` on **every command submission, for every UFS host on the
  system**. That was a diagnostic for the silent-DMA wedge; the wedge is solved
  and the memset is still in the hot path.
- HS-Rate-B CDR-lock still runs on the AOSP-parity write set; the planned crib
  of ExynosAutov920's CDR-lock logic is a TODO.

### 1.6 Edge TPU — up, but structurally blocked

The Rust `drivers/accel/edgetpu` driver is the cleanest thing in the tree
(~2.7k lines, zero TODO/FIXME markers, real Kconfig help text). Secure firmware
auth, KCI mailbox, VII inference path, DVFS, SysMMU all work.

It cannot go anywhere because `depends on GSA` → `depends on TRUSTY`, and both
GSA and Trusty are grafts (§2.3, §2.4). The end-to-end milestone
(finch → MNIST) is also still pending.

### 1.7 Display — both panels live, pipeline incomplete

Outer (ea8182-f10) and inner (ana6707-f10) both light up. But `decon1`/`dsim1`
are still `status = "disabled"`, GEM is backed by CMA because there is no
IOMMU wired for the display path, and there is no `cmu_disp`. The whole thing
rides the graft in §2.1.

### 1.8 GPU g3dl2 — fix exists, in the working tree, uncommitted

Committed (`b3b677ec4602`) is a probe-time pin of `g3dl2` to 996 MHz, described
in its own message as "validation of the bandwidth-recovery hypothesis; the
proper fix is a multi-clock OPP". Sitting **uncommitted** in
`panthor_device.c` is the better version — raise on resume, drop to 151 MHz on
suspend, so it doesn't burn power at idle. Neither is the multi-clock OPP.

### 1.9 Fuel gauge — validated fix, uncommitted

327 lines in `max1720x_battery.c` plus 38 lines of `fg-model`/`fg-params` in
`gs201-felix.dts`. Per the work log this is built, deployed and validated on
device. It is not committed, so it is one `git checkout` from gone.

### 1.10 Upstreaming — 15 patches prepared, zero sent

`upstream-patches/` holds 15 patch files with a genuinely excellent README:
maintainer routing per patch, send order, honest caveats, and explicit
"don't oversell" framing on the ones that don't fix what they might appear to.

Nothing has gone out. `upstream-help/email.md` (Peter Griffin) and
`upstream-help/pixel-team-email.md` are both **drafted, not sent** — the latter
still has `<PIXEL TEAM CONTACT>` / `<NAME>` placeholders. Patches 0005 and 0006
are on HOLD "pending replies" to emails that were never sent. The email says
"12 patches"; there are 15.

This is the highest-value, lowest-effort open item in the entire audit. The
hard part is done.

### 1.11 An unexplained revert of upstream

```
fe834bc94378 Revert "regulator: core: clamp voltage constraints before applying apply_uV"
```

+73/−90 in `drivers/regulator/core.c`, reverting upstream `a45cc646a3aa`. The
commit message is the bare `git revert` boilerplate — no symptom, no rail, no
analysis. Either gs201 has a real constraint bug that needs finding, or upstream
does and needs telling. Right now the tree just carries the revert, and anyone
rebasing forward will hit it with no context.

---

## 2. What is a graft rather than upstreamable work

"Graft" = out-of-tree code imported substantially as-is, adapted to build. None
of the following can be sent anywhere in its current form; each needs either a
rewrite or an upstream owner who is not us.

### 2.1 `drivers/gpu/drm/samsung-felix` — 101 files, 53,527 lines

The AOSP 6.1 Samsung display driver, imported pristine (`dae1d641b095
"pristine graft"`) and then beaten into building against mainline. What holds
it together:

- `compat.h`, force-included into every TU via `-include`, `#define`-ing
  mainline API names back to their 6.1 spellings (`drm_atomic_state` →
  `drm_atomic_commit`, `strlcpy` → `strscpy`, `iommu_register_device_fault_handler`
  → `(0)`, `dma_heap_*` → `-ENOSYS` inlines, `exynos_get_idle_ip_index(...)` →
  `(-1)`).
- **A 19-file fake include tree** under `stubs/` shadowing `<soc/google/*.h>`,
  `<dt-bindings/soc/google/*>`, `<linux/soc/samsung/exynos-smc.h>`,
  `<asm/unaligned.h>` — prepended to the include path so the graft resolves
  vendor headers to no-ops.
- Kconfig symbols faked on the command line:
  `-DCONFIG_SOC_GS201=1 -DCONFIG_EXYNOS_PM_QOS=1 -DCONFIG_DRM_SAMSUNG_DECON=1 …`
  because `exynos_drm_drv.c` gates sub-driver registration on `IS_ENABLED()`.
- Two whole vendor CAL trees carried side by side (`cal_9845/`, `cal_9855/`).

`compat.h` also has a straightforward bug: the include guard's `#endif` is on
line 15, and the file continues for another ~50 lines *outside* the guard. It
happens to work because the file is only ever `-include`d once per TU.

Upstream path for this is not "clean it up". It is a from-scratch mainline
DRM driver for DECON/DSIM/DPP, which is a large independent project.

### 2.2 `drivers/phy/samsung/phy-exynos-usbdp-gen2-v4*` — 36,821 lines of headers

`phy-exynos-usbdp-gen2-v4-reg.h` alone is **33,300 lines** of generated
register definitions, plus 3,521 more for the PCS variant, plus the AOSP CAL
implementation (`phy-exynos-usb3p1.c`, 1,235 lines; `phy-exynos-usbdp-gen2-v4.c`,
777). This is the AOSP USB PHY CAL lifted wholesale.

It is also the reason §1.2 is unfixable in place — the lane mux lives inside
the graft's `phy_init`, and the two attempts to reach into it from outside both
took the SoC down.

Note the DT compatible `google,gs201-aosp-usb31drd-phy` — an A/B harness
compatible so the graft and the mainline PHY driver can be swapped at boot.
Useful for bring-up; cannot ship.

### 2.3 `drivers/trusty` — 21 files, 7,919 lines

Google's Trusty driver, `Copyright (C) 2013 Google, Inc.`, dropped into
`drivers/trusty/`. Trusty has never been merged upstream. Anything depending on
it inherits that.

### 2.4 `drivers/soc/google/gsa` — 12 files, 2,981 lines

AOSP GSA (Google Security Anchor) mailbox/auth driver. `depends on TRUSTY`.
This is what authenticates the TPU firmware, so §1.6 is gated behind §2.3.

Worth separating: patch 0008 in `upstream-patches/` is a **from-scratch ~80-line
GSA mailbox shim** written specifically to avoid this dependency for the UFS
KDN path. That one is first-party and sendable. The full graft is not.

### 2.5 `drivers/iommu/samsung-iommu*` — 4 files, 2,237 lines

Samsung's out-of-tree SysMMU driver, `Copyright (c) 2020 Samsung Electronics`,
placed at `drivers/iommu/samsung-iommu.c` — **the exact filename any future
upstream Samsung SysMMU driver would want.** A rebase onto a kernel that gains
one will collide by name. Contains a bare `BUG()` at `samsung-iommu.c:543`.

### 2.6 `drivers/gpu/drm/panthor` perfcnt — 2,258 lines, 9 files

Not a graft in the vendor sense — this is Zapolskas' upstream perfcnt v5 series
backported onto the felix base. It is upstream-bound work that belongs to
someone else; our delta on top is three small gs201 fixes (shader block
off-by-one, real `shader_present` for the SC mask, and deliberately *not*
bumping the driver version to avoid a Mesa `MMU_INFO` collision). Those three
are individually sendable to the series author. The 2,258 lines are not ours to
send.

### 2.7 Smaller grafts and appeasement

- **`gs201-android-handoff.dtsi`** — DT nodes (`soc_id`, `/dpm`, `/avf`, `/ect`,
  `/firmware`, reserved-memory carveouts) that exist purely so the factory ABL
  bootloader doesn't null-deref during dtb handoff. Reverse-engineered from a
  disassembled `abl.img`. Necessary; unshippable.
- **`drivers/soc/samsung/gs201-s2mpu-stub.c`** — 78 lines, probe-only, writes
  no registers. Placeholder claiming the S2MPU instances.
- **`gs201-felix-trusty.dtsi`** — Trusty DT with `android,trusty-*`
  compatibles. checkpatch flags `android` as an undocumented vendor prefix.

### 2.8 What is genuinely first-party and upstream-shaped

For balance, the good column:

| Area | Lines | State |
|---|--:|---|
| `upstream-patches/` 0001–0015 (UFS, UFS PHY, CMU_TOP/PERIC0, UART compat) | ~1,500 | **Formatted, routed, ready. Unsent.** |
| `drivers/pmdomain/samsung/gs201-pm-domains.c` | 200 | Clean, well-argued, needs a binding |
| `drivers/accel/edgetpu` (Rust) | 2,684 | Clean; blocked on GSA/Trusty |
| `drivers/thermal/samsung/gs201_acpm_thermal.c` + `s2mpg13_spmic_thermal.c` | 390 | Plausible |
| `drivers/regulator/s2mpg13-powermeter.c` (ODPM) | 626 | Validated on both PMICs |
| `drivers/mfd/sec-*` s2mpg13 sub-PMIC | 347 | Plausible |
| `drivers/devfreq/event/gs201-ppc.c` | 132 | Plausible |
| `clk-acpm` orphaned-provider fix | 1 line | Already identified as standalone |

---

## 3. What is not of upstream quality

### 3.1 Zero device-tree bindings, ~20 new compatibles

**`Documentation/` is untouched by all 140 commits.** `MAINTAINERS` is
untouched. Meanwhile the tree introduces roughly twenty new `google,gs201-*`
compatible strings — `-pd`, `-pmu`, `-pinctrl`, `-cmu-top`, `-cmu-peric0`,
`-cmu-peric1`, `-cmu-hsi0`, `-cmu-hsi2`, `-ufs`, `-ufs-phy`, `-usb31drd-phy`,
`-mbox`, `-ppc`, `-wdt`, `-acpm-ipc`, `-acpm-thermal`, `-mali`, `-edgetpu-gs201`,
plus `google,s2mpg12-powermeter` / `s2mpg13-powermeter` /
`s2mpg13-spmic-thermal`.

checkpatch flags 17 distinct undocumented compatible strings. This is not a
formatting nit — every DT-touching patch in the tree is un-sendable until its
binding exists, and binding review is where Samsung-SoC series historically
spend most of their calendar time. **This is the real cost of upstreaming, and
none of it has been paid.**

### 3.2 Shared-core edits that exist to serve one SoC

Three files outside any gs201-specific directory are modified:

1. **`drivers/ufs/core/ufshcd.c`** (+147/−4) — the 0xAB magic-stamp memset per
   submission plus hex-dump diagnostics, discussed in §1.5. Affects every UFS
   host.
2. **`drivers/clk/samsung/clk.c`** (+92/−9) — the `skip_ids[]` /
   `SAMSUNG_FILTER_CLKS` machinery: a macro that `kcalloc`s a filtered copy of
   each clock array, runs the register helpers on the copy, then frees it. The
   header comment justifies itself with "C allows us to treat the first field as
   `unsigned int` via a cast when all structs follow the same layout". It is
   proposed as patch 0013, so this one at least goes in eyes-open — but a
   reviewer will reasonably ask why gs201 doesn't just have its own tables
   instead of borrowing gs101's and subtracting.
3. **`drivers/regulator/core.c`** (+83/−90) — the unexplained revert, §1.11.

### 3.3 checkpatch on the first-party delta

Over the ~25.4k first-party diff: **6 ERROR, 240 WARNING, 126 CHECK.** For
bring-up that is respectable. The recurring items:

| count | issue |
|--:|---|
| 53 | line over 80 columns |
| 37 | alignment doesn't match open paren |
| 27 | `uintN_t` instead of kernel `uN` |
| 13 | should use `BIT()` |
| 13 | trailing `*/` placement |
| 11 | multiple blank lines |
| 3 | `BUG()`/variants — "do not crash the kernel unless absolutely unavoidable" |
| 2 | memory barrier without comment |
| 1 | one-element array instead of C99 flexible array |

Mechanical, a day's work, but it has to happen before anything goes to a list.

### 3.4 Bring-up scaffolding left in shipping code

- `GS201_MAINLINE_FORCE_PWM_GEAR` — a `#define`-gated alternate power-mode path
  in a production driver, with 18 `#if` blocks around it.
- The `dev_info` → `dev_dbg` sweep (patch 0012) is described in its own README
  entry as **"not an upstream-quality patch (it's a quick 'shut it up' sweep); a
  proper cleanup pass is owed"**. Correct assessment. Still owed.
- 29 `dev_dbg`/`print_hex_dump` sites in `ufs-exynos.c`.

### 3.5 Placeholder regulators standing in for real rails

`gs201-felix.dts` defines `reg_placeholder` and `reg_disp_placeholder` —
always-on fixed regulators — and wires **seven USB PHY supplies** (`pll-supply`,
`dvdd-usb20`, `vddh-usb20`, `vdd33-usb20`, `vdda-usbdp`, `vddh-usbdp`, `vdd33`,
`vdd10`) plus three display supplies to them. The DT comments are honest about
it, and the display path has since been moved onto real s2mpg13 rails in one
place. The USB path has not. A DT reviewer will not accept a fake regulator
standing in for a described supply.

### 3.6 Documentation drift

`docs/gs201-cmu-clock-scoping.md` states `cmu_top` is "**disabled** — **NO —
SError**" and that `cmu_hsi2` has "**no DT node**". Both are stale: the DT now
says `status = "okay"` for both and the offset bugs were fixed in
`af004ca8042a`/`f8c5539d3f1d`/`7baa74b07bba`. The doc is the primary reference
for the largest open project in the tree, so this matters more than usual.

---

## 4. Repository hygiene

Not "quality" in the code sense, but it is what makes the port hard to hand to
anyone else — including future-you.

- **The submodule branch pin is meaningless.** `.gitmodules` says
  `branch = felix`. `felix` is at `v7.2-rc3-95-gae1396dc10e1`: **95 commits
  diverged, 1,308 behind** the actual HEAD. The tree you build is
  `wip/panthor-perf-v5`.
- **The shipping kernel is a WIP branch with dirty files.** HEAD is
  `wip/panthor-perf-v5`; three files are uncommitted on top (§1.8, §1.9), two of
  which are validated improvements. `felix-7.2-rc5` — the name that sounds
  authoritative — is 11 commits behind.
- **30 local branches**, including `feature/mainline-fbcon-KNOWN-BAD`,
  `experiment/pmu-intr-gen-WEDGES`, `experiment/deep-idle-smc` ("TEMP
  DIAGNOSTIC"), and six `feature/gs201-genpd-*` bisect branches. Plus one stash.
  None of them is labelled dead in a way a tool can read.
- **~20 `modules-*.tar.gz` untracked** in the `jboot-mainline` worktree, along
  with `.flashtmp/` and `.working-00127/`.
- Two `WIP` commits are permanent history on the shipping branch
  (`1805bf776d64`, `ae2c70618823`).

---

## 5. Where this leaves the port

Three honest sentences:

1. **As a bring-up platform it is in good shape.** UFS beats AOSP, both panels
   work, the GPU runs on Panthor, the TPU executes inferences, USB does host and
   gadget and PD charge-through. The engineering log quality — the caveats in
   `upstream-patches/README.md`, the DT comments explaining *why* a stub is
   there — is well above what bring-up trees usually carry, and it is the reason
   this audit was possible at all.

2. **As an upstream contribution it has not started.** Not "is behind" — has
   not started. Fifteen patches are formatted and routed and none has been sent;
   zero bindings exist for twenty new compatibles; four fifths of the diff is
   code we cannot send.

3. **The gap between those two is one specific, bounded task:** separating the
   sendable first-party work from the graft it currently shares a branch with.

### Suggested order

1. **Send patches 0001–0004, 0007, 0009–0011, 0015.** Weeks of work already
   done, sitting idle. The two emails need finishing (`pixel-team-email.md` still
   has placeholder names) or abandoning — 0005/0006 are blocked on replies to
   mail that was never sent, which is the worst kind of blocked.
2. **Commit the three dirty files.** The fuel-gauge fix in particular is
   validated work that exists in exactly one place.
3. **Fix the branch pin and prune the branches.** `.gitmodules` should name the
   branch that is actually built. Tag or delete the `KNOWN-BAD` / `WEDGES` /
   bisect branches.
4. **Revert the revert, or explain it.** §1.11 either hides a gs201 bug or an
   upstream one.
5. **Take the shared-core edits back out of the shared cores** —
   `ufshcd.c` first, since the 0xAB memset runs on every I/O on every image.
6. **Then decide about bindings.** Writing ~20 binding YAMLs is the real
   upstream cost and it should be a deliberate decision, not something
   discovered halfway through a series. Cheapest first: `gs201-pd`,
   `gs201-ppc`, `s2mpg13-powermeter` — small, self-contained, and each unblocks
   a clean first-party driver.
7. **Leave the grafts alone.** Display, Trusty, GSA, the USB PHY CAL — these are
   not "not yet cleaned up", they are separate multi-month projects. Naming them
   that way stops them from silently blocking things that are actually ready.
