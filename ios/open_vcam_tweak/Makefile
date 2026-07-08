export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_ARCH := iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := OpenVCam
# Video (Tweak.xm): hooks BWNodeOutput -emitSampleBuffer: in mediaserverd and
# overwrites the camera's OWN image buffer IN PLACE with a SINGLE
# VTPixelTransferSessionTransferImage (one GPU pass, no per-frame pixel rotation) —
# exactly like the closed vcamera's photo-mode flow (VCAMERA_DEB_REVERSE_ANALYSIS.md
# §3.9-3.10, memory openvcam-photomode-original-flow). Orientation is carried by the
# pipeline's existing metadata. Audio (VCamAudioMS.x) is temporarily OUT of the build
# while video is finalised. Set -DVCAM_DEBUG=1 to re-enable verbose per-frame diagnostics.
OpenVCam_FILES := Tweak.xm VCamConfig.m VCamFrameStore.m VCamH264Decoder.mm VCamRTMPSource.mm vendor/rtmp/vcam_rtmp.c
OpenVCam_CFLAGS := -fobjc-arc -Wall -Wextra -Ivendor/rtmp

# Diagnostic / feature toggles, passthrough from the command line or CI.
#   make package VCAM_HOOK_PHOTO_NODES=1   -> build the opt-in still-path deb
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
OpenVCam_FRAMEWORKS := Foundation AVFoundation CoreMedia CoreVideo VideoToolbox

after-install::
	@echo "Installed OpenVCam. Restart the target camera app; no respring required."

include $(THEOS_MAKE_PATH)/tweak.mk
