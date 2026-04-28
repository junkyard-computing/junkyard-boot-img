.PHONY: all clean clean_image

# This Makefile is driven by the justfile; most variables come in via env.
# Targets with a leading "." are sentinel files that track whether a stage has
# completed successfully, so reruns skip already-finished work.

RELEASE ?= trixie
ROOT_PW ?= 0000
USER_LOGIN ?= kalm
USER_PW ?= 0000
HOSTNAME ?= fold
# Pinned because trixie drops kmscon; snagged from the Debian pool arm64 builds.
KMSCON_URL ?= http://ftp.us.debian.org/debian/pool/main/k/kmscon/kmscon_9.0.0-4_arm64.deb
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

# --resolv-conf=bind-host overrides the container's /etc/resolv.conf for the
# lifetime of the nspawn session. Packages.txt installs systemd-resolved,
# whose postinst points /etc/resolv.conf at a stub that only resolves when
# systemd-resolved is running (it isn't, under nspawn). Without this flag,
# any nspawn call after that postinst loses DNS, including reruns.
NSPAWN := sudo systemd-nspawn --resolv-conf=bind-host

# Running `make` directly bypasses the env vars set by the justfile (notably
# KERNEL_VERSION, which is read from kernel/kernel_version). Always go through
# `just all` so those are in scope.
all:
	@echo "Use 'just all' instead so KERNEL_VERSION and friends are exported."
	@just --list

.create_image:
	mkdir -p $(SYSROOT_DIR)
	sudo fallocate -l $(SIZE) $(ROOTFS_IMG)
	sudo mkfs.btrfs -f -L rootfs $(ROOTFS_IMG)
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
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c "apt-get update"
	# Locale setup.
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"DEBIAN_FRONTEND=noninteractive apt-get -y install locales apt-utils"
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"export DEBIAN_FRONTEND=noninteractive; \
		sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
		&& dpkg-reconfigure locales \
		&& update-locale en_US.UTF-8"
	# Pre-stage the pinned kmscon .deb (trixie dropped the package) so the
	# single apt-get install below resolves its deps alongside packages.txt.
	sudo curl -L --fail -o $(SYSROOT_DIR)/var/cache/apt/archives/kmscon.deb "$(KMSCON_URL)"
	# Packages from rootfs/packages.txt plus the staged kmscon .deb.
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"DEBIAN_FRONTEND=noninteractive apt-get -y install $(APT_PACKAGES) /var/cache/apt/archives/kmscon.deb"
	# Unprivileged user with passwordless sudo. Paired with the autologin
	# override in rootfs/overlay/etc/systemd/system/kmsconvt@.service.d/.
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"id -u $(USER_LOGIN) >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo $(USER_LOGIN)"
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"echo $(USER_LOGIN):$(USER_PW) | chpasswd"
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"echo '%sudo ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-sudo-nopasswd \
		&& chmod 0440 /etc/sudoers.d/99-sudo-nopasswd"
	# Explicitly enable a getty on felix's UART console. The compiled-in
	# `console=ttynull` in CONFIG_CMDLINE masks ttySAC0 from /sys/class/tty/
	# console/active, so systemd-getty-generator won't spawn one on its own.
	$(NSPAWN) -D $(SYSROOT_DIR) systemctl enable serial-getty@ttySAC0.service
	# systemd-backlight@.service pulls felix into systemd "degraded" on every
	# boot; mask it (symlink to /dev/null) to keep `systemctl is-system-running`
	# green.
	$(NSPAWN) -D $(SYSROOT_DIR) \
		ln -sf /dev/null /etc/systemd/system/systemd-backlight@.service
	# Prefer NetworkManager over dhcpcd and pre-seed a DHCP ethernet profile.
	$(NSPAWN) -D $(SYSROOT_DIR) systemctl disable dhcpcd
	$(NSPAWN) -D $(SYSROOT_DIR) systemctl enable NetworkManager
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c \
		"nmcli --offline connection add type ethernet con-name default_connection ipv4.method auto autoconnect true \
		> /etc/NetworkManager/system-connections/default_connection.nmconnection"
	$(NSPAWN) -D $(SYSROOT_DIR) chmod 600 /etc/NetworkManager/system-connections/default_connection.nmconnection
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
	# Wipe stale .ko files from a previous kernel build before resyncing.
	# rsync below must overwrite, not skip — a previous build's modules have
	# __versions CRCs computed against the old vmlinux, so leaving them in
	# place causes every module to fail MODVERSIONS check against a freshly
	# rebuilt kernel and kicks the device into a watchdog reboot loop.
	sudo find $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION) -name '*.ko' -delete 2>/dev/null || true
	for staging in vendor_dlkm system_dlkm; \
	do \
		sudo mkdir -p rootfs/unpack/"$$staging" && \
		sudo tar \
			-xvzf $(KERNEL_BUILD_DIR)/"$$staging"_staging_archive.tar.gz \
			-C rootfs/unpack/"$$staging"; \
		sudo rsync -avK --include='*/' --include='*.ko' --exclude='*' rootfs/unpack/"$$staging"/ $(SYSROOT_DIR)/; \
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

.install_initramfs: .install_kernel .install_packages .install_vendor_firmware
	just mount_rootfs
	# Bundle aoc.bin into the initramfs at the path firmware_class.path
	# (/vendor/firmware, set by the dtb's /chosen/bootargs) points at.
	# Without it, the AOC coprocessor retry-loops in dracut and starves
	# UART RX, so emergency-shell keystrokes are dropped.
	sudo systemd-nspawn -D $(SYSROOT_DIR) dracut \
		--kver $(KERNEL_VERSION) \
		--lz4 \
		--show-modules \
		--force \
		--add "rescue bash" \
		--install /vendor/firmware/aoc.bin \
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
