# Kernel-tree patches

Patches against the **repo-managed** AOSP kernel checkout under `kernel/source/`.

## Why this directory exists

`kernel/source/` is a `repo` checkout and `kernel/source/.gitignore` ignores
**everything**, so nothing edited in there is tracked by this repo. A `repo
sync`, a fresh clone, or `just clone_kernel_source` silently reverts any local
edit — and the build then succeeds against the *unpatched* tree with no error.
That is the same failure shape as the sentinel/gitlink gotchas in CLAUDE.md:
the build reports success while quietly losing a capability.

Kconfig changes already have a home that survives syncs
(`kernel/custom_defconfig_mod/`, wired in via `--defconfig_fragment`). **Device
tree changes have no such mechanism**, so they are kept here as patches.

## Layout

```
kernel/patches/<repo-project-path>/NNNN-name.patch
```

e.g. `kernel/patches/private/devices/google/gs201/0001-….patch`.

`repo` makes each project its own git, so one `git apply` cannot span them. The
directory under `kernel/patches/` names the project the patch is applied
**inside**, and each patch is `-p1` relative to that project root — i.e.
generate it with `git diff` from within the project directory.

## These ARE applied automatically

The `.apply_kernel_patches` make stage applies everything here, and
`.build_kernel` depends on it, so a normal build is patched with no extra step.

- **Idempotent** — already-applied patches are detected via
  `git apply --check --reverse` and skipped.
- **Fail-loud** — a patch that neither applies nor is already applied *aborts
  the build*. A kernel patch that silently no-ops is the exact failure this
  stage exists to prevent.
- **Survives syncs** — `clone_kernel_source` deletes `.apply_kernel_patches`
  (and `.build_kernel`) after `repo sync`, because a sync reverts the tree and a
  stale sentinel would otherwise mean quietly building an unpatched kernel.
- `just apply_kernel_patches` runs the stage alone, without building.
- `just clean_kernel` drops the sentinel too.

To force a rebuild after adding or editing a patch, the dependency does it for
you (the sentinel is older than the patch file). To rebuild by hand:

```sh
rm -f .build_kernel .install_kernel .install_initramfs .build_boot
nix run .#bazel-fhs -- -c "make .build_kernel BAZEL=$(pwd)/kernel/source/tools/bazel"
tools/dockershell just update_kernel_modules_and_source update_initramfs build_boot_images
```

Two invocation traps worth knowing:

- `make .build_kernel` alone fails — `$(BAZEL)` is repo-relative but the recipe
  `cd`s into `kernel/source` first, hence the absolute `BAZEL=` above.
- Do **not** call `make .install_kernel` directly: `KERNEL_VERSION` is exported
  by the justfile, not defined in the Makefile, so it expands empty, every path
  becomes `lib/modules//…`, and the `find … -name '*.ko' -delete` in that recipe
  hits the whole module tree. Go through the `just` targets.

## Verifying a DT patch actually landed

Three traps, each of which produced a wrong answer once:

1. **The felix `&udc` node lives in the OVERLAYS, not the base dtb.** Check
   `dtbo.img`, not `dtb.img` — and always alongside a *control* property known
   to be present (`dis-u1-entry-quirk`), which is likewise absent from
   `dtb.img`. **A `&udc` change requires reflashing the `dtbo` partition.**
2. **`find /proc/device-tree -name '*foo*'` does not work here** — it returns 0
   hits even for properties that are demonstrably live. Use
   `grep -ac <prop> /sys/firmware/fdt` on the device instead.
3. **Never trust the build's exit code alone** — piping a build through `tail`
   masks a failed `make`. Check artifact mtimes and expected strings.

## Patches

### 0001-gs201-dwc3-parkmode-disable-ss-quirk.patch

Adds `snps,parkmode-disable-ss-quirk` to the felix `&udc/dwc3` node.

**Status: PARTIAL MITIGATION, not a fix.** Sustained host-mode ingest above
~90 Mb/s kills the xHCI host controller outright (`HC died; cleaning up`),
taking the dongle and the only network path with it. With this quirk the
identical flood survived 91 s instead of 15–19 s — roughly 6× better, but it
still dies. The mainline gs201 port survives the same flood indefinitely and
sets this quirk; the AOSP DT never did, though the AOSP dwc3 core does read the
property (`drivers/usb/dwc3/core.c`).

Ship the `flash-ssh.sh` rate cap (`SCP_RATE_KBIT`, default 80 Mb/s) as the
actual protection until the host-controller bug is properly fixed. Remaining
suspect: the vendor `xhci-exynos.c` module, which mainline does not have at all.

See the `project_felix_xhci_hc_died_under_load` note for the full measurement.
