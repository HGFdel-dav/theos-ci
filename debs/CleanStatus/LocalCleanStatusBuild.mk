DEBUG = 0
FINALPACKAGE = 1
ARCHS = arm64e
TARGET = iphone:clang:15.5:15.5
THEOS_PACKAGE_SCHEME ?= roothide
ifneq ($(THEOS_PACKAGE_SCHEME),roothide)
$(error CleanStatus 0.1.14 currently supports RootHide only)
endif
