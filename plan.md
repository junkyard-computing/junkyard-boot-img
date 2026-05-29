# Plan: kube + ceph cluster roles

## Goal

Produce two kinds of felix node images from this build — a **kube** node and a
**ceph** node (standalone Ceph cluster on its own phones) — without forking the
expensive, hardware-specific build machinery.

## Findings that shape the design

- The current "kube focus" is **only** in the kernel defconfig fragment
  ([kernel/custom_defconfig_mod/custom_defconfig](kernel/custom_defconfig_mod/custom_defconfig)):
  the `# k8s/k3s` sections (cgroup controllers, PID/USER namespaces,
  `BRIDGE_NETFILTER`, `VXLAN`, netfilter xt matches) and the `cgroup_enable=*`
  args in `CONFIG_CMDLINE`. Userspace ([rootfs/packages.txt](rootfs/packages.txt))
  is a bare Debian system — no k8s/ceph packages today.
- The **kernel build is the expensive, role-independent step** (~1hr Bazel build,
  same felix hardware either way). Every rootfs target depends on
  `kernel_version` being current, and kernel↔rootfs modules must stay in lockstep.
- **Ceph daemons (MON/MGR/OSD) need almost no special kernel support** — they're
  userspace and BlueStore talks to raw block directly. The kernel modules people
  associate with Ceph (`rbd`, CephFS) are for *consuming* storage, so they belong
  on the **kube** nodes that mount volumes, not on the storage nodes. The storage
  nodes mostly need block/device-mapper plumbing for OSD prep.
- `boot.img` / `vendor_boot.img` / `dtbo.img` are **role-independent** (kernel +
  dtb + dracut initramfs that just mounts `super` by partlabel). Only `rootfs.img`
  differs by role.

## Decisions

1. **One repo, not three.** The shared machinery dominates; the per-role delta is
   a package list + overlay subtree + first-boot unit + a few CONFIG lines.
   Splitting would export the kernel↔rootfs lockstep across a git boundary. Roles
   become *directories*, not repositories. Defer any real split until a role grows
   its own maintainers/cadence — isolating role bits under `profiles/<role>/` now
   makes a future `git filter-repo` extraction a one-shot.

2. **One superset kernel, not two.** Union the kube and ceph CONFIG needs into the
   same fragment. Unused modules simply never load on the other role; the kube
   `cgroup_enable=*` cmdline args are harmless on a storage node. Two kernels would
   mean two 1hr builds and two lockstep module trees for a handful of CONFIG diffs.
   Revisit only if the two roles ever need divergent `CONFIG_CMDLINE`.

3. **Universal boot artifacts.** Build `boot.img` / `vendor_boot.img` / `dtbo.img`
   once; flash the same trio to every phone. The only per-role artifact is
   `rootfs-<role>.img` flashed to `super`.

4. **Common base + thin role layer for rootfs.** The existing sentinel chain builds
   a pristine common base (debootstrap + vendor firmware + kernel modules + common
   packages + initramfs + boot images). A new cheap, re-runnable, profile-
   parameterized finalize step derives each role image from a copy of the base.

5. **Per-node identity at first boot, not baked.** One `rootfs-ceph.img` flashes to
   N storage phones; they can't all be the same MON. Hostname + cluster join
   material are a first-boot concern.

## Work items

### Kernel (superset fragment)

Add a `# ceph` section to
[kernel/custom_defconfig_mod/custom_defconfig](kernel/custom_defconfig_mod/custom_defconfig):

```
# ceph — client side (kube nodes mounting RBD/CephFS volumes)
CONFIG_CEPH_LIB=y
CONFIG_BLK_DEV_RBD=y
CONFIG_CEPH_FS=y
CONFIG_CEPH_FS_POSIX_ACL=y

# ceph — storage/OSD side (BlueStore is userspace; dm-crypt for encrypted OSDs)
CONFIG_BLK_DEV_DM=y
CONFIG_DM_CRYPT=y
CONFIG_BLK_DEV_LOOP=y
```

Verify after a build by grepping the built `.config` in
`kernel/source/out/felix/dist`:
- Several of these are likely already `=y` in GKI — only the off-by-default ones
  matter.
- The GKI filesystem allowlist silently strips non-allowlisted on-disk filesystems
  (btrfs, squashfs). `rbd` is block and CephFS is a network fs (sibling of the
  already-working `NFS_FS=y`), so they *should* survive — confirm they weren't
  dropped.

### Rootfs profiles (directory layout)

```
profiles/
  common/
    packages.txt        # today's rootfs/packages.txt
    overlay/            # today's rootfs/overlay
  kube/
    packages.txt        # k3s/containerd deps
    overlay/            # kube units, first-boot join
  ceph/
    packages.txt        # cephadm/podman or distro ceph, lvm2, cryptsetup
    overlay/            # ceph units, first-boot bootstrap/enroll
```

Apply order per role: common, then role.

### Build wiring

- Keep the existing chain producing a **common base** `rootfs.img` (common packages
  + overlay only) plus the universal boot images.
- Add `just build_role kube|ceph`:
  - `cp --reflink=auto` base `rootfs.img` → `rootfs-<role>.img`
  - mount, apt-install role packages in nspawn, rsync role overlay, write first-boot
    config, unmount
  - guard with a per-role sentinel `.finalize_<role>` so the expensive base is never
    redone per role.
- Leave `boot.img` / `vendor_boot.img` / `dtbo.img` shared.

### Flashing

- [flash.sh](flash.sh) takes a role arg to pick `rootfs-<role>.img` for `super`;
  everything else unchanged.

### Per-node identity (first boot)

- Small per-role first-boot systemd unit:
  - derive a stable hostname (from MAC/serial)
  - **ceph:** bootstrap one MON manually, let `cephadm` enroll the rest
  - **kube:** join with a k3s server token
- Decide the join mechanism before writing the overlays so each role carries the
  right unit.

## Open questions

- Kube distribution: k3s vs full kubeadm? (affects packages + first-boot unit)
- Ceph deployment: `cephadm`/containerized vs distro packages? (affects whether the
  storage nodes also need a container runtime)
- Storage layout on felix for OSDs (UFS-backed; partitioning of `super` vs a
  dedicated data partition).
- First-boot identity source: cmdline, a small per-device config partition, or
  MAC/serial derivation.

## Out of scope for this PR

This PR is the plan only. No build changes yet.
