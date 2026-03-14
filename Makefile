export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += procmond
SUBPROJECTS += tweak
SUBPROJECTS += prefs
SUBPROJECTS += cli

include $(THEOS_MAKE_PATH)/aggregate.mk