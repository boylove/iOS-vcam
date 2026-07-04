export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := iOSVCAMAudioBridgeSafe
iOSVCAMAudioBridgeSafe_FILES := Tweak.x
iOSVCAMAudioBridgeSafe_CFLAGS := -fobjc-arc -Wall -Wextra
iOSVCAMAudioBridgeSafe_FRAMEWORKS := Foundation AVFoundation CoreMedia AudioToolbox AudioUnit

after-install::
	@echo "Installed iOSVCAMAudioBridgeSafe. Restart the target app only; no respring required."

include $(THEOS_MAKE_PATH)/tweak.mk
