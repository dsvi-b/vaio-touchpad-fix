#!/usr/bin/env bash
# Cross-distribution uninstaller for amd_i2c_enable.
set -Eeuo pipefail

PKG=amd-i2c-enable
VER=1.0
MODULE=amd_i2c_enable
KERNEL_ARG='acpi_osi="Windows 2015"'
[[ $(id -u) -eq 0 ]] || { echo "Run as root: sudo ./uninstall.sh" >&2; exit 1; }

modprobe -r "$MODULE" 2>/dev/null || true
dkms remove -m "$PKG" -v "$VER" --all 2>/dev/null || true
rm -rf "/usr/src/${PKG}-${VER}"
rm -f /etc/modules-load.d/amd-i2c-enable.conf

if command -v rpm-ostree >/dev/null 2>&1 && rpm-ostree status >/dev/null 2>&1; then
  rpm-ostree kargs --delete-if-present="$KERNEL_ARG"
elif command -v grubby >/dev/null 2>&1; then
  grubby --update-kernel=ALL --remove-args="$KERNEL_ARG"
elif [[ -f /etc/default/grub ]]; then
  sed -i 's/ *acpi_osi=\\"Windows 2015\\"//' /etc/default/grub
  if command -v update-grub >/dev/null 2>&1; then update-grub
  elif command -v grub2-mkconfig >/dev/null 2>&1; then grub2-mkconfig -o /boot/grub2/grub.cfg
  elif command -v grub-mkconfig >/dev/null 2>&1; then grub-mkconfig -o /boot/grub/grub.cfg
  else echo "WARNING: regenerate the bootloader configuration manually." >&2
  fi
elif [[ -f /etc/kernel/cmdline ]]; then
  sed -i 's/ *acpi_osi="Windows 2015"//' /etc/kernel/cmdline
  kernel-install add-all
else
  echo "WARNING: remove $KERNEL_ARG from the kernel command line manually." >&2
fi

echo "Removed. Reboot to complete."
