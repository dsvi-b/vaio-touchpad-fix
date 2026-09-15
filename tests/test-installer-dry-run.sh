#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cases=(
  'apt-get:update-grub:'
  'dnf:grubby:'
  'zypper:grub2-mkconfig:'
  'pacman:kernel-install:linux'
  'xbps-install:grub-mkconfig:'
  'apk:kernel-install:'
  'emerge:grub2-mkconfig:'
)

for spec in "${cases[@]}"; do
  IFS=: read -r manager boot arch_kernel <<<"$spec"
  out="$tmp/$manager.out"
  PACKAGE_MANAGER=$manager \
  BOOT_TOOL_OVERRIDE=$boot \
  ARCH_KERNEL_PACKAGE=$arch_kernel \
    "$root/install.sh" --dry-run >"$out"
  grep -Fq "Boot configuration: $boot" "$out"
  grep -Fq 'dkms' "$out"
  grep -Fq 'amd_i2c_enable' "$out"
  grep -Fq 'acpi_osi=' "$out"
done

echo 'installer dry-run matrix: PASS'
