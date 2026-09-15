#!/usr/bin/env bash
# Cross-distribution installer for amd_i2c_enable.
set -Eeuo pipefail

PKG=amd-i2c-enable
VER=1.0
MODULE=amd_i2c_enable
KERNEL=${KERNEL_VERSION:-$(uname -r)}
SRC="/usr/src/${PKG}-${VER}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KERNEL_ARG='acpi_osi="Windows 2015"'
DRY_RUN=0
INSTALL_DEPS=1

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [--dry-run] [--no-install-deps]

  --dry-run          Print the detected plan without changing the system.
  --no-install-deps  Require DKMS, compiler, make and matching headers to exist.
EOF
}

while (($#)); do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --no-install-deps) INSTALL_DEPS=0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

run() {
  printf '+ '; printf '%q ' "$@"; printf '\n'
  ((DRY_RUN)) || "$@"
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
headers_present() { [[ -e "/lib/modules/$KERNEL/build/Makefile" ]]; }

detect_boot_tool() {
  [[ -n ${BOOT_TOOL_OVERRIDE:-} ]] && { echo "$BOOT_TOOL_OVERRIDE"; return; }
  if have rpm-ostree && rpm-ostree status >/dev/null 2>&1; then echo rpm-ostree
  elif have grubby; then echo grubby
  elif have update-grub && [[ -f /etc/default/grub ]]; then echo update-grub
  elif have grub2-mkconfig && [[ -f /etc/default/grub ]]; then echo grub2-mkconfig
  elif have grub-mkconfig && [[ -f /etc/default/grub ]]; then echo grub-mkconfig
  elif have kernel-install && [[ -f /etc/kernel/cmdline ]]; then echo kernel-install
  else echo unsupported
  fi
}

preflight_firmware() {
  if have mokutil; then
    secure_boot=$(mokutil --sb-state 2>/dev/null || true)
    grep -Fq 'SecureBoot enabled' <<<"$secure_boot" && \
      die "Secure Boot is enabled; enroll a module-signing key before installing this DKMS module"
  fi

  cmdline=$(cat /proc/cmdline 2>/dev/null || true)
  if [[ $cmdline == *acpi_osi=* && $cmdline != *'acpi_osi=Windows 2015'* ]]; then
    die "A different acpi_osi parameter is active; review it manually instead of overwriting it"
  fi
}

install_dependencies() {
  headers_present && have dkms && have make && have cc && return
  ((INSTALL_DEPS)) || die "DKMS/compiler/matching headers for $KERNEL are missing"
  [[ $BOOT_TOOL != rpm-ostree ]] || die "Install the DKMS toolchain in the immutable deployment first, reboot, then rerun with --no-install-deps"
  local manager=${PACKAGE_MANAGER:-auto}
  if [[ $manager == auto ]]; then
    for candidate in apt-get dnf zypper pacman xbps-install apk emerge; do
      if have "$candidate"; then manager=$candidate; break; fi
    done
  fi
  if [[ $manager == apt-get ]]; then
    run apt-get update
    run apt-get install -y dkms build-essential "linux-headers-$KERNEL"
  elif [[ $manager == dnf ]]; then
    run dnf -y install dkms gcc make "kernel-devel-$KERNEL"
  elif [[ $manager == zypper ]]; then
    run zypper --non-interactive install dkms gcc make kernel-devel kernel-default-devel
  elif [[ $manager == pacman ]]; then
    kernel_pkg=${ARCH_KERNEL_PACKAGE:-$(pacman -Qqo "/usr/lib/modules/$KERNEL/vmlinuz" 2>/dev/null | head -n1 || true)}
    [[ -n $kernel_pkg ]] || die "Cannot infer the Arch kernel package; install matching headers and use --no-install-deps"
    run pacman -S --needed --noconfirm dkms base-devel "${kernel_pkg}-headers"
  elif [[ $manager == xbps-install ]]; then
    run xbps-install -Sy dkms base-devel linux-headers
  elif [[ $manager == apk ]]; then
    run apk add dkms build-base linux-headers
  elif [[ $manager == emerge ]]; then
    run emerge --noreplace sys-kernel/linux-headers sys-devel/gcc sys-devel/make sys-kernel/dkms
  else
    die "Unsupported package manager; install DKMS, compiler, make and matching kernel headers, then use --no-install-deps"
  fi
  ((DRY_RUN)) || { headers_present || die "Matching headers for $KERNEL are still missing"; have dkms || die "dkms is still missing"; }
}

append_grub_default() {
  local file=/etc/default/grub
  grep -Fq "$KERNEL_ARG" "$file" && return
  run cp -a "$file" "${file}.pre-vaio-touchpad-fix"
  ((DRY_RUN)) && { printf '+ add %q to GRUB_CMDLINE_LINUX in %s\n' "$KERNEL_ARG" "$file"; return; }
  awk -v arg='acpi_osi=\\"Windows 2015\\"' '
    BEGIN { done=0 }
    /^GRUB_CMDLINE_LINUX=/ && !done { sub(/"[[:space:]]*$/, " " arg "\""); done=1 }
    { print }
    END { if (!done) print "GRUB_CMDLINE_LINUX=\"" arg "\"" }
  ' "$file" > "${file}.vaio-touchpad-fix.tmp"
  cat "${file}.vaio-touchpad-fix.tmp" > "$file"
  rm -f "${file}.vaio-touchpad-fix.tmp"
}

configure_kernel_argument() {
  case $BOOT_TOOL in
    rpm-ostree) run rpm-ostree kargs --append-if-missing="$KERNEL_ARG" ;;
    grubby) run grubby --update-kernel=ALL --args="$KERNEL_ARG" ;;
    update-grub) append_grub_default; run update-grub ;;
    grub2-mkconfig) append_grub_default; run grub2-mkconfig -o /boot/grub2/grub.cfg ;;
    grub-mkconfig) append_grub_default; run grub-mkconfig -o /boot/grub/grub.cfg ;;
    kernel-install)
      grep -Fq "$KERNEL_ARG" /etc/kernel/cmdline || {
        run cp -a /etc/kernel/cmdline /etc/kernel/cmdline.pre-vaio-touchpad-fix
        if ((DRY_RUN)); then printf '+ append %q to /etc/kernel/cmdline\n' "$KERNEL_ARG"
        else printf ' %s' "$KERNEL_ARG" >> /etc/kernel/cmdline; fi
      }
      run kernel-install add-all
      ;;
    *) die "No supported persistent kernel-argument mechanism found" ;;
  esac
}

[[ $DRY_RUN -eq 1 || $(id -u) -eq 0 ]] || die "Run as root: sudo ./install.sh"
[[ -r "$HERE/amd_i2c_enable.c" && -r "$HERE/Makefile" && -r "$HERE/dkms.conf" ]] || die "Incomplete source tree"
BOOT_TOOL=$(detect_boot_tool)
[[ $BOOT_TOOL != unsupported ]] || die "No supported boot configuration tool found"
printf 'Kernel: %s\nBoot configuration: %s\n' "$KERNEL" "$BOOT_TOOL"

preflight_firmware
install_dependencies
run install -d -m0755 "$SRC"
run install -m0644 "$HERE/amd_i2c_enable.c" "$HERE/Makefile" "$HERE/dkms.conf" "$SRC/"

dkms_state=$(dkms status -m "$PKG" -v "$VER" 2>/dev/null || true)
if ! grep -Fq installed <<<"$dkms_state"; then
  run dkms add -m "$PKG" -v "$VER"
  run dkms build -m "$PKG" -v "$VER" -k "$KERNEL"
  run dkms install -m "$PKG" -v "$VER" -k "$KERNEL"
fi

if ((DRY_RUN)); then printf '+ write %s to /etc/modules-load.d/amd-i2c-enable.conf\n' "$MODULE"
else printf '%s\n' "$MODULE" > /etc/modules-load.d/amd-i2c-enable.conf; fi
configure_kernel_argument
run modprobe "$MODULE"

printf '\nInstalled for kernel %s. Reboot, then verify with:\n' "$KERNEL"
printf '  grep -i touchpad /proc/bus/input/devices\n'
