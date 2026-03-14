include $(THEOS)/makefiles/common.mk

TOOL_NAME = procmond

procmond_FILES = \
	main.m \
	PMDaemon.m \
	PMEventStore.m \
	PMMonitor.m \
	PMIPCServer.m \
	../shared/PMEvent.m \
	../shared/PMConfig.m \
	../shared/PMIPCProtocol.m

procmond_CFLAGS += -fobjc-arc
procmond_FRAMEWORKS = Foundation
procmond_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
