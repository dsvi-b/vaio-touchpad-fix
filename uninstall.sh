#!/usr/bin/env bash
# Uninstaller for the AMD FCH I2C / VAIO touchpad fix.
set -uo pipefail

PKG=amd-i2c-enable
VER=1.0

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root:  sudo ./uninstall.sh"
	exit 1
fi

modprobe -r amd_i2c_enable 2>/dev/null || true
dkms remove -m "${PKG}" -v "${VER}" --all 2>/dev/null || true
rm -rf "/usr/src/${PKG}-${VER}"
rm -f /etc/modules-load.d/amd-i2c-enable.conf

# remove the kernel parameter this fix added
sed -i 's/ *acpi_osi=\\"Windows 2015\\"//' /etc/default/grub
update-grub

echo "Removed. Reboot to complete."
