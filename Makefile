export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = roothide
export INSTALL_TARGET_PROCESSES = SpringBoard

$(shell mkdir -p layout/Library/MobileSubstrate/DynamicLibraries && cp WXChooser_filter.plist layout/Library/MobileSubstrate/DynamicLibraries/WXChooser.plist)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXChooser
WXChooser_FILES = WXChooser.x
WXChooser_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable
WXChooser_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
