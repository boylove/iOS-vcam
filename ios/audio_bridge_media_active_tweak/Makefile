export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_ARCH := iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := iOSVCAMAudioBridgeMediaActive
iOSVCAMAudioBridgeMediaActive_FILES := Tweak.x
iOSVCAMAudioBridgeMediaActive_CFLAGS := -fobjc-arc -Wall -Wextra
iOSVCAMAudioBridgeMediaActive_FRAMEWORKS := Foundation AudioToolbox

after-install::
	@echo "Installed iOSVCAMAudioBridgeMediaActive. Restart only mediaserverd after explicit approval."

include $(THEOS_MAKE_PATH)/tweak.mk
