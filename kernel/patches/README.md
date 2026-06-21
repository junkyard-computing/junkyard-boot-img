# kernel/patches

Local patches applied on top of the `repo`-synced AOSP kernel tree
(`kernel/source/`), which is **not** tracked by this repo. This is how we carry
changes to repo-managed kernel projects reproducibly.

`just clone_kernel_source` applies every `*.patch` here after `repo sync`, in the
project directory the patch was generated from. Application is **idempotent**
(`repo sync` preserves a dirty tree, so already-applied patches are detected via
a clean reverse-apply and skipped). A newly-applied patch removes the
`.build_kernel` sentinel so the kernel rebuilds (that sentinel doesn't track
kernel-source content — edit source, then it must be invalidated).

| patch | applied in (under `kernel/source/`) | what |
| --- | --- | --- |
| `0001-gpu-clk-provider-soc-gs.patch` | `private/google-modules/soc/gs` | `clk-acpm-gpu.c` + Kbuild — exposes the GPU (G3D/G3DL2) ACPM DVFS domains as common-clk clocks (`cal_dfs_*` backend) for the open Panthor driver to bind |
| `0002-gpu-clk-node-gs201.patch` | `private/devices/google/gs201` | `gpu_clk` DT node (`google,gs201-acpm-gpu-clk`) + `BUILD.bazel` module out |

Verified on felix: the provider registers `g3d`/`g3dl2`, reporting hardware-correct
rates (202 MHz / 302 MHz). Inert until a clk consumer (Panthor) references it; kbase
is unaffected (it drives the GPU via `cal_dfs_*` directly).

## Regenerating a patch after editing the synced tree

```sh
cd kernel/source/<project>
git add -N <any-new-files>
git diff -- <changed paths> > <repo>/kernel/patches/<name>.patch
git reset <any-new-files>
```
