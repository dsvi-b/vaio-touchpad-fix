// SPDX-License-Identifier: GPL-2.0-only
/*
 * amd_i2c_enable - re-enable AMD FCH I2C controllers disabled by a buggy BIOS
 *
 * Some AMD laptops (e.g. VAIO VJFE69F11X-B0321H) ship a BIOS whose ACPI DSDT
 * reports every AMD FCH I2C controller (ACPI _HID "AMDI0010") as not-present
 * (_STA = 0): the hardware enable bits IC0E..IC5E in an FCH register are left
 * at 0. With no I2C bus, the I2C-HID touchpad is never enumerated.
 *
 * This module reads the FCH function-table base (FRTB) from the EC, sets the
 * IC0E..IC5E bits, then re-scans the ACPI namespace so the controllers and
 * their child HID devices get enumerated. A syscore resume hook re-applies the
 * bits after suspend/hibernate.
 *
 * NOTE: this is half of the fix. The touchpad device's own _STA also gates on
 * TPOS, which the BIOS only sets when the OS answers _OSI("Windows ...").
 * You must ALSO boot with the kernel parameter:  acpi_osi="Windows 2015"
 * (install.sh adds it to /etc/default/grub for you).
 */
#include <linux/module.h>
#include <linux/io.h>
#include <linux/acpi.h>
#include <linux/memremap.h>
#include <linux/syscore_ops.h>
#include <linux/bitops.h>

#define EC_IDX    0x72		/* EC index port  */
#define EC_DAT    0x73		/* EC data port   */
#define FRTB_OFF  0x08		/* EC offset of the 32-bit FRTB pointer */

/* bits 5..10 of the dword at FRTB+4 = IC0E..IC5E (AMDI0010:00..05) */
#define ICxE_MASK 0x7E0UL

static const char * const i2c_paths[] = {
	"\\_SB.I2CA", "\\_SB.I2CB", "\\_SB.I2CC",
	"\\_SB.I2CD", "\\_SB.I2CE", "\\_SB.I2CF",
};

static void __iomem *fch_reg;

static u32 read_frtb(void)
{
	u32 v = 0;
	int i;

	for (i = 0; i < 4; i++) {
		outb(FRTB_OFF + i, EC_IDX);
		v |= ((u32)inb(EC_DAT)) << (i * 8);
	}
	return v;
}

static void apply_icxe(void)
{
	u32 val = readl(fch_reg);

	if ((val & ICxE_MASK) != ICxE_MASK)
		writel(val | ICxE_MASK, fch_reg);
}

/* runs before device-resume callbacks (atomic ctx): only touch cached ptr */
static void amd_i2c_resume(void *data)
{
	if (fch_reg)
		apply_icxe();
}

static const struct syscore_ops amd_i2c_syscore_ops = {
	.resume = amd_i2c_resume,
};

static struct syscore amd_i2c_syscore = {
	.ops = &amd_i2c_syscore_ops,
};

static int __init amd_i2c_enable_init(void)
{
	u32 frtb;
	int i;

	frtb = read_frtb();
	pr_info("amd_i2c_enable: FRTB=0x%08X\n", frtb);
	if (!frtb || frtb == 0xFFFFFFFF) {
		pr_err("amd_i2c_enable: invalid FRTB, aborting\n");
		return -EIO;
	}

	fch_reg = memremap(frtb + 4, 4, MEMREMAP_WB);
	if (!fch_reg) {
		pr_err("amd_i2c_enable: memremap failed\n");
		return -EIO;
	}

	apply_icxe();
	pr_info("amd_i2c_enable: FCH reg=0x%08X\n", readl(fch_reg));

	/* re-enumerate the now-present controllers and their HID children */
	acpi_scan_lock_acquire();
	for (i = 0; i < ARRAY_SIZE(i2c_paths); i++) {
		acpi_handle h;

		if (ACPI_SUCCESS(acpi_get_handle(NULL,
				(acpi_string)i2c_paths[i], &h)))
			acpi_bus_scan(h);
	}
	acpi_scan_lock_release();

	register_syscore(&amd_i2c_syscore);
	pr_info("amd_i2c_enable: done\n");
	return 0;
}

static void __exit amd_i2c_enable_exit(void)
{
	unregister_syscore(&amd_i2c_syscore);
	if (fch_reg)
		memunmap(fch_reg);
}

module_init(amd_i2c_enable_init);
module_exit(amd_i2c_enable_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Re-enable AMD FCH I2C controllers disabled by a buggy BIOS");
