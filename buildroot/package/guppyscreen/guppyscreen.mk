################################################################################
#
# guppyscreen
#
################################################################################
# WORK IN PROGRESS, NOT BUILT YET. GuppyScreen as zMod builds it for the Adventurer 5M
# (ghzserg/guppyscreen_ff5m; its ci/build-release.sh does the same under a Buildroot SDK):
# apply the patches to the submodules, build libhv and spdlog, build with GUPPY_FF5M_SCREEN=1.
# The submodules (lvgl, lv_drivers, libhv, spdlog) are fetched at the commits the fork pins.

GUPPYSCREEN_VERSION = acd92c548fe73861c1c2582e3b9f7801b2c79dcb
GUPPYSCREEN_SITE = https://github.com/ghzserg/guppyscreen_ff5m.git
GUPPYSCREEN_SITE_METHOD = git
GUPPYSCREEN_GIT_SUBMODULES = YES
GUPPYSCREEN_LICENSE = GPL-3.0
GUPPYSCREEN_LICENSE_FILES = LICENSE
GUPPYSCREEN_DEPENDENCIES = tslib host-cmake host-gettext
GUPPYSCREEN_PKGDIR = $(BR2_EXTERNAL_AD5X_PATH)/package/guppyscreen

# The fork's patches to its submodules (ci/apply-patches.sh with model=ad5m, at the pinned commit):
# 0001 adds the AD5M's framebuffer ioctls to lv_drivers. GNU patch with -d, not "git apply": the
# build directory sits inside the Kiln OS git checkout, where git would resolve paths differently.
GUPPYSCREEN_SUBMODULE_PATCHES = \
	lv_drivers:0001-lv_driver_fb_ioctls_flashforge_ad5m.patch \
	spdlog:0002-spdlog_fmt_initializer_list.patch \
	libhv:0004-fix-cppflags-override.patch \
	libhv:0005-libhv-websocket-release-big-message-buffer.patch \
	lvgl:0006-lvgl-draw-indexed-8bit-decoded-images.patch \
	lvgl:0007-lvgl-draw-indexed-8bit-images-whole.patch \
	lvgl:0009-lvgl-transformed-area-margin-only-when-transformed.patch \
	lvgl:0010-lvgl-redraw-skips-children-under-a-covering-one.patch

define GUPPYSCREEN_APPLY_SUBMODULE_PATCHES
	for e in $(GUPPYSCREEN_SUBMODULE_PATCHES); do \
		dir=$${e%%:*}; p=$${e#*:}; \
		echo "guppyscreen: patching $$dir with $$p"; \
		patch -p1 -d $(@D)/$$dir < $(@D)/patches/$$p || exit 1; \
	done
endef
GUPPYSCREEN_POST_PATCH_HOOKS += GUPPYSCREEN_APPLY_SUBMODULE_PATCHES

GUPPYSCREEN_MAKE_OPTS = \
	CROSS_COMPILE="$(TARGET_CROSS)" \
	CC="$(TARGET_CC)" CXX="$(TARGET_CXX)" AR="$(TARGET_AR)" \
	GUPPY_FF5M_SCREEN=1 \
	GUPPYSCREEN_VERSION="$(GUPPYSCREEN_VERSION)" \
	FF5M_CMAKE_FLAGS="-DCMAKE_C_COMPILER=$(TARGET_CC) -DCMAKE_CXX_COMPILER=$(TARGET_CXX) -DCMAKE_SYSROOT=$(STAGING_DIR)"

define GUPPYSCREEN_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(GUPPYSCREEN_MAKE_OPTS) libhv.a
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(GUPPYSCREEN_MAKE_OPTS) libspdlog.a
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) -j$(PARALLEL_JOBS) $(GUPPYSCREEN_MAKE_OPTS)
	# translations: the .mo files the program loads from /srv/guppyscreen/locale
	for po in $(@D)/src/locale/*/LC_MESSAGES/guppyscreen.po; do \
		lang=$$(basename $$(dirname $$(dirname $$po))); \
		mkdir -p $(@D)/locale-out/$$lang/LC_MESSAGES; \
		$(HOST_DIR)/bin/msgfmt -o $(@D)/locale-out/$$lang/LC_MESSAGES/guppyscreen.mo $$po || exit 1; \
	done
endef

define GUPPYSCREEN_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/build/bin/guppyscreen $(TARGET_DIR)/usr/bin/guppyscreen
	mkdir -p $(TARGET_DIR)/srv/guppyscreen
	cp -r $(@D)/locale-out $(TARGET_DIR)/srv/guppyscreen/locale
	# themes: copied next to the config on /data at first start (S80guppyscreen)
	mkdir -p $(TARGET_DIR)/usr/share/guppyscreen/themes
	cp $(@D)/themes/*.json $(TARGET_DIR)/usr/share/guppyscreen/themes/
	$(INSTALL) -D -m 0644 $(GUPPYSCREEN_PKGDIR)/files/guppyconfig.json \
		$(TARGET_DIR)/usr/share/guppyscreen/guppyconfig.json
	$(INSTALL) -D -m 0644 $(GUPPYSCREEN_PKGDIR)/files/ts.conf $(TARGET_DIR)/etc/ts.conf
	$(INSTALL) -D -m 0755 $(GUPPYSCREEN_PKGDIR)/files/S80guppyscreen \
		$(TARGET_DIR)/etc/init.d/S80guppyscreen
endef

$(eval $(generic-package))
