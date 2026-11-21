# Adventurer 5M: the first test, step by step

WORK IN PROGRESS. Nothing here has been run on a printer. Written to be followed in order; every stage
ends with a checkpoint and a way back. Stop at the first thing that does not match what is written here
and send the output. Facts marked MEASURED were read from a real AD5M (stock 5.1.9 with zMod).

Read `ad5m-boot.md` first: it explains the hand-over and the ways back to stock.

## Before anything

- The printer idle, nothing printing, bed clear, filament out of the way. You can lose nothing printed.
- A wired network connection for the first tests (a cable is more certain than Wi-Fi: Kiln OS only
  brings over the Wi-Fi networks it finds in stock's files, which is untested).
- Know where the printer's power switch is and that pulling the plug always works.
- Strongly advised before Stage 3: a **3.3 V** USB-to-serial adapter on the debug UART (ttyS3, 115200;
  zMod's Setup page shows the wiring, RX/TX/GND only, never the 3.3 V pin, converter set to 3.3 V). With it
  you see every boot message and can reach U-Boot's prompt (3-second window at power-on). Without it, a
  hand-over that fails in an unforeseen way can only be fixed by pulling the plug and relying on the
  automatic return to stock (3 failed tries). Stages 1 to 2 do not need it.
- `bash tools/ad5m-verify-image.sh` on the image: no FAIL lines.

## Stage 1: install, without switching over

1. Copy the installer and the image to the printer's data partition (not /tmp: it is RAM):
   `scp -O ad5m-install.sh rootfs.tar root@<printer>:/data/`
2. `ssh root@<printer>` then `sh /data/ad5m-install.sh --check` (changes nothing). Expect `Checks passed`.
3. `sh /data/ad5m-install.sh /data/rootfs.tar`. It backs up first, unpacks the image into
   `/data/ad5x/os/root`, writes ONE file onto the stock root (`/sbin/ad5m-init`) and creates
   `/data/ad5x/mcu.disable` (so the first Kiln OS boots cannot write to the boards). It does not switch
   anything over: the next boot is still stock.
4. **Copy the backup off the printer**: `scp -O -r root@<printer>:/data/ad5x/backup .` and check it
   (`sha256sum -c SHA256SUMS` inside a backup folder). Keep it somewhere that is not the printer.
5. Reboot the printer normally.

Checkpoint: the printer starts exactly as before (zMod and all). `fw_printenv init` still prints `/init`.
Way back: nothing to undo; to remove the hook, `rm /sbin/ad5m-init` and `rm -rf /data/ad5x`.

## Stage 2: look at what the hand-over would do (no reboot)

On the printer: `sh /data/ad5x/os/root/usr/bin/ad5m-handoff status`. Expect `init=/init`,
`hook_installed=yes`, `kiln_root=yes`, no markers. Then
`ls /data/ad5x/os/root/sbin/init /data/ad5x/os/root/usr/share/ad5x/mcu` (firmware version present).

Checkpoint: all present. If `hook_installed=no`, the installer did not finish: do not continue.

## Stage 3: the first Kiln OS boot (boards untouched)

1. Serial adapter connected and a terminal open at 115200 if you have one.
2. `sh /data/ad5x/os/root/usr/bin/ad5m-handoff on`. It sets the U-Boot variable `init` to
   `/sbin/ad5m-init` and the enable marker, and reads the variable back. If it reports anything wrong,
   stop and run `status`.
3. `reboot`.
4. What to expect: the panel will not show an interface unless the image has GuppyScreen (it needs a
   build with that package, which the first image does not have): the boot logo or a black screen is normal.
   Find the printer's address on your router. After about a minute: `ssh root@<address>` (the password
   is the one stock had: zMod's is `root`).
5. On Kiln OS: `cat /run/ad5x-boot.log` (every service, when it started), `ad5m-handoff status`
   (attempts goes back to 0 when the boot finished), `uname -r` (5.4.61), `ad5m-vendor status`
   (`vendor=ok`), `dmesg | tail -50`, `ip addr`, `ps`.
6. The web interface: `http://<address>/` (Fluidd). Klipper is not started yet: that is correct, it
   waits for both boards to run Kiln's firmware (`/data/ad5x/klipper.enable`).

Checkpoint: SSH works, `attempts=0`, `vendor=ok`, Fluidd loads (it will say Klipper is not ready).
Ways back, easiest first:
- On Kiln OS: `ad5m-handoff stock` then `reboot` (stock with zMod comes back; Kiln stays installed).
- Hard way back, from Kiln OS or stock: `ad5m-handoff off` (resets the U-Boot variable to `/init`).
- It did not come up at all: wait 3 minutes, pull the plug, power on. After three starts that never
  finished, `ad5m-init` disables Kiln OS by itself and starts stock.
- With the serial adapter: at power-on press a key within 3 seconds, then `setenv init /init`,
  `saveenv`, `boot`.

## Stage 4: the boards' reset and boot lines (no flashing)

The mainboard's reset (NRST) and boot (BOOT0) lines are driven through GPIO numbers that are inside stock's
flashing tool. A stock system has gpio 205 (output, high) and 206 (output, low) exported, which fits
NRST and BOOT0; that is an inference. On Kiln OS (Klipper is not running):

1. `AD5M_BOOT0_GPIO=206 AD5M_NRST_GPIO=205 ad5m-mcu probe`
2. It connects to the chip's built-in bootloader over `ttyS5`, prints the chip information and resets
   the chip. It writes nothing.
3. If it prints chip information: put the two numbers into `/etc/kiln-board`
   (`MCU_BOOT0_GPIO=206`, `MCU_NRST_GPIO=205`): that file is in `/data/ad5x/os/root/etc/`.
4. If it does not connect: try the pair swapped ONCE, then stop and send the output.

Checkpoint: `ad5m-mcu probe` prints the chip. Also check the way back to stock's own board firmware is
there before any flashing: `ad5m-vendor status` and
`ls /data/ad5x/vendor/stock/mcu/*` must list `run.sh`, `NationsCommand`, `IAPCommand` and both firmware files.

## Stage 5: flash the boards

Only after Stage 4 passed.

1. `rm /data/ad5x/mcu.disable`, then `reboot` (back into Kiln OS).
2. At start-up `ad5m-mcu boot` reads the version on each board, flashes what differs (mainboard through
   the ROM bootloader, eboard through its own) and checks the version again; read
   `/data/ad5x/mcu/log` and `/data/ad5x/mcu/nations.log` / `iap.log`. Both boards on the new version
   enables Klipper (`/data/ad5x/klipper.enable`).
3. If it asks for a power-cycle (the eboard only flashes from its bootloader), pull the plug, power on,
   and it carries on.

Way back to Flashforge's own board firmware: `ad5m-mcu restore-stock` (stop Klipper first), then power-cycle.
It runs stock's own `run.sh`. A board that stops answering after a failed flash can still be reflashed: the
mainboard's ROM bootloader is reached through the same two lines.

## Stage 6: first movements

Bed clear, a hand near the power switch, Fluidd open.

1. `QUERY_ENDSTOPS`: press each switch by hand and query again: X, Y, Z must change when pressed.
2. `FIRMWARE_RESTART` if needed; temperatures read sane at room temperature (`M105`).
3. Small manual moves with the printer NOT homed: `FORCE_MOVE STEPPER=stepper_x DISTANCE=5 VELOCITY=5`,
   same for Y and Z in both directions: the direction must match the axis.
4. `G28` with a finger on the power switch.
5. `LOAD_CELL_TARE` (it stops with an error if the load cell module is missing), then `PROBE` once at a
   safe height.
6. Heater tests at low targets with the printer watched; verify_heater will stop a runaway.
7. A first print from a slicer profile using `START_PRINT`.

Anything that moves the wrong way, grinds or heats unexpectedly: power switch first, questions after.

## What to send me

For any stage that does not match: the exact command, its full output, and `cat /run/ad5x-boot.log`,
`dmesg | tail -100`, `/data/ad5x/mcu/log`, `ad5m-handoff status`. With the serial adapter, the console
log of the boot.
