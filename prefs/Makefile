include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ProcMonRootlessPrefs

ProcMonRootlessPrefs_FILES = ProcMonRootlessListController.m ../shared/PMConfig.m ../shared/PMIPCProtocol.m
ProcMonRootlessPrefs_FRAMEWORKS = UIKit Foundation
ProcMonRootlessPrefs_PRIVATE_FRAMEWORKS = Preferences
ProcMonRootlessPrefs_INSTALL_PATH = /Library/PreferenceBundles
ProcMonRootlessPrefs_RESOURCE_DIRS = Resources
ProcMonRootlessPrefs_CFLAGS += -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
