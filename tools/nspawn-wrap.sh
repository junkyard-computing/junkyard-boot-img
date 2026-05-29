#!/bin/sh
# Wrapper around systemd-nspawn that works around two systemd >= 260 quirks
# we ran into when invoking nspawn against a debootstrap-managed sysroot:
#
#   1. mount_all() in nspawn skips mounting its own /dev tmpfs if the target
#      path is already a mountpoint (nspawn-mount.c "Skip this entry if it
#      is not a remount."). A previous failed nspawn invocation can leave
#      a populated /dev tmpfs at sysroot/dev — propagated back from the
#      container NS via the host's shared `/` peer group — and the next
#      invocation then reuses it, instead of mounting a fresh empty one.
#
#   2. setup_pts() in nspawn does a strict `mkdir(sysroot/dev/pts, 0755)`
#      with no EEXIST tolerance. When a stale /dev tmpfs from (1) already
#      contains /dev/pts, this mkdir aborts the whole nspawn run with
#      "Failed to create /dev/pts: File exists".
#
# Fix: tear down any mounts under sysroot/dev, then recreate the directory
# empty so nspawn's mount_all happily mounts a fresh tmpfs and setup_pts
# can create /dev/pts. The unshare wrapper isolates this invocation's
# mount NS so the new /dev mounts don't propagate back to the host (only
# partially effective on its own because nspawn explicitly re-shares its
# root mount after switch_root — but combined with the pre-clean above,
# every invocation starts from a known-good state regardless).
#
# Usage:
#   sudo tools/nspawn-wrap.sh <sysroot> -- <nspawn args...>
set -eu

if [ "$#" -lt 2 ] || [ "$2" != "--" ]; then
    echo "usage: nspawn-wrap.sh <sysroot> -- <systemd-nspawn args...>" >&2
    exit 2
fi

sysroot="$1"
shift 2  # drop sysroot and "--"

# Refuse empty or "/" sysroot: we run `rm -rf "$sysroot/dev"` as root below,
# which on an empty or root path would wipe the host's /dev and brick the
# system. Also fail fast if the path isn't a directory.
case "$sysroot" in
    ""|"/")
        echo "nspawn-wrap.sh: refusing to operate on sysroot='$sysroot'" >&2
        exit 2
        ;;
esac
if [ ! -d "$sysroot" ]; then
    echo "nspawn-wrap.sh: sysroot '$sysroot' is not a directory" >&2
    exit 2
fi

# Tear down anything left behind under sysroot/dev. -lR is lazy + recursive:
# even if a previous run's container NS still holds refs, the mounts are
# detached from our namespace immediately so the directory contents below
# become accessible.
umount -lR "$sysroot/dev" 2>/dev/null || true

# Wipe and recreate /dev so nspawn's mkdir(/dev/pts) sees an empty tmpfs.
# We're inside sudo already; the rm/mkdir run as root.
rm -rf "$sysroot/dev"
mkdir -p "$sysroot/dev"

# On NixOS, /run/binfmt/aarch64-linux is a /nix/store-pathed wrapper around
# the real qemu-aarch64 (also under /nix/store). The F flag pre-opens the
# wrapper so it runs, but its own execve() of the real qemu fails inside
# the chroot with ENOENT because /nix/store isn't visible there. Bind it
# read-only so qemu's inner execve resolves. Skipped on hosts without
# /nix/store (no-op for non-Nix builds).
extra_binds=""
if [ -d /nix/store ]; then
    extra_binds="--bind-ro=/nix/store"
fi

# nspawn inherits PATH from the host, which on NixOS is full of /nix/store
# entries that don't exist inside the container. Override with a standard
# Debian-style PATH so debootstrap's bare `grep`, `dpkg`, `perl`, etc.
# resolve to the container's own /usr/bin and /usr/sbin. Harmless on
# non-Nix hosts (just a redundant explicit override).
container_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Run nspawn in a private mount namespace so its tmpfs/bind setup at
# /dev does not leak back into the host's view of sysroot. nspawn will
# still mark its switched-root MS_SHARED internally — that's fine, the
# new peer groups it creates only live inside this unshared NS.
exec unshare -m --propagation private \
    systemd-nspawn $extra_binds --setenv="PATH=$container_path" "$@"
