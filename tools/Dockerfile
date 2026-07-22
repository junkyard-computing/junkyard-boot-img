# Ephemeral build environment for the junkyard-boot-img build pipeline.
#
# Host setup (one time, before the first debootstrap stage):
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
# This registers an aarch64 binfmt handler on the host kernel with the F flag,
# so qemu-user-static is reachable from inside the rootfs nspawn even though
# the qemu binary isn't visible in the foreign-arch sysroot.
#
# Build container is invoked via tools/dockershell, which bind-mounts the repo
# at its real host path (and the owning gitdir, for worktree checkouts, so git
# works inside) and runs as a user matching the host uid/gid so files created on
# the bind mount are owned by the invoking user (sudo'd commands inside the
# Makefile still produce root-owned files, matching the existing design).
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates sudo \
        just qemu-user-static \
        make e2fsprogs rsync debootstrap systemd-container \
        curl unzip xxd git python3 \
        erofs-utils android-sdk-libsparse-utils \
        build-essential bc bison flex libssl-dev libelf-dev \
        gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
        lz4 cpio kmod zstd \
        fastboot tio \
    && rm -rf /var/lib/apt/lists/*

# `repo` was dropped from Debian; install from Google's hosted script.
RUN curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
        -o /usr/local/bin/repo \
 && chmod 0755 /usr/local/bin/repo

# Rust with the aarch64-musl target, for the static on-device helpers
# (.build_pixel_bootctl / .build_pixel_ota). Without it those stages die with
# "cargo: not found" and the image build stops before .install_packages.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
ENV PATH=/opt/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --no-modify-path \
              --default-toolchain stable --target aarch64-unknown-linux-musl \
 && chmod -R a+rwX /opt/cargo /opt/rustup

ARG USER_UID=1000
ARG USER_GID=1000
# Reuse a pre-existing group if $USER_GID is already taken (e.g. host GID 100 =
# Debian's built-in 'users' group), and make sure the supplementary groups exist
# before adding the user to them — keeps the build working across host uid/gids.
RUN for g in dialout plugdev; do getent group "$g" >/dev/null || groupadd "$g"; done \
 && (getent group "$USER_GID" >/dev/null || groupadd -g "$USER_GID" builder) \
 && useradd -m -u $USER_UID -g $USER_GID -G dialout,plugdev -s /bin/bash builder \
 && echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-builder \
 && chmod 0440 /etc/sudoers.d/99-builder

USER builder
# WORKDIR is set by dockershell (-w) to the repo's real path.
WORKDIR /work
