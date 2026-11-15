TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GlassCCPrefs
GlassCCPrefs_FILES = GCRootListController.m
GlassCCPrefs_FRAMEWORKS = UIKit
# Framework privat 'Preferences' tidak ada di SDK runner; kelasnya di-resolve saat runtime di app Settings
GlassCCPrefs_LDFLAGS = -undefined dynamic_lookup
GlassCCPrefs_INSTALL_PATH = /Library/PreferenceBundles
GlassCCPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
