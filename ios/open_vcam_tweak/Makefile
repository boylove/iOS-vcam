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
# existing metadata. Audio (VCamAudioMS.x + VCamAACDecoder): OBS audio is demuxed from the SAME
# RTMP stream the video path pulls (VCamRTMPSource msg_type 8 -> AAC decode -> the mic-replacement
# ring the AudioUnitRender hook consumes). One tweak, one stream, both A/V. Audio is fail-open and
# runtime-gated (default on; disable flag / Enabled=false pref), so it can never wedge the video
# path. For a video-only build, drop VCamAudioMS.x + VCamAACDecoder.mm from FILES below.
OpenVCam_FILES := Tweak.xm VCamConfig.m VCamFrameStore.m VCamH264Decoder.mm VCamRTMPSource.mm VCamAACDecoder.mm VCamAudioMS.x vendor/rtmp/vcam_rtmp.c
OpenVCam_CFLAGS := -fobjc-arc -Wall -Wextra -Ivendor/rtmp

# Feature toggles, passthrough from the command line or CI. Using := on OpenVCam_CFLAGS
# above means a command-line `OpenVCam_CFLAGS+=` would NOT append (make command-line
# override gotcha), so route toggles through their own variables that default to unset
# and are appended here instead.
#   VCAM_DEST_COLOR   (default 1) pin the transfer session's destination colour like the
#                     closed vcamera; 0 lets VT infer it.
#   VCAM_GPU_ACCEL    (default 1) GPU-accelerated transfer; 0 forces the CPU path.
#   VCAM_DEST_MATRIX_709 (default 0 = 601) VIDEO-path destination YCbCr matrix A/B knob.
# Rotation direction + front mirror are no longer knobs: they are driven by camera position
# (back CW90 / front CCW90+FlipVertical), faithful to the closed vcamera (RE 0x83e20).
ifdef VCAM_DEST_COLOR
OpenVCam_CFLAGS += -DVCAM_DEST_COLOR=$(VCAM_DEST_COLOR)
endif
ifdef VCAM_GPU_ACCEL
OpenVCam_CFLAGS += -DVCAM_GPU_ACCEL=$(VCAM_GPU_ACCEL)
endif
ifdef VCAM_DEST_MATRIX_709
OpenVCam_CFLAGS += -DVCAM_DEST_MATRIX_709=$(VCAM_DEST_MATRIX_709)
endif
# VCAM_AUDIO_DISABLE (default 0) — video-only A/B build: audio subsystem installs nothing.
ifdef VCAM_AUDIO_DISABLE
OpenVCam_CFLAGS += -DVCAM_AUDIO_DISABLE=$(VCAM_AUDIO_DISABLE)
endif
OpenVCam_FRAMEWORKS := Foundation AVFoundation CoreMedia CoreVideo VideoToolbox AudioToolbox

after-install::
	@echo "Installed OpenVCam. Restart the target camera app; no respring required."

include $(THEOS_MAKE_PATH)/tweak.mk
