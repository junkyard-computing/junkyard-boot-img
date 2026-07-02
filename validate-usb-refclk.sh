#!/bin/sh
# validate-usb-refclk.sh — on-device check for the gs201 USB SS-PHY refclk fix
# (commit "clk: gs101: fix gs201 USB SS-PHY refclk"): PLL_USB 614.4 MHz ÷32 =
# 19.2 MHz, fed to the PHY "ref" from the real cmu_hsi0 gate.
#
# Run on the mainline slot-A build after boot. For the MMIO reads it needs
# felixprobe at /tmp/felixprobe (push it first with uartfs). clk_summary alone
# already validates most of the fix, so the script still prints if it's absent.
set -u
FP=/tmp/felixprobe

echo "==================== USB refclk validation ===================="
echo "kernel: $(uname -r)"

echo
echo "--- [1] clk_summary: USB/HSI0 refclk chain ---"
echo "    WANT: fout_usb_pll=614400000, dout_hsi0_usb=19200000,"
echo "          mout_hsi0_usb31drd=19200000 (=> mux index 0 selected),"
echo "          ...ref_clk_40=19200000 with enable_cnt>=1 (=> PHY enabled the real gate)"
if sudo test -r /sys/kernel/debug/clk/clk_summary; then
	sudo grep -iE 'usb_pll|hsi0_usb|usb31drd|ref_clk_40|oscclk' \
		/sys/kernel/debug/clk/clk_summary
else
	echo "    clk_summary not readable (debugfs mounted? running as root?)"
fi

echo
echo "--- [2] cmu_hsi0 MUX_CLK_HSI0_USB31DRD select @0x11001008 ---"
echo "    WANT bits[1:0]=00 (index 0 = PLL/32 path). (redundant with [1].)"
sudo "$FP" mmio read 0x11001008 4 2>&1 || echo "    felixprobe mmio unavailable"

echo
echo "--- [3] SS PMA (base 0x110F0000, NOT 0x11100000 — pcs/pma were swapped) ---"
echo "    LCPLL lock  @0x110F0700 (WANT != 0; observed 0xd5 when locked)"
sudo "$FP" mmio read 0x110F0700 4 2>&1 || echo "    felixprobe mmio unavailable"
echo "    CMN_REG0027 @0x110F009C (WANT != 0; observed 0x82 => PMA config latched)"
sudo "$FP" mmio read 0x110F009C 4 2>&1 || true
echo "    COMBO_PMA_CTRL @0x11200048 (reg_phy+0x48, NOT in the PMA region; observed 0x100 = ref_freq_sel + resets released)"
sudo "$FP" mmio read 0x11200048 4 2>&1 || true

echo
echo "--- [4] dmesg: USB PHY / dwc3 / refclk (WANT no -71/-EINVAL, phy probe ok) ---"
sudo dmesg | grep -iE 'usbdrd|dwc3|exynos.*phy|phy.*usb|lcpll|refclk|-71|EPROTO|error -[0-9]+' | tail -30

echo
echo "--- [5] UDC / xhci / enumeration ---"
echo "udc: $(ls /sys/class/udc/ 2>/dev/null || echo none)"
sudo dmesg | grep -iE 'xhci|new .*USB device|device descriptor|Cannot enable' | tail -15
echo "==================== end ===================="
