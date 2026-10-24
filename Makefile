TARGET := iphone:clang:16.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PerigeeLyrics
PerigeeLyrics_FILES = $(wildcard src/*.m)
PerigeeLyrics_CFLAGS = -fobjc-arc -Wall
PerigeeLyrics_LDFLAGS = -Wl,-current_version,1.0.0
PerigeeLyrics_FRAMEWORKS = UIKit MediaPlayer QuartzCore CoreGraphics CoreText Metal AVFoundation CoreMedia NaturalLanguage
PerigeeLyrics_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
