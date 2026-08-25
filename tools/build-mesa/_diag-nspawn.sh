#!/usr/bin/env bash
cd /work
echo "=== overmount /run with fresh tmpfs ==="
sudo mount -t tmpfs tmpfs /run
sudo mkdir -p /run/systemd
just unmount_rootfs 2>/dev/null || true
just mount_rootfs
sudo rm -f rootfs/sysroot/root/marker.txt
sudo tools/nspawn-wrap.sh rootfs/sysroot -- --resolv-conf=bind-host \
  -D rootfs/sysroot bash -c 'echo XYZZY > /root/marker.txt; sync' 2>&1 | tail -2
sudo cat rootfs/sysroot/root/marker.txt 2>/dev/null && echo ">>> PAYLOAD RAN with tmpfs /run" || echo ">>> still broken"
just unmount_rootfs 2>/dev/null || true
