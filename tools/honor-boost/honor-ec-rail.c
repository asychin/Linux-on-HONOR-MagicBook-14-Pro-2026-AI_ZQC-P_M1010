/*
 * honor-ec-rail — dump of the HONOR ZQC-P extended EC banks.
 *
 * The boost-relevant EC fields live in SystemMemory OperationRegions that the
 * standard ACPI EC interface (ec_sys, ports 0x62/0x66) cannot reach.  The AML
 * (DSDT.dsl) declares them as plain MMIO:
 *
 *   ECF0 @ 0xFE0B0000   CRWM @ 0x0A
 *   ECF3 @ 0xFE0B0300   SVFT @ 0xB0, GFP0/2/3/GFF0 @ 0xB2/0xB4/0xB6/0xB8
 *   ECF5 @ 0xFE0B0500   FTSL @ 0x30, FWMD @ 0x31, SCPM @ 0x32
 *   ECF6 @ 0xFE0B0600   VCCC @ 0x20, VCCG @ 0x21, VCCS @ 0x22, VCCL @ 0x23,
 *                       PPL4 @ 0x24, VRSS @ 0x25, VR10..16 @ 0x26/0x28/0x2A/0x2C,
 *                       ODP0..9 @ 0x10..0x19, PP1M/PP1R/PP2R/PP4R @ 0xC1..0xC5
 *
 * /dev/mem cannot read these on this kernel (CONFIG_IO_STRICT_DEVMEM=y), so an
 * ioremap module is the way to observe the EC banks.  All fields are read-only
 * except pp1r/pp2r/pp4r, which are writable only so the EC power budget can be
 * restored to its Smart default after an IMOK experiment (no ACPI method writes
 * them).  The module never writes anything else.
 *
 * Exposes /sys/kernel/honor-ec-rail/ with attributes.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/slab.h>
#include <linux/sysfs.h>

#define BANK_LEN 0x100

static void __iomem *ecf0;
static void __iomem *ecf3;
static void __iomem *ecf5;
static void __iomem *ecf6;

static struct kobject *rail_kobj;

static u8 rd8(void __iomem *base, unsigned int off)
{
	return readb(base + off);
}

static u16 rd16(void __iomem *base, unsigned int off)
{
	return readw(base + off);
}

/* Register/telemetry fields are emitted as bare lowercase hex ("33", "ff") so
 * the SVRF restore path in svrf-test.sh can round-trip them.  Temperature and
 * fan RPM stay decimal. */
#define RAIL_SHOW_HEX8(_name, _expr) \
	static ssize_t _name##_show(struct kobject *kobj, \
		struct kobj_attribute *attr, char *buf) \
	{ \
		return sysfs_emit(buf, "%02x\n", (unsigned)(_expr)); \
	} \
	static struct kobj_attribute _name##_attr = \
		__ATTR_RO(_name)

#define RAIL_SHOW_HEX16(_name, _expr) \
	static ssize_t _name##_show(struct kobject *kobj, \
		struct kobj_attribute *attr, char *buf) \
	{ \
		return sysfs_emit(buf, "%04x\n", (unsigned)(_expr)); \
	} \
	static struct kobj_attribute _name##_attr = \
		__ATTR_RO(_name)

#define RAIL_SHOW_DEC(_name, _expr) \
	static ssize_t _name##_show(struct kobject *kobj, \
		struct kobj_attribute *attr, char *buf) \
	{ \
		return sysfs_emit(buf, "%d\n", (int)(_expr)); \
	} \
	static struct kobj_attribute _name##_attr = \
		__ATTR_RO(_name)

/* Writable power-budget registers.  These are the EC's own PP1R/PP2R/PP4R,
 * which no ACPI method writes; the module exposes them so the budget can be
 * restored to its Smart default (0x28/0x32/0xA0) after an IMOK experiment.
 * Values are parsed as hex. */
#define RAIL_RW8(_name, _off) \
	static ssize_t _name##_show(struct kobject *kobj, \
		struct kobj_attribute *attr, char *buf) \
	{ \
		return sysfs_emit(buf, "%02x\n", (unsigned)rd8(ecf6, _off)); \
	} \
	static ssize_t _name##_store(struct kobject *kobj, \
		struct kobj_attribute *attr, const char *buf, size_t count) \
	{ \
		unsigned int v; \
		if (kstrtouint(buf, 16, &v) || v > 0xff) \
			return -EINVAL; \
		writeb((u8)v, ecf6 + _off); \
		return count; \
	} \
	static struct kobj_attribute _name##_attr = \
		__ATTR_RW(_name)

#define RAIL_RW16(_name, _off) \
	static ssize_t _name##_show(struct kobject *kobj, \
		struct kobj_attribute *attr, char *buf) \
	{ \
		return sysfs_emit(buf, "%04x\n", (unsigned)rd16(ecf6, _off)); \
	} \
	static ssize_t _name##_store(struct kobject *kobj, \
		struct kobj_attribute *attr, const char *buf, size_t count) \
	{ \
		unsigned int v; \
		if (kstrtouint(buf, 16, &v) || v > 0xffff) \
			return -EINVAL; \
		writew((u16)v, ecf6 + _off); \
		return count; \
	} \
	static struct kobj_attribute _name##_attr = \
		__ATTR_RW(_name)

RAIL_SHOW_HEX8(crwm,  rd8(ecf0, 0x0A));
RAIL_SHOW_DEC(ec_cpu_temp, rd8(ecf0, 0x10));
RAIL_SHOW_DEC(fan0, rd16(ecf0, 0x2C));
RAIL_SHOW_DEC(fan1, rd16(ecf0, 0x2E));

RAIL_SHOW_HEX8(svft, rd8(ecf3, 0xB0));

RAIL_SHOW_HEX8(ftsl, rd8(ecf5, 0x30));
RAIL_SHOW_HEX8(fwmd, rd8(ecf5, 0x31));
RAIL_SHOW_HEX8(scpm, rd8(ecf5, 0x32));

RAIL_SHOW_HEX8(vccc, rd8(ecf6, 0x20));
RAIL_SHOW_HEX8(vccg, rd8(ecf6, 0x21));
RAIL_SHOW_HEX8(vccs, rd8(ecf6, 0x22));
RAIL_SHOW_HEX8(vccl, rd8(ecf6, 0x23));
RAIL_SHOW_HEX8(ppl4, rd8(ecf6, 0x24));
RAIL_SHOW_HEX8(vrss, rd8(ecf6, 0x25));
RAIL_SHOW_HEX16(vr10, rd16(ecf6, 0x26));
RAIL_SHOW_HEX16(vr12, rd16(ecf6, 0x28));
RAIL_SHOW_HEX16(vr14, rd16(ecf6, 0x2A));
RAIL_SHOW_HEX16(vr16, rd16(ecf6, 0x2C));

/* DTT policy slots and EC power-limit registers (see boost-refactoring.md) */
RAIL_SHOW_HEX8(odp0, rd8(ecf6, 0x10));
RAIL_SHOW_HEX8(odp1, rd8(ecf6, 0x11));
RAIL_SHOW_HEX8(odp2, rd8(ecf6, 0x12));
RAIL_SHOW_HEX8(odp3, rd8(ecf6, 0x13));
RAIL_SHOW_HEX8(odp4, rd8(ecf6, 0x14));
RAIL_SHOW_HEX8(odp5, rd8(ecf6, 0x15));
RAIL_SHOW_HEX8(odp6, rd8(ecf6, 0x16));
RAIL_SHOW_HEX8(odp7, rd8(ecf6, 0x17));
RAIL_SHOW_HEX8(odp8, rd8(ecf6, 0x18));
RAIL_SHOW_HEX8(odp9, rd8(ecf6, 0x19));
RAIL_SHOW_HEX8(dttf, rd8(ecf0, 0x52) >> 7);
RAIL_SHOW_HEX8(pp1m, rd8(ecf6, 0xC1));
RAIL_RW8(pp1r, 0xC2);
RAIL_RW8(pp2r, 0xC3);
RAIL_RW16(pp4r, 0xC4);
RAIL_SHOW_HEX16(ppp1, rd16(ecf6, 0xC6));
RAIL_SHOW_HEX16(ppp2, rd16(ecf6, 0xC8));

static struct attribute *rail_attrs[] = {
	&crwm_attr.attr,
	&ec_cpu_temp_attr.attr,
	&fan0_attr.attr,
	&fan1_attr.attr,
	&svft_attr.attr,
	&ftsl_attr.attr,
	&fwmd_attr.attr,
	&scpm_attr.attr,
	&vccc_attr.attr,
	&vccg_attr.attr,
	&vccs_attr.attr,
	&vccl_attr.attr,
	&ppl4_attr.attr,
	&vrss_attr.attr,
	&vr10_attr.attr,
	&vr12_attr.attr,
	&vr14_attr.attr,
	&vr16_attr.attr,
	&odp0_attr.attr,
	&odp1_attr.attr,
	&odp2_attr.attr,
	&odp3_attr.attr,
	&odp4_attr.attr,
	&odp5_attr.attr,
	&odp6_attr.attr,
	&odp7_attr.attr,
	&odp8_attr.attr,
	&odp9_attr.attr,
	&dttf_attr.attr,
	&pp1m_attr.attr,
	&pp1r_attr.attr,
	&pp2r_attr.attr,
	&pp4r_attr.attr,
	&ppp1_attr.attr,
	&ppp2_attr.attr,
	NULL,
};

static const struct attribute_group rail_group = {
	.attrs = rail_attrs,
};

static int __init honor_ec_rail_init(void)
{
	int ret;

	ecf0 = ioremap(0xFE0B0000, BANK_LEN);
	ecf3 = ioremap(0xFE0B0300, BANK_LEN);
	ecf5 = ioremap(0xFE0B0500, BANK_LEN);
	ecf6 = ioremap(0xFE0B0600, BANK_LEN);
	if (!ecf0 || !ecf3 || !ecf5 || !ecf6) {
		pr_err("honor-ec-rail: ioremap failed\n");
		ret = -ENOMEM;
		goto err_map;
	}

	rail_kobj = kobject_create_and_add("honor-ec-rail", kernel_kobj);
	if (!rail_kobj) {
		ret = -ENOMEM;
		goto err_kobj;
	}

	ret = sysfs_create_group(rail_kobj, &rail_group);
	if (ret)
		goto err_group;

	pr_info("honor-ec-rail: loaded, read-only\n");
	return 0;

err_group:
	kobject_put(rail_kobj);
err_kobj:
err_map:
	if (ecf6) iounmap(ecf6);
	if (ecf5) iounmap(ecf5);
	if (ecf3) iounmap(ecf3);
	if (ecf0) iounmap(ecf0);
	return ret;
}

static void __exit honor_ec_rail_exit(void)
{
	sysfs_remove_group(rail_kobj, &rail_group);
	kobject_put(rail_kobj);
	iounmap(ecf6);
	iounmap(ecf5);
	iounmap(ecf3);
	iounmap(ecf0);
	pr_info("honor-ec-rail: unloaded\n");
}

module_init(honor_ec_rail_init);
module_exit(honor_ec_rail_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Linux-on-HONOR-ZQC-P");
MODULE_DESCRIPTION("Read-only dump of HONOR ZQC-P extended EC banks");
