################################################################################
#
# ad5m-system
#
################################################################################
# WORK IN PROGRESS, NOT BUILT YET. Board support for the Adventurer 5M / 5M Pro. It
# reuses the board-independent parts of ad5x-system (same directory layout, same data
# root /data/ad5x) and adds the AD5M ones. Needs BR2_PACKAGE_AD5X_SYSTEM's package
# directory in the same external tree.

# The AD5M keeps the stock 5.4.61 kernel, but the headers are 5.10 (see ad5m_defconfig) and
# Buildroot passes the headers' version to glibc as its minimum kernel (--enable-kernel=5.10):
# every program would stop with "FATAL: kernel too old" on 5.4.61. External makefiles are
# included after glibc.mk, so this later option wins (configure keeps the last one).
# Not applied to other boards. Anything the 5.10 headers know that a 5.4 kernel lacks is
# probed at run time by glibc and Python (they fall back on ENOSYS).
ifeq ($(BR2_PACKAGE_AD5M_SYSTEM),y)
GLIBC_CONF_OPTS += --enable-kernel=5.4
endif

AD5M_SYSTEM_VERSION = 1
AD5M_SYSTEM_SITE = $(BR2_EXTERNAL_AD5X_PATH)/package/ad5m-system
AD5M_SYSTEM_SITE_METHOD = local
AD5M_SYSTEM_LICENSE = GPL-3.0
AD5M_SYSTEM_PKGDIR = $(BR2_EXTERNAL_AD5X_PATH)/package/ad5m-system
AD5M_SYSTEM_SHARED = $(BR2_EXTERNAL_AD5X_PATH)/package/ad5x-system
AD5M_SYSTEM_TOOLS = $(BR2_EXTERNAL_AD5X_PATH)/../tools
# klipper first: its package installs the AD5X's default configs, which this one replaces
AD5M_SYSTEM_DEPENDENCIES = host-python3 klipper
AD5M_SYSTEM_KLIPPER = $(BR2_EXTERNAL_AD5X_PATH)/../klipper

# The boards' Klipper firmware this image is tested against, as Kiln does it for the AD5X:
# klipper/mcu-dicts/FLASHED_AD5M names the version, klipper/mcu-firmware/<version>/ holds
# mainboard.bin, eboard.hex and SHA256SUMS. tools/build_mcu_ad5m.sh builds them and writes
# FLASHED_AD5M. Without that file the image has no firmware and ad5m-mcu only starts the eboard.
AD5M_SYSTEM_MCU_VERSION = $(strip $(shell cat $(BR2_EXTERNAL_AD5X_PATH)/../klipper/mcu-dicts/FLASHED_AD5M 2>/dev/null))
AD5M_SYSTEM_MCU_DIR = $(BR2_EXTERNAL_AD5X_PATH)/../klipper/mcu-firmware/$(AD5M_SYSTEM_MCU_VERSION)

define AD5M_SYSTEM_INSTALL_MCU_FIRMWARE
	if [ -n "$(AD5M_SYSTEM_MCU_VERSION)" ] && [ -d $(AD5M_SYSTEM_MCU_DIR) ]; then \
		cd $(AD5M_SYSTEM_MCU_DIR) && sha256sum -c --quiet SHA256SUMS || exit 1; \
		mkdir -p $(TARGET_DIR)/usr/share/ad5x/mcu; \
		cp $(AD5M_SYSTEM_MCU_DIR)/mainboard.bin $(AD5M_SYSTEM_MCU_DIR)/eboard.hex \
			$(AD5M_SYSTEM_MCU_DIR)/SHA256SUMS $(TARGET_DIR)/usr/share/ad5x/mcu/; \
		echo $(AD5M_SYSTEM_MCU_VERSION) > $(TARGET_DIR)/usr/share/ad5x/mcu/VERSION; \
	else \
		echo "ad5m-system: no MCU firmware (klipper/mcu-dicts/FLASHED_AD5M): image without it"; \
	fi
endef

# The printer's Klipper config: the AD5M's factory files, and the first-boot templates in place of
# the AD5X's (klipper.mk installs those: printer.cfg includes ad5x.cfg, unit.cfg is read from
# stock's AD5X settings, macros/*.cfg are the IFS and purge box ones)
define AD5M_SYSTEM_INSTALL_CONFIG
	for f in ad5m.cfg ad5m-pro.cfg ad5m-loadcell.cfg ad5m-macros.cfg ad5m-guppy.cfg ad5m-setup.cfg; do \
		$(INSTALL) -D -m 0644 $(AD5M_SYSTEM_KLIPPER)/$$f \
			$(TARGET_DIR)/usr/share/ad5x/config/$$f || exit 1; \
	done
	$(INSTALL) -D -m 0644 $(AD5M_SYSTEM_KLIPPER)/printer-ad5m.cfg \
		$(TARGET_DIR)/usr/share/ad5x/defaults/printer.cfg
	$(INSTALL) -D -m 0644 $(AD5M_SYSTEM_KLIPPER)/local-ad5m.cfg \
		$(TARGET_DIR)/usr/share/ad5x/defaults/local.cfg
	rm -f $(TARGET_DIR)/usr/share/ad5x/defaults/unit.cfg
	rm -rf $(TARGET_DIR)/usr/share/ad5x/defaults/macros
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
	$(AD5M_SYSTEM_INSTALL_CONFIG)
	$(AD5M_SYSTEM_INSTALL_MCU_FIRMWARE)
endef

$(eval $(generic-package))
