export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := iOSVCAMAudioBridge
iOSVCAMAudioBridge_FILES := Tweak.x
iOSVCAMAudioBridge_CFLAGS := -fobjc-arc -Wall -Wextra
iOSVCAMAudioBridge_FRAMEWORKS := Foundation AVFoundation CoreMedia AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
