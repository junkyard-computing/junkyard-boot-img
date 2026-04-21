#!/bin/bash
# Extract the contents of an Android partition image into a directory, auto-
# detecting the filesystem and unwrapping Android sparse-image framing.
#
# Usage: extract-partition-fs.sh <partition.img> <staging-dir>
set -euo pipefail

SRC=$1
DST=$2

if [ ! -f "$SRC" ]; then
  echo "extract-partition-fs: missing source image: $SRC" >&2
  exit 2
fi

rm -rf "$DST"
mkdir -p "$DST"

magic=$(xxd -l 4 -p "$SRC")
if [ "$magic" = "3aff26ed" ]; then
  echo "Input is an Android sparse image; converting to raw"
  if ! command -v simg2img >/dev/null 2>&1; then
    echo "extract-partition-fs: simg2img not found. Install: sudo apt install android-sdk-libsparse-utils" >&2
    exit 3
  fi
  simg2img "$SRC" "$SRC.raw"
  mv "$SRC.raw" "$SRC"
fi

if fsck.erofs --extract="$DST" "$SRC" 2>/dev/null; then
  echo "Extracted as EROFS into $DST"
  exit 0
fi

if debugfs -R "rdump / $DST" "$SRC" 2>/dev/null; then
  if [ -n "$(ls -A "$DST" 2>/dev/null)" ]; then
    echo "Extracted as ext4 into $DST"
    exit 0
  fi
fi

echo "extract-partition-fs: could not identify filesystem of $SRC" >&2
file "$SRC" >&2 || true
xxd -l 32 "$SRC" >&2 || true
exit 4
