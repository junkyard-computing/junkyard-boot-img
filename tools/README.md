# `tools/`

Helper scripts and pinned third-party binaries used by the build pipeline. The
scripts are invoked from the [Makefile](../Makefile) and [justfile](../justfile);
none of them are meant to be run by hand in normal use, but each is safe to run
directly for debugging (paths are resolved relative to the script, not the cwd).

| Path | Tracked? | Invoked by |
|------|----------|------------|
| [`update-snapshot.sh`](update-snapshot.sh) | yes | `just update_snapshot` |
| [`extract-partition-fs.sh`](extract-partition-fs.sh) | yes | `just sync_vendor_firmware` |
| [`nspawn-wrap.sh`](nspawn-wrap.sh) | yes | Makefile `NSPAWN` / `NSPAWN_WRAP` |
| [`mkbootimg/`](mkbootimg/) | submodule | Makefile `.build_boot` |
| `payload-dumper-go/` | downloaded at build time | `just sync_vendor_firmware` |

## `update-snapshot.sh`

Refreshes the project's two [snapshot.debian.org](https://snapshot.debian.org)
pins (both committed, both reproducibility anchors):

- **Debian archive timestamp** → `rootfs/debian_snapshot`, read by the Makefile's
  `SNAPSHOT`/`MIRROR`. Pinning the mirror is what makes the package set
  reproducible: the same pin always resolves the same packages.
- **kmscon `.deb`** → `rootfs/kmscon.env` (`-include`'d by the Makefile as
  `KMSCON_URL`/`KMSCON_SHA256`). kmscon was dropped from trixie, so it can't come
  from the pinned suite; instead it's resolved from snapshot.debian.org's
  machine-readable binary API to a permanent content-addressed `/file/<sha1>` URL,
  then downloaded to record its sha256.

For the archive pin, snapshot.debian.org redirects any timestamp to the canonical
nearest snapshot (`302` + `Location`), so the script doesn't enumerate snapshots —
it requests a target instant, follows the redirect to the real ID, and verifies
the suite's `Release` resolves there (`HTTP 200`) before writing.

```sh
just update_snapshot                      # newest snapshot + refresh kmscon (default)
just update_snapshot --latest             # same thing, explicit
just update_snapshot --date 2026-05-01    # nearest snapshot to that day
just update_snapshot 20260501T083000Z     # canonicalize/verify an exact stamp
just update_snapshot --suite sid --latest # pin a different suite
just update_snapshot --no-kmscon          # archive pin only, leave kmscon.env
just update_snapshot --kmscon-only        # refresh kmscon.env only
just update_snapshot --kmscon-version X   # pin a different kmscon version
just update_snapshot --dry-run            # resolve + print, write nothing
```

"Newest" is whatever snapshot.debian.org has most recently published — the
service snapshots a few times a day, so it will typically be a few hours old, not
current-to-the-minute. After changing a pin, rebuild the rootfs
(`just clean_rootfs && just all`) for it to take effect.

## `extract-partition-fs.sh`

`extract-partition-fs.sh <partition.img> <staging-dir>` — unpacks an Android
partition image into a directory, auto-detecting the filesystem. It unwraps
Android sparse framing via `simg2img` when present, then tries EROFS
(`fsck.erofs --extract`) and falls back to ext4 (`debugfs rdump`). felix has
shipped both EROFS and ext4 vendor partitions across OTAs, which is why the
detection is needed. Used by `sync_vendor_firmware` to extract `/vendor` out of
the factory OTA payload.

## `nspawn-wrap.sh`

`sudo nspawn-wrap.sh <sysroot> -- <systemd-nspawn args...>` — a thin wrapper that
makes `systemd-nspawn` start from a known-good state against a
debootstrap-managed sysroot. It tears down any stale mounts under `sysroot/dev`,
recreates the directory empty, and runs nspawn in a private mount namespace, to
sidestep two systemd >= 260 quirks (a reused `/dev` tmpfs from a prior failed run,
and `setup_pts()`'s no-EEXIST `mkdir /dev/pts`). It also bind-mounts `/nix/store`
read-only and sets a Debian-style `PATH` so the build works on NixOS hosts (both
no-ops on non-Nix hosts). All in-sysroot shell work in the build goes through this
wrapper rather than calling nspawn directly. The script header has the full
rationale.

## `mkbootimg/`

The upstream AOSP [mkbootimg](https://android.googlesource.com/platform/system/tools/mkbootimg/)
repo, pulled in as a git submodule (see [`.gitmodules`](../.gitmodules)). The
Makefile's `.build_boot` stage invokes its `mkbootimg.py` twice — once for
`boot.img` (kernel + `root=` cmdline) and once for `vendor_boot.img` (dtb +
dracut initramfs fragment), both header version 4, pagesize 2048.

Initialize it after cloning with:

```sh
git submodule update --init tools/mkbootimg
```

## `payload-dumper-go/`

Not tracked in git — `just sync_vendor_firmware` downloads a pinned release of
[payload-dumper-go](https://github.com/ssut/payload-dumper-go) here on first run
(version pinned in the justfile) and reuses it on subsequent runs. It extracts the
`vendor` partition image from the felix OTA's `payload.bin`.
