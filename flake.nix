{
  description = "Pixel Fold (felix / gs201) Debian boot-img build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

      # Everything the build host needs, grouped by build stage.
      buildToolsFor = pkgs: with pkgs; [
        # --- orchestration ---
        just
        gnumake
        git
        git-repo            # `repo` — AOSP kernel manifest sync (just clone_kernel_source)

        # --- rootfs image + debootstrap ---
        debootstrap
        e2fsprogs           # mkfs.ext4  (main / mainline rootfs)
        btrfs-progs         # mkfs.btrfs (feature/btrfs-root)
        dosfstools
        util-linux          # mount/losetup helpers
        rsync
        qemu                # qemu-aarch64 user-mode (foreign-arch 2nd-stage debootstrap; see binfmt note)

        # --- vendor firmware / OTA extraction ---
        curl
        unzip
        xxd
        erofs-utils         # fsck.erofs for the vendor partition
        android-tools       # fastboot, adb, simg2img

        # --- kernel build deps (mainline kbuild + AOSP/kleaf host tools) ---
        python3             # kleaf's cache_dir_config_tags etc. bootstrap via `/usr/bin/env python3`
        perl                # kleaf hermetic-tools host_tools = [bash perl rsync sh]
        bc
        bison
        flex
        openssl
        (pkgs.lib.getDev openssl)
        elfutils
        ncurses             # nconfig (just config_kernel)
        pkg-config
        cpio
        kmod                # depmod
        dtc                 # device tree compiler
        lz4
        zstd
        gzip
      ];

      # AOSP / Bazel track (`main`, `feature/btrfs-root`): the vendored
      # kernel/source/tools/bazel downloads hermetic prebuilt toolchains and
      # kleaf py_binaries that expect a standard FHS layout (/usr/bin/python3,
      # /lib64/ld-linux, ...), which a plain nix shell does not provide. This FHS
      # env supplies those so the Bazel build's sandboxed actions resolve.
      fhsFor = pkgs: pkgs.buildFHSEnv {
        name = "felix-bazel-fhs";
        targetPkgs = p: (buildToolsFor p) ++ (with p; [
          coreutils which gnutar gzip xz zip unzip file diffutils
          gcc binutils zlib
        ]);
        runScript = "bash";
        profile = ''
          export ARCH=arm64
          echo "felix AOSP/Bazel FHS shell — run 'just build_kernel' here (then 'just all' in the default shell)"
        '';
      };
    in
    {
      devShells = eachSystem (pkgs:
        let
          # aarch64 Linux cross toolchain for the *mainline* kbuild path
          # (the AOSP/Bazel path brings its own hermetic toolchain).
          crossCC = pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc;
          crossPrefix = crossCC.targetPrefix; # "aarch64-unknown-linux-gnu-"
        in
        {
          # Default: clean shell for the mainline kbuild track, the rootfs
          # stages, image packaging, and flashing.
          default = pkgs.mkShell {
            packages = buildToolsFor pkgs;
            nativeBuildInputs = [ crossCC ];
            shellHook = ''
              export ARCH=arm64
              export CROSS_COMPILE=${crossPrefix}
              echo "felix build shell — ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE"
              echo
              echo "AOSP/Bazel kernel build (main / btrfs-root): use the FHS shell instead —"
              echo "  nix develop .#bazel        (interactive)   or   nix run .#bazel-fhs -- -c 'just build_kernel'"
              echo
              echo "NOTE — system-level prerequisites a flake CANNOT provide (set in your NixOS host / krg-nixos-flakes):"
              echo "  • binfmt for foreign-arch debootstrap:  boot.binfmt.emulatedSystems = [ \"aarch64-linux\" ];"
              echo "  • passwordless sudo for mount_rootfs / systemd-nspawn stages"
              echo "  • udev/plugdev access for fastboot (flash.sh)"
            '';
          };

          # Interactive FHS shell for the AOSP/Bazel kernel build:
          #   nix develop .#bazel   then   just build_kernel
          bazel = (fhsFor pkgs).env;
        });

      # Scriptable/non-interactive FHS entry for the AOSP/Bazel build:
      #   nix run .#bazel-fhs -- -c 'just build_kernel'
      #   nix run .#bazel-fhs                       (drops into an FHS bash)
      packages = eachSystem (pkgs: {
        bazel-fhs = fhsFor pkgs;
      });

      formatter = eachSystem (pkgs: pkgs.nixpkgs-fmt);
    };
}
