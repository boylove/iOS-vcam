export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_ARCH := iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := iOSVCAMAudioBridgeMediaProbe
iOSVCAMAudioBridgeMediaProbe_FILES := Tweak.x
iOSVCAMAudioBridgeMediaProbe_CFLAGS := -fobjc-arc -Wall -Wextra
iOSVCAMAudioBridgeMediaProbe_FRAMEWORKS := Foundation

after-install::
	@echo "Installed iOSVCAMAudioBridgeMediaProbe. Restart only the target media process after explicit approval."

include $(THEOS_MAKE_PATH)/tweak.mk
