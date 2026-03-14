include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ProcMonRootless

ProcMonRootless_FILES = \
	Tweak.xm \
	PMTweakClient.m \
	PMHookReporter.m \
	HUD/PMHUDView.m \
	HUD/PMHUDController.m \
	../shared/PMConfig.m \
	../shared/PMEvent.m \
	../shared/PMIPCProtocol.m

ProcMonRootless_CFLAGS += -fobjc-arc
ProcMonRootless_FRAMEWORKS = UIKit Foundation
ProcMonRootless_INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS_MAKE_PATH)/tweak.mk
