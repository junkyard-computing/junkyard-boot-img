# Platform Strategy — Requirements & Direction (DRAFT)

> Status: **living strategy doc / requirements scaffold.** Not a design or a
> commitment to any one solution. Debian/debootstrap, the boot-img pipeline, and
> "an image" as the unit are all on the table to keep, change, or discard.
>
> **Reading-order note:** this doc grew by *successive reframings* (newest
> context first, hence negative-numbered leading sections). The chain:
> "fix the version string" → image *lifecycle* (fleet) → **two products on one
> bring-up platform** (§–1) → **what is this repo for / charter** (§–2) →
> **ground-truth against the existing KRG fleet, krg-infra** (§–3). The
> first-principles identity work (§1.6–1.8) was *independently validated* by §–3.
>
> **TL;DR of current direction:**
> - This repo = **substrate + dev platform** (felix bring-up + rich Debian base +
>   profile system). The fleet *operate* plane is a **different team's** repo
>   (§–2). Charter = goals 3+4 (kernel/userland dev), enabling 1+2.
> - **Identity = git commit** (ordered human version + exact hash + honest dirty
>   handle). Manifest is *code, not a stored artifact* (§1.6) — confirmed as the
>   existing fleet's production model (§–3).
> - **Profiles** (`base + package-set + config overlay`) unify interactivity /
>   role / hardening (§1.8). The "minimal/hardened" OS = *stripped Debian*, not a
>   different OS.
> - **Harden the substrate now; userland reproducibility/immutability waits on
>   the build-model decision** (§2a), whose strong lean is now **NixOS-on-felix**
>   (§–3).

---

## –3. Ground truth: how KRG's existing fleet (krg-infra) already works

The operator pointed at `github.com/KastnerRG/krg-infra` — the lab's existing
server fleet, which the future phone-fleet-operate plane will resemble (owned by
a *different team* the operator is also on; §–2/cross-team seam). Read in-session
(local clone). **It independently validates almost every conclusion we reached
from first principles** — and revises one.

### What it confirms

- **Identity = git commit. Confirmed, in production.** krg-infra is a pure
  **NixOS flake**. A host's identity is the **flake's `main` commit** (via
  `flake.lock` on the GitHub ref) + the nix derivation hash. **No stored version
  string, no content manifest** — the commit IS the version, the manifest is the
  derivation (i.e. *code, computed*, not a stored artifact). This is *exactly*
  §1.6 ("identity = git hash; manifest is code"). They live it.
- **Profiles. Confirmed, house style.** `profiles/{base,server,compute,
  directory}.nix`, composed per host. Identical abstraction to §1.8
  (`profile = base + package-set + config overlay`). New node = new
  `hosts/{name}/default.nix` choosing a profile. Roles ARE profiles.
- **Reproducible by construction.** Nix ⇒ same inputs → same closure. The thing
  §1.6 says the git-hash claim *depends on*, they get for free from the build
  model. (Their build model already satisfies F3.)
- **Atomic update + rollback. Confirmed.** NixOS generations + GRUB generation
  menu = atomic switch with rollback to prior generation. (Our F2, their default.)
- **Immutable-root pattern exists.** `waiter` uses **impermanence** — `/` rolled
  back to a blank ZFS snapshot every boot; durable state in `/persist`, `/nix`,
  etc. That's F1 (immutable root + explicit mutable state carve-out) **already in
  production** — and directly the model for Garage storage nodes (R7 state
  separation).

### What it REVISES — §2a default (⚠️ SUPERSEDED by §–4)

> **CORRECTION (see §–4):** I originally leaned **NixOS** for the fleet build
> model here, generalizing from krg-infra being NixOS. **That was wrong.** §–4
> (the "cloud of phones" design context) explicitly *rejects* NixOS for felix —
> because krg-infra runs NixOS on **x86 servers that boot normally**, whereas
> felix has the **Pixel A/B/AVB/bootctl boot chain** that NixOS's
> generation/bootloader model fights. I generalized from a reference that lacks
> the one constraint that dominates felix. The fleet lean is now **minimal Debian
> + mkosi/debos**, Talos-shaped. Original (wrong) paragraph kept below struck
> through for honesty.

~~The biggest open fork (§2a) now has a strong house-style default: NixOS… a
felix fleet image that is a NixOS system closure would slot into krg-infra's
machinery…~~ — **retracted; see §–4.** krg-infra still validates the *identity
model* (git-commit = version, manifest = code) and the *profile* abstraction;
it does **not** validate NixOS as the felix build model (different boot chain).

### What it LACKS (gaps we'd be adding, not inheriting)

- **No image building.** krg-infra **deploys configs to already-running
  machines** (`nixos-rebuild switch --target-host`); it never builds bootable
  artifacts (no nixos-generators/ISO/SD/disk images). Phones can't be
  `nixos-rebuild`-ed from bare metal the way a provisioned server can — **felix
  needs a flashed boot image first.** So the seam is NOT "export a toplevel and
  let krg-infra deploy it" for *initial* provisioning; bring-up/flashing is genuinely
  this repo's job. After first boot, the krg-infra-style closure-deploy *could*
  take over.
- **No version registry / no expected-vs-actual.** Git is the only truth; drift =
  "host hasn't auto-upgraded." A `drift/` dir exists but is undocumented. At
  20k-phone scale this is a gap the fleet plane must close (not this repo).
- **No k8s/Karmada/Garage yet.** The existing fleet is standalone VMs + hosts +
  docker-compose, coordinated by AD/DNS/NFS/Prometheus. The k8s/Karmada/Garage
  fleet (Product A) is **new build-out for the other team**, not an existing
  pattern to inherit. (So Product A's *orchestration* is greenfield for them too.)

### The seam, concretely (this repo → fleet plane)

The fleet plane consumes **versioned, provenance-bearing boot images** (per §–4,
NOT NixOS closures — corrected). The cleanest seam this repo can offer:

- **Emit a versioned, reproducible boot image + rootfs** the fleet pipeline
  references by content hash + commit (NOT a Nix flake output — see §–4).
- **Identity = this repo's git commit** (+ the package lock, §–4 #2). Matches the
  fleet's `(commit, lock)` provenance model — no translation.
- **Profiles** here map onto the fleet's per-role images (compute/storage).
- **Bring-up/flash stays here**; A/B-slot image delivery (RAUC/Mender, §–4 #5) is
  the fleet plane's job, riding the Pixel slots this repo already wires.

⇒ The §1.6/§1.8 design (git-commit identity + profiles) IS the consuming fleet's
model (§–4 #2, #4) — confirmed. Only my "express the seam in NixOS terms" was
wrong (§–4 rejects NixOS); express it as **versioned boot images + a committed
package lock** instead.

---

## –4. The "cloud of phones" design context (most authoritative input)

The operator supplied a full design-discussion capture for the actual fleet
("Cloud of Phones" — datacenter-scale compute/storage out of Pixel Folds, tens of
thousands of devices). This is the **most authoritative fleet input** so far:
real reasoning for the actual Product A. Treats its "facts/constraints" as hard
givens; its "leans" as provisional. **It validates the bulk of §1.6–§1.8 and
corrects two things I got wrong.** Summary + how it lands against this doc:

### Hard constraints it adds (treat as given)

- **Custom kernel required.** Flatcar/CoreOS/Talos are *references, not flashable
  targets* (each owns its own kernel + boot).
- **⚠️ CONTRADICTION — "mainline-on-Tensor not viable / Pixel A/B/AVB/bootctl is
  THE substrate":** §–4 asserts this as a hard constraint. **It directly
  contradicts this repo's active work and the operator's stated goal.** This repo
  has a live **mainline gs201 port** (`feature/linux-kernel`/`mainline-graft`):
  bidirectional UART working, UFS bring-up (PWM workaround shipped), USB Phase A
  at UDC/configfs, upstream patches drafted. **Operator: mainline is the GOAL,
  not a dead end** — §–4's "not viable" is the opposite of the target. Reading:
  §–4 captured a fleet discussion that *assumed the AOSP/Android boot chain*,
  likely stale or AOSP-perspective, possibly written without the mainline push in
  view. **Resolution: the mainline goal WINS over §–4's assumption here** (the
  operator owns the goal; the working port is evidence). Cascade consequences to
  re-examine (don't inherit §–4's Android-boot reasoning blindly):
  - **⚠️ SELF-CORRECTION (operator, 2026-06-03):** I initially claimed mainline
    *removes* the Android boot-chain constraint. **WRONG.** The **bootloader**
    (not the kernel) imposes the partition layout, the **A/B slots**, the
    boot.img-in-a-slot format, and slot selection/retry. The Pixel bootloader
    kicks us off and **we are beholden to it regardless of which kernel rides in
    boot.img.** So mainline does NOT free us from the A/B/partition substrate.
    What *may* still differ on mainline is the *userspace* slot-marking path
    (Android `bootctl`/Keymaster HAL vs `pixel-bootctl`→`devinfo` direct), but the
    bootloader-imposed structure persists either way.
  - ⇒ **Mainline does NOT, on its own, strengthen the anti-Android-boot arguments
    or the Nix case.** The boot.img-in-a-slot, atomic-A/B, opaque-image model is
    imposed by the bootloader for *both* tracks. (My earlier "mainline kills the
    #1 Nix objection" is retracted — see §–5.)
  - **Still true:** mainline-vs-AOSP remains a real fork (it changes kernel
    source, drivers, the userspace slot-marking path, Titan/Keymaster
    reachability), but it does **not** change the bootloader/partition substrate.
    §–4's boot/partition leans largely **survive** the mainline goal; its
    *kernel* "mainline not viable" claim does not.
- **USB-Ethernet interconnect** = high bandwidth, high latency, shared — *"the
  single most influential physical constraint."* No data locality.
- **On-device builds BANNED** (= drift). Phones are *dumb applicators*: pull
  prebuilt image → verify → write inactive slot → flip → mark good / rollback.
- **Byte-for-byte repro NOT required; verifiable provenance IS.**
- **Compute and storage do NOT share hosts** (tier separation decided).
- **No-SSH appliance / cattle-not-pets** for the fleet (Talos is the reference).
- Dead ends: **MinIO dead**, **snaps unavailable** (⇒ Ubuntu Core + Ubuntu
  differentiators out).

### What it CONFIRMS in this doc (independent agreement)

- **Identity = (git commit, lock).** §1.6 ("identity = git hash; manifest =
  code") confirmed — *and sharpened*: a bare commit pins the recipe but not the
  Debian archive, so identity = **(commit, package-lock)**. Provenance is "table
  stakes"; byte-repro explicitly not. ⇒ see §1.6 correction below.
- **Per-role images** (#4) — confirmed, and *preferred over single golden image*,
  for the exact reason §1.8 + §2d gave: **capability-absent > capability-disabled**
  (storage image has no kubelet), smaller images (×2 slots on limited UFS), few
  coarse SKUs (~2–4), built **common base + thin role overlays** (= our profile =
  base + overlay). The "line that must not be crossed": **role → image (coarse,
  delivery layer); per-device identity → config service at boot (fine).** Never
  bake per-device identity into images. This is §1.8 made concrete.
- **Stripped Debian, not a different OS** (§1.8) — confirmed as the lean:
  **minimal Debian + mkosi/debos**, Talos-*shaped*. NixOS, Gentoo, Ubuntu(Core),
  Flatcar/CoreOS/Bottlerocket/Talos all weighed and rejected for felix.
- **Immutable host + explicit persistent carve-out** (F1 + R7) — confirmed:
  immutable OS image / boot-time identity config / **persistent data mount**
  (Garage dirs survive A/B swaps + reboots, exempt from wipe-on-boot).
- **Atomic A/B update + rollback** (F2) — confirmed as the delivery model.

### What it CORRECTS in this doc

1. **NixOS retracted as fleet build model** (fixes my §–3 lean). NixOS's
   generation/bootloader model fights the Pixel A/B/AVB chain ("NixOS cosplaying
   as an opaque image"); store weight ×2 slots on constrained UFS; bus factor.
   krg-infra is NixOS only because it's **x86 servers that boot normally** — it
   lacks felix's dominating boot-chain constraint. Fleet build model lean =
   **mkosi/debos minimal Debian.**
2. **Precondition relaxed: provenance, not hermeticity.** §1.6 said "identity =
   git hash *requires a pure/hermetic build*." Overstated. Required property is
   **verifiable provenance**, not bit-reproducibility. Mechanism = **`repro-env`**
   (kpcyrd, in trixie): a committed, hash-bearing `repro-env.lock`
   (name/version/url/sha256 per package + base digest), resolved *before* build,
   self-validating (hashes in-repo, not snapshot-timestamp trust), no circularity.
   (`repro-get` = decentralized-fetch variant.) ⇒ retargets the "harden
   determinism now" decision: **harden toward the lock, not toward bit-identical.**

### A distinction it forces: IMAGE identity vs NODE identity

This whole doc up to here used "identity" for **image identity** (*what software*
→ git commit). §–4 #10 introduces **node identity** (*which physical device*):
**location-as-identity** — the USB-Eth dongle MAC + its switch port + backplane
slot hold identity; the phone is anonymous interchangeable mass. Config service =
pure function `MAC → {role-image, failure-zone, per-node identity, join secrets}`,
secrets gated on "MAC arrived on its expected switch port" (unspoofable).
**Plus** Titan M2 as a hardware trust anchor (non-extractable keys, boot
attestation) — *additive*: slot = name/place (swap-surviving), Titan =
credential/integrity (swap-dying); the seam between them is the enrollment
checkpoint.

> These are **orthogonal, both required**: image identity (this repo emits) vs
> node identity (the fleet plane assigns at boot). They never conflate. This
> repo's job is **image** identity; node identity is entirely fleet-plane (§–2
> seam). Naming them apart prevents the conflation I'd been making.

### Open questions §–4 owns (fleet plane, NOT this repo — listed for awareness)

RAUC vs Mender (A/B orchestration) · Garage vs SeaweedFS (CRDT/churn-cheap-heal
vs EC/capacity) · rotation state machine + failure-domain rate limiter ·
location-as-identity + administratively-assigned-MAC scheme · **Titan
reachability off-Android** (gating hardware verification — Keymaster/StrongBox
HAL may not exist on custom-kernel+Debian; verify on real hardware) · how-tiny
(Debian+systemd vs Alpine/musl vs static) · naming (Krill/School/Shoal).

## –5. The Nix re-discussion + mainline + September deadline (IN PROGRESS — paused)

Operator asked to revisit Nix once more (krg-infra is a substantial existing
NixOS base, partial team overlap) and corrected my mainline reasoning. State so
far, **paused for more operator input**:

### New hard facts (operator, treat as given)
- **September deadline (~3 months):** a small number of phones deployed. Short
  horizon ⇒ favors the **known-working path**. **Android kernel is relevant here**
  (the AOSP track is the near-term deploy vehicle; mainline is the longer goal).
- **Bootloader imposes the substrate, both tracks:** even with a mainline kernel,
  the **Pixel bootloader** kicks us off ⇒ we're beholden to its **partition
  structure incl. A/B**. boot.img-in-a-slot + atomic A/B is a given regardless of
  kernel. (This corrects my overstatement; see §–4 boot bullet.)
- **Team overlap with the NixOS fleet team is *partial*, not complete.** So the
  "align to krg-infra for bus-factor" argument is *weaker* than I framed — the
  operators are not simply the same Nix-fluent people.

### What this does to the Nix case
- My claim "mainline removes the #1 Nix objection (boot-chain collision)" is
  **RETRACTED.** The A/B/opaque-image/boot.img-in-a-slot model is bootloader-
  imposed for both tracks, so Nix still has to "cosplay as an opaque image" either
  way. Mainline does **not** rescue Nix here.
- Operator (provisional): **"Yes, reopen NixOS seriously"** — BUT this predates
  the boot-chain correction above, so the reopening rests more on **krg-infra
  prior art + native flake.lock identity** than on mainline. Net: reopened, but
  the strongest *new* reason I gave for reopening was wrong.
- **September + Android-kernel relevance pulls the *near-term* toward the
  existing AOSP/Debian path**, not a Nix rebuild. Nix (if adopted) is a
  *longer-horizon fleet* question, not a 3-month-deadline question.

### ⚠️ "Two horizons" framing RETRACTED (operator)

Operator: **Nix-vs-Debian is NOT a horizon decision — it must be made in the near
future.** September is smaller scale but **still thousands of phones**, so *all
the fleet logistics already exist.* ⇒ **pick-once dominates:** building September
on Debian and re-platforming thousands of devices to Nix later IS the logistics
pain we're trying to avoid. The decision is load-bearing NOW; "defer to the 20k
horizon" was a dodge.

### The reframe that strengthens the Nix case (more than §–4 credited)

§–4's central anti-Nix objection — *"NixOS fights the Pixel boot chain; you'd ship
the store and disable the boot model, cosplaying as an opaque image"* — is **barely
a cost here**, for a reason independent of mainline:

- NixOS's "boot model" = generation-based bootloader mgmt (systemd-boot/GRUB +
  rollback). On felix the **Pixel bootloader already owns slot selection + A/B
  rollback.** So "disabling NixOS's boot model" loses nothing — **the bootloader
  replaces exactly that function.** Clean division of labor:
  - **Nix owns build + identity** (flake.lock — the wanted property). Kept whole.
  - **Pixel bootloader owns slot + atomic rollback** (it does anyway).
- ⇒ "NixOS as opaque image" keeps the *entire* flake.lock property and discards
  only the part the bootloader overrides regardless. §–4's framing oversold this
  as a sad compromise; structurally it's a clean fit.

And the kernel/firmware foreign-build pinning being equal effort in both worlds
(my earlier point) cuts **pro-Nix**: the hard novel integration (felix boot,
kernel, firmware) is ~equal cost either way, so Nix's userspace flake.lock
advantage comes nearly free over the work already being done.

### What actually remains — a SHORT EMPIRICAL list (not philosophy)

1. **Closure weight ×2 A/B slots on constrained UFS** — *measurable.*
2. **Does NixOS-as-opaque-image boot on felix through the Pixel bootloader?** —
   *testable*, and the gating September-timeline risk.
3. **Bus factor at partial team overlap** — real but soft.

(1)+(2) decide it; both are cheap to find out. **Prior art to verify (not
settled): Mobile NixOS** runs NixOS on Android phones *through the Android boot
chain* — the exact pattern (verify Tensor G2/felix coverage). This repo started
on **postmarketOS** (Alpine mobile-Linux analog), so non-Android-userland-via-
Android-bootloader is already trodden here.

### RECOMMENDATION: decide by spike, not by argument

The decision is load-bearing + near-term; the experiment is days. **Spike: build a
minimal NixOS image, flash it to a felix A/B slot via the existing `flash.sh`
path, measure (a) does it boot, (b) closure size ×2 vs UFS.** Converts the two
deciding unknowns into evidence *before* September's architecture is committed. If
it boots and fits, the flake.lock property is yours and the remaining objections
are mitigations, not blockers.

**Current assessment (revised):** operator's flake.lock instinct is well-founded;
§–4's case against Nix is weaker than it appeared once "ship as opaque image, let
the bootloader own slots" is seen as a *clean fit* rather than a compromise. Lean
shifting **toward Nix**, gated on the spike. **Awaiting operator go/no-go on the
spike.**

### Two operator corrections that further strengthen Nix (2026-06-03)

**Correction A — ssh-able, NOT tiny appliance (even in September).** §–4's
"no-SSH / cattle / Talos appliance / capability-absent" posture is **relaxed for
September**: images **should be ssh-able and debuggable.** Consequence: the one
objection that survived prior analysis — **closure weight ×2 slots on UFS** —
loses most of its force. That objection's weight came entirely from "tiny
appliance" being the target; a big Nix closure only looks bad *next to a minimal
appliance image*. If the image is a comfortable debuggable system anyway, "Nix
closure > minimal appliance" is not a penalty — there was no minimal appliance.
Closure just needs to **fit ×2 in UFS** (measurable yes/no), not "stay tiny."
Also collapses the §1.7 interactivity tension for September: human sshs in ⇒
rich; the stripped/capability-absent appliance question moves to a later
real-fleet horizon. (Spike objective (b) becomes "fits ×2", not "is it small".)

**Correction B — requirement is "STATE CAPTURED IN THE GIT REPO", NOT byte-repro.
This adjudicates the A-vs-B question and it favors Nix decisively.**

The earlier A-vs-B framing: **A** = provenance (verify/enumerate a built image's
contents after the fact; repro-env reaches this). **B** = byte-reproducible pure
build (Nix-only). Operator has now stated the requirement precisely, and it is
**neither A nor B — it is CLOSURE/COMPLETENESS of the committed definition:**

> *Byte reproduction is not a requirement. State captured in the git repo is.*

i.e. **the repo must be the total, sufficient, closed definition of the image** —
`commit → everything that determines the image`, nothing living only on a build
server, a maintainer's machine, or "whatever the archive served that day." This
is *stronger than A* (A is post-hoc verifiability of an artifact; this is
completeness-of-source) and *not B* (no identical bytes required).

**This IS the defining property of a flake, definitionally.** A flake = "repo +
lock = a complete, closed description of the system"; the sandbox *enforces* that
nothing else enters. So the operator has independently re-derived exactly what a
flake *is*.

**Why Debian loses on THIS — and note it's NOT about byte-repro:**
- `repro-env` locks the **package set** only. But an *image* is also defined by
  the mkosi/debos recipe + maintainer-script behavior + overlay files + build
  flags + base image + host-tool versions. In the Debian world that definition is
  **scattered across stitched-together tools, and some of it (dpkg script
  behavior, host toolchain) isn't committed at all.** The repo is a *recipe that
  references external state*, NOT a closed definition.
- A flake **is** the closed definition by construction: `commit + flake.lock` is
  *provably* the total input set.

⇒ The operator's requirement ("repo = complete definition") is the property Nix
gives **natively** and Debian gives only **partially and by assembly** — and
critically this conclusion does **not** depend on byte-repro (which remains a
non-requirement). This is a *better* argument for Nix than the one previously
under debate. **Assessment hardens: toward Nix.** The spike (does it boot on
felix + fit ×2 UFS) remains the one empirical gate.

### The pain comparison: Nix store cost vs repro-env maintenance cost

The honest decision needs **both** ongoing pains weighed, not just Nix's. I've
been under-weighting repro-env's. Side by side:

**Pain the Nix store brings (cost of choosing Nix):**

- **Closure size on UFS.** The Nix store ships the *full transitive closure* —
  every lib, every build-time-ish dep that ends up runtime-referenced, no shared
  system libs, often multiple versions coexisting. A debuggable NixOS closure is
  plausibly ~1.5–3 GiB. *Reality check against this repo:* the rootfs flashes to
  the **`super` partition (~8.1 GiB)**; the kernel+initramfs go to the small
  `boot`/`vendor_boot` slots separately. So "×2 slots" for the *rootfs* is really
  "does the closure fit in super," and super is roomy — **this fear is smaller
  than the generic "×2 on constrained flash" scare.** *Measure in the spike;
  don't assume.* (UFS endurance over many A/B *writes* is a separate, real
  long-term concern — bigger images = more bytes written per update.)
- **The store model itself.** `/nix/store` + symlink farm + profiles is a
  foreign filesystem shape. Even "as opaque image" you carry the store; tooling,
  paths, and debugging-by-ssh all look non-standard to someone expecting FHS.
- **Skill floor / debuggability under fire.** When a node misbehaves at 2am, the
  on-call person debugs a NixOS system (store paths, `nixos-rebuild`-isms) — and
  team overlap with the Nix-fluent fleet folks is **partial** (operator). This is
  the genuine, recurring Nix tax and it does not go away.
- **Foreign builds are still hand-pinned.** Kernel (AOSP Bazel / mainline kbuild
  via `repo`) and vendor firmware are not nixpkgs; you wrap them in fixed-output
  derivations with manually-declared hashes — *the same hand-pinning repro-env
  would need.* Nix gives no free lock for the hardest, most security-critical
  components. (Neutral, but it caps Nix's "totality" upside.)

**Pain repro-env brings (cost of staying Debian) — previously under-weighted:**

- **It's integration you own forever.** flake.lock is the ecosystem default,
  regenerated by one `nix flake update`, maintained by nixpkgs. repro-env is a
  *tool you bolt on*: you wire it into mkosi/debos, keep the lock regeneration in
  CI, and own every breakage when Debian/the tool/the archive shifts. **Recurring
  human maintenance, on you, indefinitely.**
- **It locks packages, not the IMAGE.** This is the load-bearing gap (per
  Correction B): repro-env covers the apt set, but the image is *also* defined by
  the mkosi recipe + maintainer-script behavior + overlays + build flags + base
  digest + host toolchain. **Closing the rest of that gap to reach "repo = complete
  definition" is bespoke work you design and maintain** — and parts (dpkg script
  nondeterminism, host-tool drift) you may *never* fully close. So the maintenance
  pain doesn't even *buy* you the closure property; it only approximates it.
- **Bus factor cuts BOTH ways.** Nix's skill floor is a real tax — but a
  hand-assembled "mkosi + repro-env + overlay + custom lock-glue" pipeline is
  *also* a bespoke stack only its author fully understands, with **worse** prior
  art than NixOS (which at least has Mobile NixOS + krg-infra + a large
  community). The Debian path is not the "low bus-factor" option by default; it
  may be *higher* because it's homegrown.
- **It's younger / thinner.** repro-env (kpcyrd) is recent and niche vs flake.lock's
  ecosystem-baseline maturity. You're betting on a smaller tool.

**Net of the comparison:** the Nix pains are **real but mostly one-time or
measurable** (closure size → spike; store-model unfamiliarity → fixed cost; skill
floor → mitigated by krg-infra prior art + partial overlap). The repro-env pains
are **recurring, owned-by-you, and don't fully deliver the very property you
require** (closure). The one Nix pain that genuinely *persists* is the
**debuggability/skill-floor tax at partial team overlap** — that is the strongest
honest argument for staying Debian, and it's an *operations/people* argument, not
a technical-property one. Everything technical-property-wise favors Nix.

> **So the real trade is: Nix's recurring cost = "people must know Nix" vs
> Debian's recurring cost = "we forever maintain a bespoke lock pipeline that
> still doesn't fully give us closure."** Framed that way, Nix's recurring cost at
> least *buys* the property; Debian's recurring cost buys an approximation. The
> decision turns on whether the team-skill tax is payable — which the spike does
> NOT answer (it's a people question, not a boot question). **Flag for operator:
> the spike settles feasibility + size; the skill-floor/bus-factor tax is the
> residual judgment call only you can make.**

### §–5 CONCLUSION (current state of the Nix-vs-Debian decision)

**Per-product, the answer splits cleanly — and that split is the resolution:**

| | Product A (fleet, thousands by Sept) | Product B (demo / hobby robot) |
|---|---|---|
| Closure / "repo=complete def" req | **Required** (§ Correction B) | **Not required** |
| Audience | fleet operators (partial Nix overlap) | students/hobbyists (no Nix) |
| Mutability | immutable image, ssh for debug | mutable/hackable BY DESIGN |
| **OS/build lean** | **Nix** (pending spike) | **Debian/Ubuntu — DECIDED** |

- **Product A → Nix**, because the operator's true requirement is **closure**
  ("state captured in the git repo," not byte-repro), which is *definitionally*
  what a flake is and which Debian+repro-env only approximates while costing
  recurring bespoke maintenance. Technical-property-wise Nix wins; the **only**
  surviving counter is the **skill-floor/bus-factor tax at partial team overlap**
  — a people question. **Gated on a spike** (does NixOS-as-opaque-image boot on
  felix through the Pixel bootloader + fit in `super`) which settles feasibility/
  size but NOT the people question.
- **Product B → Debian/Ubuntu, decided.** It lacks the closure requirement
  entirely, and its **education/hobby/Pi-like target makes Debian/Ubuntu
  positively correct** (familiar apt/Python/ROS ecosystem; Raspberry Pi OS *is*
  Debian) while Nix would be *maximally* wrong for that audience (highest-turnover,
  least-Nix-fluent, wants to hack the thing). See §–1 Product B resolution.
- **Both ride the same bring-up substrate** (kernel/dtbo/firmware/boot); they
  diverge only above it — A on a Nix build, B on the rich-Debian dev-platform
  image. This is the §–2 platform-vs-product seam, now expressed in the OS/build
  choice itself.

**Status:** Product B settled (Debian/Ubuntu). Product A leaning Nix, **two gates
remain**: (1) the **spike** (technical feasibility + closure size on felix),
(2) the operator's **judgment on the team-skill tax** (not answerable by spike).

---

### What §–4 means for THIS repo's near-term

Mostly *confirms* the plan and sharpens two near-term items:
- **Identity stamp** = `(commit, lock)`, not just commit. The Phase-1 deliverable
  should anticipate a **committed package lock** (repro-env) as part of identity —
  even if we don't adopt repro-env yet, design the identity string to carry it.
- **"Harden determinism now"** retargets to **"adopt/move toward a package
  lock,"** not "make the build bit-reproducible." Cheaper and correct.
- **One gating hardware unknown lands partly here:** Titan M2 reachability off
  Android (#11) needs *real-hardware verification on our OS image* — and we have
  the hardware + bring-up expertise. This is a place the dev/bring-up platform
  (this repo) directly de-risks the fleet (verify Keymaster/StrongBox path on the
  felix Debian image). Candidate concrete bring-up task.

---

## –6. The incumbent image, feature-equivalence, and the NDA Mali blob

Late but decisive context (operator, 2026-06-03). Three facts, each adjusted by
the operator's clarifying answers:

### Fact 1 — there is an incumbent image to replace; parity-before-switch
A pre-existing image (function similar to this repo's output) is being replaced.
**Feature-equivalence with it is a hard gate before switching.** Implication for
§–5: do NOT change the build model and port features simultaneously — that
compounds risk. **Reach parity on the known-good (Debian) path first; Nix is a
follow-on, not a prerequisite.** This is *sequencing*, not a reversal of §–5.

### Fact 2 — the REAL near-term blocker: apples-to-apples experiments (~1 month)
Operator: *"I have a bunch of experiments that need to remain apples-to-apples for
the next month. Nix maybe after."* This is **stronger than schedule risk** —
changing the build model mid-experiment-series **breaks experimental
comparability** (a methodological invalidation, not just a deadline). ⇒ **Nix is
strictly AFTER the experiment window**, not "risky for September." Hard constraint:
the build model stays fixed (current Debian path) for ~the next month so
experiments stay comparable. The §–5 spike and any Nix move are **gated behind
the experiment window**, not behind September per se.

### Fact 3 — Mali userland driver under NDA (de-risked by clarifications)
The incumbent (and our parity target) includes a **Mali userspace GPU driver
under NDA**. Initial worry: an uncommittable blob would break "repo = complete
definition" (the §–5 closure argument). **Resolved by operator answers — the
worry does NOT materialize:**
- **Blob CAN live in a *private* repo** ⇒ **closure is PRESERVED.** It's a
  *permissions* boundary, not a "not in git" boundary. The §–5 Nix thesis is
  **unharmed** — the consuming (internal) party just needs repo access. (Standard
  in both worlds: Nix fixed-output derivation / Debian committed blob, from a
  private source.) So the NDA does **not** weaken the closure case.
- **Internal-use-only is fine** ⇒ **no fleet/Product-A redistribution problem.**
  Shipping images across the internal fleet is covered.
- **The one carve-out — Product B:** an external handoff (hobby/education image,
  Google demo) carrying the Mali blob would hit the internal-use boundary. So
  **Product B images for external parties must either exclude the NDA Mali driver
  or clear redistribution separately.** B-specific; not a main-line blocker.
  (Cross-ref §–1 Product B; B is Debian/Ubuntu anyway.)
- **Like kernel/firmware, the Mali blob is foreign to the package manager** —
  hand-pinned in either OS (caps Nix's totality upside identically; §–5 already
  noted this for kernel/firmware).

### Fact 4 — medium-term plan: port mainline Mali → drop the NDA (UNIFIES the timeline)
Operator: *"My medium-term goal is to port Mali from mainline into Android and
ditch the NDA. By the time we are ready for Nix, the NDA should be gone."*

This is the keystone that makes the gates **cohere into one ordered timeline**
rather than independent deferrals. The NDA-retirement and the Nix-migration are
**causally linked and retire in the right order:**

- **Plan (clarified):** port the **full mainline GPU stack** — the mainline
  **kernel DRM driver** AND **upstream Mesa** userspace — into the Android-kernel
  image → reach feature-equivalence with the NDA blob → drop the proprietary
  driver. NOT bridging open userspace onto the vendor kernel driver; both halves
  come from mainline, so the uABI matches by construction. By Nix-time, no NDA.
  - **Driver pair (verify):** Tensor G2 GPU is **Mali-G710** (Valhall, CSF) ⇒ the
    mainline path is **Panthor** (kernel DRM) + **Panthor Mesa** (userspace), NOT
    Panfrost (older Midgard/Bifrost). The backup's `junkyard-mesa` project is
    consistent with the Mesa-userspace side. Confirm G710→Panthor before relying.
- **It restores closure to its PURE form (strengthens §–5 at exactly the right
  moment).** §–6 accepted the NDA as survivable because a private-repo blob keeps
  closure "behind an access wall." Once Mali is open mainline, that asterisk is
  **gone** — the repo is the complete definition with *nothing* NDA-gated. So the
  closure argument that won Nix is **strongest precisely when Nix is adopted**;
  you carry zero NDA baggage into the Nix world. The ordering is optimal, not just
  convenient.
- **It removes the Product B carve-out** (Fact 3): an open Mali driver
  redistributes freely ⇒ external hobby/education/Google-demo images become
  unencumbered. Both products benefit from the same port.
- **Same effort as the mainline track**, not a new workstream: open Mali
  (Panfrost/Panthor) is part of the **mainline gs201** push (§–4 mainline
  contradiction). "Mainline is the goal" and "ditch the NDA" are the *same effort*
  — GPU userspace is one thing mainline buys.
- **⚠️ Risk RESHAPED (not eliminated) by the full-stack plan:** bringing the whole
  mainline stack removes the uABI-mismatch hazard (both halves are mainline). The
  real work becomes **porting the mainline Panthor *kernel* DRM driver onto the
  Android gs201 kernel** — i.e. **GPU SoC bring-up**: clocks, power domains,
  SMMU/IOMMU wiring, and the **CSF firmware** the G710 needs. That is the hard
  part, and it **couples this even more tightly to the mainline gs201 track**
  (same clock/power/IOMMU bring-up already in flight on the mainline port). The
  Mesa userspace side (`junkyard-mesa`) is comparatively well-trodden upstream.
  Net determinant of "by Nix-time = months or longer" is the **kernel-side GPU
  SoC integration**, not the userspace.

### Net effect on the §–5 decision — the unified timeline
- **Conclusion unchanged; now a coherent ORDERED sequence** (not scattered gates):
  1. **Now → ~1 month:** current Debian path **fixed** (experiment comparability,
     Fact 2). Land path-agnostic Phase-1 identity (commit + lock) — safe on either
     path, doesn't disturb experiments.
  2. **Parity on Debian** with the incumbent (Fact 1), including the NDA Mali blob
     (private repo; closure-behind-access-wall acceptable interim).
  3. **Port mainline Mali → drop NDA** (Fact 4), coupled to the mainline gs201
     track. Retires the NDA asterisk.
  4. **Then:** Nix spike (§–5) + adopt for Product A — now with *pure* closure, no
     NDA baggage.
- **Product B:** Debian/Ubuntu throughout; external images unencumbered *after*
  step 3 (before that, exclude the NDA blob from external handoffs).
- **The one thing safe to build NOW:** Phase-1 `(commit, lock)` identity on the
  current path — path-agnostic, experiment-safe, and the original concrete pain.

---

## –2. What is this repo for? (charter)

The operator listed four candidate goals and asked whether the repo should be
all / some / none of them:

1. Bring up the **cluster**
2. Bring up the **robot**
3. Be a **test platform for userland development**
4. Be a **test platform for kernel development**

### The lens: two axes — these are not the same *kind* of thing

- **Substrate ↔ Product:** shared foundation, or specific deliverable?
- **Develop ↔ Operate:** harness for *changing* things, or stable artifact you
  *ship and run*?

| Goal | Substrate/Product | Develop/Operate |
|---|---|---|
| 4. Kernel dev | **Substrate** | **Develop** |
| 3. Userland dev | **Substrate** | **Develop** |
| 1. Cluster | Product | *bring-up* = Develop; *run 20k* = Operate |
| 2. Robot | Product (demo) | Develop only (never Operates) |

### The load-bearing principle

**Platforms and products have opposite virtues.** A dev platform wants
mutability, fast iteration, hackability ("ssh in and change it"). A product —
*especially the fleet* — wants reproducibility, immutability, determinism ("you
**cannot** change it"). These fight. A repo that is both a hackable dev platform
and a production fleet-image builder serves neither.

> This is not hypothetical: it already surfaced this session as **F1 (mutable, to
> experiment) vs F3/F5 (reproducible/immutable, for the fleet)**. That tension is
> the *seam* between these goals showing through.

### Verdict: SOME — the repo is the bring-up + development substrate

This repo **owns goals 3 and 4** as its core charter, **enables 1 and 2**, and
should **not grow into *operating*** them. The line is **develop/bring-up vs
operate/ship**:

- **Goal 4 — core.** Kernel bring-up + iteration. Irreplaceably here.
- **Goal 3 — core**, sharply scoped: platform for developing userland *against
  the substrate* — NOT where each product's final userland is productized.
- **Goal 1 — SPLIT.** "Bring up cluster *nodes*" (boot, join Karmada, run
  kubelet/Garage) = a target you **develop toward here**. "Operate 20k with
  reproducible/immutable images + distribution" = the **downstream fleet
  pipeline** (§3c Option B, a separate artifact) — **not here.**
- **Goal 2 — yes, thin.** A demo assembled from the substrate (§–1), ~zero cost.
  A *demonstrated capability*, not a maintained product.

### Why this is tractable: it's time-dependent

- **Now (bring-up, single device):** all four cohere in ONE repo — they reduce to
  "make felix do X" and share ~90% (the substrate). Splitting now = premature
  decomposition.
- **The split is FORCED at Product A Phase 2** (fleet productization), when
  immutability/reproducibility break away from the mutable dev platform.

**Operating principle:** build as **one repo now — the dev/bring-up platform,
charter = goals 3+4, serving 1+2** — but keep the fleet *production* pipeline
factored out from day one so the eventual split is clean, not surgical. Concretely
that means: don't weld fleet-*operate* machinery (reproducible image production,
distribution, immutability enforcement, signing) into this repo; let it consume
this repo's outputs instead.

### Consequence for the near-term identity work

Unchanged, and now better-justified: a **dev/bring-up platform is mutable by
nature**, so "honest, content-derived identity on a mutable image" (Phase 1) is
this repo's *permanent* condition, not a temporary one. It's charter-aligned, not
a stopgap.

---

## –1. Two products, one platform (the latest reframe)

The operator surfaced a second product that may reshape priorities:

**PRIORITY (operator):** **A is the primary path.** **B is a *demo* shown to
Google** as another way to repurpose devices — a strategic proof point, **not a
near-term development track.** B must therefore cost ~nothing beyond what A
already produces; it must not pull near-term engineering. Its job is to *argue*
the platform thesis (one bring-up substrate → many products), which conveniently
is the §3c-Option-B argument. Keep B in view as narrative + a thin demo, design
for A.

**Product A — Fleet node.** 2k→20k phones as Karmada-managed k8s/Garage cluster
nodes. (Detailed in §0 onward.) Headless, stateless, immutable-at-scale.

**Product B — Educational/hobby robot brain (DEMO ONLY).** Repurpose discarded phones as a
"phone → Raspberry Pi" path for the education/maker market. A Pixel Fold is not a
*worse* Pi — it's a Pi **plus** integrated battery + PMIC, foldable screen (robot
face/UI), multiple cameras (CV), full IMU, mic/speaker, wifi/BT, and a Tensor TPU
for on-device ML. The missing piece vs. a Pi is **GPIO**, filled by a USB GPIO
module (e.g. Numato 8-channel USB GPIO). Sustainability/e-waste story is a bonus
for the education market.

### Why this matters to *this* doc

It clarifies **what the shared substrate is** — and therefore what this repo's
durable value is (the §3c question, now much sharper):

- **Common to A and B:** the felix **bring-up** — AOSP kernel build, dtbo
  partition handling, vendor firmware, A/B slot/boot infra, a bootable
  Debian/Linux userspace on the hardware. *This* is the platform.
- **Divergent:** everything above the substrate.
  - A: headless, immutable, reproducible, fleet-managed, **USB device/gadget**
    leanings irrelevant (it's a server).
  - B: interactive (screen + sensors + actuators), **USB host mode** (to drive
    the GPIO dongle + hub), mutable/hackable by design, single-device, possibly
    **Ubuntu-based** (operator floated this — education familiarity, ROS/maker
    ecosystem) rather than minimal Debian.

So the platform is a **base image + bring-up**, and A and B are **two
divergent userspace targets** built on it. This strongly favors §3c **Option B**
(this repo = bring-up/platform substrate; products are built *on* it) over
Option A (this repo grows into one product's builder).

### New technical fork Product B introduces (USB direction)

- B needs **USB host mode** (Numato module + hub are USB peripherals) — the
  *opposite* of the gadget/`ttyGS0` work in the mainline-track notes.
- Implication: the **AOSP-kernel track (`main`)** is likely the better base for B
  — stock Android kernel has mature OTG/host support (the AOSP ref device already
  does USB-host networking), whereas mainline USB host on gs201 is unproven.
- The **dongle-PD hazard** (direct USB-C peripheral attach crashes pre-BL2; notes
  say use a powered hub) means B's reference hardware is **phone + powered USB-C
  hub + GPIO module** anyway — which also solves "single port" (power + GPIO +
  more simultaneously).
- **RESOLVED (operator, 2026-06-03): Product B → Debian/Ubuntu, NOT Nix.** The
  closure/"repo = complete definition" requirement that drives **Product A toward
  Nix** (§–5) is **the requirement Product B does not have.** B is a single
  demo/hobby device, not a fleet — there is no provenance-at-scale, no
  re-platform-thousands logistics, no fleet inventory pressure. And the
  **education / hobby / "Raspberry-Pi-like" target makes Debian/Ubuntu positively
  CORRECT**, not merely acceptable:
  - The whole value to that audience is the **familiar, hackable, apt-get/Python/
    ROS ecosystem.** A Pi-replacement that hands a hobbyist `/nix/store` and
    `nixos-rebuild` defeats the "approachable, like a Pi" pitch. Debian/Ubuntu
    *is* the lingua franca of the maker/education world (Raspberry Pi OS is
    Debian; most robotics tutorials assume apt).
  - The Nix skill-floor tax (§–5) is **maximally bad** for this audience —
    students/hobbyists, highest-turnover, least-Nix-fluent population imaginable.
  - B is mutable/hackable by design (a hobbyist *should* ssh in and `apt install`
    things), so the immutability/closure machinery is not just unneeded but
    *actively hostile* to the use case.
  ⇒ **The Nix-vs-Debian split falls cleanly along the product line:** Product A
  (fleet, closure-required) → Nix (pending §–5 spike); Product B (demo/hobby,
  rich+familiar) → **Debian/Ubuntu, decided.** This is the §–2 platform-vs-product
  seam expressing itself one more time, now in the build-model/OS choice.
- **Build-machinery sharing:** B shares the **bring-up substrate** (kernel/dtbo/
  firmware/boot — same for everyone) but **NOT** Product A's Nix build/identity
  machinery. B uses the rich-Debian path (which is also today's dev-platform
  path, §1.7), so B costs ~nothing extra: it *is* essentially the dev-platform
  image with a robot demo on top.

### Does this change the near-term work?

**No.** B is demo-only; **A drives all near-term engineering.** B's role is
strategic narrative for the Google demo, and as *evidence* for §3c Option B (the
repo's value is the shared bring-up substrate). Constraints that follow:

- **Do not build B-specific machinery now.** No USB-host bring-up, no Ubuntu
  variant, no GPIO integration as engineering tasks — only as a thin demo if/when
  the Google demo is scheduled.
- **The platform/substrate framing is the takeaway, kept.** Design the
  bring-up + base image so that *a* divergent userspace (B) is plausible later,
  but spend zero now making it real.
- **B is the cheapest possible proof** that bring-up is the asset (§3c). That's
  its entire value to this doc.

Near-term work therefore remains exactly Phase 1 for Product A (§0.5): honest,
content-derived identity on the current mutable experimental image.

---

## 0. Resolved context (was §2 — now load-bearing for everything)

Confirmed by the operator:

- **Scale:** 2,000 phones now → **20,000** target.
- **Roles:** each phone is **Kubernetes compute** *or* **storage** (leaning
  **Garage**). **One role at a time** (role is reassignable, not fixed-per-device).
- **Orchestration:** **Karmada**, **many clusters** (multi-cluster federation).
- **Images are immutable.** Updating = **deploying a new image**, never mutating
  in place.
- **Phones are stateless**, except Garage storage nodes (which hold object data).

### What this FORCES — and the timeline each lands on

These follow from the context, but they are **not all near-term**. The operator
has set an explicit sequencing: **experiment before scale.** Some forced
constraints are *eventual targets* deliberately relaxed during the experimental
phase. Marked **[TARGET]** (eventual, relaxed now) vs **[NOW]** (binding today).

- **F1 [TARGET].** On-device rootfs **read-only / immutable**. **Relaxed for
  now** — mutations are *necessary* during experimentation. We keep mutating the
  image until other experiments conclude, then enforce immutability.
- **F2 [NOW, agreed].** Update is **whole-image replacement** with **atomic
  activation + rollback**. The A/B slot work already done is *foundational
  infrastructure*, not a papercut fix.
- **F3 [TARGET].** Builds must be **reproducible** — "same inputs → same image,"
  verifiably. *Eventual*: can't be built until the replacement build model (§2a)
  is chosen, which is unknown. Experimentation continues on the current
  (non-reproducible) build.
- **F4 [REVISED — see §1.6].** ~~Image identity is content-derived.~~
  **Superseded.** The operator's position is **identity = the git commit hash**;
  the manifest is *code*, not a stored artifact. Content-derivation was the
  *fallback you build when you can't trust the build to be deterministic* — and
  the operator refuses that fallback. F4 now reads: **identity is the source
  revision that (re)produces the image; a clean (non-dirty) commit is the
  identity, and the manifest is regenerable from it.** See §1.6 for the
  load-bearing precondition.
- **F5 [TARGET, agreed].** The **mutable-sysroot, sentinel-gated,
  debootstrap-in-place** build model is **disqualified as the fleet path**
  (non-reproducible by construction). *Eventual*: we keep using it to experiment
  until §2a picks a replacement. — The concrete "maybe not Debian" moment.

> **Orthogonality that makes the relaxation coherent:** F1 (a *runtime* property:
> image doesn't change on the device) and F3/F5 (a *build* property: same inputs
> → same image) are independent — you can have either without the other.
> Relaxing F1 doesn't logically touch F3/F5. But *operationally* F3/F5 are also
> deferred, because §2a (what replaces debootstrap-mutate) is unknown and you
> can't build the reproducible replacement before choosing it. Net: **F1/F3/F5
> are all the experimental phase's "later"; F2/F4 bind now.**

> Note F5 disqualifies the *build model*, **not** necessarily Debian userspace.
> Whether the userspace stays Debian at all is **OPEN** (§3a).

---

## 0.5 Phasing (the shape of "experiment before scale")

The operator's sequencing decomposes the work into phases. This is the single
most useful output of the fleet discussion: it tells us **what to build next**
is small, not the 20k pipeline.

- **Phase 0 — now.** Current mutable build, used for felix bring-up + role
  experiments. Identity is the broken thing that started this.
- **Phase 1 — experimental (NEXT DELIVERABLE).** A **cost-proportional, honest,
  content-derived identity** (F4) that **survives a mutable image** (F1 relaxed).
  This is exactly the original "stop the version string lying" — solved properly
  (truthful, interrogable) rather than band-aided, but *scoped to one
  experimental device/build*, not the fleet.
- **Phase 2 — scale.** Reproducible fleet build (F3/F5 → §2a), enforce
  immutability (F1), per-role images (§2d), distribution/rollout (§2c, *not this
  repo's problem yet*), signing (§2f, *hand-waved for now*).

**Implication:** §2c (distribution), §2f (trust/signing), and the reproducible
build are all **Phase 2** — explicitly deferred. Phase 1's bar is: make identity
truthful on a mutable image, cheaply.

## 1.5 The hard part of Phase 1: identity on a *mutable* image

Relaxing F1 makes the *near-term* identity problem **harder**, not easier, and
this is worth stating plainly:

- If the image were immutable, "what's in it" = "what the build produced" — a
  build-time fact.
- Because the image **is** mutable now, on-device contents can **drift from the
  build** (you ssh in, change something, experiment). So identity must answer
  about the **actual current bytes**, not the build's claim — which is precisely
  R1/R2 (truthfulness + interrogability from the artifact itself).
- This means Phase 1 cannot be "stamp a better string at build time." It must be
  "**derive identity from whatever is actually there, whenever asked**" — on the
  running (mutated) device and on a pulled image alike.

> So the F1 relaxation doesn't shrink the problem to a string fix — it *confirms*
> identity must describe *whatever is actually there, whenever asked*. NOTE: §1.6
> revises *how* — via source revision, not byte-manifest.

---

## 1.6 Identity = git hash (operator's model) — and its precondition

**Operator's position:** *Identity is a git hash, first and foremost. It points
back to a commit that can reproduce the exact image. Therefore a manifest is
CODE, not an artifact.*

This is the **Nix/OSTree-correct inversion** and it is better than the
content-derived manifest I was proposing:

- Content-from-bytes manifest = what you build when you've **given up** on the
  build being deterministic. Operator refuses to give up → the *source revision*
  IS the identity; the manifest is a pure *function of* the commit, regenerable
  on demand, never stored.

### It dissolves the original bug — and reverses the blame

Through this lens, the `ee66cc0-dirty` image was **not lying** — it truthfully
recorded "built from ee66cc0's dirty tree." The lie was *my expectation* that a
no-op rebuild should re-stamp `acb4613`. Worse: stamping `acb4613` would have
been the **actual** lie, because the hash promises "this commit reproduces these
bytes," and the bytes predated that commit. So the real rule is not "make the
stamp re-run" — it is **"never derive identity from a dirty tree."**

### THE PRECONDITION (load-bearing) — ⚠️ REFRAMED by §–4

> **§–4 correction:** this section originally said the precondition is a
> *pure/hermetic build* (bit-reproducibility). **Overstated.** §–4 establishes the
> required property is **verifiable PROVENANCE, not byte-reproducibility**:
> identity must let you *enumerate and verify* what's in the image and tie it to a
> commit — it need NOT rebuild bit-identically. The precondition is therefore
> **(commit + a committed, hash-bearing package lock)**, not hermeticity. Read the
> rest of this section with "hermetic/pure-function" softened to "provenance-
> complete (commit + lock)." The mechanism is `repro-env` (§–4 #2), not a from-
> scratch hermeticity project.

"A git hash describes the **exact** image" is provenance-complete **iff the commit
pins all inputs** — including the Debian archive, which a bare commit does NOT
(apt pulls current versions at build time). The missing piece is a **package
lock** committed alongside the recipe. (Bit-identical *rebuild* is a stronger
property we explicitly do NOT require.)

**How much holds today (CORRECTED after inspecting the repo — earlier draft
overstated the gap):** the *inputs* are already substantially pinned —
- Debian archive **pinned** to a snapshot.debian.org timestamp
  (`rootfs/debian_snapshot`, e.g. `20260529T144010Z`) — not a live mirror.
- kmscon **pinned** by URL + SHA256 (`rootfs/kmscon.env`, verified at build).
- Kernel source **pinned** by `kernel/kernel-manifest.xml` (per-project SHAs).

So input-addressing is *most of the way there*. What remains unpinned/nondeter-
ministic is the **output/process side**, not the inputs:
- **Timestamps** baked into the image (`BUILD_DATE`, mtimes across the rootfs).
- **In-place sysroot mutation** as root (debootstrap second-stage + nspawn
  scriptlets) — apt/dpkg ordering, generated files, caches can vary run-to-run.
- **Host-toolchain drift** for the non-pinned host tools.

Net: the git hash is **close to** input-addressing a deterministic function, but
not yet — a clean hash could still yield byte-different images across runs
(mainly via timestamps + apt/dpkg nondeterminism), even though the *inputs* match.
The remaining gap is narrower and more tractable than a from-scratch hermeticity
project.

> **Therefore (REFRAMED by §–4): "identity = git hash" and "provenance-complete
> build" are the same project** — NOT "identity = git hash" and "bit-reproducible
> build." Adopting the identity model is a commitment to a **committed package
> lock** (repro-env), not to hermeticity. Until the lock exists, the commit
> describes the *recipe* but not the *resolved archive*, so identity is a
> **promise**, not yet a **guarantee**; `-dirty` is the visible promise-breaker,
> the **missing lock** the invisible one. (Input-pinning already done — snapshot
> timestamp, kmscon SHA, kernel manifest — is *most* of the lock already; §–4's
> repro-env makes it self-validating in-repo instead of snapshot-timestamp-trust.)

### Two clean consequences

1. **`-dirty` = no identity (cardinal sin, not cosmetic).** A dirty hash points
   to no checkout-able commit, so a **dirty image is a throwaway by definition.**
   This *enforces* "commit before you build a real image" as a rule, not a habit.
   (The dirty suffix that annoyed us was the system correctly saying "not a real
   build.")

2. **The hash answers PROVENANCE, not CONTENT — and that bound is right for a dev
   platform.** A git hash says "what I was built from," not "what I am now." On a
   mutable dev platform, an ssh'd-into / mutated device still reports its build
   hash, which no longer matches its bytes. The operator's model answers this
   correctly: **mutate-without-committing ⇒ you are dirty ⇒ you have no identity;
   commit to earn one.** For a *dev platform* (mutable by nature), "want identity?
   commit." is exactly right. (This bound would be UNacceptable for fleet
   *verification* — detecting a node that drifted from its claimed image — but
   that is Product-A-Operate, the separate pipeline, NOT this repo. §–2.)

### 1.6.1 Identity needs TWO fields: exact (hash) AND ordered (version)

**Operator:** *an honest human-readable version is also important — I need to
look at two phones and see "this one is older than that one." The commit hash
doesn't buy me that.*

Correct, and structural: a git hash gives **identity + provenance** but **no
order.** `acb4613` vs `ee66cc0` reveals nothing about sequence by eye; divergent
branches may have no linear order at all. "Older/newer at a glance" needs a
**monotonic, human-legible** field the hash cannot be. These are complementary,
not rival, models:

| Field | Question | Property |
|---|---|---|
| **Version** | newer/older? which release? | **ordered, human** |
| **Commit hash** | what exactly / what reproduces it? | **unique, exact** |
| **dirty** | is it a real build at all? | **honest** |

Canonical form = what the repo already has the shape of: `1.0.0-gacb4613` =
`<ordered human version>-g<exact hash>`. Operator's instinct and existing
convention already agree.

**The sharp sub-question — where does the ordered field come from?** It must be
**monotonic** (only increases) for the glance test to be *true*:

- **Hand-bumped semver (`version.txt`, today):** monotonic ONLY at release
  boundaries. Every dev build between 1.0.0 and 1.1.0 stamps the *same*
  `1.0.0-g<hash>` → two experimental phones built a week apart are
  indistinguishable by version. **This is the gap the operator's point exposes**
  — and it bites *exactly* on the mutable dev platform (the common case here).
- **`git describe` (`1.0.0-14-gacb4613`):** adds commits-since-tag → monotonic
  along a linear branch, human-legible, **free from git.** Restores the glance
  test for dev builds.
- **Date component (`2026.06.03`, or committer-date):** always monotonic by
  wall-clock; best pure "older/newer," looser tie to "which release."

⇒ **New requirement R-ORDER** (added to §4): identity MUST carry a monotonic,
human-readable version distinct from the hash; the hand-bumped semver alone is
insufficient for dev images. **OPEN:** which monotonic source (git-describe /
date / both).

> **Determinism timing — operator chose "start hardening broadly now"** (over my
> "cheap-now/expensive-later"). So nondeterminism closure (timestamps AND the
> harder apt/dpkg ordering) begins now, ahead of the build-model decision —
> EXCEPT this is gated by the §1.7 question below: hardening *Debian's*
> debootstrap-mutate may be wasted effort if Debian isn't the tool. Resolve §1.7
> first.

## 1.7 The real axis is INTERACTIVITY, not Debian (governing frame)

Operator's reframe — sharper than "Debian or not," which was premature. The
honest question is **does a human ssh into this?** That single bit drives
everything; "fleet vs dev" was only a *proxy* for it.

> **DECISION RULE:** human sshs in → **rich** userland (frustration-free; apt /
> Python / tools on hand). No human → **minimal + hardened** (small attack
> surface). Reason from the bit, not the product label.

**Two operator observations that resolve the near term:**

1. **Only the fleet wants minimal — and we are NOT at fleet scale yet.** So today,
   on *every* path that currently exists (bring-up, dev platform, robot demo), a
   human sshs in ⇒ **today's answer is uniformly "rich."** Debian is fine — not
   because we vetted Debian, but because the bit says "rich" and Debian is a fine
   rich userland. *That's why "is Debian right" is premature: the question above
   it ("interactive?") already answers "rich, for now."*
2. **The userland WILL change significantly at the fleet transition.** The
   minimal/hardened userland is **a different userland adopted when the bit flips
   to "no,"** NOT something we reach by hardening what we have. ⇒ the current
   Debian rootfs is **explicitly disposable.** You don't harden what you've
   already decided to replace.

### Consequence — substrate vs userland

| Layer | Survives the interactivity flip? | Posture now |
|---|---|---|
| **Substrate** (kernel/dtbo/firmware/boot) | **Yes** — fleet host still needs felix to boot | **Harden now** (determinism + security). Never wasted. |
| **Userland base** (Debian rootfs + build) | **Yes — REVISED, see §1.8** | base is durable; *rich extras* are the disposable part |

The determinism-hardening + attack-surface posture still fall primarily on the
**substrate.** But the userland is **NOT wholesale disposable** — see §1.8;
operator corrected this.

## 1.8 Profiles: minimal = stripped Debian, not a different OS (operator)

**Operator:** *"Is Debian right" IS a here-and-now question. The hardened OS is
probably a STRIPPED-DOWN version of the current Debian — that's likely EASIER. We
probably build rootfs images from "profiles."*

This **reverses §1.7's "userland is disposable / minimal is a different
userland."** Corrected position:

- **Subtraction beats green-field.** We've already solved the hard problem — a
  rich Debian boots on felix. Minimal = *removing* packages/config from a
  known-good base (low-risk) vs. bringing up a fresh Talos/Flatcar on felix
  (re-fighting bring-up from zero). So the hardened userland is the **same Debian
  base, stripped**, not a replacement.
- **Profiles = the right abstraction**, and it UNIFIES three axes we'd treated
  separately:
  - **Interactivity** (rich/ssh ↔ minimal/headless) — today's driver (§1.7)
  - **Role** (compute ↔ storage) — the earlier "per-role image" (§2d) is a
    profile dimension
  - **Hardening** (dev-open ↔ locked-down)
  ⇒ `profile = base + package-set + config overlay`. One build system,
  parameterized — not N separate OSes.

### The load-bearing distinction: WHAT vs HOW (keep separate)

> `image = profile (WHAT is in the rootfs) × build-model (HOW it's built)`

Profiles answer **what** (packages/config/role). They do **NOT** answer **how**
(mutable-debootstrap vs reproducible-immutable) — orthogonal, composes. A
stripped-Debian *minimal* profile built by today's debootstrap-mutate is still
**mutable + non-reproducible.** So profiles cleanly solve the
rich/minimal/role axis but DON'T grant F1/F3 — the build-model question
(F5/§2a) stays separate. The win: it's now **one base to make reproducible, with
profiles on top**, not a separate Talos pipeline. ("Is Debian right" answers:
**yes, as the shared base; profiles for variation.**)

### Honest caveat on "stripped Debian" as the hardened target

It lands at **"smaller + locked-down-ish"**, NOT **"Talos-minimal/immutable"**
(Debian still carries a shell, dpkg, glibc, FHS). For the current hand-waved
threat model (§2f) that 80/20 is very likely good enough; **true-minimal is a
later optimization only if the threat model demands it.** Don't over-promise
stripped-Debian == hardened-immutable; it's hardened-*enough*, reusing
everything.

### Consequence for "harden now"

- **Substrate determinism + security:** harden now (unchanged).
- **Userland base + profile machinery:** now WORTH building (it's durable, not
  disposable) — BUT its *reproducibility/immutability* (the HOW) still waits on
  the build-model decision (§2a). So: **build the profile structure now**
  (cheap, organizes rich-vs-minimal-vs-role); **defer making it
  reproducible/immutable** to the build-model work.

### (Earlier framing, kept for the workload reasoning)

### (Downstream) "Debian" is three separable choices

1. **Build method** (debootstrap + in-place mutation) — **already disqualified
   (F5)** for the fleet. Non-deterministic. Not defended long-term.
2. **Userspace / package ecosystem** (apt/.deb/glibc) — *the actual question.*
3. **Base filesystem** (FHS, /etc) — mostly downstream of #2.

The real question is #2, and it hinges on **what must run on the phones.**

### Reasoning from the stated goals → the workload splits

- **Product A (fleet):** node runs **kubelet + container runtime** OR **Garage**.
  Workloads live in **containers** (own userspace); the host just boots,
  networks, runs one binary. ⇒ wants the **thinnest possible host**, NOT full
  Debian. The Debian package universe is dead weight on a k8s node.
- **Product B (robot demo) + Goals 3/4 (dev platform):** want a **rich,
  familiar, hackable** userspace (Python/ROS/apt-get, ssh-in-and-debug). Debian
  or Ubuntu's ecosystem **is** the value here.

⇒ **The fleet wants minimal; dev/demo wants rich.** This is the **§–2
platform-vs-product seam again**, in a new place.

### Provisional answer (shape, not final)

- **Fleet node OS (Product A):** Debian probably **NOT** right. A k8s/Garage host
  wants minimal/immutable/reproducible — design space is **Talos / Flatcar /
  Nix-built minimal / buildroot-style**, purpose-built for container-host-only.
  None are debootstrap; most aren't Debian-userspace.
- **Dev platform + robot demo:** Debian/Ubuntu **fine, arguably right** — rich,
  hackable, familiar.
- **Maps onto the charter (§–2):** THIS repo = dev/bring-up platform ⇒ Debian
  fine *here*. The fleet pipeline is a separate artifact ⇒ free to pick
  Talos/Flatcar/Nix *there*, independent of this repo.

### Consequence for "harden now" (this is the payoff of pausing)

- **Harden the SUBSTRATE determinism now** (kernel / dtbo / vendor firmware /
  boot images): shared by A, B, and dev regardless of userspace. **Never
  wasted.**
- **Do NOT harden the Debian-rootfs determinism now** (apt/dpkg ordering, leaving
  debootstrap bit-reproducible): that polishes the F5 model the fleet won't use.
  If the fleet host becomes Talos/Flatcar/Nix, it's dead work. For the dev
  platform's purposes the current **pinned-input** build is already good enough.

⇒ **Determinism effort targets the substrate (always shared), not the Debian
userspace (maybe discarded).** The pause saved the expensive half of the
hardening from being misdirected.

**OPEN (Phase 2, don't resolve now):** the fleet host OS — Talos vs Flatcar vs
Nix-minimal vs minimal-Debian — is part of the §2a build-model decision. Noted,
deferred.

### What this resolves vs. leaves open (Phase 1)

- **Resolves §2b granularity / carrier:** moot for now. No stored content
  manifest. Identity = the commit; the on-image stamp = ordered version + commit
  hash + dirty-handle (below).
- **DIRTY HANDLE — RESOLVED: `<base-commit>-dirty-<diff-hash>`.** A dirty build
  stamps the base commit + a hash **of the uncommitted diff only** (not the whole
  tree). Rationale: keeps the commit as the spine and fingerprints just the
  delta, so two dirty experiments are distinguishable **without** re-introducing
  whole-tree content-identity (the thing the operator's model rejects). NOT a
  full tree content-hash.
- **Reproducibility is the foundation, not a nicety** (§3d/F3): the git hash is
  the identity claim's bedrock. Phase 1 deliverable: **(a)** stamp ordered
  version + commit hash (+ dirty handle); **(b)** dirty ⇒ `-dirty-<diffhash>`,
  never a clean identity; **(c)** honest about promise-vs-guarantee until the
  build is hardened — and per the decision below, **start hardening now.**

---

## 1. The real problem: a lifecycle, not a string

"What's in an image?" unpacks into questions asked at different **stages** by
different **actors**:

| Stage | Actor | Question |
|---|---|---|
| Build | build host / CI | what did I just produce, and is it reproducible? |
| Identify | build + registry | what is this image's canonical identity? |
| Distribute | update system | get *this* image to *those* N nodes |
| Activate | device bootloader (A/B) | swap atomically; roll back on failure |
| Verify | device at boot | am I running the image I was told to? intact? |
| Report | Karmada / control plane | which image + role is each node on; any drift? |
| Debug | you, at the bench | what's *actually* on this pulled device? |

The old `IMAGE_VERSION` string tried to answer all of these and could lie about
every one. The requirements below are organized by **what the lifecycle needs**,
not by "how do we fix the string."

---

## 2. The dominant axes (reframed for fleet) — OPEN questions

Identity (the original concern) is now **§2b**, one axis among several. The
genuinely hard, still-open forks:

### 2a. Build / production model — *the biggest open question* — **UNKNOWN (Phase 2)**
F5 disqualifies debootstrap-mutate. What replaces it? **Operator: unknown.**
Deferred to Phase 2 — we experiment on the current build until this is chosen.
(Candidates, to scope only: Nix-built image, OSTree/image-based, read-only
erofs/squashfs from a pinned input set, Bazel-built.) Requirement is F3 + F1;
mechanism open.
- **Does the Debian userspace survive?** (§3a) Still open; not forced by 2a.

### 2b. Identity — granularity & carrier
F4 forces content-derived. Still open:
- **Whole-image hash** vs **manifest of curated parts** (kernel / rootfs /
  felix-bits) — does the fleet ever need sub-part identity, or is one
  whole-image digest king?
- **What carries it into the control plane?** Karmada/k8s **node labels**?
  A report from a boot-time agent? Both?
- **Relationship to git/release tag:** is the human-facing release name (e.g.
  `1.0.0`) just an *annotation* on the content hash (per the "keep string +
  hard record beside it" decision)?

### 2c. Distribution — getting images to 20k nodes — **NOT THIS REPO'S PROBLEM YET (Phase 2)**
**Operator: "not this repo's problem yet."** Deferred. (Recorded for Phase 2:
pull vs push, transport over USB-Eth/wifi, staged/canary rollout, Karmada's
relationship to rollout.) Out of scope for the near-term identity work.

### 2d. Role model — compute vs storage — **RESOLVED: per-role image (reassign = reflash)**
**Operator: per-role image; reassignment is a reflash.** Settled. (So role is an
*image variant*, NOT runtime config.) Caveat: **don't design the role mechanism
yet** — operator wants to defer role specifics and would rather relax F1 than
tackle roles now. So: direction fixed (per-role images), details Phase 2.

### 2e. State — the stateless/stateful divide — **CONFIRMED**
**Operator: yes.** Compute = stateless cattle. Storage (Garage) = stateful;
object data must survive image updates. So for storage nodes "what's on the
device" = (image identity) + (mutable state identity), kept separate (R7).
*Where* the state lives and how it's decoupled = Phase 2 detail, but the
requirement (no conflation) stands.

### 2f. Trust / authenticity — **DEFERRED: hand-wave for now**
**Operator: for current testing, continue to hand-wave trust.** So Phase 1 is
**integrity/consistency only** (content hashing to catch drift/corruption), **no
signing / verified boot.** Re-open at Phase 2 / before real deployment.
- This sets a large cost fork (keys, signing infra, verified boot).

### 2g. Verification & drift reporting
- On boot, should a node **verify its own image** (hash matches expected; not
  corrupted in flash/transport) and **report** image+role to the control plane?
- How is **drift** ("node 7 isn't on the image Karmada thinks it is") detected
  and surfaced?

---

## 3. Still-genuinely-open foundational choices

- **3a. Userspace:** does Debian survive, or do compute/storage roles want a
  minimal purpose-built userspace (just kernel + kubelet/Garage + agent)?
- **3b. Unit of identity:** whole flashed artifact set vs rootfs vs manifest.
- **3c. This repo's role:** today it hand-builds ONE image for ONE phone. Is it
  the *seed* of the fleet image builder, or does it become a **bring-up/dev tool**
  while a separate, reproducible fleet-image pipeline is built? (My instinct:
  the fleet pipeline is a different artifact; this repo's value is the felix
  kernel/dtbo/firmware bring-up knowledge, not its rootfs build.)

---

## 4. First-cut requirements (construction-agnostic)

"The system shall…" — no mechanism implied. Ratify/cut after §2–3 resolve.

- **R1 (Truthfulness).** Reported identity MUST be derivable from actual
  contents, never asserted independently. (subsumes the original bug)
- **R2 (Interrogability).** "What is in this artifact" MUST be answerable from
  the artifact itself — at build, on-device, and from a pulled device — without
  trusting the builder.
- **R3 (Reproducibility).** Same inputs MUST produce the same image, verifiably
  (F3). Strength TBD (bit-for-bit vs content-equivalent).
- **R4 (Immutability & atomic update).** OS image read-only on device; updates
  are atomic whole-image swaps with rollback (F1/F2).
- **R5 (Fleet inventory).** MUST answer "are these N nodes the same image" and
  "which image is node X on," remotely, at 20k scale (F4).
- **R6 (Role-aware).** Identity/lifecycle MUST account for a node's role
  (compute/storage) and reassignment.
- **R7 (State separation).** Mutable state (Garage) MUST be decoupled from the
  immutable image and survive image updates; identity MUST not conflate them.
- **R8 (Provenance).** Where-from metadata (git rev, release, build host/time) as
  *annotation*, subordinate to content (R1).
- **R9 (Two registers).** Soft human-readable identity + hard machine-verifiable
  record; hard record authoritative.
- **R10 (Authenticity, tiered/conditional).** IF the threat model warrants (§2f),
  images are signed and verified before activation.
- **R11 (Cost proportionality).** Mechanism burden proportional to need — but the
  need is now "20k-node fleet," so the bar is real, not minimal.
- **R12 (Non-regression / migration).** Existing consumers (`/etc/os-release`,
  `/etc/image-version`, `\S{}` banner) migrated, not silently broken.

---

## 5. Still explicitly NOT assuming

- That the userspace stays **Debian** (F5 only kills the *build model*; §3a open).
- That "an **image**" is the unit of identity (§3b).
- That the answer lives in **`/etc/`** of a running system.
- That the fix is a **manifest tool** (parked candidate).
- That the **git rev** belongs in *authoritative* identity (annotation only).
- That **this repo** is the fleet builder vs a bring-up tool (§3c).
- That role is an **image variant** vs **runtime config** (§2d).
- That we **do** or **don't** need signing (§2f).

---

## 6. Status of the forks (after operator pass)

| Fork | Status |
|---|---|
| §2a build model | **UNKNOWN → Phase 2.** Experiment on current build first. |
| §2c distribution | **Deferred — "not this repo's problem yet."** Phase 2. |
| §2d role model | **RESOLVED: per-role image, reassign = reflash.** Details deferred. |
| §2e state | **CONFIRMED.** Storage state separate (R7); details Phase 2. |
| §2f trust | **Deferred — hand-wave.** Phase 1 = integrity only, no signing. |
| F1 immutability | **Relaxed now (TARGET).** Mutations needed for experiments. |
| F3/F5 reproducible/build | **TARGET, blocked on §2a.** Phase 2. |
| F2/F4 atomic-update / content-identity | **Bind now.** |

### What's left for the NEAR term (Phase 1)

Almost everything fleet-scale is deferred. The near-term question collapses to:

> **Build a cost-proportional, content-derived, truthful identity that works on a
> *mutable, single experimental* image — answerable from the artifact itself,
> on the running device and on a pulled image alike** (R1, R2, F4; R11 cheap).

Open sub-questions that DO need answering for Phase 1 (small):
1. **§2b granularity** — whole-image digest vs curated-part manifest? (Leaning:
   curated parts, because on a *mutable* image a whole-rootfs hash is noisy and a
   raw ext4 hash is non-deterministic — §3d-style reasoning.)
2. **§2b carrier** — where does the identity live so it's interrogable on-device
   *and* on a pulled image without a running OS? (the `debugfs`-readable path
   used twice this session is the existence proof)
3. **§3b unit** — for Phase 1, is the unit the rootfs, or rootfs + boot images?
4. **R12 migration** — how the existing `IMAGE_VERSION` / banner coexists with
   or is replaced by the new record.

### Still-open foundational (Phase 2, don't resolve now)
- **§3a** Debian survives? **§3c** this repo = fleet builder or bring-up tool?
  (My instinct unchanged: this repo's lasting value is felix bring-up knowledge;
  the fleet builder is a separate, reproducible artifact. Not deciding now.)
