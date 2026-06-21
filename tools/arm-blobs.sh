#!/usr/bin/env bash
# Pack / install the ARM NDA GPU userland blobs (Mali Vulkan + OpenCL).
#
# The blobs ship under an ARM NDA and cannot be committed in the clear, so the
# repo carries only an age-encrypted tarball ($ARM_BLOBS_ENC). The tarball is a
# *rootfs-rooted overlay*: its contents are extracted at the root of the target
# rootfs, exactly like rootfs/overlay/. Arrange the source dir to mirror the
# on-device layout, e.g.:
#
#   src/
#     usr/lib/aarch64-linux-gnu/libmali.so
#     etc/OpenCL/vendors/mali.icd                 # one line: abs path to the .so
#     usr/share/vulkan/icd.d/mali_icd.json        # Vulkan ICD manifest
#
# Encryption is age (https://age-encryption.org) in MULTI-RECIPIENT mode: the
# blob is encrypted to every public key in $ARM_RECIPIENTS (SSH or age pubkeys).
# NO private key is ever shared — each builder decrypts with their OWN private
# key (their ~/.ssh/id_ed25519 by default). To add/remove a builder, edit
# $ARM_RECIPIENTS and re-pack.
#
# Crucially, a build with no usable key (not a recipient / no SSH key / blob
# absent) is a WARNING, never a failure: `install` prints a loud notice and
# exits 0 so the image still builds, just without the GPU drivers.
set -euo pipefail

SECRETS_DIR="${SECRETS_DIR:-secrets}"
ARM_BLOBS_ENC="${ARM_BLOBS_ENC:-$SECRETS_DIR/arm-mali-blobs.tar.age}"
ARM_RECIPIENTS="${ARM_RECIPIENTS:-$SECRETS_DIR/recipients.txt}"
# Optional override: a single identity (private key) file to decrypt with.
# When empty, fall back to the builder's default SSH private keys below.
ARM_NDA_KEY="${ARM_NDA_KEY:-}"

# ANSI bold yellow for the skip notices so they don't get lost in build spam.
warn() { printf '\033[1;33m[arm-blobs] %s\033[0m\n' "$*" >&2; }
info() { printf '[arm-blobs] %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[arm-blobs] error: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
	cat >&2 <<-EOF
	usage:
	  $0 pack <srcdir>     encrypt <srcdir> (a rootfs-rooted tree) to every
	                       recipient in $ARM_RECIPIENTS -> $ARM_BLOBS_ENC
	  $0 install <sysroot> decrypt (with your SSH key) + rsync into a mounted
	                       rootfs (warn-only; never fails the build)
	EOF
	exit 2
}

# Count non-comment, non-blank lines in the recipients file.
count_recipients() {
	grep -cvE '^[[:space:]]*(#|$)' "$ARM_RECIPIENTS" 2>/dev/null || echo 0
}

cmd_pack() {
	local srcdir="${1:-}"
	[ -n "$srcdir" ] || usage
	[ -d "$srcdir" ] || die "source dir '$srcdir' does not exist"
	command -v age >/dev/null || die "age not found in PATH"
	[ -f "$ARM_RECIPIENTS" ] || die "recipients file '$ARM_RECIPIENTS' missing"
	[ "$(count_recipients)" -gt 0 ] || die "no recipients in '$ARM_RECIPIENTS' — add a pubkey line first"
	if [ -z "$(find "$srcdir" -type f -print -quit)" ]; then
		die "source dir '$srcdir' is empty — nothing to pack"
	fi
	info "packing $(find "$srcdir" -type f | wc -l) file(s) for $(count_recipients) recipient(s)"
	# Deterministic-ish tar (sorted, no mtimes) so re-packing identical inputs
	# yields stable plaintext; age still randomizes the ciphertext per run.
	mkdir -p "$(dirname "$ARM_BLOBS_ENC")"
	tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
		-czf - -C "$srcdir" . \
		| age -R "$ARM_RECIPIENTS" -o "$ARM_BLOBS_ENC"
	info "wrote $ARM_BLOBS_ENC ($(du -h "$ARM_BLOBS_ENC" | cut -f1)) — commit it"
}

# Echo the -i identity flags age should decrypt with: ARM_NDA_KEY if set, else
# the builder's existing SSH private keys. Empty output => no identity found.
resolve_identities() {
	if [ -n "$ARM_NDA_KEY" ]; then
		if [ -f "$ARM_NDA_KEY" ]; then printf '%s\0%s\0' -i "$ARM_NDA_KEY"; fi
		return
	fi
	local cand
	for cand in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
		[ -f "$cand" ] && printf '%s\0%s\0' -i "$cand"
	done
}

cmd_install() {
	local sysroot="${1:-}"
	[ -n "$sysroot" ] || usage
	[ -d "$sysroot" ] || die "sysroot '$sysroot' does not exist"

	if [ ! -f "$ARM_BLOBS_ENC" ]; then
		warn "no encrypted ARM NDA blobs at '$ARM_BLOBS_ENC' — skipping GPU (Vulkan/OpenCL) driver install."
		return 0
	fi
	if ! command -v age >/dev/null; then
		warn "age not found in PATH — cannot decrypt ARM NDA blobs; skipping GPU driver install."
		return 0
	fi

	local -a ids=()
	mapfile -d '' -t ids < <(resolve_identities)
	if [ "${#ids[@]}" -eq 0 ]; then
		if [ -n "$ARM_NDA_KEY" ]; then
			warn "decryption key '$ARM_NDA_KEY' (ARM_NDA_KEY) not found."
		else
			warn "no SSH private key found (~/.ssh/id_ed25519 or id_rsa)."
			warn "Set ARM_NDA_KEY=/path/to/key to point at a specific identity."
		fi
		warn "GPU (Vulkan/OpenCL) drivers will NOT be installed. Build continues without them."
		return 0
	fi

	local tmp
	tmp="$(mktemp -d)"
	if ! age -d "${ids[@]}" "$ARM_BLOBS_ENC" 2>/dev/null | tar -xzf - -C "$tmp" 2>/dev/null; then
		rm -rf "$tmp"
		warn "could not decrypt '$ARM_BLOBS_ENC' — your key is not an authorized recipient (or the blob is corrupt)."
		warn "Ask the maintainer to add your SSH pubkey to '$ARM_RECIPIENTS' and re-pack."
		warn "Skipping GPU driver install; build continues."
		return 0
	fi

	local n
	n="$(find "$tmp" -type f | wc -l)"
	if [ "$n" -eq 0 ]; then
		rm -rf "$tmp"
		warn "decrypted blob contained no files — nothing to install."
		return 0
	fi
	info "installing $n ARM NDA GPU file(s) into rootfs:"
	(cd "$tmp" && find . -type f | sed 's/^\./  /') >&2
	# Root-owned mounted sysroot, same pattern as the overlay rsync in the Makefile.
	sudo rsync -a "$tmp"/ "$sysroot"/
	rm -rf "$tmp"
	info "ARM NDA GPU drivers installed."
}

main() {
	local sub="${1:-}"
	shift || true
	case "$sub" in
		pack)    cmd_pack "$@" ;;
		install) cmd_install "$@" ;;
		*)       usage ;;
	esac
}

main "$@"
