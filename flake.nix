{
  description = "Pixel Fold (felix / gs201) mainline-kernel boot-img build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Cross-capable Rust toolchain for building tools/pixel-bootctl + tools/pixel-ota
    # to a static aarch64-musl binary (.build_pixel_bootctl / .build_pixel_ota).
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems
        (s: f (import nixpkgs { system = s; overlays = [ rust-overlay.overlays.default ]; }));

      # Everything the build host needs for the *mainline* kbuild + rootfs/boot stages.
      # (Unlike `main`, this track's kernel/source is plain upstream Linux built with
      # `make`, not the AOSP kleaf/Bazel tree — so no FHS env or hermetic toolchain.)
      buildToolsFor = pkgs: with pkgs; [
        # --- orchestration ---
        just
        gnumake
        git

        # --- rootfs image + debootstrap ---
        debootstrap
        e2fsprogs           # mkfs.ext4
        dosfstools
        util-linux          # mount/losetup helpers
        rsync
        qemu                # qemu-aarch64 user-mode (foreign-arch 2nd-stage debootstrap)

        # --- vendor firmware / OTA extraction + flashing ---
        curl
        unzip
        xxd
        erofs-utils         # fsck.erofs for the vendor partition
        android-tools       # fastboot, adb, simg2img

        # --- mainline kernel build deps (kbuild) ---
        python3
        perl
        bc
        bison
        flex
        openssl
        (pkgs.lib.getDev openssl)
        elfutils            # libelf for objtool
        pahole              # CONFIG_DEBUG_INFO_BTF
        ncurses             # nconfig (just config_kernel)
        pkg-config
        cpio
        kmod                # depmod
        dtc                 # device tree compiler
        lz4                 # Image.lz4
        zstd
        gzip
      ];
    in
    {
      devShells = eachSystem (pkgs:
        let
          # aarch64 Linux cross toolchain for the mainline kbuild path. Using the
          # stdenv.cc gives `aarch64-unknown-linux-gnu-*`; native gcc (HOSTCC for
          # kbuild host tools) comes from mkShell's own stdenv.
          crossCC = pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc;
          crossPrefix = crossCC.targetPrefix; # "aarch64-unknown-linux-gnu-"
          # Static aarch64-musl Rust for the on-device pixel-bootctl / pixel-ota
          # binaries (musl = zero runtime deps; runs unchanged on the Debian rootfs).
          rustToolchain = pkgs.rust-bin.stable.latest.minimal.override {
            targets = [ "aarch64-unknown-linux-musl" ];
          };
        in
        {
          # Default: mainline kbuild, rootfs stages, image packaging, flashing.
          #   nix develop   then   just build_kernel   /   just all
          default = pkgs.mkShell {
            packages = buildToolsFor pkgs ++ [ rustToolchain ];
            nativeBuildInputs = [ crossCC ];
            shellHook = ''
              export ARCH=arm64
              export CROSS_COMPILE=${crossPrefix}
              export KERNEL_CROSS_COMPILE=${crossPrefix}
              echo "felix mainline build shell — ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE"
              echo "  kernel:  just build_kernel        (or: make .build_kernel)"
              echo "  full:    just all                 (rootfs/nspawn stages need sudo + aarch64 binfmt)"
              echo
              echo "NOTE — system-level prerequisites a flake CANNOT provide (set in the NixOS host):"
              echo "  • binfmt for foreign-arch debootstrap:  boot.binfmt.emulatedSystems = [ \"aarch64-linux\" ];"
              echo "  • passwordless sudo for mount_rootfs / systemd-nspawn stages"
              echo "  • udev/plugdev access for fastboot (flash-fastboot.sh)"
            '';
          };
        });

      formatter = eachSystem (pkgs: pkgs.nixpkgs-fmt);
    };
}
