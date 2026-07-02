// SPDX-License-Identifier: GPL-2.0
/*
 * felix_usb_host - automatic USB host-mode bring-up for the Pixel Fold
 *                  (felix / gs201), driving the MAX77759 over i2c.
 *
 * Mainline has no MAX77759 TCPC/TCPM glue, so a USB device attached to the
 * single Type-C connector never reaches the dwc3 host controller: the vendor
 * USB2 data switch is never closed, no CC role is presented, and VBUS is never
 * sourced -- xhci PORTSC.CCS stays 0.
 *
 * This module reproduces, from the running kernel, the host-mode enable
 * sequence reverse-engineered from the AOSP tcpci_max77759 driver:
 *
 *   1. present Rp on the CC lines            (ROLE_CONTROL, source role)
 *   2. detect the attached sink's orientation (CC_STATUS)
 *   3. set the plug orientation              (TCPC_CONTROL)
 *   4. close the vendor USB2 data switch     (TCPC_VENDOR_USBSW_CTRL=CONNECT)
 *      -> this is THE step mainline omits; it routes D+/D- to dwc3
 *   5. source VBUS via the charger OTG reverse-boost (CHG_CNFG_00 MODE=OTG)
 *
 * A poll thread re-applies on hot-plug (sink attach) and tears the path down on
 * detach. This is a bring-up shim, not a USB-PD stack; the proper fix is the
 * mainline tcpci_maxim + TCPM port with a real connector/role-switch. It exists
 * to make felix USB host mode work automatically today, hub-free.
 *
 * All addresses are on i2c-0 (usi@10d600c0 / hsi2c14, the MAX77759 bus).
 */
#include <linux/module.h>
#include <linux/i2c.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/kthread.h>

#define FELIX_I2C_BUS		0
#define MAX77759_TCPC_ADDR	0x25
#define MAX77759_CHG_ADDR	0x69

/* --- TCPCI standard registers (MAX77759 is TCPCI-compliant) --- */
#define TCPC_CONTROL		0x19
#define  TCPC_CTRL_ORIENT_CC2	BIT(0)	/* PlugOrientation: 0=CC1, 1=CC2/flipped */
#define ROLE_CONTROL		0x1A
#define  ROLE_RP_BOTH		0x05	/* CC1=Rp, CC2=Rp, RP=default, DRP=0 (source) */
#define CC_STATUS		0x1D
#define  CC1_STATE(v)		(((v) >> 0) & 0x3)
#define  CC2_STATE(v)		(((v) >> 2) & 0x3)
#define  CC_STATE_RD		0x2	/* while presenting Rp: sink (Rd) detected */
#define POWER_STATUS		0x1E
#define  PWR_VBUS_PRESENT	BIT(2)
#define VENDOR_ID		0x00
#define  MAX77759_VENDOR_ID_LO	0x6A

/* --- MAX77759 vendor registers --- */
#define TCPC_VENDOR_USBSW_CTRL	0x93
#define  USBSW_CONNECT		0x09	/* route USB2 D+/D- to the SoC controller */
#define  USBSW_DISCONNECT	0x00

/* --- MAX77759 charger (0x69) --- */
#define CHG_CNFG_00		0xB9
#define  CHG_MODE_MASK		0x0F
#define  CHG_MODE_ALL_OFF	0x00
#define  CHG_MODE_OTG_BOOST_ON	0x0A	/* reverse boost: source VBUS out */

#define FELIX_POLL_MS		500

static struct i2c_client *tcpc;
static struct i2c_client *chg;
static struct task_struct *poll_thread;
static bool path_up;

static inline int reg_read(struct i2c_client *c, u8 reg)
{
	return i2c_smbus_read_byte_data(c, reg);
}

static inline int reg_write(struct i2c_client *c, u8 reg, u8 val)
{
	return i2c_smbus_write_byte_data(c, reg, val);
}

/* True if a sink (Rd) is presented on either CC line (device attached). */
static bool sink_attached(int cc_status)
{
	if (cc_status < 0)
		return false;
	return CC1_STATE(cc_status) == CC_STATE_RD ||
	       CC2_STATE(cc_status) == CC_STATE_RD;
}

static void felix_host_enable(void)
{
	int cc, tc, chg_mode;

	/* 1. Present Rp so the port acts as a source and detects a sink. */
	reg_write(tcpc, ROLE_CONTROL, ROLE_RP_BOTH);
	msleep(50);

	cc = reg_read(tcpc, CC_STATUS);
	if (cc < 0) {
		pr_err("felix_usb_host: CC_STATUS read failed (%d)\n", cc);
		return;
	}

	/* 2/3. Set plug orientation from whichever CC sees the sink's Rd. */
	tc = reg_read(tcpc, TCPC_CONTROL);
	if (tc < 0)
		tc = 0;
	tc &= ~TCPC_CTRL_ORIENT_CC2;
	if (CC2_STATE(cc) == CC_STATE_RD)
		tc |= TCPC_CTRL_ORIENT_CC2;		/* flipped */
	reg_write(tcpc, TCPC_CONTROL, tc);

	/* 4. Close the vendor USB2 data switch -- the step mainline omits. */
	reg_write(tcpc, TCPC_VENDOR_USBSW_CTRL, USBSW_CONNECT);

	/* 5. Source VBUS via charger OTG. The reverse-boost only engages on a
	 * fresh mode transition, so cycle OFF -> OTG. (Inhibited while the
	 * charger sees valid CHGIN, e.g. a back-feeding powered hub.)
	 */
	reg_write(chg, CHG_CNFG_00, CHG_MODE_ALL_OFF);
	msleep(20);
	reg_write(chg, CHG_CNFG_00, CHG_MODE_OTG_BOOST_ON);
	msleep(30);

	chg_mode = reg_read(chg, CHG_CNFG_00);
	pr_info("felix_usb_host: host path UP (CC_STATUS=0x%02x orient=%s USBSW=CONNECT CHG_CNFG_00=0x%02x POWER_STATUS=0x%02x)\n",
		cc, (tc & TCPC_CTRL_ORIENT_CC2) ? "CC2" : "CC1",
		chg_mode, reg_read(tcpc, POWER_STATUS));
}

static void felix_host_disable(void)
{
	reg_write(tcpc, TCPC_VENDOR_USBSW_CTRL, USBSW_DISCONNECT);
	reg_write(chg, CHG_CNFG_00, CHG_MODE_ALL_OFF);
	pr_info("felix_usb_host: host path DOWN\n");
}

static int felix_poll_fn(void *data)
{
	while (!kthread_should_stop()) {
		bool sink = sink_attached(reg_read(tcpc, CC_STATUS));

		if (sink && !path_up) {
			felix_host_enable();
			path_up = true;
		} else if (!sink && path_up) {
			felix_host_disable();
			path_up = false;
		}
		msleep(FELIX_POLL_MS);
	}
	return 0;
}

static int __init felix_usb_host_init(void)
{
	struct i2c_adapter *adap;
	int vid;

	adap = i2c_get_adapter(FELIX_I2C_BUS);
	if (!adap) {
		pr_err("felix_usb_host: i2c adapter %d not found\n", FELIX_I2C_BUS);
		return -ENODEV;
	}

	tcpc = i2c_new_dummy_device(adap, MAX77759_TCPC_ADDR);
	chg = i2c_new_dummy_device(adap, MAX77759_CHG_ADDR);
	i2c_put_adapter(adap);

	if (IS_ERR(tcpc) || IS_ERR(chg)) {
		pr_err("felix_usb_host: could not claim i2c clients (0x25/0x69)\n");
		goto err;
	}

	vid = reg_read(tcpc, VENDOR_ID);
	if (vid != MAX77759_VENDOR_ID_LO)
		pr_warn("felix_usb_host: unexpected TCPC VENDOR_ID 0x%02x (want 0x%02x)\n",
			vid, MAX77759_VENDOR_ID_LO);

	/*
	 * Present Rp up front. At boot ROLE_CONTROL defaults to 0x0a (presenting
	 * Rd/sink), and CC_STATUS only reports an attached sink's Rd while WE
	 * present Rp -- so the poll loop's sink_attached() can never trip until
	 * the port is a source. Assert Rp once here; the poll then sees the sink
	 * on the next cycle and runs the full enable (which re-asserts Rp).
	 */
	reg_write(tcpc, ROLE_CONTROL, ROLE_RP_BOTH);
	msleep(50);
	pr_info("felix_usb_host: presented Rp; CC_STATUS=0x%02x\n",
		reg_read(tcpc, CC_STATUS));

	poll_thread = kthread_run(felix_poll_fn, NULL, "felix_usb_host");
	if (IS_ERR(poll_thread)) {
		pr_err("felix_usb_host: failed to start poll thread\n");
		goto err;
	}

	pr_info("felix_usb_host: loaded; watching CC for host-mode enable\n");
	return 0;

err:
	if (!IS_ERR_OR_NULL(tcpc))
		i2c_unregister_device(tcpc);
	if (!IS_ERR_OR_NULL(chg))
		i2c_unregister_device(chg);
	return -ENODEV;
}

static void __exit felix_usb_host_exit(void)
{
	if (poll_thread)
		kthread_stop(poll_thread);
	if (path_up)
		felix_host_disable();
	if (!IS_ERR_OR_NULL(tcpc))
		i2c_unregister_device(tcpc);
	if (!IS_ERR_OR_NULL(chg))
		i2c_unregister_device(chg);
	pr_info("felix_usb_host: unloaded\n");
}

module_init(felix_usb_host_init);
module_exit(felix_usb_host_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Christopher L. Crutchfield");
MODULE_DESCRIPTION("Automatic USB host-mode bring-up for Pixel Fold (felix/gs201) via MAX77759");
