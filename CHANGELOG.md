# Changelog

## [1.3.0](https://github.com/junkyard-computing/junkyard-boot-img/compare/v1.2.0...v1.3.0) (2026-06-21)


### Features

* **gpu:** add encrypted ARM NDA Mali Vulkan/OpenCL blobs ([768745f](https://github.com/junkyard-computing/junkyard-boot-img/commit/768745f7a9694932bc9521d7e92f9213d7c07b2d))
* **gpu:** ARM NDA blob encryption pipeline + Mali Vulkan/OpenCL loaders ([236968f](https://github.com/junkyard-computing/junkyard-boot-img/commit/236968fd0ea5c320eb41893bf6fe0e83fd6e59aa))

## [1.2.0](https://github.com/junkyard-computing/junkyard-boot-img/compare/v1.1.0...v1.2.0) (2026-06-21)


### Features

* add flash-ssh.sh in-place OTA path; rename flash.sh -&gt; flash-fastboot.sh ([e239aac](https://github.com/junkyard-computing/junkyard-boot-img/commit/e239aacd45072aedf53858c26169f223b16188c4))
* **rootfs:** add 90rootfs-flash dracut module for in-place super reflash ([31c3bbb](https://github.com/junkyard-computing/junkyard-boot-img/commit/31c3bbb0e360c41c810ff0441d61ad02edb3b7ce))
* **rootfs:** replace pixel-devinfo with pixel-bootctl + pixel-ota; show boot slot on login ([b0998c0](https://github.com/junkyard-computing/junkyard-boot-img/commit/b0998c0f9b2e47667c39df0ffc9f9bff6fb60748))


### Documentation

* plan for kube + ceph cluster roles ([425d965](https://github.com/junkyard-computing/junkyard-boot-img/commit/425d9656502259bdf3883bfc2ba031ac19a722f3))
* plan for kube + garage cluster roles ([5c46510](https://github.com/junkyard-computing/junkyard-boot-img/commit/5c4651020ab4fb268108695b3705341c3bc62c05))
* switch cluster storage role from ceph to garage ([2ba9ae1](https://github.com/junkyard-computing/junkyard-boot-img/commit/2ba9ae1fe6638df5b92bcc4c8fec0bbf36baffb3))

## [1.1.0](https://github.com/junkyard-computing/junkyard-boot-img/compare/v1.0.0...v1.1.0) (2026-06-04)


### Features

* **rootfs:** truthful kernel-bound image version + dongle MAC on login ([afb9e10](https://github.com/junkyard-computing/junkyard-boot-img/commit/afb9e10c6cc0eab02609e832ac6cafadf17a5b1d))
* **rootfs:** truthful kernel-bound image version + dongle MAC on login ([db70af2](https://github.com/junkyard-computing/junkyard-boot-img/commit/db70af2cebb76390cb4ba0ce0596ac5659893d9a))

## 1.0.0 (2026-06-03)


### Features

* **build:** show image version on login + reproducible package/kernel pins ([e4b7034](https://github.com/junkyard-computing/junkyard-boot-img/commit/e4b70348e60d6012846f89ea91c8215a5a0ef6c2))
* fix some build errors and add gitignore ([64e8576](https://github.com/junkyard-computing/junkyard-boot-img/commit/64e8576e49eab41dc92604dd07d7479884f38563))
* flash felix dtbo, enable UART getty, expose USB NCM ([f797244](https://github.com/junkyard-computing/junkyard-boot-img/commit/f797244fc42346a6df24822457b64e0ee08edeb8))
* install vendor firmware to fix UART keystroke drops ([5388b06](https://github.com/junkyard-computing/junkyard-boot-img/commit/5388b06cba8bcd363b21332beeaac370429b0ab5))
* kube kernel modules are now built. ([3095279](https://github.com/junkyard-computing/junkyard-boot-img/commit/3095279b2d8700b5453b10820e80c0487fa39721))
* pull changes from Gabe's upstream repo.  Not all changes are pulled yet. ([2a474f3](https://github.com/junkyard-computing/junkyard-boot-img/commit/2a474f323fa34b3d288d21dd31317d138d1cce72))
* pull in some of Eric's changes as well. ([5ce9dd5](https://github.com/junkyard-computing/junkyard-boot-img/commit/5ce9dd573d10367cf9f8a8ebc3462eed80a546bf))
* **rootfs:** enlarge the kmscon console font ([349fb7b](https://github.com/junkyard-computing/junkyard-boot-img/commit/349fb7bdfacec616d850223f20ca9f05dd7f5490))
* **rootfs:** mark A/B slot successful on boot to stop fastboot fallback ([5af3aeb](https://github.com/junkyard-computing/junkyard-boot-img/commit/5af3aeb46be2f539a70c11cc3c2c2a874cd7ab7f))
* **rootfs:** mark A/B slot successful on boot to stop fastboot fallback ([3cdd7f8](https://github.com/junkyard-computing/junkyard-boot-img/commit/3cdd7f8de5310e8c48d486311067cf411bfe2cb5))
* **rootfs:** show battery status on the login banner ([10c4e50](https://github.com/junkyard-computing/junkyard-boot-img/commit/10c4e507f2e6c175d6f6396ec16327b9ece41bfb))


### Bug Fixes

* it appears as if aoc.bin is needed for boot. ([0ffa2a1](https://github.com/junkyard-computing/junkyard-boot-img/commit/0ffa2a1cc3ae33fa3f65e98794f2b369401b362f))
* **rootfs:** apply Copilot review — sysroot safety + unconditional rprivate ([714695b](https://github.com/junkyard-computing/junkyard-boot-img/commit/714695b2f2ce3c22a593ca3df97a0ec1ee32c7ac))
* **rootfs:** build pixel-devinfo as static aarch64-musl ([ae6ac36](https://github.com/junkyard-computing/junkyard-boot-img/commit/ae6ac3678232531b15ec53a5369a76f536b30568))
* **rootfs:** make os-release version stamping idempotent ([3052041](https://github.com/junkyard-computing/junkyard-boot-img/commit/30520415385f651a97b0270eddc8bab0f7ad46fe))
* **rootfs:** make sysroot mount private and fall back to lazy unmount ([b63dde6](https://github.com/junkyard-computing/junkyard-boot-img/commit/b63dde6e082ed8e3e156d160eac1169c71743722))
* **rootfs:** patch nixpkgs-patched debootstrap script post --foreign ([c9165af](https://github.com/junkyard-computing/junkyard-boot-img/commit/c9165af28447e4ba9d18f61b8014037c05ba0d12))
* **rootfs:** route nspawn through a wrapper for systemd 260 + NixOS ([07f9db9](https://github.com/junkyard-computing/junkyard-boot-img/commit/07f9db9d65ce336ebca0b9289d6a2cb7caa71fdf))


### Build System

* add `nix run .#build` one-command NixOS build ([b2d6f75](https://github.com/junkyard-computing/junkyard-boot-img/commit/b2d6f75dcafc6f356f6184902bb58a4f317d3143))
* kill stale bazel server (host ns) before the FHS build ([369a8df](https://github.com/junkyard-computing/junkyard-boot-img/commit/369a8df5215d6fe081aba33a7448627a02f54bfb))
* **rootfs:** stop the rootfs image growing unboundedly across builds ([349f69a](https://github.com/junkyard-computing/junkyard-boot-img/commit/349f69acb7258c7356f2cf077e128058d1b2a299))
* shut down stale bazel server before the FHS kernel build ([c2ee22a](https://github.com/junkyard-computing/junkyard-boot-img/commit/c2ee22a9c36ade32f92499dde9a70897f4f69b54))


### Documentation

* add CLAUDE.md ([dc73cd1](https://github.com/junkyard-computing/junkyard-boot-img/commit/dc73cd130902f896febf6f0f3dcd6a7d551c8b82))
* **rootfs:** correct stale ext2 comment in .create_image ([d5ba694](https://github.com/junkyard-computing/junkyard-boot-img/commit/d5ba694eef61e96053b18ae9ea6160fb40aaf679))
