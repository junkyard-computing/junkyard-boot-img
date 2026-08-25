#!/usr/bin/env bash
set -uo pipefail
cd /work
echo "=== src head ==="; git -C build/mesa/src log --oneline -1
BEFORE=$(md5sum build/mesa/out/libvulkan_panfrost.so 2>/dev/null | cut -d' ' -f1)
just unmount_rootfs 2>/dev/null || true
just mount_rootfs
# Bypass nspawn's broken --bind (overlayfs /run breaks bind-propagation): pre-bind
# the mesa tree + build script INTO the rootfs dir at the host mount level, so they
# appear as /mesa and /build-mesa.sh inside the container with NO nspawn --bind.
sudo mkdir -p rootfs/sysroot/mesa
sudo mount --bind /work/build/mesa rootfs/sysroot/mesa
sudo cp tools/build-mesa/build-in-sysroot.sh rootfs/sysroot/build-mesa.sh
echo "=== [$(date +%T)] nspawn build (no --bind; 255 cleanup is cosmetic) ==="
sudo tools/nspawn-wrap.sh rootfs/sysroot -- --resolv-conf=bind-host \
  -D rootfs/sysroot bash /build-mesa.sh 2>&1
echo "=== [$(date +%T)] nspawn returned ==="
sudo umount rootfs/sysroot/mesa 2>/dev/null || true
sudo rm -f rootfs/sysroot/build-mesa.sh 2>/dev/null || true
just unmount_rootfs 2>/dev/null || true
AFTER=$(md5sum build/mesa/out/libvulkan_panfrost.so 2>/dev/null | cut -d' ' -f1)
echo "=== lib md5 before=$BEFORE after=$AFTER ==="
strings build/mesa/out/libvulkan_panfrost.so 2>/dev/null | grep -m1 "Mesa 2"
