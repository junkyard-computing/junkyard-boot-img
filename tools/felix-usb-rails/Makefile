# Out-of-tree build of felix_usb_rails against the exact mainline kernel that is
# running on the device (kernel/source built with O=out).
obj-m += felix_usb_rails.o

KDIR ?= /home/chris/Repos/school/krg/junkyard/jboot-mainline/kernel/source
KOUT ?= $(KDIR)/out
ARCH ?= arm64
CROSS_COMPILE ?= aarch64-unknown-linux-gnu-

default:
	$(MAKE) -C $(KDIR) O=$(KOUT) M=$(CURDIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

clean:
	$(MAKE) -C $(KDIR) O=$(KOUT) M=$(CURDIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) clean
