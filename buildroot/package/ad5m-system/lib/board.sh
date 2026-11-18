# SPDX-License-Identifier: GPL-3.0-or-later
# Kiln OS (Adventurer 5M): read the board profile. Sourced; call board_get KEY.
# The profile is /etc/kiln-board (buildroot/board/ad5m/rootfs-overlay/etc/kiln-board).
#   board_get MAINBOARD_TTY   ->  /dev/ttyS5
#   board_need MCU_NRST_GPIO  ->  the value, or an error message and return 1
#                                 when it is missing or empty
KILN_BOARD_FILE=${KILN_BOARD_FILE:-/etc/kiln-board}

board_get() {
	sed -n "s/^$1=//p" "$KILN_BOARD_FILE" 2>/dev/null | tail -n 1
}

board_need() {
	_v=$(board_get "$1")
	if [ -z "$_v" ]; then
		echo "board: $1 is not set in $KILN_BOARD_FILE" >&2
		return 1
	fi
	echo "$_v"
}
