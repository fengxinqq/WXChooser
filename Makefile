export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = roothide
export INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXChooser
WXChooser_FILES = WXChooser.x
WXChooser_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable
WXChooser_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

TOOL_NAME = wxchooseropen
wxchooseropen_FILES = wxchooseropen_main.m
wxchooseropen_FRAMEWORKS = Foundation UIKit
wxchooseropen_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
wxchooseropen_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
wxchooseropen_CODESIGN_FLAGS = -Swxchooseropen.entitlements

include $(THEOS_MAKE_PATH)/tool.mk

after-install::
	install.exec "killall -9 SpringBoard"
