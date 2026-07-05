export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_ARCH := iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := iOSVCAMAudioBridgeSystemHook
iOSVCAMAudioBridgeSystemHook_FILES := Tweak.x
iOSVCAMAudioBridgeSystemHook_CFLAGS := -fobjc-arc -Wall -Wextra
iOSVCAMAudioBridgeSystemHook_FRAMEWORKS := Foundation AudioToolbox

after-install::
	@echo "Installed iOSVCAMAudioBridgeSystemHook. Restart only the target media process after explicit approval."

include $(THEOS_MAKE_PATH)/tweak.mk
