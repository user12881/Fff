ARCHS = arm64
TARGET = iphone:clang:latest:14.0
include $(THEOS)/makefiles/common.mk
LIBRARY_NAME = AutoClick
AutoClick_FILES = Tweak.m
AutoClick_FRAMEWORKS = UIKit
AutoClick_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
include $(THEOS_MAKE_PATH)/library.mk
