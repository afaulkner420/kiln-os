# Draft: issue for djvalic/kiln-os (edit before posting)

Kiln OS's CONTRIBUTING.md asks for an issue before a new board or anything in the boot path. This is a draft
of that issue, written as you; change anything that is not true or not how you would say it. Notes for you
are at the bottom (delete them before posting).

---

**Title:** Proposal: Adventurer 5M / 5M Pro support (new board, boot hand-over via U-Boot `init`)

I own an Adventurer 5M and an AD5X (running Kiln OS). I would like to try a port of Kiln OS to the AD5M and
the 5M Pro, and I would like to agree the approach with you before going further, as CONTRIBUTING.md asks.

**Where it stands.** I have drafts of most pieces and a first image that builds. Nothing has been started on
a printer yet; I will say so in anything I send you. The first test runs on my own AD5M, with a serial
adapter on the debug UART and an off-printer copy of its boot data.

**What the AD5M is, measured on my unit** (stock 5.1.9, zMod running):
- Allwinner sun8iw20 (R528/T113-S3 family), 2x Cortex-A7, 128 MB RAM, 7.6 GB eMMC; stock kernel 5.4.61
  (no squashfs, overlayfs, loop devices, initramfs or kexec).
- U-Boot 2018.05. Its `bootcmd` builds the kernel command line from the variables `root=${mmc_root}` and
  `init=${init}`, and loads `uImage` and `sunxi.dtb` as files from a FAT partition. The environment is in
  two partitions and stock ships `fw_setenv`. One root partition, no A/B slots.
- Mainboard and toolhead boards: the same N32G455 chips, flash layout and bootloader handshake as the AD5X
  (ports `ttyS5` and `ttyS1`). No IFS. The bed's load cell sits behind the mainboard MCU and is zeroed
  over its UART before probing, as stock and the AD5M mod do.

**What I would like to do:**
1. Boot: Kiln OS starts as PID 1 through the U-Boot variable `init` (a small shell script on the stock root
   that either enters a Kiln root kept on the data partition or runs stock's `/init`), with a try counter
   that falls back to stock after three unfinished boots. The stock kernel, `uImage` and the other
   partitions are never written; the only U-Boot change is that variable. A real A/B (second root,
   `mmc_root`) would be a later step.
2. Build: an `ad5m_defconfig` (ARM, glibc, 5.10 headers with `--enable-kernel=5.4` for this board) and an
   `ad5m-system` package that reuses the board-independent parts of `ad5x-system` (Klipper, Moonraker,
   nginx, Fluidd) and adds the AD5M ones.
3. Klipper: AD5M config, macros and MCU firmware built from mainline plus the load cell / TVOC bridges from
   xblax's AD5M fork.
4. Screen: GuppyScreen (zMod's AD5M fork) instead of HelixScreen, with a setup wizard on the same
   Klipper-side contract as yours.

**Questions for you:**
1. Is a new board welcome in Kiln OS at all, or is the AD5M better left outside the project?
2. Boot hand-over through `init=${init}`: acceptable to you, given it touches the boot path? What would you
   want to see before it is released (tests, a recovery story)?
3. Structure: a separate `ad5m-system` package that borrows from `ad5x-system`, or a refactor into a common
   package plus board packages? The first leaves the AD5X untouched, which is what I would start with.
4. How would you like to receive the work, given that PRs are ported by hand from a private copy? Small
   topic-by-topic PRs as the pieces get tested on hardware?

**Credit.** Most of the AD5M knowledge comes from xblax's flashforge_ad5m_klipper_mod (GPL-3.0), which Kiln OS
already builds on, from ghzserg's zMod and guppyscreen_ff5m, and from consp's backlight/audio libraries.
Their code stays under its own licences with credits intact.

I can test every change on both an AD5M and an AD5X, so the AD5X does not regress.

---

## Notes for you (delete before posting)

- **Be open about how this was made.** Much of this work was drafted with an AI assistant and has not
  been run on a printer. CONTRIBUTING.md has no rule against that, but it does say commits carry no
  tool or AI attribution lines ("credit people, not tools"), so do not add `Co-Authored-By` lines. A
  sentence in the issue saying the drafts were AI-assisted and are untested is honest, saves the maintainer
  from finding out in review, and it is your call. If you say it, say it once, plainly.
- You are responsible for what you submit: run it, understand it, and be ready to answer review questions
  in your own words. Do not post the issue before you have at least done Stages 1 to 3 of
  `docs/ad5m-first-test.md`, so that "I tried it" is true and you can say what happened.
- Replace "I have drafts ... a first image that builds" with what is true on the day.
- The maintainer's repository is an export of a private one; PRs are not merged on GitHub, they are ported by
  hand and credited. Expect a conversation, not a merge button.
- When it gets to PRs: one topic per PR, a CHANGELOG line in the PR text, a row in `deviations-from-stock.md`
  for anything that differs from stock, a licence line on new source files, what happens if it goes wrong
  and how to get back (for boot changes), and the tests described in the PR.
