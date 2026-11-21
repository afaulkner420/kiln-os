#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Install Kiln OS (milestone 1) on a Flashforge Adventurer 5M / 5M Pro running the STOCK system.
# WORK IN PROGRESS, NOT TESTED ON A PRINTER. Run it as root on the printer (SSH or the serial
# console), with a stock or zMod system running and no print in progress.
#
# usage: sh ad5m-install.sh --check                  only check; changes nothing
#        sh ad5m-install.sh TARBALL                  install (rootfs.tar or .tar.gz of the ad5m image)
#        sh ad5m-install.sh TARBALL --activate       ... and switch the boot over (see below)
#
# What it does, in order (docs/ad5m-boot.md):
#   1. checks (machine, kernel, root device, free space, tools). Nothing is changed before they pass;
#   2. backs up into /data/ad5x/backup/<time>: the U-Boot environment (fw_printenv and the raw
#      env and env-redund partitions), the boot FAT partition p1 (uImage, sunxi.dtb) and the
#      first MiB of the eMMC (partition table);
#   3. unpacks the image into /data/ad5x/os/root.new, then renames it to root;
#   4. copies the hand-over hook /sbin/ad5m-init onto the stock root: THE ONLY FILE THIS
#      WRITES OUTSIDE /data. The stock kernel, p1, p4 and the U-Boot environment are not touched
#      by this script, unless you give --activate (then "ad5m-handoff on" changes one U-Boot
#      variable, init, with fw_setenv);
#   5. leaves the system on stock. Without --activate the next boot is still stock.
# Undo: "sh /data/ad5x/os/root/usr/bin/ad5m-handoff off" (or, from Kiln OS, "ad5m-handoff off"),
# or give U-Boot's console (ttyS3, 115200) "setenv init /init; saveenv".
: "${AD5M_DATA:=/data}"
MIN_FREE_KB=${AD5M_MIN_FREE_KB:-800000}
TAR=; ACTIVATE=; CHECK=
for a in "$@"; do
	case "$a" in
	--check) CHECK=1 ;;
	--activate) ACTIVATE=1 ;;
	-*) echo "unknown option $a" >&2; exit 2 ;;
	*) TAR=$a ;;
	esac
done
[ -n "$CHECK" ] || [ -n "$TAR" ] || { sed -n '2,/^# Undo/p' "$0"; exit 2; }

fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "ok:   $*"; }

# --- 1. checks -------------------------------------------------------------------------
[ "$(id -u)" = 0 ] && ok "root" || bad "not root"
[ "$(uname -m)" = armv7l ] && ok "armv7l" || bad "not armv7l ($(uname -m))"
case "$(uname -r)" in
5.4.61*) ok "kernel $(uname -r)" ;;
*) bad "kernel $(uname -r): the vendor files and the stock uImage are for 5.4.61" ;;
esac
machine=$(sed -n 's/^MACHINE=//p' /opt/auto_run.sh 2>/dev/null | head -n 1)
case "$machine" in
Adventurer5M|Adventurer5MPro) ok "machine $machine" ;;
*) bad "machine '$machine' (expected Adventurer5M or Adventurer5MPro from /opt/auto_run.sh)" ;;
esac
[ -d /opt/PROGRAM ] && ok "stock root (/opt/PROGRAM)" || bad "no /opt/PROGRAM: not the stock system (a mod's own chroot?)"
root=$(sed -n 's/.*root=\([^ ]*\).*/\1/p' /proc/cmdline)
[ "$root" = /dev/mmcblk0p6 ] && ok "root=$root" || bad "root=$root (expected /dev/mmcblk0p6)"
grep -q ' /data ext4 ' /proc/mounts && ok "/data mounted (ext4)" || bad "/data is not mounted"
free=$(df -k "$AD5M_DATA" 2>/dev/null | awk 'NR==2 {print $4}')
[ "${free:-0}" -ge "$MIN_FREE_KB" ] && ok "free space ${free} KB" || bad "free space on $AD5M_DATA: ${free:-?} KB (need $MIN_FREE_KB)"
for t in fw_printenv fw_setenv dd tar sync sha256sum; do
	command -v $t >/dev/null 2>&1 && ok "$t" || bad "no $t"
done
[ -s /etc/fw_env.config ] && ok "/etc/fw_env.config" || bad "no /etc/fw_env.config"
init=$(fw_printenv -n init 2>/dev/null)
[ "$init" = /init ] && ok "U-Boot init=/init (stock)" || { [ "$init" = /sbin/ad5m-init ] && ok "init already /sbin/ad5m-init" || bad "U-Boot init='$init' (expected /init)"; }
[ "$(fw_printenv -n mmc_root 2>/dev/null)" = /dev/mmcblk0p6 ] && ok "mmc_root=/dev/mmcblk0p6" || bad "mmc_root is not /dev/mmcblk0p6"
if [ -n "$TAR" ]; then
	[ -f "$TAR" ] && ok "image $TAR" || bad "no image $TAR"
fi
[ $fail = 0 ] || { echo "Checks failed: nothing was changed." >&2; exit 1; }
[ -z "$CHECK" ] || { echo "Checks passed. Nothing was changed."; exit 0; }

# --- 2. backup -------------------------------------------------------------------------
BK=$AD5M_DATA/ad5x/backup/$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
mkdir -p "$BK" || { echo "can't create $BK" >&2; exit 1; }
echo "Backup in $BK"
fw_printenv > "$BK/fw_printenv.txt" 2>&1
dd if=/dev/mmcblk0p2 of="$BK/env-p2.bin" bs=1M count=1 2>/dev/null || { echo "backup of env failed" >&2; exit 1; }
dd if=/dev/mmcblk0p3 of="$BK/env-p3.bin" bs=1M count=1 2>/dev/null || { echo "backup of env-redund failed" >&2; exit 1; }
dd if=/dev/mmcblk0p1 of="$BK/p1-boot-resource.img" bs=1M 2>/dev/null || { echo "backup of p1 failed" >&2; exit 1; }
dd if=/dev/mmcblk0 of="$BK/first-mib.bin" bs=1M count=1 2>/dev/null || { echo "backup of the partition table failed" >&2; exit 1; }
( cd "$BK" && sha256sum ./* > SHA256SUMS ) && sync
echo "Backup done. Keep a copy of $BK off the printer too (scp -O -r)."

# --- 3. unpack -------------------------------------------------------------------------
OS=$AD5M_DATA/ad5x/os
mkdir -p "$OS" && rm -rf "$OS/root.new" && mkdir "$OS/root.new" || exit 1
echo "Unpacking the image (a few minutes)..."
case "$TAR" in
*.gz|*.tgz) gzip -dc "$TAR" | tar -xpf - -C "$OS/root.new" ;;
*) tar -xpf "$TAR" -C "$OS/root.new" ;;
esac
[ $? = 0 ] && [ -x "$OS/root.new/sbin/init" ] && [ -f "$OS/root.new/usr/share/ad5x/stock-side/ad5m-init" ] ||
	{ echo "the image did not unpack to a Kiln OS root: nothing else was changed" >&2; rm -rf "$OS/root.new"; exit 1; }
rm -rf "$OS/root.old"
[ -d "$OS/root" ] && mv "$OS/root" "$OS/root.old"
mv "$OS/root.new" "$OS/root" && rm -rf "$OS/root.old" && sync

# --- 4. the hook on the stock root ------------------------------------------------------
cp "$OS/root/usr/share/ad5x/stock-side/ad5m-init" /sbin/ad5m-init.new && chmod 755 /sbin/ad5m-init.new &&
	mv /sbin/ad5m-init.new /sbin/ad5m-init && sync || { echo "could not install /sbin/ad5m-init" >&2; exit 1; }
mkdir -p "$AD5M_DATA/ad5x/handoff"
# The first Kiln OS boots must not write to the boards: until the reset/boot lines are confirmed
# (ad5m-mcu probe) and the way back (restore-stock) is checked, ad5m-mcu only starts the eboard.
# Remove this file to allow flashing (docs/ad5m-first-test.md).
[ -e "$AD5M_DATA/ad5x/mcu.disable" ] || { : > "$AD5M_DATA/ad5x/mcu.disable" && echo "Created $AD5M_DATA/ad5x/mcu.disable: Kiln OS will not flash the boards yet."; }
echo "Installed: Kiln OS root in $OS/root, hook /sbin/ad5m-init. The next boot is still STOCK."

# --- 5. activate (optional) --------------------------------------------------------------
if [ -n "$ACTIVATE" ]; then
	sh "$OS/root/usr/bin/ad5m-handoff" on || { echo "ad5m-handoff on failed: still on stock" >&2; exit 1; }
	echo "Activated: reboot to start Kiln OS. Back to stock: ad5m-handoff off, or remove /data/ad5x/handoff/enable."
else
	echo "To start Kiln OS at the next boot: sh $OS/root/usr/bin/ad5m-handoff on"
fi
