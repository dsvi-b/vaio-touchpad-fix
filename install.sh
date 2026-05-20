#!/usr/bin/env bash
# Installer for the AMD FCH I2C / VAIO touchpad fix.
# See README.md for what this does and why.
set -euo pipefail

PKG=amd-i2c-enable
VER=1.0
SRC="/usr/src/${PKG}-${VER}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root:  sudo ./install.sh"
	exit 1
fi

echo "==> Installing build dependencies (dkms + kernel headers)"
apt-get update
apt-get install -y dkms "linux-headers-$(uname -r)" linux-headers-generic

echo "==> Installing module source to ${SRC}"
mkdir -p "${SRC}"
cp "${HERE}/amd_i2c_enable.c" "${HERE}/Makefile" "${HERE}/dkms.conf" "${SRC}/"

echo "==> Registering and building with DKMS"
dkms add    -m "${PKG}" -v "${VER}" 2>/dev/null || true
dkms build  -m "${PKG}" -v "${VER}" --force
dkms install -m "${PKG}" -v "${VER}" --force

echo "==> Enabling auto-load at boot"
echo amd_i2c_enable > /etc/modules-load.d/amd-i2c-enable.conf

echo '==> Adding acpi_osi="Windows 2015" kernel parameter'
if grep -q 'acpi_osi=' /etc/default/grub; then
	echo "    acpi_osi= already present; leaving /etc/default/grub untouched."
	echo "    Make sure it includes:  acpi_osi=\"Windows 2015\""
else
	sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 acpi_osi=\\"Windows 2015\\""/' \
		/etc/default/grub
	update-grub
fi

echo "==> Loading module now"
modprobe amd_i2c_enable || true

echo
echo "Done.  >>> REBOOT <<< for the fix to fully take effect."
echo "After reboot, verify with:"
echo "  grep -i touchpad /proc/bus/input/devices"
