// SPDX-License-Identifier: GPL-2.0
/*
 * hwmon driver for HONOR MagicBook Pro 14 AI (ZQC-P / M1010) EC fan tachometers.
 *
 * The EC exposes two 16-bit little-endian RPM words in its RAM (the standard
 * 0x62/0x66 ACPI EC address space, region ECF0 in the DSDT):
 *
 *   0x2C/0x2D - fan 0 (FA0L/FA0R in the DSDT field list)
 *   0x2E/0x2F - fan 1 (FA1L/FA1R)
 *
 * The DSDT field names split each word into two 8-bit fields, which is what
 * originally led us to read them as "PWM duty + status flag". They are in fact
 * one LE word per fan: idle reads ~2280/2000 rpm, and ~3650/3270 rpm was
 * observed at 89 degC under a sustained compile load. The same offsets were
 * independently confirmed on the sibling FMB-P by
 * colorcube/Linux-on-Honor-Magicbook-14-Pro PR #21.
 *
 * Read-only by design: the EC only accepts a manual duty via SFNS when its
 * MFGM master flag is set, and MFGM is never set from any AML path. The DPTF
 * fan participant (INTC10D6, cooling_device "TFN1", 51 states) accepts writes
 * to cur_state but the EC ignores them - verified: cur_state 0 -> 50 produced
 * no change in either tachometer. Fan speed is therefore EC-autonomous.
 */

#include <linux/acpi.h>
#include <linux/dmi.h>
#include <linux/hwmon.h>
#include <linux/module.h>
#include <linux/platform_device.h>

/* Anything above this is a bad EC read rather than a real fan speed. */
#define HONOR_EC_RPM_MAX		20000

/*
 * Where the tachometers sit in EC RAM. There is no firmware method that
 * describes this, so it is pure driver knowledge and it is per model: the EC
 * layout belongs to the EC firmware, not to the platform. Hanging it off the
 * DMI match keeps a wrong offset from ever reaching a machine it was not
 * measured on.
 */
struct honor_ec_layout {
	u8 fan0_lo, fan0_hi;
	u8 fan1_lo, fan1_hi;
};

/*
 * HONOR MagicBook Pro 14 2026 (ZQC-P). Measured on this unit: ~2280 / ~2000
 * rpm at 48 degC idle, 3656 / 3276 rpm at 89 degC under a sustained compile.
 * The same offsets were confirmed independently on the sibling FMB-P
 * (colorcube PR #21), but nobody has run this driver there, so FMB-P is
 * deliberately not in the table below.
 */
static const struct honor_ec_layout honor_ec_zqcp_layout = {
	.fan0_lo = 0x2c, .fan0_hi = 0x2d,
	.fan1_lo = 0x2e, .fan1_hi = 0x2f,
};

static const struct honor_ec_layout *honor_ec_layout_cur;
static struct platform_device *honor_ec_pdev;

static int honor_ec_read_fan(u8 lo_addr, u8 hi_addr, long *rpm)
{
	u8 lo, hi;
	int ret;

	ret = ec_read(lo_addr, &lo);
	if (ret)
		return ret;
	ret = ec_read(hi_addr, &hi);
	if (ret)
		return ret;

	*rpm = (hi << 8) | lo;
	if (*rpm > HONOR_EC_RPM_MAX)
		return -EIO;

	return 0;
}

static int honor_ec_hwmon_read(struct device *dev, enum hwmon_sensor_types type,
			   u32 attr, int channel, long *val)
{
	if (type != hwmon_fan || attr != hwmon_fan_input)
		return -EOPNOTSUPP;

	switch (channel) {
	case 0:
		return honor_ec_read_fan(honor_ec_layout_cur->fan0_lo, honor_ec_layout_cur->fan0_hi, val);
	case 1:
		return honor_ec_read_fan(honor_ec_layout_cur->fan1_lo, honor_ec_layout_cur->fan1_hi, val);
	default:
		return -EOPNOTSUPP;
	}
}

static const char * const honor_ec_fan_labels[] = { "CPU fan", "System fan" };

static int honor_ec_hwmon_read_string(struct device *dev,
				  enum hwmon_sensor_types type, u32 attr,
				  int channel, const char **str)
{
	if (type != hwmon_fan || attr != hwmon_fan_label ||
	    channel >= ARRAY_SIZE(honor_ec_fan_labels))
		return -EOPNOTSUPP;

	*str = honor_ec_fan_labels[channel];
	return 0;
}

static umode_t honor_ec_hwmon_is_visible(const void *data,
				     enum hwmon_sensor_types type, u32 attr,
				     int channel)
{
	if (type == hwmon_fan && channel < ARRAY_SIZE(honor_ec_fan_labels))
		return 0444;

	return 0;
}

static const struct hwmon_channel_info * const honor_ec_hwmon_info[] = {
	HWMON_CHANNEL_INFO(fan,
			   HWMON_F_INPUT | HWMON_F_LABEL,
			   HWMON_F_INPUT | HWMON_F_LABEL),
	NULL
};

static const struct hwmon_ops honor_ec_hwmon_ops = {
	.is_visible = honor_ec_hwmon_is_visible,
	.read = honor_ec_hwmon_read,
	.read_string = honor_ec_hwmon_read_string,
};

static const struct hwmon_chip_info honor_ec_hwmon_chip_info = {
	.ops = &honor_ec_hwmon_ops,
	.info = honor_ec_hwmon_info,
};

/*
 * Gate on DMI so the module is inert on any other machine, and carry the EC
 * layout in driver_data so a new model cannot accidentally inherit another
 * one's offsets.
 *
 * Adding a model means: measure its tachometer offsets, add a layout above,
 * add an entry here, and only then mark that model's profile verified in
 * devices/. Do not add an entry on the strength of a DSDT that merely looks
 * similar.
 *
 * Note DMI_MATCH is a substring test, so an entry for "FMB-P" would also
 * catch "FMB-PM". Distinct models need distinct enough strings, or a further
 * DMI_MATCH on the board name.
 */
static const struct dmi_system_id honor_ec_dmi_table[] = {
	{
		.matches = {
			DMI_MATCH(DMI_SYS_VENDOR, "HONOR"),
			DMI_MATCH(DMI_PRODUCT_NAME, "ZQC-P"),
		},
		.driver_data = (void *)&honor_ec_zqcp_layout,
	},
	{}
};
MODULE_DEVICE_TABLE(dmi, honor_ec_dmi_table);

static int honor_ec_hwmon_probe(struct platform_device *pdev)
{
	struct device *hwmon_dev;

	hwmon_dev = devm_hwmon_device_register_with_info(&pdev->dev,
							"honor_ec", NULL,
							&honor_ec_hwmon_chip_info,
							NULL);

	return PTR_ERR_OR_ZERO(hwmon_dev);
}

static struct platform_driver honor_ec_hwmon_driver = {
	.driver = {
		.name = "honor-ec-sensors",
	},
	.probe = honor_ec_hwmon_probe,
};

static int __init honor_ec_hwmon_init(void)
{
	const struct dmi_system_id *id;
	long rpm;
	int ret;

	/*
	 * dmi_first_match rather than dmi_check_system: we need the matched
	 * entry itself, because the EC layout for this model hangs off it.
	 */
	id = dmi_first_match(honor_ec_dmi_table);
	if (!id)
		return -ENODEV;
	honor_ec_layout_cur = id->driver_data;

	/* Refuse to register if the EC does not answer plausibly. */
	ret = honor_ec_read_fan(honor_ec_layout_cur->fan0_lo, honor_ec_layout_cur->fan0_hi, &rpm);
	if (ret) {
		pr_info("honor-ec-sensors: EC fan read failed (%d), not loading\n",
			ret);
		return -ENODEV;
	}

	ret = platform_driver_register(&honor_ec_hwmon_driver);
	if (ret)
		return ret;

	honor_ec_pdev = platform_device_register_simple("honor-ec-sensors", -1,
						    NULL, 0);
	if (IS_ERR(honor_ec_pdev)) {
		platform_driver_unregister(&honor_ec_hwmon_driver);
		return PTR_ERR(honor_ec_pdev);
	}

	return 0;
}

static void __exit honor_ec_hwmon_exit(void)
{
	platform_device_unregister(honor_ec_pdev);
	platform_driver_unregister(&honor_ec_hwmon_driver);
}

module_init(honor_ec_hwmon_init);
module_exit(honor_ec_hwmon_exit);

MODULE_DESCRIPTION("HONOR MagicBook Pro 14 AI (ZQC-P) EC fan hwmon driver");
MODULE_LICENSE("GPL");
