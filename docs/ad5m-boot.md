# Adventurer 5M: how Kiln OS boots (milestone 1) and how to bring up the boards

WORK IN PROGRESS, NOT TESTED ON A PRINTER. Everything marked MEASURED was read from a real AD5M
(stock 5.1.9, zMod running) on 2026-11-17.

## The boot chain (MEASURED)

U-Boot 2018.05 runs `bootcmd=run setargs_mmc boot_dsp0 boot_uImage`. `setargs_mmc` builds the kernel
command line from environment variables, among them **`root=${mmc_root}`** (`/dev/mmcblk0p6`) and
**`init=${init}`** (`/init`). `boot_uImage` loads `uImage` and `sunxi.dtb` as files from the FAT partition
p1 and boots them. The environment lives in p2 (`env`) and p3 (`env-redund`), 128 KiB each as used by
`/etc/fw_env.config`, and stock ships `fw_printenv` / `fw_setenv`. The stock kernel has no squashfs,
overlayfs, loop devices or initramfs, and the stock root is mounted read-only at boot.

## Milestone 1: hand-over by `init=`

One variable decides what runs as PID 1: `fw_setenv init /sbin/ad5m-init`.

1. `ad5m-init` (a shell script on the stock root, installed by `tools/install/ad5m-install.sh`) mounts the
   data partition and checks its markers in `/data/ad5x/handoff/`.
2. If Kiln OS is enabled and its root exists in `/data/ad5x/os/root`, it bind-mounts that directory,
   `pivot_root`s into it (stock root ends up read-only at `/mnt/orig_root`), moves `/proc`, `/sys`,
   `/dev` and `/data` across and executes Kiln's `/sbin/init`.
3. Otherwise it unmounts what it mounted and executes stock's `/init` unchanged.
4. Kiln's `S99ad5m-booted` removes the try counter. Three starts without it and `ad5m-init` renames
   `enable` to `disabled-after-failures` and boots stock from then on.

What is written where: the installer writes **one file on the stock root** (`/sbin/ad5m-init`) and
everything else under `/data/ad5x`. p1, p4, the kernel and stock's `/init` are never touched; the only
U-Boot change is the variable `init`.

### Ways back to stock

| Situation | What to do |
|---|---|
| Kiln boots but you want stock | `ad5m-handoff stock` (next boot is stock; `ad5m-handoff on` returns) |
| Kiln never finishes booting | nothing: after 3 tries stock boots by itself |
| `ad5m-init` or the data partition is broken | the script falls back to `/init` when it cannot mount `/data` or read its markers |
| Kiln's `/sbin/init` is missing or broken | not possible to leave stock unusable: `ad5m-init` checks that it exists and is executable before it moves anything; if `pivot_root` fails, stock still boots |
| `/sbin/ad5m-init` deleted but `init` still points at it | the kernel logs "Failed to execute ... Attempting defaults" and tries `/sbin/init`: boots, but not necessarily the way you want. Fix with `fw_setenv init /init` |
| Nothing boots | U-Boot's console is on the debug UART (ttyS3, 115200; `bootdelay=3`): `setenv init /init; saveenv; boot`. Needs a serial adapter: have one before activating |
| Last resort | restore `env-p2.bin` / `env-p3.bin` and `p1-boot-resource.img` from the backup the installer made (needs a way to write the eMMC) |

Not verified: whether Allwinner's USB recovery mode (FEL) is reachable on this board. Do not rely on it.

### Milestone 2 (not written): real A/B

Carve a second ext4 root out of the end of the data partition and switch with
`fw_setenv mmc_root /dev/mmcblk0pN` plus a counter, as the AD5X scheme does with its boot flag.
Needs static `resize2fs` and a GPT writer in the installer (stock has neither) and a way to extend the
7-entry partition table. Only after milestone 1 has run reliably and a backup exists.

## MCU bring-up (do this before any flashing)

The mainboard's reset and boot lines are driven through sysfs GPIO by stock's `NationsCommand`
(`chip_hardware_reset`). Their numbers are inside that binary and were not extracted. A running stock
system has **gpio 205 exported as output high and gpio 206 as output low**, which fits NRST (high = running)
and BOOT0 (low = application) with BOOT0 one number above NRST, the same pattern as the AD5X (BOOT0 50,
NRST 49). That is an inference, not a fact. To test it without writing anything:

1. Stop whatever holds the serial ports (on Kiln OS Klipper is not enabled until both boards are on
   the right firmware, so a fresh install has nothing running; on stock/zMod stop Klipper).
2. `AD5M_BOOT0_GPIO=206 AD5M_NRST_GPIO=205 ad5m-mcu probe`. It runs `ad5x-flash-n32 --check`: connects to
   the chip's ROM bootloader over `ttyS5`, prints the chip info, resets the chip. It never writes flash.
3. If it prints chip info, put the two numbers into `/etc/kiln-board` (`MCU_BOOT0_GPIO`, `MCU_NRST_GPIO`).
   If it does not connect, try the pair swapped once, then stop and report what it printed.
4. Only then `ad5m-mcu flash-mainboard` / `flash-eboard`, with `ad5m-mcu restore-stock` known to work first
   (it runs stock's own `run.sh` from the copy `ad5m-vendor` keeps, so test that the files are there:
   `ad5m-vendor status` and `ls /data/ad5x/vendor/stock/mcu/*`).

The eboard's bootloader behaves as on the AD5X (115200 baud, "Ready.", then `A`, ACK 0x06): the AD5M mod's
`boot_eboard_mcu.c` does exactly that on `ttyS1`, which is what `boot_eboard --port /dev/ttyS1` does.

## Known gaps

- The Kiln root in milestone 1 is a writable directory on the data partition (the AD5X image root is a
  read-only squashfs). Nothing in the image is meant to write to it; a read-only bind remount is a TODO.
- Wi-Fi: the 8821cu driver and how `wpa_supplicant` talks to it (nl80211 or wext) are untested.
- Boot logo, board heartbeat (none seen on the AD5M), the rest of `S42ad5x-wifi`'s robustness.
- Shared services not yet reviewed for the AD5M: camera, Fluidd defaults, update agent, plugin boot.
- The MCU firmware: no mainline images are built yet (`klipper/mcu-firmware/ad5m` is empty), and the load
  cell and TVOC bridges are not implemented.
- Everything about GuppyScreen (package, wizard).
