#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ad5m-verify-image.sh: check a built Kiln OS image for the Adventurer 5M BEFORE it goes near a
# printer. Run it in WSL (or Linux) on the rootfs.tar that tools/ad5m-build-all.sh made.
# WORK IN PROGRESS, NEVER RUN ON A REAL IMAGE YET: send the report if anything looks wrong.
#
# usage: bash tools/ad5m-verify-image.sh [rootfs.tar] [options]
#   rootfs.tar      default: the newest ~/kiln-ad5m-work/dist/*/rootfs.tar
#   --no-run        static checks only (no qemu, no root needed except for extraction)
#   --keep          keep the extracted image in the work directory (default: delete it)
#   --report FILE   where to write the report (default: ./ad5m-verify-report.txt)
#
# What it does:
#   1. static checks on the files: the hand-over hook, tools, init scripts (sh -n), config files, the
#      boards' firmware and its checksums, the users, the glibc minimum kernel (ELF ABI note: must not
#      exceed 5.4.61, the printer's kernel), every shared library the main programs need;
#   2. with qemu for ARM (sudo apt install qemu-user-static, or qemu-user if apt does not know the first): runs the image's own Python and Klipper
#      against the image's own printer.cfg and the MCU data dictionaries, in Klipper's test mode. That
#      catches config mistakes (pins, missing modules, macro syntax) without any hardware.
# It needs sudo to unpack the image with the right ownership and to chroot. Nothing outside the work
# directory is changed.
set -uo pipefail

TAR=; RUN=1; KEEP=; REPORT=$PWD/ad5m-verify-report.txt
while [ $# -gt 0 ]; do
	case "$1" in
	--no-run) RUN= ;;
	--keep) KEEP=1 ;;
	--report) REPORT=$2; shift ;;
	-h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
	-*) echo "unknown option $1" >&2; exit 2 ;;
	*) TAR=$1 ;;
	esac
	shift
done
[ -n "$TAR" ] || TAR=$(ls -t "$HOME"/kiln-ad5m-work/dist/*/rootfs.tar 2>/dev/null | head -n 1)
[ -f "$TAR" ] || { echo "no rootfs.tar: give its path" >&2; exit 2; }

PASS=0 FAIL=0 WARN=0
: > "$REPORT"
out() { echo "$*" | tee -a "$REPORT"; }
ok() { PASS=$((PASS + 1)); out "ok    $*"; }
bad() { FAIL=$((FAIL + 1)); out "FAIL  $*"; }
warn() { WARN=$((WARN + 1)); out "warn  $*"; }
section() { out ""; out "== $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "this needs '$1' (sudo apt install $2)" >&2; exit 2; }; }
need readelf binutils
need tar tar
need sha256sum coreutils

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ad5m-verify.XXXXXX")
R=$WORK/root
cleanup() {
	for m in dev proc; do mountpoint -q "$R/$m" 2>/dev/null && sudo umount "$R/$m" 2>/dev/null; done
	if [ -z "$KEEP" ]; then sudo rm -rf "$WORK" 2>/dev/null || rm -rf "$WORK"; else echo "kept: $WORK"; fi
}
trap cleanup EXIT

out "Kiln OS image check: $TAR"
out "$(date)   size: $(du -h "$TAR" | cut -f1)"
[ -f "$TAR.sha256" ] || [ -f "$(dirname "$TAR")/rootfs.tar.sha256" ] && {
	( cd "$(dirname "$TAR")" && sha256sum -c rootfs.tar.sha256 >/dev/null 2>&1 ) && ok "rootfs.tar matches its .sha256" || bad "rootfs.tar does not match its .sha256"
}

# ---------------------------------------------------------------------------------------
section "Unpacking"
mkdir -p "$R"
if sudo -n true 2>/dev/null || sudo -v; then
	sudo tar -xpf "$TAR" -C "$R" 2>"$WORK/tar.err" || { bad "tar extraction failed: $(head -n 3 "$WORK/tar.err")"; exit 1; }
	SUDO=sudo
else
	warn "no sudo: unpacking without ownership; the qemu test is skipped"
	tar --no-same-owner --exclude='./dev/*' -xf "$TAR" -C "$R" 2>"$WORK/tar.err" || true
	SUDO= RUN=
fi
files=$(find "$R" -type f 2>/dev/null | wc -l)
size_mb=$(du -sm "$R" 2>/dev/null | cut -f1)
out "files: $files   unpacked size: ${size_mb} MB"
[ "${size_mb:-0}" -le 700 ] && ok "unpacked size ${size_mb} MB (the installer wants 800 MB free on /data)" || warn "unpacked size ${size_mb} MB: more than the installer's free-space check allows for"

# ---------------------------------------------------------------------------------------
section "Hand-over and board files"
for f in sbin/init etc/kiln-version etc/ad5x-release etc/kiln-board etc/fw_env.config etc/init.d/rcS \
	usr/share/ad5x/stock-side/ad5m-init usr/bin/ad5m-handoff usr/bin/ad5m-vendor usr/bin/ad5m-mcu usr/bin/ad5m-backlight \
	usr/bin/ad5x-flash-n32 usr/bin/ad5x-flash-iap usr/bin/boot_eboard usr/bin/ad5x-mcu-version usr/lib/ad5x/board.sh; do
	[ -e "$R/$f" ] && ok "$f" || bad "missing: $f"
done
for f in usr/share/ad5x/stock-side/ad5m-init usr/bin/ad5m-handoff usr/bin/ad5m-vendor usr/bin/ad5m-mcu; do
	[ -x "$R/$f" ] && ok "executable: $f" || bad "not executable: $f"
	head -n 1 "$R/$f" 2>/dev/null | grep -q '^#!' && ok "shebang: $f" || bad "no #! line: $f"
done
head -n 1 "$R/usr/share/ad5x/stock-side/ad5m-init" 2>/dev/null | grep -q '^#!/bin/sh$' && ok "ad5m-init uses #!/bin/sh (stock has it)" || bad "ad5m-init shebang is not /bin/sh"
grep -q '^BOARD=ad5m' "$R/etc/kiln-board" 2>/dev/null && ok "/etc/kiln-board says ad5m" || bad "/etc/kiln-board is not the AD5M's"
[ -s "$R/etc/fw_env.config" ] && grep -q mmcblk0p2 "$R/etc/fw_env.config" && ok "fw_env.config names the env partitions" || bad "fw_env.config is wrong"
[ -L "$R/sbin/init" ] || [ -x "$R/sbin/init" ] && ok "/sbin/init resolves to $(readlink -f "$R/sbin/init" 2>/dev/null | sed "s#^$R##")" || bad "/sbin/init"
cat "$R/etc/kiln-version" 2>/dev/null | sed 's/^/      /' | tee -a "$REPORT" >/dev/null

# ---------------------------------------------------------------------------------------
section "Services (/etc/init.d)"
for s in "$R"/etc/init.d/S*; do
	n=${s##*/}
	if head -n 1 "$s" | grep -q 'sh$'; then
		sh -n "$s" 2>/dev/null && ok "$n parses" || bad "$n has a shell syntax error"
	fi
done
out "      order: $(ls "$R"/etc/init.d/ | grep '^S' | tr '\n' ' ')"
for want in S05ad5m-data S06ad5m-modules S07ad5m-board S35ad5m-sound S41ad5m-eth S42ad5m-wifi S60ad5m-mcu S61klipper S62moonraker S63nginx S99ad5m-booted; do
	[ -x "$R/etc/init.d/$want" ] && ok "service $want" || bad "service missing or not executable: $want"
done
for notwant in S05ad5x-data S07ad5x-board S60ad5x-eboard S00ad5x-kernel S01ad5x-tryboot; do
	[ -e "$R/etc/init.d/$notwant" ] && bad "AD5X-only service in the image: $notwant"
done
[ -e "$R/etc/init.d/S80guppyscreen" ] && ok "service S80guppyscreen" || warn "no S80guppyscreen (GuppyScreen not in this image)"

# ---------------------------------------------------------------------------------------
section "Klipper configuration files"
D=$R/usr/share/ad5x
for f in config/ad5m.cfg config/ad5m-macros.cfg config/ad5m-guppy.cfg config/ad5m-setup.cfg config/ad5m-pro.cfg config/ad5m-loadcell.cfg defaults/printer.cfg defaults/local.cfg; do
	[ -f "$D/$f" ] && ok "$f" || bad "missing: usr/share/ad5x/$f"
done
grep -q 'ad5m.cfg' "$D/defaults/printer.cfg" 2>/dev/null && ok "defaults/printer.cfg includes ad5m.cfg" || bad "defaults/printer.cfg is not the AD5M's (it must include ad5m.cfg)"
grep -q 'ad5x.cfg' "$D/defaults/printer.cfg" 2>/dev/null && bad "defaults/printer.cfg still includes ad5x.cfg"
[ -e "$D/defaults/unit.cfg" ] && bad "AD5X defaults/unit.cfg is in the image"
[ -d "$D/defaults/macros" ] && bad "AD5X defaults/macros/ is in the image"
for m in flashforge_loadcell.py flashforge_tvoc.py ad5x_sound.py ad5x_log.py ad5m_setup.py; do
	f=$(find "$R/usr/lib/klipper" -name "${m%.py}.py*" -o -name "${m%.py}.cpython*.pyc" 2>/dev/null | head -n 1)
	[ -n "$f" ] && ok "Klipper module $m" || bad "Klipper module missing: $m"
done

# ---------------------------------------------------------------------------------------
section "Boards' firmware"
M=$R/usr/share/ad5x/mcu
if [ -f "$M/VERSION" ]; then
	ok "firmware version $(cat "$M/VERSION")"
	( cd "$M" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) && ok "firmware checksums match" || bad "firmware checksums do not match"
	for f in mainboard.bin eboard.hex; do [ -s "$M/$f" ] && ok "$f $(du -h "$M/$f" | cut -f1)" || bad "$f missing or empty"; done
else
	warn "no firmware in the image (usr/share/ad5x/mcu): the build ran without the MCU step; ad5m-mcu will only start the eboard"
fi

# ---------------------------------------------------------------------------------------
section "Users"
grep -q '^klipper:x:101:' "$R/etc/passwd" 2>/dev/null && ok "user klipper (uid 101)" || bad "no user klipper with uid 101 in /etc/passwd"
# /etc/shadow is root-only (mode 600): read it with sudo, or say it could not be read
if [ -n "$SUDO" ]; then
	$SUDO grep -q '^root:' "$R/etc/shadow" 2>/dev/null && ok "root in /etc/shadow" || bad "no root entry in /etc/shadow"
else
	warn "/etc/shadow not checked (needs sudo)"
fi

# ---------------------------------------------------------------------------------------
section "Kernel compatibility (the printer runs 5.4.61)"
vgt() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" != "$2" ]; }	# $1 > $2
abi_of() { readelf -n "$1" 2>/dev/null | sed -n 's/.*ABI: *\([0-9][0-9.]*\).*/\1/p' | head -n 1; }
for b in bin/busybox usr/bin/python3 usr/sbin/nginx usr/bin/guppyscreen lib/ld-linux-armhf.so.3 lib/libc.so.6; do
	[ -e "$R/$b" ] || continue
	f=$(readlink -f "$R/$b" 2>/dev/null); case "$f" in "$R"*) ;; *) f="$R/$b" ;; esac
	abi=$(abi_of "$f")
	if [ -z "$abi" ]; then
		[ "$b" = lib/libc.so.6 ] && warn "$b: no ABI note (check with: readelf -n)" || out "      $b: no ABI note"
	elif vgt "$abi" 5.4.61; then bad "$b needs kernel $abi or newer: it will stop with 'kernel too old' on the printer"
	else ok "$b accepts kernel $abi and newer"; fi
done
file_out=$(readelf -h "$R/bin/busybox" 2>/dev/null | sed -n 's/^ *Machine: *//p')
[ -n "$file_out" ] && out "      busybox machine: $file_out"
echo "$file_out" | grep -qi arm && ok "binaries are ARM" || bad "busybox is not an ARM binary ($file_out)"

# ---------------------------------------------------------------------------------------
section "Shared libraries the main programs need"
libdirs="$R/lib $R/usr/lib $R/lib32 $R/usr/lib32"
for b in bin/busybox usr/bin/python3 usr/sbin/nginx usr/bin/guppyscreen usr/bin/ad5m-backlight; do
	[ -f "$R/$b" ] && head -c 4 "$R/$b" | grep -q ELF || continue
	missing=
	for n in $(readelf -d "$R/$b" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
		found=
		for d in $libdirs; do [ -e "$d/$n" ] && { found=1; break; }; done
		[ -n "$found" ] || missing="$missing $n"
	done
	[ -z "$missing" ] && ok "$b: all libraries present" || bad "$b: missing libraries:$missing"
done

# ---------------------------------------------------------------------------------------
if [ -n "$RUN" ]; then
section "Running the image (qemu-user): Python and Klipper's configuration test"
	QEMU=$(command -v qemu-arm-static 2>/dev/null || command -v qemu-arm 2>/dev/null)
	if [ -z "$QEMU" ]; then
		warn "no qemu for ARM: sudo apt install qemu-user-static (or, if apt does not know it, sudo apt install qemu-user), then run this again"
	elif [ -z "$SUDO" ]; then
		warn "no sudo: the qemu test is skipped"
	else
		# Two ways to run the image's ARM programs:
		#  - a static qemu (qemu-user-static): chroot into the image and run it there;
		#  - the ordinary qemu-arm (package qemu-user): no chroot; "-L <image>" makes qemu look for the
		#    program's loader and libraries, and for every absolute path that exists in the image, inside it.
		#    Files the program creates must exist in the image first, or they land on the host: the log,
		#    the output file and the variables file are created below before they are used.
		MODE=direct
		case "$QEMU" in *-static) MODE=chroot ;; esac
		out "      qemu: $QEMU ($MODE mode)"
		$SUDO mkdir -p "$R/dev" "$R/proc" "$R/tmp" "$R/home/klipper/printer_data/config" "$R/home/klipper/printer_data/gcodes" "$R/home/klipper/printer_data/logs"
		if [ "$MODE" = chroot ]; then
			$SUDO cp "$QEMU" "$R/qemu-arm-static"
			$SUDO mount --bind /dev "$R/dev" 2>/dev/null; $SUDO mount -t proc proc "$R/proc" 2>/dev/null
			inroot() { $SUDO chroot "$R" /qemu-arm-static "$@"; }
		else
			inroot() { local prog=$1; shift; $SUDO "$QEMU" -L "$R" "$R$prog" "$@"; }
		fi
		pyout=$(inroot /usr/bin/python3 -c 'import sys; print(sys.version.split()[0])' 2>&1)
		if [ $? = 0 ]; then ok "the image's Python starts: $pyout"; else bad "the image's Python does not start under qemu: $pyout"; fi
		for mod in jinja2 serial greenlet cffi numpy can tornado; do
			inroot /usr/bin/python3 -c "import $mod" >/dev/null 2>&1 && ok "python module $mod" || warn "python module $mod does not import (Moonraker/Klipper may need it)"
		done
		# Klipper test mode: the image's own printer.cfg, the data dictionaries of the firmware build
		V=$(cat "$R/usr/share/ad5x/mcu/VERSION" 2>/dev/null)
		DICT=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/klipper/mcu-dicts/$V
		if [ -n "$V" ] && [ -f "$DICT/mainboard.dict" ] && [ -f "$DICT/eboard.dict" ]; then
			CFG=$R/tmp/cfg; $SUDO mkdir -p "$CFG" "$R/home/klipper/printer_data/gcodes" "$R/home/klipper/printer_data/logs"
			$SUDO cp "$D"/defaults/*.cfg "$CFG"/ 2>/dev/null
			$SUDO cp "$DICT/mainboard.dict" "$R/tmp/mainboard.dict"; $SUDO cp "$DICT/eboard.dict" "$R/tmp/eboard.dict"
			$SUDO sh -c "printf 'G28\nM105\nM104 S200\nM140 S60\nSET_HEATER_TEMPERATURE HEATER=extruder TARGET=0\nSET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=0\nGET_POSITION\n' > '$R/tmp/test.gcode'"
			$SUDO touch "$R/tmp/klippy.log" "$R/tmp/out.bin" "$R/tmp/klippy.stdout" "$R/home/klipper/printer_data/config/variables.cfg"
			klog=$R/tmp/klippy.log
			inroot /usr/bin/python3 /usr/lib/klipper/klippy/klippy.py /tmp/cfg/printer.cfg \
				-i /tmp/test.gcode -o /tmp/out.bin -l /tmp/klippy.log \
				-d /tmp/mainboard.dict -d eboard=/tmp/eboard.dict >/tmp/klippy.stdout 2>&1
			if grep -q "Config error\|Unknown config object\|Option '.*' is not valid\|Traceback" "$klog" 2>/dev/null; then
				bad "Klipper rejected the configuration:"
				grep -m 6 -B1 "Config error\|Unknown config object\|Option '.*' is not valid\|Traceback\|Error" "$klog" 2>/dev/null | sed 's/^/        /' | tee -a "$REPORT" >/dev/null
			elif grep -q "Starting Klippy" "$klog" 2>/dev/null; then
				ok "Klipper loaded printer.cfg with the firmware's data dictionaries"
			else
				warn "no clear result from Klipper's test run: see $klog (use --keep)"
			fi
			# the macros the screen and the slicer call must exist as commands
			for c in START_PRINT PRINT_START END_PRINT PAUSE RESUME CANCEL_PRINT AUTO_BED_LEVEL LOAD_CELL_TARE AUTO_FULL_BED_LEVEL PID_TUNE_BED; do
				grep -qs "^\[gcode_macro $c\]" "$D/config/ad5m-macros.cfg" "$D/config/ad5m-guppy.cfg" || bad "macro $c is not defined in the config files"
			done
		else
			warn "no data dictionaries for firmware version '${V:-none}' in klipper/mcu-dicts: skipping Klipper's test mode (no firmware in this build?)"
		fi
	fi
fi

# ---------------------------------------------------------------------------------------
section "Result"
out "passed: $PASS   warnings: $WARN   failed: $FAIL"
out "report: $REPORT"
[ "$FAIL" = 0 ] && out "No failures. This does not prove it runs on the printer: that still needs the careful first test." || out "Fix the FAIL lines before this image goes near a printer. Send the report and I can help."
exit $((FAIL > 0))
