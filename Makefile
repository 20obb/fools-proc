export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += procmond
SUBPROJECTS += tweak
SUBPROJECTS += prefs
SUBPROJECTS += cli

include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/DEBIAN
	cp -f debian/postinst $(THEOS_STAGING_DIR)/DEBIAN/postinst
	cp -f debian/prerm $(THEOS_STAGING_DIR)/DEBIAN/prerm
	chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/prerm
