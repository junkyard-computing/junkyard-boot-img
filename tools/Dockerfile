# Ephemeral build environment for the junkyard-boot-img build pipeline.
#
# Host setup (one time, before the first debootstrap stage):
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
# This registers an aarch64 binfmt handler on the host kernel with the F flag,
# so qemu-user-static is reachable from inside the rootfs nspawn even though
# the qemu binary isn't visible in the foreign-arch sysroot.
#
# Build container is invoked via tools/dockershell, which bind-mounts the repo
# at /work and runs as a user matching the host uid/gid so files created on
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
        lz4 cpio kmod zstd \
        fastboot tio \
    && rm -rf /var/lib/apt/lists/*

# `repo` was dropped from Debian; install from Google's hosted script.
RUN curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
        -o /usr/local/bin/repo \
 && chmod 0755 /usr/local/bin/repo

ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd -g $USER_GID builder \
 && useradd -m -u $USER_UID -g $USER_GID -G dialout,plugdev -s /bin/bash builder \
 && echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-builder \
 && chmod 0440 /etc/sudoers.d/99-builder

USER builder
WORKDIR /work
