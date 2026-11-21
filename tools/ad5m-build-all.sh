#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ad5m-build-all.sh: build everything for Kiln OS on the Adventurer 5M in one run, inside
# WSL2 (Ubuntu or Debian) or any Linux x86-64 machine.
# WORK IN PROGRESS, NEVER RUN END TO END: the first real run will find problems. It stops at
# the first one, tells you the step and the log file, and can be started again (every step
# skips what is already done). Send the log tail and it can be fixed.
#
# usage: bash tools/ad5m-build-all.sh [options]
#   --repo DIR     the Kiln OS checkout to build (default: the one this script is in)
#   --work DIR     where to build (default: ~/kiln-ad5m-work). MUST be on Linux's own disk,
#                  not under /mnt/ (Windows drives: Buildroot is far too slow and breaks on
#                  file names/permissions there). If --repo is under /mnt/, it is copied
#                  here first, every run.
#   --no-apt       don't install host packages (you did it yourself)
#   --skip-mcu     don't build the boards' firmware (use what is in klipper/mcu-firmware)
#   --skip-image   don't build the root image (just the firmware)
#   --jobs N       parallel jobs (default: all cores; fewer if it runs out of memory)
#   --dry-run      print what would run, change nothing
#   --clean        remove the image build directory first (a full rebuild, ~1 hour more).
#                  Use it once after updating from a version that built glibc with the wrong
#                  minimum kernel (headers 5.10 without the --enable-kernel=5.4 override).
#
# Steps: preflight -> apt -> sync -> wire -> buildroot -> mcu -> image -> collect
# Output: <work>/dist/ad5m-<date>/  with rootfs.tar (+ .sha256), the MCU firmware, the installer
# and a README. In Windows: \\wsl$\<distro>\home\<you>\kiln-ad5m-work\dist
set -uo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SELF/.." && pwd)
WORK=${HOME}/kiln-ad5m-work
DO_APT=1 DO_MCU=1 DO_IMAGE=1 DRY= CLEAN=
JOBS=$(nproc 2>/dev/null || echo 2)
BUILDROOT_TAG=2026.02.3

while [ $# -gt 0 ]; do
	case "$1" in
	--repo) REPO=$(cd "$2" && pwd) || exit 2; shift ;;
	--work) WORK=$2; shift ;;
	--no-apt) DO_APT= ;;
	--skip-mcu) DO_MCU= ;;
	--skip-image) DO_IMAGE= ;;
	--jobs) JOBS=$2; shift ;;
	--dry-run) DRY=1 ;;
	--clean) CLEAN=1 ;;
	-h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
	*) echo "unknown option: $1 (--help)" >&2; exit 2 ;;
	esac
	shift
done

LOG=$WORK/logs/build-$(date +%Y%m%d-%H%M%S).log
[ -n "$DRY" ] || mkdir -p "$WORK/logs" 2>/dev/null || true
STEP=start

say() { echo; echo "==> $*"; }
note() { echo "    $*"; }
run() {		# run a command, log it, stop the script when it fails
	if [ -n "$DRY" ]; then echo "    DRY: $*"; return 0; fi
	"$@"
}
die() {
	echo >&2
	echo "STOPPED in step '$STEP': $*" >&2
	echo "Log: $LOG" >&2
	[ -f "$LOG" ] && { echo "--- last lines of the log:" >&2; tail -n 25 "$LOG" >&2; }
	exit 1
}
trap 'die "an unexpected error (line $LINENO)"' ERR
set -E

# Everything below also goes to the log (not in a dry run)
if [ -z "$DRY" ]; then exec > >(tee -a "$LOG") 2>&1; fi

# ---------------------------------------------------------------------------------------
STEP=preflight; say "Preflight"
[ "$(uname -s)" = Linux ] || die "this needs Linux (WSL2 is fine)"
[ "$(uname -m)" = x86_64 ] || die "this needs an x86-64 machine (Buildroot's toolchain download)"
IN_WSL=; grep -qi microsoft /proc/version 2>/dev/null && IN_WSL=1
note "WSL: ${IN_WSL:-no}   repo: $REPO   work: $WORK   jobs: $JOBS"
case "$WORK" in
/mnt/*) die "--work $WORK is on a Windows drive. Use a path on Linux's own disk (the default ~/kiln-ad5m-work)." ;;
esac
if [ "$(id -u)" = 0 ] && [ -z "$DRY" ]; then
	die "don't run this as root: Buildroot refuses to build as root. Use a normal user (sudo is asked for apt only)."
fi
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
[ "${mem_kb:-0}" -ge 6000000 ] || note "WARNING: only $((mem_kb / 1024)) MB RAM: the build may run out of memory. In WSL, raise 'memory=' in %UserProfile%\\.wslconfig, or use --jobs 2."
free_kb=$(df -Pk "$(dirname "$WORK")" 2>/dev/null | awk 'NR==2 {print $4}')
[ "${free_kb:-0}" -ge 62914560 ] || note "WARNING: free disk here is $((${free_kb:-0} / 1048576)) GB; a full build needs about 60 GB (WSL's virtual disk grows on demand, but the Windows drive it lives on must have the room)."
for f in tools/build_mcu_ad5m.sh tools/ad5m_mcu_apply.py tools/install/ad5m-install.sh buildroot/configs/ad5m_defconfig \
	buildroot/package/ad5m-system/ad5m-system.mk buildroot/board/ad5m/post-build.sh; do
	[ -e "$REPO/$f" ] || die "$f is missing from $REPO: copy the kiln-os-ad5m-wip files into the Kiln OS checkout first."
done
[ -d "$REPO/buildroot/package/klipper" ] || die "$REPO is not a Kiln OS checkout (no buildroot/package/klipper)"
if [ -z "$DRY" ]; then curl -fsI --max-time 15 https://github.com >/dev/null 2>&1 || die "no network (github.com unreachable)"; fi
note "ok"

# ---------------------------------------------------------------------------------------
STEP=apt; say "Host packages"
PKGS="build-essential g++ git curl wget ca-certificates cpio unzip zip rsync bc lzop file patch perl python3 python3-setuptools \
python3-pip flex bison libssl-dev libelf-dev libncurses-dev squashfs-tools u-boot-tools device-tree-compiler xz-utils \
gcc-arm-none-eabi libnewlib-arm-none-eabi binutils-arm-none-eabi make pkg-config"
if [ -n "$DO_APT" ]; then
	missing=
	for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; done
	if [ -n "$missing" ]; then
		note "installing:$missing"
		run sudo apt-get update -qq || die "apt-get update failed"
		run sudo apt-get install -y -qq $missing || die "apt-get install failed (package names are for Debian/Ubuntu)"
	else
		note "all host packages present"
	fi
else
	note "skipped (--no-apt)"
fi

# ---------------------------------------------------------------------------------------
STEP=sync; say "Source tree"
case "$REPO" in
/mnt/*)
	SRC=$WORK/kiln-os
	note "the checkout is on a Windows drive: copying it to $SRC (build output and downloads are not copied)"
	run mkdir -p "$SRC"
	run rsync -a --delete --exclude 'buildroot/output*' --exclude 'buildroot/src' --exclude 'buildroot/dl' \
		--exclude 'firmware/builds' --exclude 'dist' "$REPO"/ "$SRC"/ || die "rsync failed"
	;;
*) SRC=$REPO; note "building in place: $SRC" ;;
esac
cd "$SRC" 2>/dev/null || [ -n "$DRY" ] || die "can't enter $SRC"
# files on Windows drives lose their executable bit when copied by some tools
run chmod +x tools/*.sh tools/*.py tools/install/*.sh buildroot/board/ad5m/*.sh \
	buildroot/package/ad5m-system/bin/* buildroot/package/ad5m-system/sbin/* buildroot/package/ad5m-system/init.d/S* 2>/dev/null || true
# CRLF line endings (a Windows git checkout) break shell scripts: fix them in our files
if [ -z "$DRY" ]; then
	for f in $(grep -rIl $'\r' tools buildroot/board/ad5m buildroot/package/ad5m-system klipper/ad5m*.cfg klipper/printer-ad5m.cfg 2>/dev/null); do
		note "removing CRLF line endings in $f"; sed -i 's/\r$//' "$f"
	done
fi

# ---------------------------------------------------------------------------------------
STEP=wire; say "Adding the AD5M package to Buildroot's menu"
CFG=buildroot/Config.in
if [ -n "$DRY" ]; then
	note "DRY: ensure $CFG sources package/ad5m-system/Config.in"
elif ! grep -q 'package/ad5m-system/Config.in' "$CFG"; then
	echo 'source "$BR2_EXTERNAL_AD5X_PATH/package/ad5m-system/Config.in"' >> "$CFG"
	note "added ad5m-system to $CFG"
else
	note "already there"
fi
[ -d buildroot/package/guppyscreen ] && ! grep -q 'package/guppyscreen/Config.in' "$CFG" && [ -z "$DRY" ] &&
	echo 'source "$BR2_EXTERNAL_AD5X_PATH/package/guppyscreen/Config.in"' >> "$CFG"
for f in $(ls tools/*.sh tools/install/*.sh buildroot/board/ad5m/*.sh 2>/dev/null); do
	bash -n "$f" || die "syntax error in $f"
done
note "scripts parse"

# ---------------------------------------------------------------------------------------
STEP=buildroot; say "Buildroot $BUILDROOT_TAG"
if [ ! -d buildroot/src/.git ] && [ ! -f buildroot/src/Makefile ]; then
	run git clone --depth 1 --branch "$BUILDROOT_TAG" https://github.com/buildroot/buildroot.git buildroot/src || die "can't clone Buildroot $BUILDROOT_TAG"
else
	note "buildroot/src is there"
fi

# ---------------------------------------------------------------------------------------
STEP=mcu
if [ -n "$DO_MCU" ]; then
	say "Board firmware (mainboard and eboard, mainline Klipper plus the load cell bridge)"
	run env KILN_JOBS="$JOBS" bash tools/build_mcu_ad5m.sh || die "the MCU firmware build failed (is it the load cell C code against this Klipper revision? the log has the compiler output)"
	[ -n "$DRY" ] || note "firmware: $(cat klipper/mcu-dicts/FLASHED_AD5M)"
else
	say "Board firmware: skipped (--skip-mcu); using klipper/mcu-dicts/FLASHED_AD5M if present"
fi

# ---------------------------------------------------------------------------------------
STEP=image
if [ -n "$DO_IMAGE" ]; then
	say "Kiln OS root image for the AD5M (Buildroot: the first build downloads and compiles the toolchain, about 1 hour)"
	export AD5X_VENDOR_FREE=1
	export AD5X_VERSION=${AD5X_VERSION:-v0.0.0-ad5m.$(date +%Y%m%d)}
	O=$SRC/buildroot/output-ad5m
	[ -z "$CLEAN" ] || run rm -rf "$O"
	BR=(make -C buildroot/src "BR2_EXTERNAL=$SRC/buildroot" "O=$O")
	run "${BR[@]}" ad5m_defconfig || die "ad5m_defconfig failed"
	if [ -z "$DRY" ]; then
		# Buildroot silently drops symbols it does not know: check that the important ones stuck
		for s in BR2_arm=y BR2_cortex_a7=y BR2_PACKAGE_KLIPPER=y BR2_PACKAGE_MOONRAKER=y BR2_PACKAGE_FLUIDD=y BR2_PACKAGE_UBOOT_TOOLS=y; do
			grep -q "^$s\$" "$O/.config" || die "$s did not make it into the Buildroot config (a package or option this Buildroot does not have)"
		done
		# glibc must accept the printer's 5.4.61 kernel (ad5m-system.mk lowers --enable-kernel from the headers' 5.10)
		gopts=$("${BR[@]}" -s printvars VARS=GLIBC_CONF_OPTS 2>/dev/null)
		case "$gopts" in
		*--enable-kernel=5.4*) note "glibc minimum kernel: 5.4 (the printer runs 5.4.61)" ;;
		*) die "glibc would refuse to run on the printer's 5.4.61 kernel (no --enable-kernel=5.4 in GLIBC_CONF_OPTS: is BR2_PACKAGE_AD5M_SYSTEM enabled and the package wired in?)" ;;
		esac
		for s in BR2_PACKAGE_AD5M_SYSTEM BR2_PACKAGE_GUPPYSCREEN; do
			grep -q "^$s=y\$" "$O/.config" || note "NOTE: $s is not enabled (the package is missing or not wired): the image will not have it"
		done
	fi
	run "${BR[@]}" -j"$JOBS" || die "the image build failed (the first error is above the 'make:' lines in the log)"
else
	say "Image: skipped (--skip-image)"
fi

# ---------------------------------------------------------------------------------------
STEP=collect; say "Collecting the results"
D=$WORK/dist/ad5m-$(date +%Y%m%d-%H%M)
run mkdir -p "$D"
if [ -z "$DRY" ]; then
	O=$SRC/buildroot/output-ad5m
	for f in rootfs.tar rootfs.tar.sha256 rootfs.ext4 IMAGES.txt; do
		[ -f "$O/images/$f" ] && cp "$O/images/$f" "$D/"
	done
	cp tools/install/ad5m-install.sh "$D/"
	if [ -f klipper/mcu-dicts/FLASHED_AD5M ]; then
		v=$(cat klipper/mcu-dicts/FLASHED_AD5M)
		[ -d "klipper/mcu-firmware/$v" ] && cp -r "klipper/mcu-firmware/$v" "$D/mcu-firmware-$v"
	fi
	cat > "$D/README.txt" <<TXT
Kiln OS for the Flashforge Adventurer 5M / 5M Pro: first test build.
Built: $(date)   Source: $SRC
NOT TESTED ON A PRINTER. Read docs/ad5m-boot.md first. Have a serial adapter on the debug
UART and a copy of the backup the installer makes before you use --activate.

On the printer (stock or zMod running), as root:
  1. scp -O ad5m-install.sh rootfs.tar root@<printer-ip>:/data/
  2. ssh root@<printer-ip>
  3. sh /data/ad5m-install.sh --check          (changes nothing)
  4. sh /data/ad5m-install.sh /data/rootfs.tar (backup + install; the next boot is still stock)
  5. then follow docs/ad5m-boot.md: MCU bring-up first, activation last

Before step 1, check the image on this machine:   bash tools/ad5m-verify-image.sh
(needs: sudo apt install qemu-user-static, for the Klipper configuration test)
TXT
	( cd "$D" && ls -la )
fi
STEP=done
say "Done"
echo "Results: $D"
[ -z "$IN_WSL" ] || echo "In Windows Explorer: \\\\wsl\$\\${WSL_DISTRO_NAME:-<distro>}${D//\//\\}"
echo "Next: bash tools/ad5m-verify-image.sh   (checks the image before it goes near a printer)"
echo "Log: $LOG"
exit 0
