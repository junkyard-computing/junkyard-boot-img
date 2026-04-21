# Config
_apt_packages := replace(read(join("rootfs", "packages.txt")), "\n", " ")

# Tools
_repo        := require("repo")
_debootstrap := require("debootstrap")
_rsync       := require("rsync")
_fallocate   := require("fallocate")
_mkfs_ext4   := require("mkfs.ext4")
_curl        := require("curl")
_unzip       := require("unzip")
_extract_fs  := join(justfile_directory(), "tools", "extract-partition-fs.sh")
_mkbootimg   := join(justfile_directory(), "tools", "mkbootimg", "mkbootimg.py")
_bazel       := join(justfile_directory(), "kernel", "source", "tools", "bazel")

# Factory image and extraction tooling
_felix_ota_url           := "https://dl.google.com/dl/android/aosp/felix-ota-cp1a.260405.005-7a13341e.zip"
_vendor_firmware_workdir := join(justfile_directory(), "rootfs", "vendor-firmware")
_vendor_firmware_stage   := join(_vendor_firmware_workdir, "extracted")
_payload_dumper_version  := "1.2.2"
_payload_dumper_dir      := join(justfile_directory(), "tools", "payload-dumper-go")
_payload_dumper_bin      := join(_payload_dumper_dir, "payload-dumper-go")

default:
  just --list

# Will take around 1hr
[group('kernel')]
[working-directory: 'kernel/source']
clone_kernel_source android_kernel_branch="android-gs-felix-6.1-android16":
  @echo "Cloning Android kernel from branch: {{android_kernel_branch}}"
  {{_repo}} init \
    --depth=1 \
    -u https://android.googlesource.com/kernel/manifest \
    -b {{android_kernel_branch}}
  {{_repo}} sync -j {{ num_cpus() }}

_kernel_build_dir := join(justfile_directory(), "kernel", "source", "out", "felix", "dist")
_kernel_version   := trim(read(join("kernel", "kernel_version")))

[group('kernel')]
[working-directory: 'kernel/source']
clean_kernel: clone_kernel_source
  {{_bazel}} clean --expunge

[group('kernel')]
[working-directory: 'kernel/source']
build_kernel: clone_kernel_source
  cp -r ../custom_defconfig_mod .
  {{_bazel}} run \
    --config=use_source_tree_aosp \
    --config=stamp \
    --config=felix \
    --defconfig_fragment=//custom_defconfig_mod:custom_defconfig \
    //private/devices/google/felix:gs201_felix_dist
  
  @echo "Updating kernel version string"
  strings {{join(_kernel_build_dir, "Image")}} \
    | grep "Linux version" \
    | head -n 1 \
    | awk '{print $3}' > kernel_version

_sysroot_dir := join(justfile_directory(), "rootfs", "sysroot")
_user        := env("USER")

# Debian snapshot timestamp that matches the known-good image built on
# 2025-10-30. snapshot.debian.org serves historical apt archives so we pin
# the package set bit-for-bit. Bump this when you intentionally want newer
# packages and re-verify the UART still behaves afterwards.
_deb_snapshot := "20251030T000000Z"
_deb_mirror   := "http://snapshot.debian.org/archive/debian/" + _deb_snapshot + "/"
_deb_sec_mirror := "http://snapshot.debian.org/archive/debian-security/" + _deb_snapshot + "/"

[group('rootfs')]
[working-directory: 'rootfs']
build_rootfs debootstrap_release="trixie" root_password="0000" hostname="fold":
  # First stage
  sudo rm -rf {{_sysroot_dir}}
  mkdir {{_sysroot_dir}}

  sudo debootstrap \
    --variant=minbase \
    --include=symlinks \
    --arch=arm64 --foreign {{debootstrap_release}} \
    {{_sysroot_dir}} \
    {{_deb_mirror}}

  # Second stage
  sudo chroot {{_sysroot_dir}} debootstrap/debootstrap --second-stage
  sudo chroot {{_sysroot_dir}} symlinks -cr .

  # Pin apt to the same snapshot so install_apt_packages pulls matching versions.
  # The check-valid-until=no is required because snapshot URLs serve metadata
  # whose validity has expired relative to today's clock.
  printf 'deb [check-valid-until=no] %s %s main contrib non-free non-free-firmware\ndeb [check-valid-until=no] %s %s-security main contrib non-free non-free-firmware\ndeb [check-valid-until=no] %s %s-updates main contrib non-free non-free-firmware\n' \
    '{{_deb_mirror}}' '{{debootstrap_release}}' \
    '{{_deb_sec_mirror}}' '{{debootstrap_release}}' \
    '{{_deb_mirror}}' '{{debootstrap_release}}' \
    | sudo tee {{_sysroot_dir}}/etc/apt/sources.list > /dev/null

  # Set password
  sudo chroot {{_sysroot_dir}} sh -c "echo "root:{{root_password}}" | chpasswd"
  # Set hostname
  sudo chroot {{_sysroot_dir}} sh -c "echo {{hostname}} > /etc/hostname"

  sudo chown -R {{_user}}:{{_user}} {{_sysroot_dir}}

[group('rootfs')]
[working-directory: 'rootfs']
install_apt_packages:
  sudo chroot {{_sysroot_dir}} sh -c \
    "apt-get -o Acquire::Check-Valid-Until=false update"

  # Setup locale
  sudo chroot {{_sysroot_dir}} sh -c \
    "DEBIAN_FRONTEND=noninteractive apt-get -y install locales apt-utils"
  sudo chroot {{_sysroot_dir}} sh -c \
    "export DEBIAN_FRONTEND=noninteractive; \
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
    && dpkg-reconfigure locales \
    && update-locale en_US.UTF-8"

  # Actually install packages
  sudo chroot {{_sysroot_dir}} sh -c \
    "DEBIAN_FRONTEND=noninteractive apt-get -y install {{_apt_packages}}"

_overlay_dir := join(justfile_directory(), "rootfs", "overlay")

# Pull /vendor/firmware out of the Pixel Fold (felix) factory OTA and stage it
# under rootfs/vendor-firmware/extracted/. customize_rootfs copies this tree
# into /vendor/firmware/ on the target. Cached intermediates let re-runs skip
# already-completed work.
[group('rootfs')]
sync_vendor_firmware:
  mkdir -p {{_vendor_firmware_workdir}} {{_payload_dumper_dir}}

  # One-time download of payload-dumper-go (pinned) so OTA payloads can be opened.
  [ -x {{_payload_dumper_bin}} ] || ( \
    {{_curl}} -L --fail -o {{_vendor_firmware_workdir}}/payload-dumper-go.tgz \
      "https://github.com/ssut/payload-dumper-go/releases/download/{{_payload_dumper_version}}/payload-dumper-go_{{_payload_dumper_version}}_linux_amd64.tar.gz" \
    && tar -xzf {{_vendor_firmware_workdir}}/payload-dumper-go.tgz -C {{_payload_dumper_dir}} \
    && chmod +x {{_payload_dumper_bin}} \
  )

  # Download the OTA zip once. The file is ~2GB; subsequent runs are cheap.
  [ -f {{_vendor_firmware_workdir}}/felix-ota.zip ] || \
    {{_curl}} -L --fail -o {{_vendor_firmware_workdir}}/felix-ota.zip "{{_felix_ota_url}}"

  # Pull payload.bin out of the zip.
  [ -f {{_vendor_firmware_workdir}}/payload.bin ] || \
    {{_unzip}} -o {{_vendor_firmware_workdir}}/felix-ota.zip payload.bin -d {{_vendor_firmware_workdir}}

  # Extract only the vendor partition image from the A/B OTA payload.
  [ -f {{_vendor_firmware_workdir}}/vendor.img ] || \
    (cd {{_vendor_firmware_workdir}} && {{_payload_dumper_bin}} -partitions vendor -output . payload.bin)

  # Extract the vendor partition into extracted/; filesystem type on felix
  # has changed over the years (ext4 on Android 14 builds, EROFS on some
  # others) and may also be wrapped in Android sparse framing, so the helper
  # auto-detects and handles both.
  {{_extract_fs}} {{_vendor_firmware_workdir}}/vendor.img {{_vendor_firmware_stage}}

# Apply tracked sysroot customizations from rootfs/overlay/, and install
# vendor firmware blobs extracted by sync_vendor_firmware. firmware_class.path
# on the kernel cmdline points the kernel at /vendor/firmware; without blobs
# there the AOC coprocessor retry-loops and starves UART RX enough to drop
# login-prompt keystrokes.
[group('rootfs')]
[working-directory: 'rootfs']
customize_rootfs:
  @echo "Applying overlay"
  sudo {{_rsync}} -a {{_overlay_dir}}/ {{_sysroot_dir}}/

  @echo "Installing vendor firmware"
  [ -d {{_vendor_firmware_stage}}/firmware ] || \
    ( echo "Missing vendor firmware stage at {{_vendor_firmware_stage}}/firmware — run 'just sync_vendor_firmware' first" && exit 1 )
  sudo mkdir -p {{_sysroot_dir}}/vendor/firmware
  sudo {{_rsync}} -a {{_vendor_firmware_stage}}/firmware/ {{_sysroot_dir}}/vendor/firmware/

  sudo chown -R {{_user}}:{{_user}} {{_sysroot_dir}}

_module_order_path := join(justfile_directory(), "rootfs", "module_order.txt")


[group('rootfs')]
[working-directory: 'rootfs']
update_kernel_modules_and_source:
  mkdir -p {{_sysroot_dir}}/lib/modules/{{_kernel_version}}
  cp {{_kernel_build_dir}}/modules.builtin {{_sysroot_dir}}/lib/modules/{{_kernel_version}}/
  cp {{_kernel_build_dir}}/modules.builtin.modinfo {{_sysroot_dir}}/lib/modules/{{_kernel_version}}/

  rm -f {{_sysroot_dir}}/lib/modules/{{_kernel_version}}/modules.order
  touch {{_sysroot_dir}}/lib/modules/{{_kernel_version}}/modules.order
  
  @echo "Copying modules"
  for staging in vendor_dlkm system_dlkm; \
  do \
    mkdir -p unpack/"$staging" && \
    tar \
      -xvzf {{_kernel_build_dir}}/"$staging"_staging_archive.tar.gz \
      -C unpack/"$staging"; \
    {{_rsync}} -avK --ignore-existing  --include='*/' --include='*.ko' --exclude='*' unpack/"$staging"/ {{_sysroot_dir}}/; \
    cat unpack/"$staging"/lib/modules/{{_kernel_version}}/modules.order \
      >> {{_sysroot_dir}}/lib/modules/{{_kernel_version}}/modules.order; \
  done

  @echo "Updating System.map"
  cp {{_kernel_build_dir}}/System.map {{_sysroot_dir}}/boot/System.map-{{_kernel_version}}

  @echo "Updating module dependencies"
  sudo chroot {{_sysroot_dir}} depmod \
    --errsyms \
    --all \
    --filesyms /boot/System.map-{{_kernel_version}} \
    {{_kernel_version}}

  @echo "Copying kernel headers"
  mkdir -p unpack/kernel_headers
  tar \
    -xvzf {{_kernel_build_dir}}/kernel-headers.tar.gz \
    -C unpack/kernel_headers
  cp -r unpack/kernel_headers {{_sysroot_dir}}/usr/src/linux-headers-{{_kernel_version}}
  ln -rsf {{_sysroot_dir}}/usr/src/linux-headers-{{_kernel_version}} {{_sysroot_dir}}/lib/modules/{{_kernel_version}}/build
  cp {{_kernel_build_dir}}/kernel_aarch64_Module.symvers {{_sysroot_dir}}/usr/src/linux-headers-{{_kernel_version}}/
  cp {{_kernel_build_dir}}/vmlinux.symvers {{_sysroot_dir}}/usr/src/linux-headers-{{_kernel_version}}/

  @echo "Setting systemd module load order"
  rm -f {{_module_order_path}}

  cat {{_kernel_build_dir}}/vendor_kernel_boot.modules.load | xargs -I {} \
    modinfo -b {{_sysroot_dir}} -k {{_kernel_version}} -F name "{{_sysroot_dir}}/lib/modules/{{_kernel_version}}/{}" \
    > {{_module_order_path}}
  cat {{_kernel_build_dir}}/vendor_dlkm.modules.load | xargs -I {} \
    modinfo -b {{_sysroot_dir}} -k {{_kernel_version}} -F name "{{_sysroot_dir}}/lib/modules/{{_kernel_version}}/{}" \
    >> {{_module_order_path}}
  cat {{_kernel_build_dir}}/system_dlkm.modules.load | xargs -I {} \
    modinfo -b {{_sysroot_dir}} -k {{_kernel_version}} -F name "{{_sysroot_dir}}/lib/modules/{{_kernel_version}}/{}" \
    >> {{_module_order_path}}
  
_initramfs_path := join(_sysroot_dir, "boot", "initrd.img-" + _kernel_version)

# TODO: Fix for proper root password (/etc/shadow) maybe with some post service
# Add other user (kalm)
# Add sudo and add user to sudo...
# sudo adduser <username> sudo. 
# cat /sys/class/power_supply/battery/capacity
# ADD AOC.bin thing...
# userdata fstab? mkfs if it doesn't have an image...

[working-directory: 'rootfs']
update_initramfs:
  sudo chroot {{_sysroot_dir}} dracut \
    --kver {{_kernel_version}} \
    --lz4 \
    --show-modules \
    --force \
    --add "rescue bash" \
    --kernel-cmdline "rd.shell" \
    --force-drivers "$(tr '\n' ' ' < {{_module_order_path}})"
  
  sudo chown -R {{_user}}:{{_user}} {{_sysroot_dir}}

[group('rootfs')]
[working-directory: 'boot']
create_rootfs_image size="4GiB":
  rm -f rootfs.img
  {{_fallocate}} -l {{size}} rootfs.img
  # Ownership on the sysroot tree gets flipped to the build user by earlier
  # targets (so non-sudo edits work). Flip it back to root so the baked image
  # has correct ownership for systemd-tmpfiles, NetworkManager plugin loader,
  # etc. Then flip it back to the build user so downstream targets
  # (build_boot_images reading the initrd) don't need sudo.
  sudo chown -R root:root {{_sysroot_dir}}
  sudo {{_mkfs_ext4}} -d {{_sysroot_dir}} rootfs.img
  sudo chown -R {{_user}}:{{_user}} {{_sysroot_dir}}

[group('boot')]
[working-directory: 'boot']
build_boot_images:
  {{_mkbootimg}} \
    --kernel {{_kernel_build_dir}}/Image.lz4 \
    --cmdline "root=/dev/disk/by-partlabel/super" \
    --header_version 4 \
    -o boot.img \
    --pagesize 2048 \
    --os_version 15.0.0 \
    --os_patch_level 2025-02

  {{_mkbootimg}} \
    --ramdisk_name "" \
    --vendor_ramdisk_fragment {{_initramfs_path}} \
    --dtb {{_kernel_build_dir}}/dtb.img \
    --header_version 4 \
    --vendor_boot vendor_boot.img \
    --pagesize 2048 \
    --os_version 15.0.0 \
    --os_patch_level 2025-02
