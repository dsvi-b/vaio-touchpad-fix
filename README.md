# VAIO / AMD FCH touchpad fix for Linux

Re-enables the I2C-HID touchpad on AMD laptops whose BIOS disables the AMD FCH
I2C controllers at the ACPI level. Developed and verified on a **VAIO
VJFE69F11X-B0321H** (AMD APU) running Ubuntu 26.04, kernel 7.0.

The touchpad typically dies "overnight" — after a BIOS or firmware update — and
no driver, module reload, or `libinput` reinstall brings it back, because the
hardware is switched off *below* the driver layer.

## Symptoms

- Touchpad completely dead; external USB mouse works fine.
- `xinput list` / `/proc/bus/input/devices` show no touchpad.
- `dmesg` shows no `i2c_designware` / `i2c_hid` activity for the touchpad.

## Confirm you have *this* problem

```sh
for i in 00 01 02 03 04 05; do
  echo "AMDI0010:$i = $(cat /sys/bus/acpi/devices/AMDI0010:$i/status 2>/dev/null)"
done
```

If every controller reports `status = 0`, the BIOS has disabled all AMD FCH I2C
controllers via ACPI — this fix applies. (`15` means enabled.)

## Install

```sh
git clone https://github.com/dsvi-b/vaio-touchpad-fix
cd vaio-touchpad-fix
sudo ./install.sh
sudo reboot
```

After reboot:

```sh
grep -i touchpad /proc/bus/input/devices   # should list the touchpad
```

## Uninstall

```sh
sudo ./uninstall.sh
sudo reboot
```

## Root cause

The BIOS DSDT (ACPI firmware table) gates the AMD FCH I2C controllers behind two
checks in their `_STA` (status) method:

1. **Hardware enable bits `IC0E`–`IC5E`** in an FCH register. That register
   lives in firmware-reserved RAM at `FRTB + 4`, where `FRTB` is a 32-bit
   pointer read from the Embedded Controller (EC offset `0x08`, via I/O ports
   `0x72`/`0x73`). A buggy BIOS leaves these bits at `0` → every controller's
   `_STA` returns `0` → no I2C bus → no touchpad.
2. The touchpad device's own `_STA` also checks **`TPOS >= 0x60`**. `TPOS` is
   set by the BIOS from `_OSI("Windows ...")`. Linux does not claim a Windows
   OSI string by default, so `TPOS` stays `0` and the touchpad stays gated even
   if its controller is enabled.

Patching the DSDT directly does not work here:

- **initramfs DSDT override** — the kernel refuses it; the Embedded Controller
  has already initialised against the BIOS DSDT.
- **GRUB `acpi` table replace** — on UEFI the kernel takes ACPI tables from the
  EFI System Table, which GRUB's legacy RSDP patch does not touch.

So instead of patching the *table*, this fix patches the hardware register the
table *reads*.

## How the fix works

Two parts, both applied by `install.sh`:

1. **`acpi_osi="Windows 2015"`** kernel parameter (added to
   `/etc/default/grub`) → Linux now answers `_OSI("Windows 2015")` → the BIOS
   sets `TPOS = 0x70` → opens gate #2.

2. **`amd_i2c_enable` kernel module** → reads `FRTB` from the EC, sets bits
   `IC0E`–`IC5E` in the FCH register → opens gate #1 → then calls
   `acpi_bus_scan()` so the kernel enumerates the now-present controllers and
   their child HID devices. A `syscore` resume hook re-applies the bits after
   suspend/hibernate.

The module is packaged with **DKMS**, so it rebuilds automatically on kernel
updates, and `/etc/modules-load.d/` loads it on every boot.

## Caveats

- **The FCH register resets to 0 on every cold boot** (the BIOS rewrites that
  RAM). That is why the module must run at every boot — this is expected.
- **A BIOS update can break it again** by changing the `FRTB` layout. If the
  touchpad dies after a BIOS update, dump the current DSDT
  (`sudo cp /sys/firmware/acpi/tables/DSDT dsdt.aml && iasl -d dsdt.aml`) and
  re-check the `_STA` methods and the `FRTP`/`FRTB` field offsets.
- **Secure Boot**: a DKMS module is unsigned. With Secure Boot enabled you must
  enroll a MOK key, or the module will not load. Developed with Secure Boot
  off.
- Enabling all six controllers can log harmless `i2c_designware ... controller
  timed out` / `Unknown Synopsys component type` lines for controllers that
  have no device — cosmetic only.

## Adapting to a different model

This was reverse-engineered from one specific VAIO. On another AMD laptop the
EC offset of `FRTB`, the register bit layout, or the `_OSI` string the BIOS
expects may differ. Decompile your own DSDT and check:

- the `_STA` method of the `AMDI0010` devices — what bits it tests;
- the `OperationRegion`/`Field` that defines `FRTB` and `IC0E`–`IC5E`;
- which `_OSI("Windows ...")` string sets `TPOS >= 0x60`.

Then adjust `FRTB_OFF`, `ICxE_MASK` in `amd_i2c_enable.c` and the `acpi_osi`
value in `install.sh` accordingly.

## License

GPL-2.0-only. The kernel module is `MODULE_LICENSE("GPL")`.
