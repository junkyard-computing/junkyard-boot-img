#!/bin/bash
#
# package-provisioning.sh — build the provisioning kit zip handed to whoever
# flashes the phones.
#
# Bundles provisioning/ (README + scripts), the four boot images, and Google's
# factory image, into one self-contained archive. The recipient needs nothing
# from the internet and nothing from this repo.
#
#   ./package-provisioning.sh --factory ~/Downloads/felix-cp1a.260405.005-factory-*.zip
#
# ★ THE FACTORY IMAGE IS BUNDLED, NOT DOWNLOADED BY THE RECIPIENT, AND IT MUST
#   MATCH THE BUILD THIS REPO PINS.
#
# The rootfs ships /vendor/firmware extracted from a specific felix OTA — the
# one pinned as _felix_ota_url in the justfile. Those blobs are matched to the
# bootloader, radio and firmware of that same build. If the phones are flashed
# with a factory image from a different build, our vendor blobs end up paired
# with mismatched firmware. That is not a clean failure: AOC, UFS and the
# display stack all sit behind those blobs, and the symptoms would look like
# our image being broken.
#
# So this script derives the build id from the pinned OTA URL and REFUSES to
# package a factory zip that is not that build. It checks the archive contents
# rather than the filename, because a filename can be anything.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

FACTORY=""
OUT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--factory) FACTORY="${2:-}"; shift 2 ;;
		--out)     OUT="${2:-}"; shift 2 ;;
		-h|--help)
			echo "usage: $0 --factory <felix-factory.zip> [--out <kit.zip>]"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo ">>> $*"; }

# ---------------------------------------------------------------- build id ---
OTA_URL=$(grep -oP '_felix_ota_url\s*:=\s*"\K[^"]+' justfile) \
	|| die "could not read _felix_ota_url from justfile"
BUILD_ID=$(basename "$OTA_URL" | sed -n 's/^felix-ota-\([a-z0-9.]*\)-.*$/\1/p')
[ -n "$BUILD_ID" ] || die "could not derive a build id from: $OTA_URL"
say "this repo pins felix build: $BUILD_ID"

# ------------------------------------------------------------ factory image ---
[ -n "$FACTORY" ] || die "--factory <zip> is required (we ship it; the recipient must not download one)"
[ -f "$FACTORY" ] || die "no such file: $FACTORY"

command -v unzip >/dev/null || die "unzip is required to verify the factory image"

# Verify by CONTENTS. A factory zip for build X contains image-felix-X.zip; the
# outer filename is not authoritative and is routinely renamed on the way here.
say "verifying the factory image is build $BUILD_ID"
if ! unzip -l "$FACTORY" 2>/dev/null | grep -q "image-felix-${BUILD_ID}\.zip"; then
	echo "" >&2
	echo "The factory image does not contain image-felix-${BUILD_ID}.zip." >&2
	echo "It is a different build from the one this repo pins." >&2
	echo "" >&2
	echo "What it does contain:" >&2
	unzip -l "$FACTORY" 2>/dev/null | grep -oE 'image-felix-[a-z0-9.]+\.zip' | sort -u | sed 's/^/  /' >&2
	echo "" >&2
	echo "Either fetch the factory image for ${BUILD_ID}, or change _felix_ota_url" >&2
	echo "in the justfile and REBUILD — the rootfs carries vendor firmware from" >&2
	echo "the pinned build and the two have to agree." >&2
	exit 1
fi
say "factory image OK"

# ------------------------------------------------------------------ images ---
DTBO="kernel/source/out/felix/dist/dtbo.img"
for f in boot/boot.img boot/vendor_boot.img boot/super.img "$DTBO"; do
	[ -f "$f" ] || die "missing $f — build it first (see CLAUDE.md; super.img needs 'just build_super_image')"
done

# Read the version out of super.img itself — the artifact actually shipped —
# rather than from rootfs.img beside it. They are normally the same file's
# contents, but "normally" is how a stale image ships.
DEBUGFS=$(command -v debugfs || ls -d /nix/store/*e2fsprogs*/bin/debugfs 2>/dev/null | head -1)
[ -n "$DEBUGFS" ] || die "debugfs (e2fsprogs) not found — needed to read the image version"
VERSION=$("$DEBUGFS" -R 'cat /etc/image-version' boot/super.img 2>/dev/null | tr -d '\0\n')
[ -n "$VERSION" ] || die "could not read /etc/image-version from boot/super.img"
DEVICE=$("$DEBUGFS" -R 'cat /etc/image-device' boot/super.img 2>/dev/null | tr -d '\0\n')

# The README tells the operator exactly what the phone's SCREEN should say, so
# these values must come from the image being shipped — not from the working
# tree, which can have moved on since it was built.
#
# /etc/os-release is a symlink into /usr/lib, and debugfs does not follow
# symlinks, so read the real file.
BUILD_DATE_IMG=$("$DEBUGFS" -R 'cat /usr/lib/os-release' boot/super.img 2>/dev/null \
	| sed -n 's/^IMAGE_BUILD_DATE="\(.*\)"$/\1/p' | head -1)
KERNEL_VERSION=$("$DEBUGFS" -R 'ls -l /lib/modules' boot/super.img 2>/dev/null \
	| tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.')
[ -n "$KERNEL_VERSION" ] || die "could not read the kernel version from boot/super.img"

say "image version: $VERSION  (device: ${DEVICE:-unstamped})"
say "kernel version: $KERNEL_VERSION"

[ -n "$OUT" ] || OUT="junkyard-provisioning-${VERSION}.zip"
# Resolve now, so --out with an absolute or relative path both land where the
# caller meant rather than inside the staging directory.
case "$OUT" in
	/*) OUT_ABS="$OUT" ;;
	*)  OUT_ABS="$here/$OUT" ;;
esac

# Fill the README template with what this specific image will show on screen.
# The operator verifies phones by reading their displays, so a stale number here
# would have them approving the wrong image — the template exists to make that
# impossible to get wrong by hand.
render_doc() {
	local tpl="$1" out="$2"
	[ -f "$tpl" ] || die "missing $tpl"
	sed -e "s|@IMAGE_VERSION@|$VERSION|g" \
	    -e "s|@KERNEL_VERSION@|$KERNEL_VERSION|g" \
	    -e "s|@IMAGE_BUILD_DATE@|${BUILD_DATE_IMG:-unknown}|g" \
	    -e "s|@FELIX_BUILD@|$BUILD_ID|g" \
	    -e "s|@PACKAGED_DATE@|$(date -u +%Y-%m-%d)|g" \
	    "$tpl" > "$KIT/$out"
	# Leaving an unfilled @PLACEHOLDER@ in an operator-facing document is worse
	# than failing here, so treat it as a build error.
	if grep -q '@[A-Z_]*@' "$KIT/$out"; then
		echo "unfilled placeholders in $out:" >&2
		grep -o '@[A-Z_]*@' "$KIT/$out" | sort -u | sed 's/^/  /' >&2
		die "$tpl not fully rendered"
	fi
}

# ------------------------------------------------------------------- stage ---
# Preflight the staging filesystem. The zip alone is several GB and the
# uncompressed inputs are ~11 GB, so failing at 99% after twenty minutes of
# copying is a real risk worth one df call. TMPDIR is honoured so this can be
# pointed at a roomier disk — and on a host where /tmp is tmpfs, staging here
# would otherwise be written straight into RAM.
STAGE_BASE="${TMPDIR:-/tmp}"
NEED_KB=$(( 6 * 1024 * 1024 ))   # ~6 GB for the compressed archive
avail_kb=$(df -Pk "$STAGE_BASE" | awk 'NR==2 {print $4}')
if [ "${avail_kb:-0}" -lt "$NEED_KB" ]; then
	die "only $(( avail_kb / 1024 ))MB free on $STAGE_BASE; need ~$(( NEED_KB / 1024 ))MB. Set TMPDIR to a bigger disk."
fi
case "$(findmnt -no FSTYPE "$STAGE_BASE" 2>/dev/null)" in
	tmpfs|ramfs) say "WARNING: $STAGE_BASE is $(findmnt -no FSTYPE "$STAGE_BASE") (RAM) — set TMPDIR to a real disk if this struggles" ;;
esac

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
KIT="$STAGE/junkyard-provisioning"
mkdir -p "$KIT/images" "$KIT/factory"

say "staging scripts and README"
# ONE README covering both host operating systems, not one per OS. The steps are
# identical on Linux and Windows and only the command lines differ, so a second
# document would be ~60% copied prose -- and the copied part is precisely what
# the operator checks a phone against (which version string, how many minutes
# before it counts as stuck). render_doc keeps the VERSIONS in it honest; it
# cannot keep two sets of prose honest.
render_doc provisioning/README.md.in README.md
cp provisioning/*.sh  "$KIT/"
# The Windows half of the kit: PowerShell twins of the same scripts, including
# its own flash-fastboot.ps1 (there is no repo checkout on Windows to share one
# with, the way flash-fastboot.sh is shared below).
cp provisioning/*.ps1 "$KIT/"
# The kit uses the SAME flashing script as our own phones, not a copy of it.
cp flash-fastboot.sh "$KIT/"
chmod +x "$KIT"/*.sh

# SYMLINK the big inputs rather than copying them. zip follows symlinks and
# stores the target's contents by default (storing the link itself needs -y),
# and sha256sum follows them too — so the archive is identical while ~11 GB of
# pointless copying is skipped.
say "staging images"
ln -s "$here/boot/boot.img"         "$KIT/images/boot.img"
ln -s "$here/boot/vendor_boot.img"  "$KIT/images/vendor_boot.img"
ln -s "$here/boot/super.img"        "$KIT/images/super.img"
ln -s "$here/$DTBO"                 "$KIT/images/dtbo.img"
printf '%s\n' "$VERSION" > "$KIT/images/VERSION"

# EXTRACT the factory image rather than shipping the zip.
#
# A zip inside a zip means the operator has to unpack twice and guess where
# flash-all.sh ended up. Extracting it here means step 4 is just "run
# factory/flash-all.sh".
#
# ⚠ The INNER image-felix-<build>.zip stays a zip. `fastboot update` takes an
# archive, not a directory — unpacking that one would break the flash.
say "extracting the factory image"
unzip -q "$FACTORY" -d "$KIT/factory" || die "could not extract $FACTORY"

# Google's factory zips wrap everything in a single felix-<build>/ directory.
# Flatten it so the path in the README is stable regardless of that convention.
shopt -s nullglob dotglob
inner=( "$KIT/factory"/*/ )
if [ "${#inner[@]}" -eq 1 ] && [ -z "$(find "$KIT/factory" -maxdepth 1 -type f -print -quit)" ]; then
	say "flattening $(basename "${inner[0]}")/"
	mv "${inner[0]}"* "$KIT/factory/" && rmdir "${inner[0]}"
fi
shopt -u nullglob dotglob

chmod +x "$KIT/factory"/*.sh 2>/dev/null || true

# Prove the extraction produced what the operator is told to run, rather than
# assuming the archive was laid out the way we expect.
[ -f "$KIT/factory/flash-all.sh" ] \
	|| die "no flash-all.sh after extracting $FACTORY — unexpected factory image layout"
# flash-all.bat is what the Windows path runs, and it is checked with the same
# force as its shell sibling: the two READMEs are shipped side by side, so a
# factory image missing the .bat would leave a kit that only half works, and
# the half that is broken is the one nobody here tests on.
[ -f "$KIT/factory/flash-all.bat" ] \
	|| die "no flash-all.bat after extracting $FACTORY — the Windows path (README step 4) needs it"
[ -f "$KIT/factory/image-felix-${BUILD_ID}.zip" ] \
	|| die "no image-felix-${BUILD_ID}.zip after extraction — the inner archive must stay zipped for 'fastboot update'"

printf '%s\n' "$BUILD_ID" > "$KIT/factory/BUILD_ID"

# Checksums over everything, so a truncated copy is caught by the recipient
# rather than surfacing as a phone that will not boot. -type l is included
# because the big inputs are symlinks here; sha256sum reads through them, so
# the digests describe the real contents.
say "computing checksums (reads ~11G — the slow step)"
( cd "$KIT" && find . \( -type f -o -type l \) ! -name SHA256SUMS -exec sha256sum {} + \
	| sort -k2 > SHA256SUMS )

cat > "$KIT/MANIFEST.txt" <<EOF
Junkyard Debian provisioning kit
================================

image version : $VERSION
target device : ${DEVICE:-felix}
felix build    : $BUILD_ID   (factory image bundled under factory/)
packaged       : $(date -u +%Y-%m-%dT%H:%M:%SZ)

The factory image under factory/ MUST be the one used. The rootfs carries
vendor firmware extracted from this same felix build, and pairing it with a
different build's bootloader and radio produces failures that look like our
image is broken.

Verify this kit before use:
    Linux:    sha256sum -c SHA256SUMS
    Windows:  powershell -ExecutionPolicy Bypass -File .\\verify-kit.ps1

Then follow README.md from step 1. It covers both Linux and Windows; each
step gives the command for both.
EOF

# -------------------------------------------------------------------- zip ---
say "compressing (super.img is mostly empty, so it shrinks a lot)"
rm -f "$OUT"
( cd "$STAGE" && zip -r -q "$OUT_ABS" junkyard-provisioning ) || die "zip failed"

say "done: $OUT_ABS  ($(du -h "$OUT_ABS" | cut -f1))"
echo
echo "  image version : $VERSION"
echo "  felix build   : $BUILD_ID"
echo "  contents      : README.md, 6 shell + 7 PowerShell scripts, 4 images,"
echo "                  factory image, SHA256SUMS"
