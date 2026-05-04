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
KERNEL_BUILD_DIR ?= $(KERNEL_SOURCE_DIR)/out
KERNEL_DEFCONFIG ?= defconfig
KERNEL_CROSS_COMPILE ?= aarch64-linux-gnu-
# Relative path inside $(KERNEL_BUILD_DIR) to the compiled felix device tree.
KERNEL_DTB ?= arch/arm64/boot/dts/exynos/google/gs201-felix.dtb
APT_PACKAGES_FILE ?= rootfs/packages.txt
MODULE_ORDER_PATH ?= rootfs/module_order.txt
ROOTFS_IMG ?= boot/rootfs.img
MKBOOTIMG ?= tools/mkbootimg/mkbootimg.py
OVERLAY_DIR ?= rootfs/overlay
VENDOR_FIRMWARE_STAGE ?= rootfs/vendor-firmware/extracted

# Standard out-of-tree kbuild invocation. O=out keeps build artifacts under
# kernel/source/out/ so the submodule's worktree stays clean.
KMAKE := $(MAKE) -C $(KERNEL_SOURCE_DIR) ARCH=arm64 CROSS_COMPILE=$(KERNEL_CROSS_COMPILE) O=out

OVERLAY_FILES := $(shell find $(OVERLAY_DIR) -type f 2>/dev/null)

# Pre-built aarch64 binary copied into the overlay tree by .build_pixel_devinfo.
# Source-of-truth lives in the tools/pixel-devinfo submodule
# (github.com/junkyard-computing/pixel-devinfo). Used by the
# mark-slot-successful systemd unit to clear the bootloader's slot retry
# counter so the device doesn't fall into fastboot after a few boots.
PIXEL_DEVINFO_DIR ?= tools/pixel-devinfo
PIXEL_DEVINFO_TARGET ?= aarch64-unknown-linux-gnu
PIXEL_DEVINFO_BIN ?= $(PIXEL_DEVINFO_DIR)/target/$(PIXEL_DEVINFO_TARGET)/release/pixel-devinfo
PIXEL_DEVINFO_OVERLAY ?= $(OVERLAY_DIR)/usr/local/bin/pixel-devinfo
PIXEL_DEVINFO_SOURCES := $(wildcard $(PIXEL_DEVINFO_DIR)/Cargo.toml $(PIXEL_DEVINFO_DIR)/Cargo.lock $(PIXEL_DEVINFO_DIR)/src/*.rs)

# --resolv-conf=bind-host overrides the container's /etc/resolv.conf for the
# lifetime of the nspawn session. Packages.txt installs systemd-resolved,
# whose postinst points /etc/resolv.conf at a stub that only resolves when
# systemd-resolved is running (it isn't, under nspawn). Without this flag,
# any nspawn call after that postinst loses DNS, including reruns.
# --register=no + --keep-unit let nspawn run inside containers that don't have
# systemd-machined / a unit manager (e.g. tools/dockershell), and are harmless
# on a host with full systemd. dbus must be reachable; tools/dockershell starts
# a system dbus on container entry.
NSPAWN := sudo systemd-nspawn --register=no --keep-unit --resolv-conf=bind-host

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
	$(NSPAWN) -D $(SYSROOT_DIR) debootstrap/debootstrap --second-stage
	$(NSPAWN) -D $(SYSROOT_DIR) symlinks -cr .
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c "echo root:$(ROOT_PW) | chpasswd"
	$(NSPAWN) -D $(SYSROOT_DIR) sh -c "echo $(HOSTNAME) > /etc/hostname"
	just unmount_rootfs
	touch $@

.build_kernel: kernel/custom_defconfig_mod/felix.config
	$(KMAKE) $(KERNEL_DEFCONFIG)
	# Merge the felix fragment on top of the mainline defconfig: forces
	# VA_BITS=48 / no-LPA2 and turns off ARMv8.5+ extensions the GS201 cores
	# don't implement. Without this the kernel hangs silently in head.S MMU
	# setup (before earlycon is up) and the platform watchdog reboots.
	KCONFIG_CONFIG=$(KERNEL_BUILD_DIR)/.config \
		$(KERNEL_SOURCE_DIR)/scripts/kconfig/merge_config.sh -m -O $(KERNEL_BUILD_DIR) \
		$(KERNEL_BUILD_DIR)/.config $(CURDIR)/kernel/custom_defconfig_mod/felix.config
	$(KMAKE) olddefconfig
	# DTC_FLAGS=-@ makes dtc emit the __symbols__ node into the compiled dtbs.
	# Without it, the felix bootloader refuses to boot because its factory
	# dtbo partition's phandle fixups can't resolve against a symbol-less dtb
	# (ufdt_overlay_do_fixups: "No node __symbols__ in main dtb").
	$(KMAKE) -j$(shell nproc) DTC_FLAGS=-@ Image modules dtbs
	lz4 -f -9 $(KERNEL_BUILD_DIR)/arch/arm64/boot/Image $(KERNEL_BUILD_DIR)/arch/arm64/boot/Image.lz4
	@echo "Updating kernel version string"
	cat $(KERNEL_BUILD_DIR)/include/config/kernel.release > kernel/kernel_version
	touch $@

.sync_vendor_firmware:
	just sync_vendor_firmware
	touch $@

.install_vendor_firmware: .debootstrap .sync_vendor_firmware
	just mount_rootfs
	sudo mkdir -p $(SYSROOT_DIR)/vendor/firmware
	sudo rsync -a $(VENDOR_FIRMWARE_STAGE)/firmware/ $(SYSROOT_DIR)/vendor/firmware/
	# Panthor (Mali-G710 CSF) requests 'arm/mali/arch10.8/mali_csffw.bin'
	# relative to firmware_class.path=/vendor/firmware. The felix OTA ships
	# the file as /vendor/firmware/mali_csffw-r54p2.bin (and a few older
	# versions). Symlink the newest into the path panthor expects.
	sudo mkdir -p $(SYSROOT_DIR)/vendor/firmware/arm/mali/arch10.8
	sudo ln -sf ../../../mali_csffw-r54p2.bin \
		$(SYSROOT_DIR)/vendor/firmware/arm/mali/arch10.8/mali_csffw.bin
	just unmount_rootfs
	touch $@

.build_pixel_devinfo: $(PIXEL_DEVINFO_SOURCES)
	cd $(PIXEL_DEVINFO_DIR) && \
		CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=$(KERNEL_CROSS_COMPILE)gcc \
		cargo build --release --target $(PIXEL_DEVINFO_TARGET)
	$(KERNEL_CROSS_COMPILE)strip $(PIXEL_DEVINFO_BIN)
	mkdir -p $(dir $(PIXEL_DEVINFO_OVERLAY))
	install -m 0755 $(PIXEL_DEVINFO_BIN) $(PIXEL_DEVINFO_OVERLAY)
	touch $@

.install_packages: .debootstrap .build_pixel_devinfo $(APT_PACKAGES_FILE) $(OVERLAY_FILES)
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
	# Stage modules_install output into rootfs/unpack/ so kbuild runs unprivileged,
	# then sudo-rsync into the mounted sysroot to match the ownership pattern used
	# elsewhere in this pipeline. rootfs/unpack/ is typically root-owned from
	# earlier stages, so we prep the staging subdir with sudo+chown before
	# invoking kbuild unprivileged.
	sudo rm -rf rootfs/unpack/modules_install
	sudo mkdir -p rootfs/unpack/modules_install
	sudo chown $$(id -u):$$(id -g) rootfs/unpack/modules_install
	$(KMAKE) INSTALL_MOD_PATH=$(CURDIR)/rootfs/unpack/modules_install modules_install
	sudo rsync -a rootfs/unpack/modules_install/lib/modules/ $(SYSROOT_DIR)/lib/modules/
	sudo cp $(KERNEL_BUILD_DIR)/System.map $(SYSROOT_DIR)/boot/System.map-$(KERNEL_VERSION)
	@echo "Updating module dependencies"
	$(NSPAWN) -D $(SYSROOT_DIR) depmod \
		--errsyms \
		--all \
		--filesyms /boot/System.map-$(KERNEL_VERSION) \
		$(KERNEL_VERSION)
	@echo "Writing dracut force-drivers list"
	# Walk every installed *.ko(.xz|.zst) and ask modinfo for its canonical module
	# name; that avoids having to strip compression suffixes ourselves. Blacklist
	# filter mirrors /etc/modprobe.d/blacklist.conf so dracut doesn't pull those
	# modules into the initramfs (where the modprobe.d blacklist doesn't yet apply).
	sudo sh -c 'find $(SYSROOT_DIR)/lib/modules/$(KERNEL_VERSION)/kernel -type f -name "*.ko*" -exec modinfo -F name {} + > $(MODULE_ORDER_PATH)'
	sudo sed -i '/^bcmdhd4389$$/d; /^exynos_mfc$$/d' $(MODULE_ORDER_PATH)
	just unmount_rootfs
	touch $@

.install_initramfs: .install_kernel .install_packages .install_vendor_firmware
	just mount_rootfs
	# Bundle aoc.bin into the initramfs at the path firmware_class.path
	# (/vendor/firmware, set by the dtb's /chosen/bootargs) points at.
	# Without it, the AOC coprocessor retry-loops in dracut and starves
	# UART RX, so emergency-shell keystrokes are dropped.
	$(NSPAWN) -D $(SYSROOT_DIR) dracut \
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
	# Kernel cmdline.
	#   earlycon=exynos4210,mmio32,0x10A00000  UART0 output using the bootloader's
	#                                          divider setup (polled, no reprogramming)
	#   keep_bootcon                           keep earlycon attached even after a
	#                                          full console registers — important
	#                                          if samsung_tty registers and then
	#                                          panics, otherwise printk goes silent
	#                                          and the only signal is the APC
	#                                          early-watchdog reboot 60s later
	#   root=...                               rootfs location (super partition)
	#   firmware_class.path=/vendor/firmware   replaces the stock felix dtb's
	#                                          /chosen/bootargs entry; without it
	#                                          AOC retry-loops and starves UART RX.
	#   rd.udev.children-max=1                 (h14) Serialize udev workers in
	#                                          dracut/initrd. Workaround for the
	#                                          (h6) PWM SBFES wedge: when udev's
	#                                          coldplug burst fires 4 parallel
	#                                          scsi_id INQUIRYs + 2x 64KB READ_10
	#                                          back-to-back, the controller's bus
	#                                          state breaks. Serializing should
	#                                          let each command drain before the
	#                                          next is queued. Remove once HS-Rate-B
	#                                          works (controller can handle the
	#                                          parallel storm at HS speed).
	#
	# No console=ttySAC0,115200 — samsung_tty stays disabled in gs201-felix.dts
	# until we have a working serial-getty story (tentative attempt with a 200 MHz
	# fixed-clock stub for clk_uart_baud0 produced an APC-early-watchdog bootloop;
	# bisect pending).
	$(MKBOOTIMG) \
		--kernel $(KERNEL_BUILD_DIR)/arch/arm64/boot/Image.lz4 \
		--cmdline "earlycon=exynos4210,mmio32,0x10A00000 keep_bootcon root=/dev/disk/by-partlabel/super firmware_class.path=/vendor/firmware kvm-arm.mode=protected rd.udev.children-max=1 loglevel=8 ignore_loglevel" \
		--header_version 4 \
		-o boot/boot.img \
		--pagesize 2048 \
		--os_version 15.0.0 \
		--os_patch_level 2025-02
	just mount_rootfs
	sudo $(MKBOOTIMG) \
		--ramdisk_name "" \
		--vendor_ramdisk_fragment $(INITRAMFS_PATH) \
		--dtb $(KERNEL_BUILD_DIR)/$(KERNEL_DTB) \
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
