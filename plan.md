# Plan: kube + garage cluster roles

## Goal

Produce two kinds of felix node images from this build — a **kube** node
(Kubernetes compute) and a **garage** node (Garage object storage on its own
phones) — without forking the expensive, hardware-specific build machinery.

## Why Garage (not Ceph)

The earlier draft of this plan targeted Ceph. It has been switched to
[Garage](https://garagehq.deuxfleurs.fr/) to match the fleet constraints worked
out in [docs/platform-strategy.md](docs/platform-strategy.md):

- **The interconnect is USB-Ethernet: high bandwidth, high latency, shared, no
  data locality.** Ceph's synchronous, strongly-consistent replication blocks
  each write on replica acks × replication factor — hostile to a high-latency
  fabric. Garage is Dynamo-inspired with CRDT / weak consistency (no Raft/Paxos)
  and is production-tested at ~200ms inter-node latency.
- **Deliberate churn / rotation.** Phones rotate between workloads and get pulled
  from under running clusters. Ceph suffers rebalance storms under churn and is
  heavy per-OSD (RAM). Garage's cluster-layout model minimizes data transfer on
  join/leave and heals by *copying a replica* — far cheaper than Ceph or
  erasure-coding re-encode under churn.
- **Constrained nodes.** Garage runs on Pi-class ARM with tiny RAM; it fits a
  phone. Ceph's per-OSD memory footprint does not fit comfortably.
- **Already in use at KRG.** Garage is the krg-prod homelab object store, so
  there is operational familiarity (bus factor).

Trade-off accepted: Garage does 3× replication only (no erasure coding), so it is
less storage-efficient on limited UFS, and offers no read-after-write guarantee.
The rotation/churn requirement outweighs the capacity cost. (SeaweedFS was the
capacity-efficient alternative; the rotation requirement tilted the decision to
Garage. See the strategy doc §–4 #6 for the full comparison.)

The architecture below is **storage-engine-agnostic** — it was already the right
shape for Ceph and stays the right shape for Garage. The swap mostly *removes*
work (Garage needs far less kernel and userspace plumbing than Ceph).

## Findings that shape the design

- The current "kube focus" is **only** in the kernel defconfig fragment
  ([kernel/custom_defconfig_mod/custom_defconfig](kernel/custom_defconfig_mod/custom_defconfig)):
  the `# k8s/k3s` sections (cgroup controllers, PID/USER namespaces,
  `BRIDGE_NETFILTER`, `VXLAN`, netfilter xt matches) and the `cgroup_enable=*`
  args in `CONFIG_CMDLINE`. Userspace ([rootfs/packages.txt](rootfs/packages.txt))
  is a bare Debian system — no k8s/storage packages today.
- The **kernel build is the expensive, role-independent step** (~1hr Bazel build,
  same felix hardware either way). Every rootfs target depends on
  `kernel_version` being current, and kernel↔rootfs modules must stay in lockstep.
- **Garage needs almost no special kernel support.** It is a single static Rust
  binary that stores data/metadata on an ordinary filesystem (the persistent data
  mount) and speaks S3/HTTP over the network. There are **no Garage kernel
  modules**, and — unlike Ceph — **no client-side filesystem driver on the kube
  nodes**, because Garage is consumed as a *remote S3 endpoint*, not a mounted
  block device or filesystem. This deletes the entire `rbd` / CephFS client
  concern from the kube role.
- `boot.img` / `vendor_boot.img` / `dtbo.img` are **role-independent** (kernel +
  dtb + dracut initramfs that just mounts `super` by partlabel). Only `rootfs.img`
  differs by role.

## Decisions

1. **One repo, not three.** The shared machinery dominates; the per-role delta is
   a package list + overlay subtree + first-boot unit + (for kube) a few CONFIG
   lines. Splitting would export the kernel↔rootfs lockstep across a git boundary.
   Roles become *directories*, not repositories. Defer any real split until a role
   grows its own maintainers/cadence — isolating role bits under `profiles/<role>/`
   now makes a future `git filter-repo` extraction a one-shot. (This matches the
   strategy doc's "profiles = base + package-set + config overlay" abstraction.)

2. **One kernel, lightly extended for kube only.** The kube role needs its
   existing k8s CONFIG. Garage needs essentially nothing beyond a stock GKI kernel
   plus the device-mapper/loop plumbing useful for preparing a data volume. Union
   whatever is needed into the same fragment; unused bits never load on the other
   role, and the kube `cgroup_enable=*` cmdline args are harmless on a storage
   node. Two kernels would mean two 1hr builds and two lockstep module trees for a
   handful of CONFIG diffs. Revisit only if the roles ever need divergent
   `CONFIG_CMDLINE`.

3. **Universal boot artifacts.** Build `boot.img` / `vendor_boot.img` /
   `dtbo.img` once; flash the same trio to every phone. The only per-role artifact
   is `rootfs-<role>.img` flashed to `super`.

4. **Common base + thin role layer for rootfs.** The existing sentinel chain
   builds a pristine common base (debootstrap + vendor firmware + kernel modules +
   common packages + initramfs + boot images). A new cheap, re-runnable, profile-
   parameterized finalize step derives each role image from a copy of the base.

5. **Per-node identity at first boot, not baked.** One `rootfs-garage.img` flashes
   to N storage phones; they can't all be the same Garage node. Node ID, cluster
   layout/zone, and join material are a first-boot concern. (Per the strategy doc:
   role → image, coarse, delivery layer; per-device identity → first-boot config,
   fine. Never bake per-device identity into images.)

## Work items

### Kernel (extend the fragment for storage plumbing)

Garage itself needs no kernel modules. The only storage-side additions are the
generic block plumbing to prepare/optionally-encrypt the data volume on the
storage phones. Add a `# garage / storage` section to
[kernel/custom_defconfig_mod/custom_defconfig](kernel/custom_defconfig_mod/custom_defconfig)
only if not already provided by GKI:

```
# garage storage nodes — generic block plumbing for the data volume
CONFIG_BLK_DEV_DM=y       # device-mapper (lvm / partitioning flexibility)
CONFIG_DM_CRYPT=y         # optional encrypted-at-rest data volume
CONFIG_BLK_DEV_LOOP=y     # loop devices (image-backed data vol during bring-up)
```

Notably **dropped vs the Ceph draft:** `CONFIG_CEPH_LIB`, `CONFIG_BLK_DEV_RBD`,
`CONFIG_CEPH_FS*` — Garage has no in-kernel client, so none of these are needed on
either role.

Verify after a build by grepping the built `.config` in
`kernel/source/out/felix/dist`:
- Several of these are likely already `=y` in GKI — only the off-by-default ones
  matter.
- The GKI filesystem allowlist silently strips non-allowlisted on-disk
  filesystems. Garage stores onto an allowlisted fs (ext4/f2fs/erofs are fine), so
  there is no new filesystem to smuggle past the allowlist — another simplification
  vs Ceph.

### Rootfs profiles (directory layout)

```
profiles/
  common/
    packages.txt        # today's rootfs/packages.txt
    overlay/            # today's rootfs/overlay
  kube/
    packages.txt        # k3s/containerd deps
    overlay/            # kube units, first-boot join
  garage/
    packages.txt        # lvm2/cryptsetup for the data vol (garage binary via overlay)
    overlay/            # garage binary + unit + data-dir mount, first-boot layout/enroll
```

Apply order per role: common, then role.

Garage delivery note: Garage ships as a single static binary, so the `garage`
profile can drop it straight into the overlay (like `pixel-devinfo`) rather than
needing a distro package + container runtime. A Garage storage node therefore
does **not** require a container runtime at all (unlike a `cephadm`-style
deployment) — the daemon is host substrate, launched by the role's systemd unit.

### Build wiring

- Keep the existing chain producing a **common base** `rootfs.img` (common
  packages + overlay only) plus the universal boot images.
- Add `just build_role kube|garage`:
  - `cp --reflink=auto` base `rootfs.img` → `rootfs-<role>.img`
  - mount, apt-install role packages in nspawn, rsync role overlay, write
    first-boot config, unmount
  - guard with a per-role sentinel `.finalize_<role>` so the expensive base is
    never redone per role.
- Leave `boot.img` / `vendor_boot.img` / `dtbo.img` shared.

### Flashing

- [flash.sh](flash.sh) takes a role arg to pick `rootfs-<role>.img` for `super`;
  everything else unchanged.

### Per-node identity (first boot)

- Small per-role first-boot systemd unit:
  - derive a stable node identity — lean toward the dongle MAC (already surfaced
    on the login banner; maps to a physical slot, per the strategy doc's
    location-as-identity model) rather than the phone serial, so identity follows
    the slot across phone swaps.
  - **garage:** start the daemon, then assign the node into the cluster layout
    (`garage layout assign` with its zone/capacity) and apply; one node bootstraps
    the layout, the rest join with the cluster RPC secret.
  - **kube:** join with a k3s server token.
- Decide the join mechanism before writing the overlays so each role carries the
  right unit.

## Open questions

- Kube distribution: k3s vs full kubeadm? (affects packages + first-boot unit)
- Garage data volume on felix: partition `super` for a data area vs a dedicated
  data partition vs an image-backed loop during bring-up; UFS endurance under the
  storage write pattern.
- Garage zone mapping: how the first-boot unit derives the failure-domain zone
  (slot → hub → switch table from wiring, per the strategy doc) for
  `garage layout`.
- First-boot identity source: dongle MAC (current lean), cmdline, or a small
  per-device config partition.
- Replication factor vs UFS capacity: Garage is 3× replication; confirm the
  per-node UFS budget against the target usable capacity and fabric heal
  bandwidth.

## Out of scope for this PR

This PR is the plan only. No build changes yet.
