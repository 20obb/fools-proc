include $(THEOS)/makefiles/common.mk

TOOL_NAME = procmonctl

procmonctl_FILES = main.m ../shared/PMConfig.m ../shared/PMIPCProtocol.m
procmonctl_CFLAGS += -fobjc-arc
procmonctl_FRAMEWORKS = Foundation
procmonctl_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
