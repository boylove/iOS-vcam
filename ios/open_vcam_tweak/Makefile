export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_ARCH := iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := OpenVCam
# All hooks live in one dylib, all gated to mediaserverd by their %ctor:
#   Tweak.xm       - video: overwrite the capture-graph pixel buffer in place
#   VCamAudioMS.x  - audio: global AudioUnitRender replacement (RT-safe, fail-open)
OpenVCam_FILES := Tweak.xm VCamAudioMS.x VCamConfig.m VCamFrameStore.m VCamH264Decoder.mm VCamRTMPSource.mm vendor/rtmp/vcam_rtmp.c
OpenVCam_CFLAGS := -fobjc-arc -Wall -Wextra -Ivendor/rtmp
# AudioUnit has no standalone framework on iOS; AudioUnitRender/GetProperty come via AudioToolbox.
OpenVCam_FRAMEWORKS := Foundation AVFoundation CoreMedia CoreVideo CoreImage VideoToolbox AudioToolbox

after-install::
	@echo "Installed OpenVCam. Restart the target camera app; no respring required."

include $(THEOS_MAKE_PATH)/tweak.mk
