export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_ARCH := iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := OpenVCam
# Video (Tweak.xm): hooks BWNodeOutput -emitSampleBuffer: in mediaserverd and
# overwrites the camera's OWN image buffer IN PLACE with a SINGLE
# VTPixelTransferSessionTransferImage (one GPU pass, no per-frame pixel rotation) —
# exactly like the closed vcamera's photo-mode flow (VCAMERA_OPENVCAM_COMPLETE_REFERENCE.md
# §2, memory openvcam-photomode-original-flow). Orientation is carried by the pipeline's
# existing metadata. Audio (VCamAudioMS.x) is intentionally OUT of the build here — it is
# kept in the tree for the upcoming OBS audio-replacement work.
OpenVCam_FILES := Tweak.xm VCamConfig.m VCamFrameStore.m VCamH264Decoder.mm VCamRTMPSource.mm vendor/rtmp/vcam_rtmp.c
OpenVCam_CFLAGS := -fobjc-arc -Wall -Wextra -Ivendor/rtmp

# Feature toggles, passthrough from the command line or CI. Using := on OpenVCam_CFLAGS
# above means a command-line `OpenVCam_CFLAGS+=` would NOT append (make command-line
# override gotcha), so route toggles through their own variables that default to unset
# and are appended here instead.
#   VCAM_DEST_COLOR   (default 1) pin the transfer session's destination colour like the
#                     closed vcamera; 0 lets VT infer it.
#   VCAM_GPU_ACCEL    (default 1) GPU-accelerated transfer; 0 forces the CPU path.
#   VCAM_DEST_MATRIX_709 (default 0 = 601) VIDEO-path destination YCbCr matrix A/B knob.
#   VCAM_AUTO_ORIENT_DIR (default 270 = CCW90) auto-rotate direction; flip to 90 (CW90)
#                     if the preview turns the wrong way on a device.
ifdef VCAM_DEST_COLOR
OpenVCam_CFLAGS += -DVCAM_DEST_COLOR=$(VCAM_DEST_COLOR)
endif
ifdef VCAM_GPU_ACCEL
OpenVCam_CFLAGS += -DVCAM_GPU_ACCEL=$(VCAM_GPU_ACCEL)
endif
ifdef VCAM_DEST_MATRIX_709
OpenVCam_CFLAGS += -DVCAM_DEST_MATRIX_709=$(VCAM_DEST_MATRIX_709)
endif
ifdef VCAM_AUTO_ORIENT_DIR
OpenVCam_CFLAGS += -DVCAM_AUTO_ORIENT_DIR=$(VCAM_AUTO_ORIENT_DIR)
endif
OpenVCam_FRAMEWORKS := Foundation AVFoundation CoreMedia CoreVideo VideoToolbox

after-install::
	@echo "Installed OpenVCam. Restart the target camera app; no respring required."

include $(THEOS_MAKE_PATH)/tweak.mk
