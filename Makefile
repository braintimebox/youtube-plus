THEOS_DEVICE_IP = 
ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTNativeShareHybrid

YTNativeShareHybrid_FILES = Tweak.x
YTNativeShareHybrid_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
