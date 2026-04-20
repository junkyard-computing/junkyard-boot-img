# Config
_apt_packages := replace(read(join("rootfs", "packages.txt")), "\n", " ")

# Tools
_repo        := require("repo")
_debootstrap := require("debootstrap")
_rsync       := require("rsync")
_fallocate   := require("fallocate")
_mkfs_ext4   := require("mkfs.ext4")
_mkbootimg   := join(justfile_directory(), "tools", "mkbootimg", "mkbootimg.py")
_bazel       := join(justfile_directory(), "kernel", "source", "tools", "bazel")

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

[group('rootfs')]
[working-directory: 'rootfs']
build_rootfs debootstrap_release="stable" root_password="0000" hostname="fold":
  # First stage 
  sudo rm -rf {{_sysroot_dir}}
  mkdir {{_sysroot_dir}}

  sudo debootstrap \
    --variant=minbase \
    --include=symlinks \
    --arch=arm64 --foreign {{debootstrap_release}} \
    {{_sysroot_dir}}

  # Second stage
  sudo chroot {{_sysroot_dir}} debootstrap/debootstrap --second-stage
  sudo chroot {{_sysroot_dir}} symlinks -cr .
  
  # Set password
  sudo chroot {{_sysroot_dir}} sh -c "echo "root:{{root_password}}" | chpasswd"
  # Set hostname
  sudo chroot {{_sysroot_dir}} sh -c "echo {{hostname}} > /etc/hostname"

  sudo chown -R {{_user}}:{{_user}} {{_sysroot_dir}}

[group('rootfs')]
[working-directory: 'rootfs']
install_apt_packages:
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

_module_order_path := join(justfile_directory(), "rootfs", "module_order.txt")

# TODO: Download factory image and copy firmware
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
_module_order   := replace(read(_module_order_path), "\n", " ")

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
    --force-drivers "{{_module_order}}"
  
  sudo chown -R {{_user}}:{{_user}} {{_sysroot_dir}}

[group('rootfs')]
[working-directory: 'boot']
create_rootfs_image size="4GiB":
  rm -f rootfs.img
  {{_fallocate}} -l {{size}} rootfs.img
  sudo {{_mkfs_ext4}} -d {{_sysroot_dir}} rootfs.img

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
