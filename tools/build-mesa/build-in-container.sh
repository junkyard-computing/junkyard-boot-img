#!/bin/bash
# Runs INSIDE an arm64 (qemu-emulated) Debian trixie container.
#
# Builds the junkyard-computing/mesa `felix-g710` fork (Panfrost gallium +
# rusticl OpenCL + PanVK Vulkan, with the Mali-G710 model entry) against
# trixie's own glibc / LLVM-19 / libclc-19. Building in-distro is deliberate:
# the felix rootfs is also Debian trixie, so the resulting libraries drop onto
# the device with no glibc/LLVM ABI mismatch. A pure-nix cross build would bake
# /nix/store loader+lib paths that don't exist on the Debian rootfs.
#
# Inputs  (bind-mounted by the host wrapper, see ../../flake.nix #build-mesa):
#   /src/mesa  — the mesa fork checkout (felix-g710)
#   /src/out   — output dir; built .so's are collected here
# The build tree lives at /src/build and is reused across runs (ninja resumes).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== [$(date +%T)] apt update + build deps ==="
apt-get update -qq
apt-get install -y --no-install-recommends \
  meson ninja-build pkg-config python3 python3-mako python3-yaml python3-packaging \
  bison flex git ca-certificates \
  gcc g++ \
  rustc cargo bindgen \
  llvm-19-dev libclang-19-dev libclang-cpp19-dev clang-19 libclc-19-dev libclc-19 \
  libllvmspirvlib-19-dev spirv-tools spirv-headers \
  libdrm-dev libelf-dev zlib1g-dev libzstd-dev libexpat1-dev \
  libwayland-dev wayland-protocols libwayland-egl-backend-dev \
  libx11-dev libxext-dev libxfixes-dev libxdamage-dev libxshmfence-dev \
  libxxf86vm-dev libxrandr-dev libxcb1-dev libx11-xcb-dev libxcb-dri3-dev \
  libxcb-present-dev libxcb-sync-dev libxcb-randr0-dev libxcb-shm0-dev \
  libxcb-xfixes0-dev libxcb-glx0-dev libxcb-dri2-0-dev \
  2>&1 | tail -4

echo "=== [$(date +%T)] tool versions ==="
meson --version; rustc --version; llvm-config-19 --version

cd /src/mesa
# LLVM 19 is the trixie default; point meson at the versioned tools.
export PATH="/usr/lib/llvm-19/bin:$PATH"
if [ ! -f /src/build/build.ninja ]; then
  echo "=== [$(date +%T)] meson configure (fresh) ==="
  # /src/build is a bind mount (reused across runs so ninja can resume), so
  # clear its *contents* rather than the mountpoint itself (rm of the mount
  # point fails with EBUSY).
  find /src/build -mindepth 1 -delete 2>/dev/null || true
  meson setup /src/build \
    -Dprefix=/usr \
    -Dgallium-drivers=panfrost \
    -Dvulkan-drivers=panfrost \
    -Dgallium-rusticl=true \
    -Dllvm=enabled \
    -Dshared-llvm=enabled \
    -Dvideo-codecs= \
    -Dplatforms=x11,wayland \
    -Dglx=dri \
    -Degl=enabled \
    -Dgbm=enabled \
    -Dbuildtype=release \
    2>&1 | tail -30
else
  echo "=== [$(date +%T)] build dir exists ($(find /src/build -name '*.o' 2>/dev/null | wc -l) .o) — RESUMING ninja ==="
fi

echo "=== [$(date +%T)] ninja build ==="
ninja -C /src/build 2>&1 | tail -25

echo "=== [$(date +%T)] collect artifacts -> /src/out ==="
# /src/out is a bind mount too: clear contents, don't remove the mountpoint.
find /src/out -mindepth 1 -delete 2>/dev/null || true
find /src/build -type f \( -name 'libRusticlOpenCL.so*' -o -name 'libgallium-*.so' \
  -o -name 'libvulkan_panfrost.so' -o -name 'libEGL.so.*' -o -name 'libgbm.so.*' \) \
  ! -name '*.symbols' -exec cp -av {} /src/out/ \;
# Recreate the version-suffixed symlinks meson installs (find copies follow the
# real files; the device deploy expects libRusticlOpenCL.so.1 etc).
( cd /src/out
  for base in libRusticlOpenCL libEGL libgbm; do
    real=$(ls ${base}.so.*.* 2>/dev/null | head -1) || true
    [ -n "${real:-}" ] || continue
    soname=$(echo "$real" | sed -E 's/(\.so\.[0-9]+)\..*/\1/')
    ln -sf "$real" "$soname"; ln -sf "$soname" "${base}.so"
  done )
echo "=== [$(date +%T)] done; artifacts: ==="
ls -la /src/out
