# Rootless (Dopamine / palera1n rootless). Untuk jailbreak rootful hapus baris di bawah.
export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlassCC

GlassCC_FILES = Tweak.x
GlassCC_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error -Wno-arc-performSelector-leaks
GlassCC_FRAMEWORKS = UIKit QuartzCore CoreMotion MediaPlayer

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
