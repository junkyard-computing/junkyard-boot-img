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

# The Debian-trixie debootstrap used inside tools/dockershell leaves
# sysroot/proc as an ABSOLUTE symlink `proc -> /proc` instead of a real
# directory (the Nix host's debootstrap makes it a dir, so this only bites the
# container build). systemd-nspawn chases /proc within the new root; the
# absolute symlink re-prefixes to sysroot/proc -> /proc -> ... and the
# resolution loops, aborting nspawn with "Failed to resolve /proc: Too many
# levels of symbolic links". Replace any such symlink with an empty dir so
# nspawn can mount a fresh procfs there. No-op when /proc is already a dir.
if [ -L "$sysroot/proc" ]; then
    rm -f "$sysroot/proc"
    mkdir -p "$sysroot/proc"
fi

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

# --register=no + --keep-unit let nspawn run inside a container that has no
# systemd-machined / unit manager (e.g. tools/dockershell). They're harmless
# on a host that does have them, so pass them unconditionally.
nspawn_compat="--register=no --keep-unit"

# On a real host, wrap nspawn in a private mount namespace so its /dev tmpfs +
# /nix/store bind don't leak back into the host's shared sysroot view. Inside
# the build container (detected via /.dockerenv) call nspawn directly — the
# extra `unshare -m` trips "Failed to resolve /proc: Too many levels of
# symbolic links" under docker's nested namespaces, and the /dev-leak it guards
# against can't happen in an ephemeral container anyway. Gate on /.dockerenv,
# NOT /nix/store: the store is bind-mounted into the container too (so the
# binfmt qemu wrapper resolves), so its presence no longer distinguishes the
# two environments.
if [ -f /.dockerenv ]; then
    # systemd-nspawn (systemd 257 in the debian-trixie build image) fails to
    # spawn inside this docker container — it exits 255 even for `-D sysroot
    # true`, with no useful diagnostic — so nspawn is unusable here. Fall back to
    # chroot + binfmt-qemu: the dockershell host registers the aarch64 binfmt
    # with the F (fix-binary) flag, which preloads the qemu interpreter fd at
    # registration, so aarch64 binaries run under chroot without the /nix/store
    # interpreter path being visible in the new root. (On a real host we still
    # use nspawn below — it works there.)
    #
    # Strip the nspawn-only options the Makefile passes ("--resolv-conf=... -D
    # <dir>") to recover the bare command to chroot-exec.
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -D) shift 2 ;;
            --directory=*) shift ;;
            --resolv-conf=*|--setenv=*|--bind-ro=*|--register=*|--keep-unit) shift ;;
            *) break ;;
        esac
    done

    # /dev was wiped+recreated empty above; bind the container's real /dev, and
    # mount fresh proc/sys so the aarch64 tools (depmod, dracut) have a working
    # environment. resolv.conf best-effort mirrors --resolv-conf=bind-host.
    mount -t proc  proc  "$sysroot/proc" 2>/dev/null || true
    mount -t sysfs sysfs "$sysroot/sys"  2>/dev/null || true
    mount -o bind  /dev   "$sysroot/dev"
    cp -f /etc/resolv.conf "$sysroot/etc/resolv.conf" 2>/dev/null || true

    # binfmt_misc is often left UNMOUNTED in the build container (so no aarch64
    # handler is active and every aarch64 exec — even /bin/true — returns 255),
    # and any handler inherited from the NixOS host points at a /nix-pathed qemu
    # wrapper that can't resolve here. Mount binfmt_misc and register the
    # container's own qemu-aarch64-static with the F (fix-binary) flag, which
    # preloads the interpreter fd so it runs under chroot without the qemu path
    # being visible in the new root.
    mountpoint -q /proc/sys/fs/binfmt_misc 2>/dev/null || \
        mount -t binfmt_misc none /proc/sys/fs/binfmt_misc 2>/dev/null || true
    if [ ! -e /proc/sys/fs/binfmt_misc/jbqemu-aarch64 ] && \
       command -v qemu-aarch64-static >/dev/null 2>&1; then
        printf ':jbqemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F' \
            > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
    fi

    chroot_cleanup() {
        umount -lR "$sysroot/proc" "$sysroot/sys" "$sysroot/dev" 2>/dev/null || true
    }
    trap chroot_cleanup EXIT INT TERM

    PATH="$container_path" chroot "$sysroot" "$@"
    rc=$?
    chroot_cleanup
    trap - EXIT INT TERM
    exit "$rc"
else
    exec unshare -m --propagation private \
        systemd-nspawn $nspawn_compat $extra_binds --setenv="PATH=$container_path" "$@"
fi
