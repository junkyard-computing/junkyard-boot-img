# dockershell: git is unusable inside the container on a worktree checkout

## Symptom
Two failures, one loud and one silent, when the repo is a `git worktree`:

1. `just all` dies immediately:
   `clone_kernel_source` -> `fatal: not a git repository:
   .../junkyard-boot-img/.git/worktrees/jboot-mainline` (exit 128)

2. **Silent, and worse:** if you skip that recipe, the kernel still builds but
   `scripts/setlocalversion` cannot run git, so it falls back to the bare tag.
   `kernel_version` becomes `7.2.0-rc4` instead of
   `7.2.0-rc4-00112-gc39947346ac6`. The image boots, but `uname -r` no longer
   identifies which build it is — which is precisely how a module/kernel
   vermagic mismatch was diagnosed on .138 last week.

## Cause
`dockershell` mounts only the repo: `-v "$REPO_ROOT:/work"`. A worktree's git
state lives outside that tree, and is reached by a chain of paths that do not
resolve under `/work`:

    jboot-mainline/.git              -> gitdir: /home/.../junkyard-boot-img/.git/worktrees/jboot-mainline   (absolute)
    kernel/source/.git               -> gitdir: ../../../junkyard-boot-img/.git/worktrees/.../kernel/source  (relative, escapes the repo)
    ...worktrees/.../kernel/source   -> ../../../../../../../jboot-mainline/kernel/source                    (relative, points back)

Because the chain mixes absolute and relative paths in both directions, no
single mount point works. The container must see both directories at the same
absolute paths they have on the host.

## Fix
Mount the repo at its real path (not `/work`), and mount the sibling gitdir
alongside it:

```sh
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mounts=(-v "$REPO_ROOT:$REPO_ROOT")
workdir="$REPO_ROOT"

# A worktree checkout keeps its git state outside the repo; mount that too, at
# the same absolute path, or git (and therefore setlocalversion) fails inside.
if [ -f "$REPO_ROOT/.git" ]; then
  gitdir="$(sed -n 's/^gitdir: //p' "$REPO_ROOT/.git")"
  # walk up to the owning repository root
  owner="${gitdir%%/.git/*}"
  [ -d "$owner" ] && mounts+=(-v "$owner:$owner")
fi

exec docker run --rm "${tty_args[@]}" --privileged --cgroupns=host \
  "${mounts[@]}" -w "$workdir" ...
```

Verified: with those mounts, inside the container

    git describe --tags   -> v7.2-rc4-112-gc39947346ac6a
    git rev-parse --abbrev-ref HEAD -> feature/mainline-7.2-rc4

and the kernel version string comes out complete.

## Worth also doing
`setlocalversion` degrading silently is the dangerous part. Consider having the
build fail, or at least warn loudly, when `kernel_version` has no `-g<sha>`
suffix while the source tree is a git checkout — an unidentifiable kernel is a
debugging trap, not a cosmetic issue.

Separately, `tools/Dockerfile` ships no Rust toolchain, so
`.build_pixel_bootctl` / `.build_pixel_ota` fail with `cargo: not found`. They
build fine in the nix devshell, so either add Rust to the image or document that
those two stages run outside the container.
