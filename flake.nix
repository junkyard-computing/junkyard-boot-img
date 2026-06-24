{
  description = "Pixel Fold (felix / gs201) Debian boot-img build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Cross-capable Rust toolchains for building tools/pixel-bootctl to aarch64.
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
          # Rust toolchain for cross-building tools/pixel-bootctl to a fully
          # static aarch64-musl binary. Static musl means zero runtime deps, so
          # the binary runs unchanged on the Debian rootfs regardless of its
          # glibc/loader (an earlier glibc cross-build baked a Nix-store
          # ld-linux path and failed to exec on-device with 203/EXEC).
          # `targets` adds the aarch64-musl std lib alongside the host std — the
          # host std is still needed so clap's proc-macro derive compiles for the
          # build machine. No external C cross-linker is required: the Makefile's
          # .build_pixel_bootctl target links via the toolchain's bundled
          # rust-lld, so the same `cargo build` line also works on non-Nix hosts
          # that have rustup's aarch64-unknown-linux-musl target installed.
          rustToolchain = pkgs.rust-bin.stable.latest.minimal.override {
            targets = [ "aarch64-unknown-linux-musl" ];
          };
        in
        {
          # Default: clean shell for the mainline kbuild track, the rootfs
          # stages, image packaging, and flashing.
          default = pkgs.mkShell {
            packages = buildToolsFor pkgs ++ [ rustToolchain ];
            nativeBuildInputs = [ crossCC ];
            shellHook = ''
              export ARCH=arm64
              export CROSS_COMPILE=${crossPrefix}
              echo "felix build shell — ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE"
              echo
              echo "Full build on NixOS, one command (external sudo-capable terminal):  nix run .#build"
              echo "Kernel build alone (kleaf needs the FHS env):  nix run .#bazel-fhs -- -c 'just build_kernel'"
              echo "Open-GPU Mesa (felix-g710 fork, arm64 trixie container):  nix run .#build-mesa"
              echo
              echo "NOTE — system-level prerequisites a flake CANNOT provide (set in your NixOS host / krg-nixos-flakes):"
              echo "  • binfmt for foreign-arch debootstrap:  boot.binfmt.emulatedSystems = [ \"aarch64-linux\" ];"
              echo "  • passwordless sudo for mount_rootfs / systemd-nspawn stages"
              echo "  • udev/plugdev access for fastboot (flash-fastboot.sh)"
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

      # One-command NixOS build. Nix lives ONLY here, so the Makefile/justfile stay
      # portable (non-Nix hosts still build with a plain `just all`). The kernel build
      # runs in the FHS env — kleaf execs /bin/bash and /usr/bin/env python3 with a
      # sanitized PATH, and only real FHS files satisfy that (envfs resolves on exec
      # but not on the stat() that `env`/bash do, so python3 isn't found). Everything
      # else runs in the normal env where sudo works. Run from an external,
      # sudo-capable terminal (VSCode terminals block sudo):  nix run .#build
      apps = eachSystem (pkgs:
        let
          fhs = fhsFor pkgs;
          felix-build = pkgs.writeShellApplication {
            name = "felix-build";
            runtimeInputs = buildToolsFor pkgs ++ [ pkgs.procps ];
            text = ''
              echo "[felix-build] 1/2 — kernel build in FHS env (kleaf needs real /bin/bash + /usr/bin/python3)"
              # A bazel server started outside the FHS env (e.g. a prior plain `just all`)
              # persists and runs actions in the non-FHS mount namespace, so an FHS build
              # reuses it and fails `execvp(/bin/bash): No such file`. `bazel shutdown` from
              # inside FHS doesn't reliably reach it, so kill this repo's bazel server here
              # (host ns) to force a fresh one inside FHS. Harmless if none is running.
              pkill -f "$PWD/kernel/source/out/bazel" 2>/dev/null || true
              "${fhs}/bin/felix-bazel-fhs" -c 'just build_kernel'
              echo "[felix-build] 2/2 — rootfs/boot in normal env (kernel cached; needs sudo + aarch64 binfmt)"
              just all
            '';
          };

          # Build the junkyard-computing/mesa `felix-g710` fork (Panfrost +
          # rusticl OpenCL + PanVK, with the Mali-G710 model entry) for the
          # device. The build runs in an arm64 Debian *trixie* container so the
          # libs link against the same glibc/LLVM-19 as the felix rootfs — a
          # pure-nix cross build would bake /nix/store paths the Debian rootfs
          # can't resolve. Needs system docker + the aarch64-linux binfmt the
          # NixOS host registers (boot.binfmt.emulatedSystems).
          build-mesa = pkgs.writeShellApplication {
            name = "build-mesa-g710";
            runtimeInputs = [ pkgs.git pkgs.docker-client pkgs.gnutar pkgs.coreutils ];
            text = ''
              REPO="$PWD"
              FORK="''${MESA_FORK_URL:-https://github.com/junkyard-computing/mesa.git}"
              BRANCH="''${MESA_FORK_BRANCH:-felix-g710}"
              WORK="$REPO/build/mesa"; SRC="$WORK/src"; OUT="$WORK/out"
              mkdir -p "$WORK/build" "$OUT"
              echo "[build-mesa] fork=$FORK branch=$BRANCH -> $WORK"
              if [ -d "$SRC/.git" ]; then
                git -C "$SRC" fetch --depth 1 origin "$BRANCH"
                git -C "$SRC" checkout -B "$BRANCH" FETCH_HEAD
              else
                rm -rf "$SRC"; git clone --depth 1 --branch "$BRANCH" "$FORK" "$SRC"
              fi
              echo "[build-mesa] building in arm64 trixie container (slow under qemu)…"
              docker run --rm --platform linux/arm64 \
                -v /nix/store:/nix/store:ro \
                -v "$SRC":/src/mesa \
                -v "$WORK/build":/src/build \
                -v "$OUT":/src/out \
                -v "$REPO/tools/build-mesa/build-in-container.sh":/build.sh:ro \
                arm64v8/debian:trixie-slim bash /build.sh
              tar -C "$OUT" -czf "$WORK/mesa-g710-libs.tgz" .
              echo "[build-mesa] done -> $WORK/mesa-g710-libs.tgz"; ls -la "$OUT"
              echo "[build-mesa] deploy: untar the tgz into /opt/mesa-g710/lib on the device;"
              echo "             ICD /opt/mesa-g710/rusticl-g710.icd -> libRusticlOpenCL.so.1"
            '';
          };
        in
        {
          build = {
            type = "app";
            program = "${felix-build}/bin/felix-build";
          };
          build-mesa = {
            type = "app";
            program = "${build-mesa}/bin/build-mesa-g710";
          };
        });

      formatter = eachSystem (pkgs: pkgs.nixpkgs-fmt);
    };
}
