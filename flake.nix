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

      # Rust toolchain for cross-building tools/pixel-bootctl + tools/pixel-ota to
      # fully static aarch64-musl binaries. Static musl means zero runtime deps, so
      # the binary runs unchanged on the Debian rootfs regardless of its glibc/loader
      # (an earlier glibc cross-build baked a Nix-store ld-linux path and failed to
      # exec on-device with 203/EXEC). `targets` adds the aarch64-musl std lib
      # alongside the host std — the host std is still needed so clap's proc-macro
      # derive compiles for the build machine. No external C cross-linker is
      # required: .build_pixel_bootctl links via the toolchain's bundled rust-lld,
      # so the same `cargo build` line also works on non-Nix hosts that have
      # rustup's aarch64-unknown-linux-musl target installed.
      #
      # ★ This belongs in buildToolsFor, NOT in devShells.default alone. It lived
      # there, and buildToolsFor is the list that BOTH other entry points use — the
      # `nix run .#build` app and the bazel FHS env. So the one-command build ran an
      # hour of kernel, then died several stages later on a bare
      # "sh: line 2: cargo: not found", while `nix develop` built the same tree
      # fine. It only surfaces when a pixel-* submodule gitlink moves and
      # re-triggers the cross-build, which is why it hid for so long.
      rustToolchainFor = pkgs: pkgs.rust-bin.stable.latest.minimal.override {
        targets = [ "aarch64-unknown-linux-musl" ];
      };

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

        # --- flashing over the network ---
        openssh             # ssh/scp for flash-ssh.sh
        nmap                # host discovery for flash-nmap.sh

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

        # --- on-device A/B + OTA tools (.build_pixel_bootctl / .build_pixel_ota) ---
        (rustToolchainFor pkgs)
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
          echo "gs201 AOSP/Bazel FHS shell — run 'just device=<dev> build_kernel' here (then 'just <dev>' in the default shell)"
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
          # (rustToolchainFor now lives in buildToolsFor — see the note there for
          # why keeping it here alone broke `nix run .#build`.)
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
              echo "junkyard build shell (felix + lynx) — ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE"
              echo
              echo "Build (external sudo-capable terminal):"
              echo "    nix run .#build                  every device"
              echo "    nix run .#build -- felix         one device"
              echo "    nix run .#build -- lynx"
              echo "Kernel alone (kleaf needs the FHS env):"
              echo "    nix run .#bazel-fhs -- -c 'just device=<dev> build_kernel'"
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
      # portable (non-Nix hosts still build with a plain `just <device>`). The kernel build
      # runs in the FHS env — kleaf execs /bin/bash and /usr/bin/env python3 with a
      # sanitized PATH, and only real FHS files satisfy that (envfs resolves on exec
      # but not on the stat() that `env`/bash do, so python3 isn't found). Everything
      # else runs in the normal env where sudo works. Run from an external,
      # sudo-capable terminal (VSCode terminals block sudo):  nix run .#build
      apps = eachSystem (pkgs:
        let
          fhs = fhsFor pkgs;
          # No argument means EVERY device. Naming devices builds those:
          #   nix run .#build                  -> all devices
          #   nix run .#build -- lynx          -> lynx
          #   nix run .#build -- felix         -> felix
          #   nix run .#build -- felix lynx    -> both, explicitly
          #
          # ★ There is deliberately no default device. felix and lynx are equal
          # citizens, and a default is a preference: it decides, silently, which
          # device a bare command operates on. That matters most where the answer
          # is destructive or expensive — a defaulted build is a wasted hour, a
          # defaulted flash is a wrong image on real hardware.
          #
          # The loop is per-device rather than one `just all`, because phase 1 can
          # only put ONE device's kernel through the FHS env; `just all` inside it
          # would run the other device's kernel build in phase 2's normal env,
          # where kleaf cannot work.
          devices = [ "felix" "lynx" ];
          junkyard-build = pkgs.writeShellApplication {
            name = "junkyard-build";
            runtimeInputs = buildToolsFor pkgs ++ [ pkgs.procps ];
            text = ''
              ALL_DEVICES="${pkgs.lib.concatStringsSep " " devices}"
              if [ "$#" -gt 0 ]; then
                TARGETS="$*"
                for d in $TARGETS; do
                  case " $ALL_DEVICES " in
                    *" $d "*) ;;
                    *) echo "unknown device '$d' (known: $ALL_DEVICES)" >&2; exit 2 ;;
                  esac
                done
              else
                TARGETS="$ALL_DEVICES"
              fi
              echo "[junkyard-build] building:$(for d in $TARGETS; do printf ' %s' "$d"; done)"
              for DEVICE in $TARGETS; do
                echo "[junkyard-build] $DEVICE 1/2 — kernel build in FHS env (kleaf needs real /bin/bash + /usr/bin/python3)"
                # A bazel server started outside the FHS env (e.g. a prior plain
                # `just felix`) persists and runs actions in the non-FHS mount
                # namespace, so an FHS build reuses it and fails
                # `execvp(/bin/bash): No such file`. `bazel shutdown` from inside
                # FHS doesn't reliably reach it, so kill this repo's bazel server
                # here (host ns) to force a fresh one inside FHS. Harmless if none
                # is running. Per-device path — trees are kernel/source-<device>/.
                pkill -f "$PWD/kernel/source-$DEVICE/out/bazel" 2>/dev/null || true
                "${fhs}/bin/felix-bazel-fhs" -c "just device=$DEVICE build_kernel"
                echo "[junkyard-build] $DEVICE 2/2 — rootfs/boot in normal env (kernel cached; needs sudo + aarch64 binfmt)"
                # The device recipe re-runs .build_kernel, but phase 1 just touched
                # its sentinel, so make skips it and the FHS-built kernel is used.
                just "$DEVICE"
              done
            '';
          };
        in
        {
          build = {
            type = "app";
            program = "${junkyard-build}/bin/junkyard-build";
          };
        });

      formatter = eachSystem (pkgs: pkgs.nixpkgs-fmt);
    };
}
