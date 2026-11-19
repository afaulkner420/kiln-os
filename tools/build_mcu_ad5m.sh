#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build Klipper MCU firmware for the Adventurer 5M / 5M Pro mainboard and eboard (Nations N32G455).
# WORK IN PROGRESS: not yet run. Modelled on tools/build_mcu.sh (mainline source), plus the
# load cell and TVOC bridges the AD5M's mainboard needs (tools/ad5m_mcu_apply.py).
#
# usage: tools/build_mcu_ad5m.sh [klipper checkout]
#   Same Klipper revision as tools/build_mcu.sh, klipper/mcu-patches/*.patch applied as commits,
#   then the AD5M bridges as one more commit with fixed author data, so the version string is
#   the same on every machine. Configs: klipper/mcu-configs/ad5m-<board>.mainline.config.
#   The checkout defaults to firmware/builds/klipper-ad5m (separate from build_mcu.sh's).
# Output: klipper/mcu-firmware/<version>/{mainboard.bin,eboard.hex,SHA256SUMS},
#         klipper/mcu-dicts/<version>/{mainboard,eboard}.dict and klipper/mcu-dicts/FLASHED_AD5M
# Needs arm-none-eabi-gcc and arm-none-eabi-newlib, git, python3.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
# One revision for AD5X and AD5M: read it from build_mcu.sh (fallback: its value when this was written)
REV=$(sed -n '/mainline)/,/;;/s/.*KLIPPER_REV=\([0-9a-f]*\).*/\1/p' "$REPO/tools/build_mcu.sh" | head -n 1)
REV=${REV:-9cb99754c}
KLIPPER=${1:-$REPO/firmware/builds/klipper-ad5m}

if [ ! -d "$KLIPPER" ]; then
    git clone -q https://github.com/Klipper3d/klipper "$KLIPPER"
fi
git -C "$KLIPPER" reset -q --hard
git -C "$KLIPPER" clean -q -fd
git -C "$KLIPPER" checkout -q --detach "$REV"
for p in "$REPO"/klipper/mcu-patches/*.patch; do
    GIT_COMMITTER_NAME=ad5x GIT_COMMITTER_EMAIL=ad5x@localhost \
    GIT_COMMITTER_DATE="2026-10-15T00:00:00Z" \
        git -C "$KLIPPER" am -q --committer-date-is-author-date "$p"
done
python3 "$REPO/tools/ad5m_mcu_apply.py" "$KLIPPER"
git -C "$KLIPPER" add -A
GIT_AUTHOR_NAME=ad5m GIT_AUTHOR_EMAIL=ad5m@localhost GIT_AUTHOR_DATE="2026-11-18T00:00:00Z" \
GIT_COMMITTER_NAME=ad5m GIT_COMMITTER_EMAIL=ad5m@localhost GIT_COMMITTER_DATE="2026-11-18T00:00:00Z" \
    git -C "$KLIPPER" commit -q -m "stm32: Flashforge AD5M load cell and TVOC bridges (from xblax/klipper)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
VERSION=""
for board in mainboard eboard; do
    cp "$REPO/klipper/mcu-configs/ad5m-$board.mainline.config" "$WORK/$board.config"
    make -s -C "$KLIPPER" KCONFIG_CONFIG="$WORK/$board.config" OUT="$WORK/out-$board/" olddefconfig
    make -s -C "$KLIPPER" -j"${KILN_JOBS:-$(nproc)}" KCONFIG_CONFIG="$WORK/$board.config" OUT="$WORK/out-$board/"
    # IAPCommand-style hex for the eboard bootloader: the reset handler in the start-address record
    RESET=$(od -An -tx4 -j4 -N4 "$WORK/out-$board/klipper.bin" | tr -d ' ')
    arm-none-eabi-objcopy -O ihex --set-start=0x$RESET \
        "$WORK/out-$board/klipper.elf" "$WORK/out-$board/klipper.hex"
    VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
        "$WORK/out-$board/klipper.dict")
done
# The load cell bridge must really be in the mainboard build, or LOAD_CELL_TARE stops every print
grep -q flashforge_loadcell "$WORK/out-mainboard/klipper.dict" || {
    echo "the mainboard dictionary has no flashforge_loadcell commands: CONFIG_FLASHFORGE_LOADCELL is off" >&2
    exit 1
}

DEST="$REPO/klipper/mcu-firmware/$VERSION"
DICT="$REPO/klipper/mcu-dicts/$VERSION"
mkdir -p "$DEST" "$DICT"
cp "$WORK/out-mainboard/klipper.bin"  "$DEST/mainboard.bin"
cp "$WORK/out-eboard/klipper.hex"     "$DEST/eboard.hex"
cp "$WORK/out-mainboard/klipper.dict" "$DICT/mainboard.dict"
cp "$WORK/out-eboard/klipper.dict"    "$DICT/eboard.dict"
(cd "$DEST" && sha256sum mainboard.bin eboard.hex > SHA256SUMS)
echo "$VERSION" > "$REPO/klipper/mcu-dicts/FLASHED_AD5M"
echo "Built $VERSION: $DEST (FLASHED_AD5M updated)"
