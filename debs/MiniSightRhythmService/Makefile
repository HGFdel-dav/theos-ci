# No app checkout is needed. Override RHYTHM_CORE only with an audited copy.
include build/Flags.mk
FINALPACKAGE = 1
THEOS_PACKAGE_SCHEME ?= roothide
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
ARCHS = arm64
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
$(error rhythm service requires roothide or rootless scheme)
endif
TARGET := iphone:clang:15.5:15.5
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = MiniSightRhythmService
RHYTHM_CORE ?= shared
ifeq ($(wildcard $(RHYTHM_CORE)/MiniSightRhythmAnalyzer.cpp),)
$(error missing independent rhythm core: $(RHYTHM_CORE))
endif
MiniSightRhythmService_FILES = Tweak.cpp CaptureEngine.cpp FeatureAnalyzer.cpp FeatureServer.cpp $(RHYTHM_CORE)/MiniSightRhythmAnalyzer.cpp $(RHYTHM_CORE)/vendor/BeatDetektor/BeatDetektor.cpp
MiniSightRhythmService_FRAMEWORKS = AudioToolbox Accelerate
MiniSightRhythmService_LIBRARIES = substrate
MiniSightRhythmService_CCFLAGS = -I$(RHYTHM_CORE) -DMINISIGHT_ENABLE_RHYTHM_CAPTURE=$(MINISIGHT_ENABLE_RHYTHM_CAPTURE) -DMINISIGHT_ENABLE_RHYTHM_TRANSPORT=$(MINISIGHT_ENABLE_RHYTHM_TRANSPORT) -DMINISIGHT_RHYTHM_LIVE_BUILD=$(MINISIGHT_RHYTHM_LIVE_BUILD) -std=c++17 -fblocks -fvisibility=hidden -fvisibility-inlines-hidden -DNDEBUG -DMINISIGHT_RHYTHM_STRIP_LOGS=1 -DDEVTEST_BUILD=0 -Wall -Wextra -Wshadow -Wshorten-64-to-32 -Wimplicit-fallthrough -Werror=return-type
# Theos enables -Werror globally. Preserve pinned upstream bytes. Its four
# observed categories stay visible/nonfatal only on that vendor source. The
# wrapper also includes the pinned header's constructor, so only its reorder
# warning is nonfatal there. All other files/categories remain fatal.
$(RHYTHM_CORE)/vendor/BeatDetektor/BeatDetektor.cpp_CFLAGS = -Wno-error=reorder-ctor -Wno-error=unused-but-set-variable -Wno-error=shorten-64-to-32 -Wno-error=sign-compare
$(RHYTHM_CORE)/MiniSightRhythmAnalyzer.cpp_CFLAGS = -Wno-error=reorder-ctor
MiniSightRhythmService_LDFLAGS = -Wl,-dead_strip -Wl,-S -Wl,-x
OPTFLAG = -O2
include $(THEOS_MAKE_PATH)/tweak.mk
