FINALPACKAGE = 1
THEOS_PACKAGE_SCHEME = roothide
ARCHS = arm64e
TARGET := iphone:clang:15.5:15.5
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = MiniSightRhythmService
RHYTHM_CORE = ../MiniSight
MiniSightRhythmService_FILES = Tweak.cpp CaptureEngine.cpp FeatureAnalyzer.cpp FeatureServer.cpp $(RHYTHM_CORE)/MiniSightRhythmAnalyzer.cpp $(RHYTHM_CORE)/vendor/BeatDetektor/BeatDetektor.cpp
MiniSightRhythmService_FRAMEWORKS = AudioToolbox Accelerate
MiniSightRhythmService_LIBRARIES = substrate
MiniSightRhythmService_CCFLAGS = -std=c++17 -fexceptions -fcxx-exceptions -fblocks -fvisibility=hidden -fvisibility-inlines-hidden -DNDEBUG -DMINISIGHT_RHYTHM_STRIP_LOGS=1 -DDEVTEST_BUILD=0 -Wall -Wextra -Wshadow -Wshorten-64-to-32 -Wimplicit-fallthrough -Werror=return-type
MiniSightRhythmService_LDFLAGS = -Wl,-dead_strip -Wl,-S -Wl,-x
OPTFLAG = -O2
include $(THEOS_MAKE_PATH)/tweak.mk
