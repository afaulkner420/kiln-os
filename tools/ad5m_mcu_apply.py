#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Add the Flashforge AD5M load cell and TVOC bridges to a Klipper checkout.

usage: ad5m_mcu_apply.py KLIPPER_DIR

Copies klipper/mcu-sources/ad5m/*.c into KLIPPER_DIR/src/stm32/ and adds the two Kconfig options
(FLASHFORGE_LOADCELL, FLASHFORGE_TVOC) and their Makefile lines, unless they are already there.
Edits are anchored on text that has been in Klipper's stm32 files for years (the end of the
Kconfig, the "Binary output file rules" comment), not on line numbers, so it does not depend on
the exact revision the way a patch's context would. Run it after the mcu-patches/ are applied
(tools/build_mcu_ad5m.sh does that). WORK IN PROGRESS: not yet run against Kiln's Klipper revision.
"""
import os
import shutil
import sys

KCONFIG = '''
config FLASHFORGE_LOADCELL
    bool "Enable Flashforge Load Cell support"
    depends on MACH_STM32F1 || MACH_N32G45x
    help
      Enable support for communicating with the Flashforge Load Cell via UART5.
      Uses PC12 (TX) and PD2 (RX) by default.

config FLASHFORGE_TVOC
    bool "Enable Flashforge TVOC support"
    depends on MACH_STM32F1 || MACH_N32G45x
    help
      Enable support for communicating with the Flashforge TVOC via UART4.
      Uses PC10 (TX) and PC11 (RX) by default.
'''
MAKE_LINES = [
    "src-$(CONFIG_FLASHFORGE_LOADCELL) += stm32/flashforge_load_cell.c\n",
    "src-$(CONFIG_FLASHFORGE_TVOC) += stm32/flashforge_tvoc.c\n",
]
ANCHOR = "# Binary output file rules"


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    klipper = argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    src_dir = os.path.join(here, "..", "klipper", "mcu-sources", "ad5m")
    stm32 = os.path.join(klipper, "src", "stm32")
    kconfig = os.path.join(stm32, "Kconfig")
    makefile = os.path.join(stm32, "Makefile")
    for p in (kconfig, makefile):
        if not os.path.isfile(p):
            print("ad5m_mcu_apply: %s not found: is %s a Klipper checkout?" % (p, klipper))
            return 1
    for name in ("flashforge_load_cell.c", "flashforge_tvoc.c"):
        shutil.copyfile(os.path.join(src_dir, name), os.path.join(stm32, name))

    with open(kconfig) as f:
        text = f.read()
    if "MACH_N32G45x" not in text:
        print("ad5m_mcu_apply: this Klipper has no MACH_N32G45x: not the revision the AD5M configs expect")
        return 1
    if "config FLASHFORGE_LOADCELL" not in text:
        if not text.endswith("\n"):
            text += "\n"
        with open(kconfig, "w") as f:
            f.write(text + KCONFIG)

    with open(makefile) as f:
        lines = f.readlines()
    missing = [l for l in MAKE_LINES if l not in lines]
    if missing:
        at = next((i for i, l in enumerate(lines) if l.startswith(ANCHOR)), None)
        if at is None:
            lines += ["\n"] + missing
        else:
            # keep the blank line that precedes the anchor comment
            ins = at - 1 if at > 0 and lines[at - 1].strip() == "" else at
            lines[ins:ins] = missing
        with open(makefile, "w") as f:
            f.writelines(lines)
    print("ad5m_mcu_apply: load cell and TVOC bridges added to", stm32)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
