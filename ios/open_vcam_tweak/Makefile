export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_ARCH := iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := OpenVCam
# Video (Tweak.xm): hooks BWNodeOutput -emitSampleBuffer: in mediaserverd and
# overwrites the camera's OWN image buffer IN PLACE via VTPixelTransferSession —
# exactly like the closed vcamera (VCAMERA_FRAME_REPLACEMENT_DEEP_REVERSE.md).
# Audio (VCamAudioMS.x) is temporarily OUT of the build while video is finalised.
# Set -DVCAM_DEBUG=1 to re-enable verbose per-frame diagnostics.
OpenVCam_FILES := Tweak.xm VCamConfig.m VCamFrameStore.m VCamH264Decoder.mm VCamRTMPSource.mm vendor/rtmp/vcam_rtmp.c
OpenVCam_CFLAGS := -fobjc-arc -Wall -Wextra -Ivendor/rtmp
# TEMPORARY DIAGNOSTIC (0.4.1): isolate whether the per-frame VTPixelRotation pass
# is the photo-mode IOFence deadlock. Transfers raw OBS -> dst with no rotation,
# like the closed vcamera's single-pass photo flow. Orientation is wrong while on.
# REVERT this line once confirmed (then implement metadata-orientation).
OpenVCam_CFLAGS += -DVCAM_DISABLE_ROTATION=1

# Diagnostic / feature toggles, passthrough from the command line or CI.
#   make package VCAM_HOOK_PHOTO_NODES=0   -> build the still-path OFF diagnostic deb
#   make package VCAM_DEBUG=1              -> verbose per-frame logging
# Using := on OpenVCam_CFLAGS above means a command-line `OpenVCam_CFLAGS+=` would
# NOT append (make command-line override gotcha), so route toggles through their
# own variables that default to unset and are appended here instead.
ifdef VCAM_HOOK_PHOTO_NODES
OpenVCam_CFLAGS += -DVCAM_HOOK_PHOTO_NODES=$(VCAM_HOOK_PHOTO_NODES)
endif
ifdef VCAM_DEBUG
OpenVCam_CFLAGS += -DVCAM_DEBUG=$(VCAM_DEBUG)
endif
ifdef VCAM_DISABLE_ROTATION
OpenVCam_CFLAGS += -DVCAM_DISABLE_ROTATION=$(VCAM_DISABLE_ROTATION)
endif
OpenVCam_FRAMEWORKS := Foundation AVFoundation CoreMedia CoreVideo VideoToolbox

after-install::
	@echo "Installed OpenVCam. Restart the target camera app; no respring required."

include $(THEOS_MAKE_PATH)/tweak.mk
