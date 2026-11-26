# 把守护进程 plist 摆到 layout 里（仓库里只留根目录一份，避免网页上传目录结构）
launchd-copy := $(shell mkdir -p layout/Library/LaunchDaemons && cp wxchooser-launchd.plist layout/Library/LaunchDaemons/com.fengxin.wxchooser.launchd.plist 2>/dev/null && echo ok)

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
wxchooseropen_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
wxchooseropen_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
wxchooseropen_CODESIGN_FLAGS = -Swxchooseropen.entitlements

include $(THEOS_MAKE_PATH)/tool.mk

after-install::
	install.exec "killall -9 SpringBoard"
