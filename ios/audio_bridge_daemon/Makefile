export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_ARCH := iphoneos-arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME := iosvcam_audio_bridge_daemon
iosvcam_audio_bridge_daemon_FILES := audio_bridge_daemon.c
iosvcam_audio_bridge_daemon_CFLAGS := -Wall -Wextra -std=c11
iosvcam_audio_bridge_daemon_INSTALL_PATH := /usr/libexec/iosvcam

after-install::
	@echo "Installed iosvcam_audio_bridge_daemon payload. Start/load it only after explicit approval."

include $(THEOS_MAKE_PATH)/tool.mk
