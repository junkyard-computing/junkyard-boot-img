// SPDX-License-Identifier: GPL-2.0
/*
 * felix_usb_rails - force-enable the gs201 USB PHY analog rails from userspace.
 *
 * Hypothesis under test: mainline's HS -71 (USB2 device descriptor read fails)
 * is caused by the USB PHY analog supplies never being asserted.  AOSP's
 * exynos-pd_hsi0.c does regulator_enable() on four S2MPG12 LDOs at PHY
 * power-on; mainline has no S2MPG12 regulator driver and the felix DT stubs
 * these supplies as dummies, so AVDD_PLL_USB (0.85V) et al are never powered.
 * A half-powered HS PLL still lets LS/FS enumerate (keyboard works) but the
 * HS eye collapses -> -71.  This is invisible to MMIO register capture.
 *
 * The S2MPG12 main PMIC is NOT on a userspace i2c bus; it is reached over ACPM.
 * Mainline already carries the ACPM PMIC transport (acpm pmic ops + exported
 * devm_acpm_get_by_node), so this shim grabs the ACPM handle and pokes the LDO
 * enable bits directly, then re-plug the dongle to see if HS enumerates.
 *
 * Rail map (S2MPG12, PMIC page 0x01, speedy channel 0), from the AOSP
 * s2mpg12-regulator descriptors:
 *
 *   LDO8M  vdd085 (AVDD_PLL_USB, prime suspect)  enable L8M_CTRL 0x33 [7:6]=11
 *   LDO9M  vdd18                                  enable L9M_CTRL 0x34 [7:6]=11
 *   LDO10M vdd30                                  enable L10M_CTRL 0x35 [7:6]=11
 *   LDO7M  vdd_hsi                                enable LDO_CTRL1 0x48 [1:0]=11
 *
 * ACPM call convention (from mainline drivers/mfd/sec-acpm.c s2mpg1x pdata):
 *   acpm_chan_id = 2, type = 0x01 (PMIC page), chan = 0 (S2MPG12 = main).
 * acpm_chan_id=2 is the value used for gs101's s2mpg10/11; if the reads below
 * error out, that's the first thing to sweep for gs201.
 */
#include <linux/module.h>
#include <linux/device.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/err.h>
#include <linux/firmware/samsung/exynos-acpm-protocol.h>

#define ACPM_COMPAT		"google,gs201-acpm-ipc"
#define ACPM_CHAN_ID		2	/* ACPM IPC protocol channel (PMIC svc) */
#define PMIC_PAGE		0x01	/* SEC_PMIC_ACPM_ACCESSTYPE_PMIC */
#define S2MPG12_SPEEDY		0	/* main PMIC = speedy channel 0 */

struct rail_poke {
	const char *name;
	u8 reg;		/* enable register offset (PMIC page) */
	u8 mask;	/* enable field mask */
};

/* enable() writes val = enable_mask under enable_mask (all mask bits set). */
static const struct rail_poke rails[] = {
	{ "L8M/vdd085(AVDD_PLL_USB)", 0x33, 0xC0 },
	{ "L9M/vdd18",                0x34, 0xC0 },
	{ "L10M/vdd30",               0x35, 0xC0 },
	{ "L7M/vdd_hsi",              0x48, 0x03 },
};

static struct device *rail_dev;

static int __init felix_usb_rails_init(void)
{
	struct device_node *np;
	struct acpm_handle *h;
	const struct acpm_pmic_ops *pmic;
	int i, ret;
	u8 v;

	np = of_find_compatible_node(NULL, NULL, ACPM_COMPAT);
	if (!np) {
		pr_err("felix-rails: no '%s' node in DT\n", ACPM_COMPAT);
		return -ENODEV;
	}

	rail_dev = root_device_register("felix_usb_rails");
	if (IS_ERR(rail_dev)) {
		of_node_put(np);
		return PTR_ERR(rail_dev);
	}

	h = devm_acpm_get_by_node(rail_dev, np);
	of_node_put(np);
	if (IS_ERR(h)) {
		pr_err("felix-rails: acpm handle failed: %ld\n", PTR_ERR(h));
		root_device_unregister(rail_dev);
		rail_dev = NULL;
		return PTR_ERR(h);
	}
	pmic = &h->ops->pmic;

	pr_info("felix-rails: === BEFORE ===\n");
	for (i = 0; i < ARRAY_SIZE(rails); i++) {
		v = 0;
		ret = pmic->read_reg(h, ACPM_CHAN_ID, PMIC_PAGE, rails[i].reg,
				     S2MPG12_SPEEDY, &v);
		pr_info("felix-rails: %-26s reg 0x%02x = 0x%02x (ret %d)\n",
			rails[i].name, rails[i].reg, v, ret);
	}

	pr_info("felix-rails: === ENABLING ===\n");
	for (i = 0; i < ARRAY_SIZE(rails); i++) {
		ret = pmic->update_reg(h, ACPM_CHAN_ID, PMIC_PAGE, rails[i].reg,
				       S2MPG12_SPEEDY, rails[i].mask, rails[i].mask);
		pr_info("felix-rails: %-26s enable (mask 0x%02x) ret %d\n",
			rails[i].name, rails[i].mask, ret);
	}

	pr_info("felix-rails: === AFTER ===\n");
	for (i = 0; i < ARRAY_SIZE(rails); i++) {
		v = 0;
		ret = pmic->read_reg(h, ACPM_CHAN_ID, PMIC_PAGE, rails[i].reg,
				     S2MPG12_SPEEDY, &v);
		pr_info("felix-rails: %-26s reg 0x%02x = 0x%02x (ret %d)\n",
			rails[i].name, rails[i].reg, v, ret);
	}

	pr_info("felix-rails: done -- now re-plug the USB2 dongle and check for HS enumeration\n");
	return 0;
}

static void __exit felix_usb_rails_exit(void)
{
	if (rail_dev)
		root_device_unregister(rail_dev);
}

module_init(felix_usb_rails_init);
module_exit(felix_usb_rails_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("felix/gs201 USB PHY analog rail (S2MPG12 LDO) force-enable test shim");
