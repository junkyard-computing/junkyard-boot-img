#!/bin/bash
# Runs INSIDE the mounted felix rootfs via systemd-nspawn (see the Makefile
# `.build_mesa` stage). Builds the junkyard-computing/mesa `felix-g710` fork
# (Panfrost gallium + rusticl OpenCL + PanVK Vulkan, with the Mali-G710 model
# entry) against the rootfs's own trixie glibc / LLVM-19 / libclc-19.
#
# Building in the target rootfs (not a docker container) is deliberate: it works
# identically on a NixOS host and under tools/dockershell (docker-in-docker is
# not available there), and the resulting libraries are a perfect ABI match for
# the image they ship in. The build deps are installed, used, and then PURGED so
# the shipped image only carries the runtime libraries (see packages.txt).
#
# Inputs (bind-mounted by the Makefile at /mesa):
#   /mesa/src   — the mesa fork checkout (felix-g710), cloned host-side
#   /mesa/build — persisted build tree (ninja resumes across runs)
#   /mesa/out   — output dir; built .so's + ICD manifests are collected here
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Build-only packages installed below and purged at the end (keep the image
# lean). Listed explicitly — NOT via a `lib*-dev` glob — so we never disturb the
# image's intended runtime set (build-essential + the rusticl runtime libs are
# installed by .install_packages from packages.txt and must survive). gcc/g++
# are deliberately absent here: the image ships build-essential by design.
BUILD_ONLY="meson ninja-build bison flex pkg-config python3-mako \
  llvm-19-dev libclang-19-dev libclang-cpp19-dev clang-19 libclc-19-dev \
  libllvmspirvlib-19-dev spirv-tools spirv-headers rustc cargo bindgen \
  libdrm-dev libelf-dev zlib1g-dev libzstd-dev libexpat1-dev \
  libwayland-dev wayland-protocols libwayland-egl-backend-dev \
  libx11-dev libxext-dev libxfixes-dev libxdamage-dev libxshmfence-dev \
  libxxf86vm-dev libxrandr-dev libxcb1-dev libx11-xcb-dev libxcb-dri3-dev \
  libxcb-present-dev libxcb-sync-dev libxcb-randr0-dev libxcb-shm0-dev \
  libxcb-xfixes0-dev libxcb-glx0-dev libxcb-dri2-0-dev"

echo "=== [$(date +%T)] apt install build deps ==="
apt-get update -qq
apt-get install -y --no-install-recommends \
  meson ninja-build pkg-config python3 python3-mako python3-yaml python3-packaging \
  bison flex git ca-certificates gcc g++ \
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

echo "=== [$(date +%T)] versions ==="; meson --version; rustc --version; llvm-config-19 --version

cd /mesa/src
export PATH="/usr/lib/llvm-19/bin:$PATH"
if [ ! -f /mesa/build/build.ninja ]; then
  echo "=== [$(date +%T)] meson configure (fresh) ==="
  find /mesa/build -mindepth 1 -delete 2>/dev/null || true
  meson setup /mesa/build \
    -Dprefix=/usr \
    -Dgallium-drivers=panfrost \
    -Dvulkan-drivers=panfrost \
    -Dgallium-rusticl=true \
    -Dllvm=enabled -Dshared-llvm=enabled \
    -Dvideo-codecs= \
    -Dplatforms=x11,wayland -Dglx=dri -Degl=enabled -Dgbm=enabled \
    -Dbuildtype=release 2>&1 | tail -30
else
  echo "=== [$(date +%T)] build dir exists ($(find /mesa/build -name '*.o' 2>/dev/null | wc -l) .o) — RESUMING ninja ==="
fi

echo "=== [$(date +%T)] ninja build ==="
ninja -C /mesa/build 2>&1 | tail -25

echo "=== [$(date +%T)] collect artifacts -> /mesa/out ==="
find /mesa/out -mindepth 1 -delete 2>/dev/null || true
find /mesa/build -type f \( -name 'libRusticlOpenCL.so*' -o -name 'libgallium-*.so' \
  -o -name 'libvulkan_panfrost.so' -o -name 'libEGL.so.*' -o -name 'libgbm.so.*' \) \
  ! -name '*.symbols' -exec cp -av {} /mesa/out/ \;
( cd /mesa/out
  for base in libRusticlOpenCL libEGL libgbm; do
    real=$(ls ${base}.so.*.* 2>/dev/null | head -1) || true
    [ -n "${real:-}" ] || continue
    soname=$(echo "$real" | sed -E 's/(\.so\.[0-9]+)\..*/\1/')
    ln -sf "$real" "$soname"; ln -sf "$soname" "${base}.so"
  done )

# ICD manifests, emitted next to the libs. Absolute paths point at the on-device
# install location (/opt/mesa-g710/lib), which the Makefile install stage uses.
cat > /mesa/out/rusticl-g710.icd <<'ICD'
/opt/mesa-g710/lib/libRusticlOpenCL.so.1
ICD
cat > /mesa/out/panvk-g710.json <<'ICD'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "/opt/mesa-g710/lib/libvulkan_panfrost.so",
        "api_version": "1.3.0"
    }
}
ICD

echo "=== [$(date +%T)] purge build-only deps (keep the image lean) ==="
# Surgical purge: only the build-only packages by exact name, then autoremove
# their orphans. The rusticl RUNTIME libs (libclc-19, libclang-cpp19,
# libllvmspirvlib19.1, libllvm19) come from packages.txt and are manually-marked,
# so autoremove leaves them. build-essential (gcc/g++) is untouched.
apt-get purge -y $BUILD_ONLY 2>&1 | tail -2 || true
apt-get autoremove --purge -y 2>&1 | tail -2 || true
apt-get clean

echo "=== [$(date +%T)] done; artifacts: ==="
ls -la /mesa/out
