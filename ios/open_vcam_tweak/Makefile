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
# Freeze-hunt diagnostics (see Tweak.xm): VCAM_DEST_COLOR pins the transfer session's
# destination colour like the closed vcamera; VCAM_GPU_ACCEL=0 forces the CPU transfer
# path to isolate the ~24-frame GPU fence wedge.
ifdef VCAM_DEST_COLOR
OpenVCam_CFLAGS += -DVCAM_DEST_COLOR=$(VCAM_DEST_COLOR)
endif
ifdef VCAM_GPU_ACCEL
OpenVCam_CFLAGS += -DVCAM_GPU_ACCEL=$(VCAM_GPU_ACCEL)
endif
# VCAM_VIDEO_DEDUP (default 1): overwrite each sample buffer once, keyed by
# TransitionID, exactly like the closed vcamera (the ~24-frame freeze fix). Set 0 to
# A/B the old every-emit behavior.
ifdef VCAM_VIDEO_DEDUP
OpenVCam_CFLAGS += -DVCAM_VIDEO_DEDUP=$(VCAM_VIDEO_DEDUP)
endif
# VCAM_PRIVATE_DEDUP_KEY (default 1): dedup on OpenVCam's own attachment key instead
# of the shared system TransitionID, so a photo<->video mode switch's transition
# buffers get overwritten with OBS instead of passing through as the real (blurry)
# lens (the sharp/blur cycling fix). Set 0 to A/B the old shared-key behavior.
ifdef VCAM_PRIVATE_DEDUP_KEY
OpenVCam_CFLAGS += -DVCAM_PRIVATE_DEDUP_KEY=$(VCAM_PRIVATE_DEDUP_KEY)
endif
# VCAM_DEST_MATRIX_709 (default 0 = 601): pin the transfer DESTINATION YCbCr matrix
# (and the tag stamped on the output) to 709 instead of 601 — the photo-red A/B knob
# (the saved photo shifting red is a YCbCr->RGB matrix mismatch in the still encoder).
ifdef VCAM_DEST_MATRIX_709
OpenVCam_CFLAGS += -DVCAM_DEST_MATRIX_709=$(VCAM_DEST_MATRIX_709)
endif
# Orientation (default CCW90 = 270, matching the closed vcamera). Flip to 90 (CW90)
# if the auto-rotate turns the wrong way on a device.
ifdef VCAM_AUTO_ORIENT_DIR
OpenVCam_CFLAGS += -DVCAM_AUTO_ORIENT_DIR=$(VCAM_AUTO_ORIENT_DIR)
endif
OpenVCam_FRAMEWORKS := Foundation AVFoundation CoreMedia CoreVideo VideoToolbox

after-install::
	@echo "Installed OpenVCam. Restart the target camera app; no respring required."

include $(THEOS_MAKE_PATH)/tweak.mk
