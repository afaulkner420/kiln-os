#!/bin/sh
# Runs after the root filesystem images are made ($BINARIES_DIR). Adventurer 5M.
# WORK IN PROGRESS, NOT BUILT YET. No kernel and no bootloader are built (the stock ones
# are used), so the result is the root tree: rootfs.tar (milestone 1: tools/install/
# ad5m-install.sh unpacks it into /data/ad5x/os/root) and rootfs.ext4 (milestone 2).
set -e
cd "$BINARIES_DIR"
[ -f rootfs.tar ] && sha256sum rootfs.tar > rootfs.tar.sha256
[ -f rootfs.ext4 ] && sha256sum rootfs.ext4 > rootfs.ext4.sha256
cat > IMAGES.txt <<'TXT'
rootfs.tar    Kiln OS root tree for the Adventurer 5M (milestone 1: ad5m-install.sh unpacks it
              into /data/ad5x/os/root and starts it with the ad5m-init hand-over)
rootfs.ext4   the same as an ext4 image (milestone 2, not used yet)
Vendor-free build: no Flashforge/Allwinner files. The Wi-Fi driver and the MAC address are
copied from the printer's own stock system at install time (ad5m-vendor).
See docs/ad5m-boot.md.
TXT
