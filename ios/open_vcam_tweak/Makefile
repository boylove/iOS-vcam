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
# VCamFloatingPanel.xm + VCamControlChannel.m add the SpringBoard floating control panel:
# a draggable button (over apps) with an RTMP-URL field and 替换视频/替换音频 switches. Save
# writes /var/mobile/Media/vc.plist (mediaserverd reads it) AND publishes the toggles on a
# Darwin-notify bus (VCamControlChannel) so mediaserverd's VCamConfig picks them up instantly
# (no 1.5s poll wait). The panel is gated to SpringBoard and fail-open.
# VCamAudioProbe.x (mediaserverd-only) is the RootHide-surviving TikTok/VPIO mic replacement:
# it hooks AudioUnitProcess and overwrites the VoiceProcessingIO mic-effect buffers with OBS
# audio (PTS-dynamically aligned, 0.6.62), gated on 替换音频 + a live capture. This is the
# system-side mic path that covers every app whose mic mediaserverd processes (TikTok, Shopee,
# ...), which is why no per-app in-process audio hook is needed.
OpenVCam_FILES := Tweak.xm VCamConfig.m VCamFrameStore.m VCamH264Decoder.mm VCamRTMPSource.mm VCamAACDecoder.mm VCamAudioMS.x VCamFloatingPanel.xm VCamControlChannel.m VCamAudioProbe.x vendor/rtmp/vcam_rtmp.c
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
# VCAM_VIDEO_DEDUP (default 0) — overwrite each frame once (TransitionID); fixes ISP-pool fps drop.
ifdef VCAM_VIDEO_DEDUP
OpenVCam_CFLAGS += -DVCAM_VIDEO_DEDUP=$(VCAM_VIDEO_DEDUP)
endif
OpenVCam_FRAMEWORKS := Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox AudioToolbox

after-install::
	@echo "Installed OpenVCam. Restart the target camera app; no respring required."

include $(THEOS_MAKE_PATH)/tweak.mk
