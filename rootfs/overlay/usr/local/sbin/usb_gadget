#!/bin/sh
mkdir /sys/kernel/config/usb_gadget/g1
mkdir /sys/kernel/config/usb_gadget/g1/strings/0x409
echo 0x18D1 > /sys/kernel/config/usb_gadget/g1/idVendor
echo 0xD001 > /sys/kernel/config/usb_gadget/g1/idProduct
echo "Google" > /sys/kernel/config/usb_gadget/g1/strings/0x409/manufacturer
echo "DEADC0FFE" > /sys/kernel/config/usb_gadget/g1/strings/0x409/serialnumber
echo "Fold" > /sys/kernel/config/usb_gadget/g1/strings/0x409/product
mkdir /sys/kernel/config/usb_gadget/g1/functions/ncm.usb0
mkdir /sys/kernel/config/usb_gadget/g1/configs/c.1
mkdir -p /sys/kernel/config/usb_gadget/g1/configs/c.1/strings/0x409
echo "USB network" > /sys/kernel/config/usb_gadget/g1/configs/c.1/strings/0x409/configuration
ln -s /sys/kernel/config/usb_gadget/g1/functions/ncm.usb0 /sys/kernel/config/usb_gadget/g1/configs/c.1/
echo 11210000.dwc3 > /sys/kernel/config/usb_gadget/g1/UDC
