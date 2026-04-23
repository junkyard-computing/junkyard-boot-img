.PHONY: all clean clean_image

# This Makefile is driven by the justfile; most variables come in via env.
# Targets with a leading "." are sentinel files that track whether a stage has
# completed successfully, so reruns skip already-finished work.

RELEASE ?= trixie
ROOT_PW ?= 0000
HOSTNAME ?= fold
# felix's super partition is 2082816 × 4096B = 8136.9 MiB; 8100M leaves a small
# margin so fastboot doesn't reject on a slightly-oversized image.
SIZE ?= 8100M
SYSROOT_DIR ?= rootfs/sysroot
KERNEL_SOURCE_DIR ?= kernel/source
KERNEL_BUILD_DIR ?= $(KERNEL_SOURCE_DIR)/out/felix/dist
APT_PACKAGES_FILE ?= rootfs/packages.txt
MODULE_ORDER_PATH ?= rootfs/module_order.txt
ROOTFS_IMG ?= boot/rootfs.img
MKBOOTIMG ?= tools/mkbootimg/mkbootimg.py
BAZEL ?= kernel/source/tools/bazel
OVERLAY_DIR ?= rootfs/overlay
VENDOR_FIRMWARE_STAGE ?= rootfs/vendor-firmware/extracted

OVERLAY_FILES := $(shell find $(OVERLAY_DIR) -type f 2>/dev/null)

# Running `make` directly bypasses the env vars set by the justfile (notably
# KERNEL_VERSION, which is read from kernel/kernel_version). Always go through
# `just all` so those are in scope.
all:
	@echo "Use 'just all' instead so KERNEL_VERSION and friends are exported."
	@just --list

.create_image:
	mkdir -p $(SYSROOT_DIR)
	sudo fallocate -l $(SIZE) $(ROOTFS_IMG)
	sudo mkfs.ext4 -F -L rootfs $(ROOTFS_IMG)
	touch $@

.debootstrap: .create_image
	just mount_rootfs
	sudo debootstrap --variant=minbase --include=symlinks --arch=arm64 --foreign $(RELEASE) $(SYSROOT_DIR)
	sudo systemd-nspawn -D $(SYSROOT_DIR) debootstrap/debootstrap --second-stage
	sudo systemd-nspawn -D $(SYSROOT_DIR) symlinks -cr .
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c "echo root:$(ROOT_PW) | chpasswd"
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c "echo $(HOSTNAME) > /etc/hostname"
	just unmount_rootfs
	touch $@

.build_kernel: kernel/custom_defconfig_mod/BUILD.bazel kernel/custom_defconfig_mod/custom_defconfig
	cd $(KERNEL_SOURCE_DIR); $(BAZEL) run \
		--config=use_source_tree_aosp \
		--config=stamp \
		--config=felix \
		--defconfig_fragment=//custom_defconfig_mod:custom_defconfig \
		//private/devices/google/felix:gs201_felix_dist
	@echo "Updating kernel version string"
	strings $(KERNEL_BUILD_DIR)/Image | grep "Linux version" | head -n 1 | awk '{print $$3}' > kernel/kernel_version
	touch $@

.sync_vendor_firmware:
	just sync_vendor_firmware
	touch $@

.install_vendor_firmware: .debootstrap .sync_vendor_firmware
	just mount_rootfs
	sudo mkdir -p $(SYSROOT_DIR)/vendor/firmware
	sudo rsync -a $(VENDOR_FIRMWARE_STAGE)/firmware/ $(SYSROOT_DIR)/vendor/firmware/
	just unmount_rootfs
	touch $@

.install_packages: .debootstrap $(APT_PACKAGES_FILE) $(OVERLAY_FILES)
	just mount_rootfs
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c "apt-get update"
	# Locale setup.
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c \
		"DEBIAN_FRONTEND=noninteractive apt-get -y install locales apt-utils"
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c \
		"export DEBIAN_FRONTEND=noninteractive; \
		sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
		&& dpkg-reconfigure locales \
		&& update-locale en_US.UTF-8"
	# Packages from rootfs/packages.txt.
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c \
		"DEBIAN_FRONTEND=noninteractive apt-get -y install $(APT_PACKAGES)"
	# Prefer NetworkManager over dhcpcd and pre-seed a DHCP ethernet profile.
	sudo systemd-nspawn -D $(SYSROOT_DIR) systemctl disable dhcpcd
	sudo systemd-nspawn -D $(SYSROOT_DIR) systemctl enable NetworkManager
	sudo systemd-nspawn -D $(SYSROOT_DIR) sh -c \
		"nmcli --offline connection add type ethernet con-name default_connection ipv4.method auto autoconnect true \
		> /etc/NetworkManager/system-connections/default_connection.nmconnection"
	sudo systemd-nspawn -D $(SYSROOT_DIR) chmod 600 /etc/NetworkManager/system-connections/default_connection.nmconnection
	# Apply tracked overlay (usb_gadget, blacklist.conf, custom service, ...).
	sudo rsync -a $(OVERLAY_DIR)/ $(SYSROOT_DIR)/
	just unmount_rootfs
	touch $@

.install_kernel: .build_kernel .install_packages
	just mount_rootfs
	sudo mkdir -p $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)
	sudo cp $(KERNEL_BUILD_DIR)/modules.builtin $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/
	sudo cp $(KERNEL_BUILD_DIR)/modules.builtin.modinfo $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/
	sudo rm -f $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/modules.order
	sudo touch $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/modules.order
	@echo "Copying modules"
	for staging in vendor_dlkm system_dlkm; \
	do \
		sudo mkdir -p rootfs/unpack/"$$staging" && \
		sudo tar \
			-xvzf $(KERNEL_BUILD_DIR)/"$$staging"_staging_archive.tar.gz \
			-C rootfs/unpack/"$$staging"; \
		sudo rsync -avK --ignore-existing --include='*/' --include='*.ko' --exclude='*' rootfs/unpack/"$$staging"/ $(SYSROOT_DIR)/; \
		sudo sh -c "cat rootfs/unpack/\"$$staging\"/lib/modules/$(KERNEL_VERSION)/modules.order \
			>> $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/modules.order"; \
	done
	@echo "Updating System.map"
	sudo cp $(KERNEL_BUILD_DIR)/System.map $(SYSROOT_DIR)/boot/System.map-$(KERNEL_VERSION)
	@echo "Updating module dependencies"
	sudo systemd-nspawn -D $(SYSROOT_DIR) depmod \
		--errsyms \
		--all \
		--filesyms /boot/System.map-$(KERNEL_VERSION) \
		$(KERNEL_VERSION)
	@echo "Copying kernel headers"
	sudo mkdir -p rootfs/unpack/kernel_headers
	sudo tar \
		-xvzf $(KERNEL_BUILD_DIR)/kernel-headers.tar.gz \
		-C rootfs/unpack/kernel_headers
	sudo cp -r rootfs/unpack/kernel_headers $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION)
	sudo ln -rsf $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION) $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/build
	sudo cp $(KERNEL_BUILD_DIR)/kernel_aarch64_Module.symvers $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION)/
	sudo cp $(KERNEL_BUILD_DIR)/vmlinux.symvers $(SYSROOT_DIR)/usr/src/linux-headers-$(KERNEL_VERSION)/
	@echo "Writing dracut force-drivers list"
	sudo rm -f $(MODULE_ORDER_PATH)
	sudo sh -c "cat $(KERNEL_BUILD_DIR)/vendor_kernel_boot.modules.load | xargs -I {} \
		modinfo -b $(SYSROOT_DIR) -k $(KERNEL_VERSION) -F name \"$(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/{}\" \
		> $(MODULE_ORDER_PATH)"
	sudo sh -c "cat $(KERNEL_BUILD_DIR)/vendor_dlkm.modules.load | xargs -I {} \
		modinfo -b $(SYSROOT_DIR) -k $(KERNEL_VERSION) -F name \"$(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/{}\" \
		>> $(MODULE_ORDER_PATH)"
	sudo sh -c "cat $(KERNEL_BUILD_DIR)/system_dlkm.modules.load | xargs -I {} \
		modinfo -b $(SYSROOT_DIR) -k $(KERNEL_VERSION) -F name \"$(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/{}\" \
		>> $(MODULE_ORDER_PATH)"
	# Strip blacklisted modules so dracut --force-drivers doesn't pull them
	# into the initramfs despite /etc/modprobe.d/blacklist.conf.
	sudo sed -i '/^bcmdhd4389$$/d; /^exynos_mfc$$/d' $(MODULE_ORDER_PATH)
	just unmount_rootfs
	touch $@

.install_initramfs: .install_kernel .install_packages
	just mount_rootfs
	sudo systemd-nspawn -D $(SYSROOT_DIR) dracut \
		--kver $(KERNEL_VERSION) \
		--lz4 \
		--show-modules \
		--force \
		--add "rescue bash" \
		--kernel-cmdline "rd.shell" \
		--force-drivers "$$(tr '\n' ' ' < $(MODULE_ORDER_PATH))"
	just unmount_rootfs
	touch $@

.build_boot: .install_initramfs .install_vendor_firmware
	$(MKBOOTIMG) \
		--kernel $(KERNEL_BUILD_DIR)/Image.lz4 \
		--cmdline "root=/dev/disk/by-partlabel/super" \
		--header_version 4 \
		-o boot/boot.img \
		--pagesize 2048 \
		--os_version 15.0.0 \
		--os_patch_level 2025-02
	just mount_rootfs
	sudo $(MKBOOTIMG) \
		--ramdisk_name "" \
		--vendor_ramdisk_fragment $(INITRAMFS_PATH) \
		--dtb $(KERNEL_BUILD_DIR)/dtb.img \
		--header_version 4 \
		--vendor_boot boot/vendor_boot.img \
		--pagesize 2048 \
		--os_version 15.0.0 \
		--os_patch_level 2025-02
	just unmount_rootfs
	touch $@

clean_image:
	just unmount_rootfs
	rm -f $(ROOTFS_IMG)
	rm -f .create_image .debootstrap .install_vendor_firmware .install_packages .install_kernel .install_initramfs .build_boot

clean: clean_image
	rm -f boot/boot.img boot/vendor_boot.img
	sudo rm -rf rootfs/unpack
