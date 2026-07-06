export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_ARCH := iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := OpenVCam
OpenVCam_FILES := Tweak.xm VCamConfig.m VCamFrameStore.m VCamH264Decoder.mm VCamRTMPSource.mm vendor/rtmp/vcam_rtmp.c
OpenVCam_CFLAGS := -fobjc-arc -Wall -Wextra -Ivendor/rtmp
OpenVCam_FRAMEWORKS := Foundation AVFoundation CoreMedia CoreVideo CoreImage VideoToolbox

after-install::
	@echo "Installed OpenVCam. Restart the target camera app; no respring required."

include $(THEOS_MAKE_PATH)/tweak.mk
