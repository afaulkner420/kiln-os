################################################################################
#
# ad5m-system
#
################################################################################
# WORK IN PROGRESS, NOT BUILT YET. Board support for the Adventurer 5M / 5M Pro. It
# reuses the board-independent parts of ad5x-system (same directory layout, same data
# root /data/ad5x) and adds the AD5M ones. Needs BR2_PACKAGE_AD5X_SYSTEM's package
# directory in the same external tree.

AD5M_SYSTEM_VERSION = 1
AD5M_SYSTEM_SITE = $(BR2_EXTERNAL_AD5X_PATH)/package/ad5m-system
AD5M_SYSTEM_SITE_METHOD = local
AD5M_SYSTEM_LICENSE = GPL-3.0
AD5M_SYSTEM_PKGDIR = $(BR2_EXTERNAL_AD5X_PATH)/package/ad5m-system
AD5M_SYSTEM_SHARED = $(BR2_EXTERNAL_AD5X_PATH)/package/ad5x-system
AD5M_SYSTEM_TOOLS = $(BR2_EXTERNAL_AD5X_PATH)/../tools
AD5M_SYSTEM_DEPENDENCIES = host-python3

# The boards' Klipper firmware this image is tested against: klipper/mcu-firmware/ad5m/
# (VERSION, mainboard.bin, eboard.hex, SHA256SUMS), built by tools/build_mcu.sh for the
# ad5m configs. TODO: that script and directory do not exist yet; without them the image
# has no firmware and ad5m-mcu only starts the eboard.
AD5M_SYSTEM_MCU_DIR = $(BR2_EXTERNAL_AD5X_PATH)/../klipper/mcu-firmware/ad5m

define AD5M_SYSTEM_INSTALL_MCU_FIRMWARE
	if [ -f $(AD5M_SYSTEM_MCU_DIR)/VERSION ]; then \
		cd $(AD5M_SYSTEM_MCU_DIR) && sha256sum -c --quiet SHA256SUMS || exit 1; \
		mkdir -p $(TARGET_DIR)/usr/share/ad5x/mcu; \
		cp $(AD5M_SYSTEM_MCU_DIR)/mainboard.bin $(AD5M_SYSTEM_MCU_DIR)/eboard.hex \
			$(AD5M_SYSTEM_MCU_DIR)/SHA256SUMS $(AD5M_SYSTEM_MCU_DIR)/VERSION \
			$(TARGET_DIR)/usr/share/ad5x/mcu/; \
	else \
		echo "ad5m-system: no MCU firmware in $(AD5M_SYSTEM_MCU_DIR): image without it"; \
	fi
endef

define AD5M_SYSTEM_INSTALL_TARGET_CMDS
	# board profile reader, hand-over and vendor tools
	$(INSTALL) -D -m 0644 $(@D)/lib/board.sh $(TARGET_DIR)/usr/lib/ad5x/board.sh
	$(INSTALL) -D -m 0755 $(@D)/bin/ad5m-handoff $(TARGET_DIR)/usr/bin/ad5m-handoff
	$(INSTALL) -D -m 0755 $(@D)/bin/ad5m-vendor $(TARGET_DIR)/usr/bin/ad5m-vendor
	$(INSTALL) -D -m 0755 $(@D)/bin/ad5m-mcu $(TARGET_DIR)/usr/bin/ad5m-mcu
	$(INSTALL) -D -m 0755 $(@D)/bin/ad5m-backlight $(TARGET_DIR)/usr/bin/ad5m-backlight
	# the stock-side hook, kept in the image so the installer can copy it onto the stock root
	$(INSTALL) -D -m 0755 $(@D)/sbin/ad5m-init $(TARGET_DIR)/usr/share/ad5x/stock-side/ad5m-init
	# board-independent tools, reused as they are (no IFS, slot or vendor-kernel parts)
	$(INSTALL) -D -m 0755 $(AD5M_SYSTEM_TOOLS)/boot_eboard.py $(TARGET_DIR)/usr/bin/boot_eboard
	$(INSTALL) -D -m 0755 $(AD5M_SYSTEM_TOOLS)/mcu_version.py $(TARGET_DIR)/usr/bin/ad5x-mcu-version
	$(INSTALL) -D -m 0755 $(AD5M_SYSTEM_TOOLS)/flash_iap.py $(TARGET_DIR)/usr/bin/ad5x-flash-iap
	$(INSTALL) -D -m 0755 $(AD5M_SYSTEM_TOOLS)/flash_n32.py $(TARGET_DIR)/usr/bin/ad5x-flash-n32
	for f in ad5x-clock ad5x-config-templates ad5x-moonraker-migrate ad5x-sound ad5x-umask; do \
		$(INSTALL) -D -m 0755 $(AD5M_SYSTEM_SHARED)/bin/$$f $(TARGET_DIR)/usr/bin/$$f || exit 1; \
	done
	for f in network.sh apps.sh logs.sh plugin-root.sh; do \
		$(INSTALL) -D -m 0644 $(AD5M_SYSTEM_SHARED)/lib/$$f $(TARGET_DIR)/usr/lib/ad5x/$$f || exit 1; \
	done
	# services: shared ones that do not touch AD5X-only parts, then the AD5M ones.
	# TODO review before adding: S64ad5x-camera, S66ad5x-fluidd-defaults, S68ad5x-update-agent,
	# S69ad5x-plugin-boot (they mention the IFS or HelixScreen).
	for f in S51ad5x-clock S61ad5x-web S61klipper S62moonraker S63nginx S65ad5x-screen; do \
		$(INSTALL) -D -m 0755 $(AD5M_SYSTEM_SHARED)/init.d/$$f $(TARGET_DIR)/etc/init.d/$$f || exit 1; \
	done
	for f in $(@D)/init.d/S*; do \
		$(INSTALL) -D -m 0755 $$f $(TARGET_DIR)/etc/init.d/$$(basename $$f) || exit 1; \
	done
	$(AD5M_SYSTEM_INSTALL_MCU_FIRMWARE)
endef

$(eval $(generic-package))
