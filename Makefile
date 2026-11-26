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
wxchooseropen_INSTALL_PATH = /usr/libexec
wxchooseropen_CODESIGN_FLAGS = -Swxchooseropen.entitlements

include $(THEOS_MAKE_PATH)/tool.mk

STAGED_DYLIB = $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/WXChooser.dylib

before-package::
	@echo "==> 写入完整性锚点"
	python3 $(THEOS_PROJECT_DIR)/pin_integrity.py "$(STAGED_DYLIB)"
	@echo "codesign=[$(TARGET_CODESIGN)] allocate=[$(TARGET_CODESIGN_ALLOCATE)] flags=[$(TARGET_CODESIGN_FLAGS)]"
	@test -n "$(TARGET_CODESIGN_ALLOCATE)" || (echo "!! CODESIGN_ALLOCATE 为空，拒绝签名，否则 arm64e 会被写坏" && exit 1)
	CODESIGN_ALLOCATE="$(TARGET_CODESIGN_ALLOCATE)" $(TARGET_CODESIGN) $(TARGET_CODESIGN_FLAGS) "$(STAGED_DYLIB)"
	python3 $(THEOS_PROJECT_DIR)/pin_integrity.py "$(STAGED_DYLIB)" --verify

after-install::
	install.exec "killall -9 SpringBoard"
