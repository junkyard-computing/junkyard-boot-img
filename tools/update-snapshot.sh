#!/bin/bash
# Refresh the project's snapshot.debian.org pins:
#   - the Debian archive timestamp -> rootfs/debian_snapshot  (read by the
#     Makefile's SNAPSHOT/MIRROR; makes the package set reproducible)
#   - the kmscon .deb              -> rootfs/kmscon.env        (-include'd by the
#     Makefile; kmscon was dropped from trixie, so it's pinned to a permanent
#     content-addressed snapshot URL + sha256 instead of a rotting pool path)
#
# snapshot.debian.org redirects any timestamp to the canonical nearest snapshot
# (302 + Location), so we don't enumerate snapshots — we request a target instant,
# follow the redirect to the real ID, and verify the suite's Release resolves
# there before writing. The kmscon pin is resolved from the machine-readable
# binary API (the .deb's sha1 -> /file/<sha1>), then downloaded to record sha256.
#
# Usage:
#   update-snapshot.sh                 # newest snapshot + refresh kmscon
#   update-snapshot.sh --latest
#   update-snapshot.sh --date 2026-05-01   # nearest snapshot to that day
#   update-snapshot.sh 20260501T083000Z    # canonicalize/verify an exact stamp
#   update-snapshot.sh --suite sid --latest
#   update-snapshot.sh --no-kmscon         # snapshot only, leave kmscon.env
#   update-snapshot.sh --kmscon-only       # refresh kmscon.env only
#   update-snapshot.sh --kmscon-version 9.0.0-4   # pin a different kmscon version
#   update-snapshot.sh --dry-run --date 2026-05-01   # resolve + print, don't write
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="$ROOT/rootfs/debian_snapshot"
KMSCON_ENV="$ROOT/rootfs/kmscon.env"
BASE_URL="https://snapshot.debian.org/archive/debian"

SUITE="trixie"
DRY_RUN=0
TARGET=""          # YYYYMMDDTHHMMSSZ instant to ask snapshot.d.o about; empty => now
DO_SNAPSHOT=1
DO_KMSCON=1
KMSCON_VERSION="9.0.0-4"   # last kmscon in the Debian archive (dropped from trixie)
KMSCON_ARCH="arm64"

die() { echo "update-snapshot: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl not found"

while [ $# -gt 0 ]; do
  case "$1" in
    --latest)        TARGET="" ;;
    --date)
      shift; [ $# -gt 0 ] || die "--date needs an argument (YYYY-MM-DD)"
      echo "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
        || die "--date must be YYYY-MM-DD, got: $1"
      TARGET="$(echo "$1" | tr -d '-')T000000Z"
      ;;
    --suite)         shift; [ $# -gt 0 ] || die "--suite needs an argument"; SUITE="$1" ;;
    --no-kmscon)     DO_KMSCON=0 ;;
    --kmscon-only)   DO_SNAPSHOT=0 ;;
    --kmscon-version) shift; [ $# -gt 0 ] || die "--kmscon-version needs an argument"; KMSCON_VERSION="$1" ;;
    --dry-run)       DRY_RUN=1 ;;
    -h|--help)       sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    [0-9]*T[0-9]*Z)
      echo "$1" | grep -qE '^[0-9]{8}T[0-9]{6}Z$' \
        || die "explicit timestamp must be YYYYMMDDTHHMMSSZ, got: $1"
      TARGET="$1"
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

resolve_snapshot() {
  # Default target is "now" -> snapshot.d.o redirects to the most recent snapshot.
  local target="$TARGET"
  [ -n "$target" ] || target="$(date -u +%Y%m%dT%H%M%SZ)"

  echo "Resolving snapshot near $target ..." >&2
  local location new_ts code old_ts
  location="$(curl -fsS -o /dev/null -D - --max-time 60 "$BASE_URL/$target/" \
              | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r' | tail -n1)"
  [ -n "$location" ] || die "no redirect from snapshot.debian.org for $target (service down?)"

  new_ts="$(basename "$location")"
  echo "$new_ts" | grep -qE '^[0-9]{8}T[0-9]{6}Z$' \
    || die "could not parse canonical timestamp from redirect: $location"

  # Confirm the suite exists at that snapshot (follow the content-store redirect).
  code="$(curl -sL -o /dev/null -w '%{http_code}' --max-time 60 \
          "$BASE_URL/$new_ts/dists/$SUITE/Release" || true)"
  [ "$code" = "200" ] || die "suite '$SUITE' not found at snapshot $new_ts (HTTP $code)"

  old_ts="$(cat "$PIN_FILE" 2>/dev/null || true)"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "snapshot: $new_ts  (suite=$SUITE)  [dry-run, not written]"
    return 0
  fi

  printf '%s\n' "$new_ts" > "$PIN_FILE"
  if [ -n "$old_ts" ] && [ "$old_ts" != "$new_ts" ]; then
    echo "snapshot pin: $old_ts -> $new_ts"
  elif [ "$old_ts" = "$new_ts" ]; then
    echo "snapshot pin unchanged: $new_ts"
  else
    echo "snapshot pin set: $new_ts"
  fi
  echo "wrote $PIN_FILE  (suite=$SUITE)"
}

resolve_kmscon() {
  local ver="$KMSCON_VERSION" arch="$KMSCON_ARCH"
  echo "Resolving kmscon $ver ($arch) on snapshot.debian.org ..." >&2

  local json sha1 url tmp sha256
  json="$(curl -fsS --max-time 60 \
          "https://snapshot.debian.org/mr/binary/kmscon/$ver/binfiles?fileinfo=1")" \
    || die "kmscon $ver: machine-readable API request failed"

  # Pull the 40-hex sha1 of the 'debian'-archive .deb for this version+arch.
  # (dots in $ver match literally-enough; the arch + archive_name disambiguate.)
  sha1="$(printf '%s' "$json" \
    | grep -oP '"[0-9a-f]{40}":\[\{"archive_name":"debian","first_seen":"[^"]*","name":"kmscon_'"$ver"'_'"$arch"'\.deb"' \
    | grep -oP '^"\K[0-9a-f]{40}' | head -n1)"
  [ -n "$sha1" ] || die "kmscon $ver $arch: no 'debian' archive file in API (removed/renamed?)"

  url="https://snapshot.debian.org/file/$sha1"
  tmp="$(mktemp)"
  curl -fsSL --max-time 120 -o "$tmp" "$url" || { rm -f "$tmp"; die "kmscon download failed: $url"; }
  sha256="$(sha256sum "$tmp" | cut -d' ' -f1)"
  rm -f "$tmp"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "kmscon: $url  sha256=$sha256  [dry-run, not written]"
    return 0
  fi

  {
    echo "# Generated by tools/update-snapshot.sh — do not edit by hand."
    echo "# Durable content-addressed snapshot.debian.org pin for the kmscon .deb"
    echo "# ($ver $arch; kmscon was dropped from trixie). -include'd by the Makefile."
    echo "KMSCON_URL = $url"
    echo "KMSCON_SHA256 = $sha256"
  } > "$KMSCON_ENV"
  echo "wrote $KMSCON_ENV"
  echo "  KMSCON_URL    = $url"
  echo "  KMSCON_SHA256 = $sha256"
}

[ "$DO_SNAPSHOT" -eq 1 ] && resolve_snapshot
[ "$DO_KMSCON" -eq 1 ] && resolve_kmscon

if [ "$DRY_RUN" -eq 0 ]; then
  echo "Rebuild the rootfs (just clean_rootfs && just all) to pick up the new pins."
fi
