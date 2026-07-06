export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_ARCH := iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := OpenVCam
# Tweak.xm (video, mediaserverd) + VCamAudio.x (audio, TikTok only) live in one
# dylib; each %ctor self-gates by process, so they never run in the wrong place.
OpenVCam_FILES := Tweak.xm VCamAudio.x VCamConfig.m VCamFrameStore.m VCamH264Decoder.mm VCamRTMPSource.mm vendor/rtmp/vcam_rtmp.c
OpenVCam_CFLAGS := -fobjc-arc -Wall -Wextra -Ivendor/rtmp
OpenVCam_FRAMEWORKS := Foundation AVFoundation CoreMedia CoreVideo CoreImage VideoToolbox AudioToolbox AudioUnit

after-install::
	@echo "Installed OpenVCam. Restart the target camera app; no respring required."

include $(THEOS_MAKE_PATH)/tweak.mk
