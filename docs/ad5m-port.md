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
  from the AD5M mod's config (its PID, input shaper, rotation distance and probe offset included as
  starting values from one unit). Every uncertain value is marked `TODO:`.
- `klipper/mcu-configs/ad5m-{mainboard,eboard}.mainline.config`: the AD5X ones with a note. The AD5M
  mod's mainboard config differs only by the load cell and TVOC bridge options.
- `buildroot/configs/ad5m_defconfig`: ARM target on the stock 5.4 kernel, ext4 root, GuppyScreen.
  Needs `package/ad5m-system` and `package/guppyscreen`, which do not exist yet.
- `buildroot/board/ad5m/rootfs-overlay/etc/kiln-board`: board profile (ports, partitions, display) for
  the shared scripts, with the unknowns left blank (MCU boot/reset GPIO numbers).

## Checking a built image

`tools/ad5m-verify-image.sh` unpacks `rootfs.tar` and checks, without a printer: the hand-over hook, tools and
services (shell syntax), the Klipper config files and modules, the firmware and its checksums, the users, the ELF ABI
notes (nothing may need a kernel newer than 5.4.61), every shared library the main programs need, and, with
qemu-user-static, that the image's Python starts and that the image's Klipper accepts its own `printer.cfg` with the
firmware's MCU data dictionaries (Klipper's test mode: `-d mainboard.dict -d eboard=eboard.dict`). The static part
was run against a deliberately incomplete fake image (it reported each missing piece); the qemu part has not been run.

## GuppyScreen (the zMod fork)

`buildroot/package/guppyscreen/` builds ghzserg/guppyscreen_ff5m, pinned to commit `acd92c5` (the one read), the
way its own `ci/build-release.sh` does for the AD5M: the eight submodule patches (applied with GNU `patch`,
the AD5M framebuffer one included), libhv and spdlog, then `GUPPY_FF5M_SCREEN=1`; translations through
`msgfmt`. One small patch of ours (`GUPPY_CONFIG`) lets the config and themes live on `/data`. What was read
from the source: framebuffer 800x480 through `fbdev`, touch through tslib (`TSLIB_TSDEVICE`) with LVGL's own
calibration screen (`touch_calibrated: true` and the coefficients kept in the config; the shipped `ts.conf`
has no `linear` stage so the two do not stack), no `wpa_supplicant` client in the FF5M build (Wi-Fi is not set
up from this screen: the first start takes stock's saved networks, `S42ad5m-wifi`), and it restarts itself
through `/etc/init.d/S80guppyscreen`.

The screen was written for zMod's Klipper config and sends zMod's macro names. `klipper/ad5m-guppy.cfg` maps the
ones that have a Kiln equivalent (`AUTO_FULL_BED_LEVEL`, `PID_TUNE_*`, `_T_HEATER`, `BED_LEVEL_SCREWS_TUNE`,
`LOAD_CELL_TARE`) and answers "not available on Kiln OS yet" for the rest (shell commands, shaper and belt
calibration, power off, cold pull, nozzle clearing). It also queries a `zmod_color` Klipper object; whether it
copes with its absence is untested. Its repository's `AGENTS.md` (Russian) sets rules for contributions there:
minimal diffs, new comments in Russian, no changes to submodules or build settings without reason, memory
measurements (`VmRSS` etc.) for any PR; they apply if the wizard is ever offered upstream.

Not done: the first-boot setup wizard panels (Klipper side: a variant of `ad5x_setup.py` without the IFS and
purge box steps; screen side: new LVGL panels in a patch), the `ad5x-fbstream` (screen in the browser) helper.

## Kernel headers and glibc's minimum kernel (found when the first build ran)

The AD5X's userland is built with 5.10 headers because its stock kernel is 5.10.186 (Kiln starts its own 6.6
from it). The AD5M's stock kernel is 5.4.61, and Buildroot 2026.02 has dropped its 5.4 headers (legacy option),
so `ad5m_defconfig` uses 5.10 headers. Buildroot passes the headers' version to glibc as its minimum kernel
(`--enable-kernel`); a glibc that requires 5.10 stops every program on a 5.4.61 kernel with "FATAL: kernel too
old". `ad5m-system.mk` therefore adds `--enable-kernel=5.4` for this board only (verified with Buildroot's own
`printvars`: AD5M gets `5.10` then `5.4`, the later wins; the AD5X defconfig is unchanged), `ad5m-build-all.sh`
refuses to build without it, and `post-build.sh` fails the build if BusyBox or Python's ELF ABI note asks for
more than 5.4.61. Calls newer than 5.4 that the 5.10 headers expose are probed at run time by glibc/Python.

## Also in this change (fourth batch: building it)

- `tools/ad5m-build-all.sh`: one script that does everything in WSL2/Linux: preflight, host packages, copies the
  checkout off a Windows drive, wires the package into Buildroot's menu, clones Buildroot 2026.02.3, builds the
  boards' firmware and the root image, collects `rootfs.tar`, the firmware and the installer into `dist/`.
  Stops at the first problem with the step name and the log; start it again to carry on.
- `tools/build_mcu_ad5m.sh`, `tools/ad5m_mcu_apply.py`, `klipper/mcu-sources/ad5m/`, `klipper/extras/flashforge_*.py`:
  mainline Klipper plus xblax's load cell and TVOC bridges (GPL-3.0, copied unchanged with a provenance header).
  The apply script edits Klipper's Kconfig and Makefile by anchors, not line numbers; tested against the fork's own
  files rebuilt without the bridges (identical result, and a second run changes nothing).
- `buildroot/board/ad5m/`: BusyBox fragment, users, post-build/post-image scripts, an rcS without the AD5X's slot
  trace, and the overlay; `ad5m_defconfig` uses the AD5X overlay (nginx, chrony, sudoers, udev rules, dropbear)
  plus this one. `ad5m-system.mk` installs the AD5M's Klipper configs over the AD5X defaults the Klipper package
  leaves in the image.
- Checked here: Buildroot's own configuration step on `ad5m_defconfig` with Kiln's external tree (using the
  Buildroot 2025.02.4 copy from the second download, the only one available offline: its upstream
  `python-inotify-simple` clashes with Kiln's and was hidden in the test copy), the options that must stick, the
  package recipe parsing and its dependencies, and the package's install commands against a fake target
  directory (every shared file it copies exists). Not checked: any compile or download.

## Also in this change (third batch)

- `klipper/ad5m-macros.cfg`: START_PRINT / PRINT_START, END_PRINT / PRINT_END, CANCEL_PRINT, PAUSE / RESUME with
  a park spot, M600, M24/M25, filament load/unload/purge, AUTO_BED_LEVEL and BED_MESH_CALIBRATE with a tare, and
  Kiln's `[ad5x_sound]` and `[ad5x_log]` modules (board-independent). Checked by parsing every macro in Klipper's
  template syntax and rendering the main ones against a mock printer object (parameters, branches, the pause
  clamp, the tare refusal); not run in Klipper.
- `klipper/ad5m-loadcell.cfg`: the two sections that load the load cell module once it exists.

## Also in this change (second batch)

- `buildroot/package/ad5m-system/`: `sbin/ad5m-init` (PID 1 hand-over), `bin/ad5m-handoff`, `ad5m-vendor`,
  `ad5m-mcu`, `ad5m-backlight`, `lib/board.sh`, init scripts for data, modules, display, buzzer, ethernet,
  Wi-Fi, MCUs and boot completion, and the Buildroot recipe. Reuses the board-independent parts of
  `ad5x-system` and its Klipper services unchanged.
- `tools/install/ad5m-install.sh`: the installer for stock (checks, backup, unpack, hook, optional activate).
- `docs/ad5m-boot.md`: the boot design, the ways back to stock and the MCU bring-up procedure.

## Not done yet

1. The setup wizard (an AD5M variant of `ad5x_setup.py` and the GuppyScreen panels); the GuppyScreen package itself exists but has never been built.
2. AD5M macros layer (print start, prime line, quick actions) and `setup.cfg`.
3. Build the MCU firmware for the AD5M (`tools/build_mcu_ad5m.sh`: untested, the load cell C code may need changes for the newer Klipper) and confirm the reset/boot GPIO lines.
4. **Load cell support, which printing needs.** The probe's trigger (PB4) comes from the load cell board
   and stock and the AD5M mod tare it over its UART before every probe or mesh (`FLASHFORGE_LOAD_CELL_TARE`,
   board command H1, bridged by the mainboard MCU). Mainline Klipper has no such module, so without it the
   bed cannot be probed safely: `LOAD_CELL_TARE` in `ad5m-macros.cfg` refuses with an error instead. The bridge sources and the host module are now in this tree (`klipper/mcu-sources/ad5m`,
   `klipper/extras/flashforge_*.py`, applied by `tools/build_mcu_ad5m.sh`) but have never been compiled against
   Kiln's Klipper revision; once built and flashed, include `klipper/ad5m-loadcell.cfg` from printer.cfg. The TVOC sensor (Pro) is the same kind of bridge and not on the print path.
5. Review of the shared services not yet reused (camera, Fluidd defaults, update agent, plugin boot).
6. Milestone 2 (A/B root through `fw_setenv mmc_root`) and a RAM recovery (needs an own kernel).

## Credits

The printer config, MCU configs and the hardware facts about the AD5M come from xblax's AD5M mod
(GPL-3.0), which Kiln OS already builds on for the AD5X.
