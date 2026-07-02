# Build `aospdiff` — host-side AOSP-vs-mainline differ family (`dt` first)

> Supersedes `dtdiff.md`. dtdiff is now the `dt` subcommand of `aospdiff`, the first member of
> the static, host-side AOSP-vs-mainline differ family that felixprobe's README already names
> (the others — `defconfig`, `driver-bind`, `boot-log` — land later as sibling crates).

## Purpose / context

felix bring-up is **differential**: the stock AOSP image fully drives the same silicon, so the
AOSP-side artifacts are the authoritative oracle and "what mainline is missing" is just the diff.
For device tree specifically, mainline felix/gs201 DT is incomplete; the felix **AOSP dtbs**
(base `gs201-*.dtb` + the `dtbo.img` overlays) are the real description of how the hardware is
wired. This session I repeatedly did, by hand: `fdtoverlay` the base+overlay, `dtc -I dtb -O dts`,
then resolve raw phandles to node names (`0x1dd`→`gpa9`, `0x36d`→`max77759_gpio`, `0x75`→the clock
controller), then eyeball the AOSP node vs the mainline node to see what's missing (clocks,
pinctrl, interrupts, reg, sub-nodes). Every one of those steps is automatable.

`aospdiff dt` turns "what does the AOSP DT say about this node, and what is my mainline DT
missing" into one command. The same `resolve → match → diff → to-do list` shape is what the later
siblings reuse — so it's built as a family, not a one-off.

## Repo shape (this is the first crate of the family)

A Rust cargo workspace, host-native (the `dtdiff` half of felixprobe's flake — no cross-musl;
these tools eat files on the host). One **single binary** `aospdiff` with subcommands, each backed
by its own crate, all wired through a shared core:

```
crates/differ-core/   the domain-agnostic engine + CLI shell (below)
crates/dt/            the `aospdiff dt …` subcommand — DT specifics (first consumer)
crates/defconfig/     later
crates/driver-bind/   later
crates/boot-log/      later
```

One install, one `--help`, one `--json` contract, one exit-code table. nix flake (host build) +
`.github/workflows/ci.yml` (clippy `-D warnings` · tests · build), matching the sibling repos.

### `differ-core` owns (domain-agnostic)
- **Entity matching** — pair "the same thing" across two sources by a *domain-supplied key*.
- **Field-level diff** — `add` / `remove` / `change`.
- **A first-class `NeedsReview` / `Unmappable` verdict in the diff model** — the "flag it, don't
  silently mismap" rule lives here, not reinvented per tool.
- **The to-do-list renderer** (text + `--json`) and the **exit-code contract**.
- **CLI plumbing.**
- **A `Resolve` trait** the core calls during render ("turn this raw ref into a display name").
  Resolution is *not* generic — phandle→label is DT-only, Kconfig-symbol is defconfig-only — so
  each crate implements `Resolve`. This trait is the difference between siblings genuinely reusing
  core and each gluing its own resolver to a shared formatter.

### Exit codes (`aospdiff`)
`0` clean / no missing props · `1` differences found · `2` usage · `3` selector not found /
unresolvable input. `--json` everywhere for the next agent step to consume.

## `crates/dt` — the DT subcommand

### Inputs
- AOSP base dtb(s) (e.g. `out/felix/dist/gs201-b0.dtb`) + `dtbo.img`.
- The mainline **compiled** `gs201-felix.dtb`. **Compiled DTBs only** — both sides — not `.dts`
  sources (reimplementing dtc's cpp/macro/`/include/` frontend is a near-clone of dtc for zero
  bring-up value; defer `.dts` parsing to a later version).
- **Both sides must be compiled with `dtc -@`** so the `__symbols__` node survives — that's what
  lets `0x1dd`→`gpa9` render paste-ready. Without symbols you're back to numbers; detect its
  absence and say so rather than emitting paths as if they were labels.

### DTB tooling (hybrid — and it lives in `crates/dt`, not core)
- **Overlay merge: shell out to `fdtoverlay`.** Applying `dtbo.img` overlays correctly means
  honoring `__fixups__`/`__local_fixups__` phandle fixups; a hand-rolled Rust merger is a real
  correctness risk for zero payoff, and `fdtoverlay` is the authoritative tool (already in the
  flake, already what I do by hand).
- **`dtbo.img` is multi-blob — select before merging.** Split on the fdt magic to get N overlays,
  then pick the felix one by matching its `id`/`rev`/`custom` against the base (or `--overlay N`),
  and `fdtoverlay base + that one`. "Merge base+overlay" assumes a choice that has to be made.
- **DTB read + resolve + diff: pure Rust.** Reading a flattened FDT is trivial and `__symbols__`
  gives label→path directly — own this so label fallback and diffs are golden-file testable
  (bundle a felix base dtb + dtbo fixture; the whole suite is hardware-free).

### Capabilities (subcommands of `aospdiff dt`)
Lead with the two that ate this session by hand; the rest fall out of the same engine as thin
helpers.
- **`dt node <selector>`** — select a node by path / `compatible` / `reg` address in both the
  AOSP-resolved DT and the mainline DT and **diff their properties** with resolved names. Match
  by **reg base address** (robust: compatible strings and unit-addresses drift between AOSP and
  mainline; the physical address doesn't). Output reads like a to-do list:
  "AOSP `hsi2c@10d60000` has clocks `<&cmu_peric1 …PCLK_6/IPCLK_6>`, pinctrl `hsi2c13_bus`,
  interrupt `GIC_SPI 695`; mainline node missing: pinctrl, …".
- **`dt irq|gpio <node> <prop>`** — resolve an interrupt/gpio specifier to bank + line + flags
  with names (the MAX77759 IRQ → `gpa9 4 IRQ_TYPE_LEVEL_LOW`, the in-switch →
  `max77759_gpio 5 ACTIVE_LOW`). Needs **bundled `dt-bindings` constant tables** (GIC SPI/PPI,
  `IRQ_TYPE_*`, gpio flags) plus per-provider `#interrupt-cells`/`#gpio-cells` awareness — the
  same "bundled, named lookup table" mechanism `regmap` is to felixprobe.
- **`dt resolve <dtb> [overlay]`** — emit a fully-resolved DTS: every `phandle = <0xNN>` and
  `<&ref …>` rendered as the target node's label/name. (Thin helper: largely `dtc -I dtb -O dts`,
  its only delta being forcing numeric phandles → names even where dtc emits `0xNN`.)
- **`dt phandle <dtb> 0xNN`** — quick: what node owns this phandle.

## The hard part: representation impedance (flag it, don't silently mismap)
AOSP and mainline model the SoC differently — most importantly **clocks** (AOSP uses one big
`clock-controller` with thousands of IDs; mainline uses per-CMU controllers with the
`google,gs101.h` bindings) and **pinctrl** (positional bank subnodes). `aospdiff` can't always
auto-translate these, so it emits the core's **`NeedsReview`** verdict, never a guess: "AOSP clock
id 0x589 on controller 0x75 — no direct mainline equivalent; this is
`CLK_GOUT_PERIC1_PERIC1_TOP0_*` territory, verify by hand." Where a mapping table exists (CMU base
addr → mainline compatible), apply it; otherwise flag, don't fabricate.

## Success criteria
`aospdiff dt node hsi2c@10d60000` prints, in one shot, exactly what the mainline i2c node needs vs
the AOSP one — clocks, pinctrl, interrupt, USI parent — with all phandles resolved to names. The
MAX77759 IRQ bank (gpa9) and the in-switch GPIO (max77759_gpio 5) come straight out of
`aospdiff dt gpio`/`dt irq` instead of manual `fdtoverlay` + awk archaeology. `--json` on any of
these feeds the next step.

## Non-goals
- Not a DT *writer* — it tells you what's missing; you edit the mainline source.
- Not arbitrary SoCs — felix/gs201 (gs101 as the mainline template) first.
- Not a substitute for the driver-side check (a property can resolve fine in DT yet the mainline
  driver not support it) — pair with reading the driver.
- No `.dts`-source parsing in v1 (compiled DTBs only); no pure-Rust overlay merger (shell
  `fdtoverlay`).

## Build order
Stand up `crates/differ-core` (matching + diff + `NeedsReview` verdict model + renderer +
`Resolve` trait + CLI) → `crates/dt` (`fdtoverlay`-shell + Rust FDT reader + the `node`/`irq`/
`gpio` decoders) as the first consumer. The three later siblings then only write a key-extractor,
a `Resolve` impl, and their decoders.
