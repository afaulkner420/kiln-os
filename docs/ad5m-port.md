# Adventurer 5M / 5M Pro port: status (work in progress)

Not built, not run on a printer. Facts marked MEASURED were read from a real AD5M
(stock 5.1.9) on 2026-11-17; the rest comes from the AD5M mod
(xblax/flashforge_ad5m_klipper_mod, GPL-3.0) and zMod (ghzserg/zmod).

## What is different from the AD5X

| | AD5X | AD5M / 5M Pro (MEASURED) |
|---|---|---|
| SoC | Ingenic X2600, MIPS | Allwinner sun8iw20 (R528 / T113-S3 family), 2x Cortex-A7, 128 MB RAM |
| Stock kernel | 5.10 | 5.4.61: no squashfs, overlayfs, loop, initramfs, kexec or cgroups |
| Storage | eMMC, A/B slots, flag in a sector | eMMC: p1 FAT (uImage, sunxi.dtb), p2/p3 U-Boot env, p4 boot, p5 dsp0, p6 rootfs (ext4, 1280 MiB), p7 /data. One root, no A/B |
| Boot | SPL boots the stock kernel from the slot | U-Boot 2018.05: `bootcmd=run setargs_mmc boot_dsp0 boot_uImage`, `root=${mmc_root}` from the env, kernel and dtb loaded as files from p1. `fw_setenv` is on stock |
| MCU ports | mainboard ttyS2, eboard ttyS5 | mainboard ttyS5, eboard ttyS1, both 230400 baud |
| MCUs | N32G455 x2 (eboard behind a 64 KiB bootloader) | same chips, same flash layout, same bootloader handshake |
| Extras | IFS, bed weighing board on the host | no IFS; load cell board and TVOC sensor sit behind the mainboard MCU's UARTs |
| Touch / display | HelixScreen | GuppyScreen: 800x480 `fb0`, SoC resistive touch (tslib), backlight through `/dev/disp` |

## What is in this change

- `klipper/ad5m.cfg`, `ad5m-pro.cfg`, `printer-ad5m.cfg`: hardware config ported to mainline syntax
  from the AD5M mod's config. Every uncertain value is marked `TODO:`.
- `klipper/mcu-configs/ad5m-{mainboard,eboard}.mainline.config`: the AD5X ones with a note. The AD5M
  mod's mainboard config differs only by the load cell and TVOC bridge options.
- `buildroot/configs/ad5m_defconfig`: ARM target on the stock 5.4 kernel, ext4 root, GuppyScreen.
  Needs `package/ad5m-system` and `package/guppyscreen`, which do not exist yet.
- `buildroot/board/ad5m/rootfs-overlay/etc/kiln-board`: board profile (ports, partitions, display) for
  the shared scripts, with the unknowns left blank (MCU boot/reset GPIO numbers).

## Also in this change (second batch)

- `buildroot/package/ad5m-system/`: `sbin/ad5m-init` (PID 1 hand-over), `bin/ad5m-handoff`, `ad5m-vendor`,
  `ad5m-mcu`, `ad5m-backlight`, `lib/board.sh`, init scripts for data, modules, display, buzzer, ethernet,
  Wi-Fi, MCUs and boot completion, and the Buildroot recipe. Reuses the board-independent parts of
  `ad5x-system` and its Klipper services unchanged.
- `tools/install/ad5m-install.sh`: the installer for stock (checks, backup, unpack, hook, optional activate).
- `docs/ad5m-boot.md`: the boot design, the ways back to stock and the MCU bring-up procedure.

## Not done yet

1. `package/guppyscreen` and the setup wizard panels.
2. AD5M macros layer (print start, prime line, quick actions) and `setup.cfg`.
3. Mainline MCU firmware images for the AD5M and `tools/build_mcu.sh` support; confirm the reset/boot GPIO lines.
4. Load cell and TVOC support (a mainboard MCU patch; not on the Z probing path).
5. Review of the shared services not yet reused (camera, Fluidd defaults, update agent, plugin boot).
6. Milestone 2 (A/B root through `fw_setenv mmc_root`) and a RAM recovery (needs an own kernel).

## Credits

The printer config, MCU configs and the hardware facts about the AD5M come from xblax's AD5M mod
(GPL-3.0), which Kiln OS already builds on for the AD5X.
