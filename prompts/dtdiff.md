# Build `dtdiff` — resolve + diff the AOSP device tree against mainline

## Purpose / context

Mainline felix/gs201 DT is incomplete; the felix **AOSP dtbs** (base `gs201-*.dtb` + the
`dtbo.img` overlays) are the authoritative description of how the hardware is actually wired.
This session I repeatedly did, by hand: `fdtoverlay` the base+overlay, `dtc -I dtb -O dts`,
then resolve raw phandles to node names (`0x1dd`→`gpa9`, `0x36d`→`max77759_gpio`, `0x75`→the
clock controller), then eyeball the AOSP node vs the mainline node to see what's missing
(clocks, pinctrl, interrupts, reg, sub-nodes). Every one of those steps is automatable.

`dtdiff` is a **host-side** tool that turns "what does the AOSP DT say about this node, and what
is my mainline DT missing" into one command.

## Inputs
- AOSP base dtb(s) (e.g. `out/felix/dist/gs201-b0.dtb`) + `dtbo.img` (a multi-blob Android dtbo
  image — split it on the fdt magic).
- The mainline DT (the `.dts`/`.dtsi` sources, or the compiled `gs201-felix.dtb`).

## Capabilities
- `dtdiff resolve <dtb> [overlay]` — apply the overlay onto the base (fdtoverlay), then emit a
  **fully-resolved** DTS: every `phandle = <0xNN>` and every `<&ref …>` rendered as the target
  **node's label/name**, not a number. (The thing I did one phandle at a time.)
- `dtdiff phandle <dtb> 0xNN` — quick: what node owns this phandle.
- `dtdiff node <node-selector>` — select a node by path / `compatible` / `reg` address in both
  the AOSP-resolved DT and the mainline DT and **diff their properties** with resolved names:
  "AOSP `hsi2c@10d60000` has clocks `<&cmu_peric1 …PCLK_6/IPCLK_6>`, pinctrl `hsi2c13_bus`,
  interrupt `GIC_SPI 695`; mainline node missing: pinctrl, …". This is the exact comparison I
  assembled across many manual steps.
- `dtdiff irq|gpio <node> <prop>` — resolve an interrupt/gpio specifier to bank + line + flags
  with names (e.g. the MAX77759 IRQ → `gpa9 4 IRQ_TYPE_LEVEL_LOW`, the in-switch →
  `max77759_gpio 5 ACTIVE_LOW`).

## The hard part: representation impedance (flag it, don't silently mismap)
AOSP and mainline model the SoC differently — most importantly **clocks** (AOSP uses one big
`clock-controller` with thousands of IDs; mainline uses per-CMU controllers with the
`google,gs101.h` bindings) and **pinctrl** (positional bank subnodes). `dtdiff` can't always
auto-translate these, but it must **flag** them clearly: "AOSP clock id 0x589 on controller
0x75 — no direct mainline equivalent; this is `CLK_GOUT_PERIC1_PERIC1_TOP0_*` territory, verify
by hand." Where a mapping table exists (CMU base addr → mainline compatible), apply it.

## Output
- A readable resolved DTS, and per-node diffs that read like a to-do list of properties to add
  to the mainline node, with names resolved so they're paste-ready.

## Success criteria
`dtdiff node hsi2c@10d60000` prints, in one shot, exactly what the mainline i2c node needs vs
the AOSP one — clocks, pinctrl, interrupt, USI parent — with all phandles resolved to names.
The MAX77759 IRQ bank (gpa9) and the in-switch GPIO (max77759_gpio 5) come straight out of
`dtdiff gpio`/`irq` instead of manual `fdtoverlay` + awk archaeology.

## Non-goals
- Not a DT *writer* — it tells you what's missing; you edit the mainline source.
- Doesn't need to handle arbitrary SoCs — felix/gs201 (and gs101 as the mainline template) first.
- Not a substitute for the driver-side check (a property can resolve fine in DT yet the mainline
  driver not support it) — pair with reading the driver.
