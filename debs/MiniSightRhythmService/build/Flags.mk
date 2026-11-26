# Local source-review default. LIVE is a build label, NOT runtime permission.
MINISIGHT_RHYTHM_MODE ?= SOURCE
ifneq ($(filter $(MINISIGHT_RHYTHM_MODE),SOURCE LIVE),$(MINISIGHT_RHYTHM_MODE))
$(error MINISIGHT_RHYTHM_MODE must be SOURCE or LIVE)
endif
ifeq ($(MINISIGHT_RHYTHM_MODE),LIVE)
MINISIGHT_ENABLE_RHYTHM_CAPTURE ?= 1
MINISIGHT_ENABLE_RHYTHM_TRANSPORT ?= 1
MINISIGHT_RHYTHM_LIVE_BUILD := 1
else
MINISIGHT_ENABLE_RHYTHM_CAPTURE ?= 0
MINISIGHT_ENABLE_RHYTHM_TRANSPORT ?= 0
MINISIGHT_RHYTHM_LIVE_BUILD := 0
endif
ifneq ($(filter $(MINISIGHT_ENABLE_RHYTHM_CAPTURE),0 1),$(MINISIGHT_ENABLE_RHYTHM_CAPTURE))
$(error capture must be 0 or 1)
endif
ifneq ($(filter $(MINISIGHT_ENABLE_RHYTHM_TRANSPORT),0 1),$(MINISIGHT_ENABLE_RHYTHM_TRANSPORT))
$(error transport must be 0 or 1)
endif
ifneq ($(MINISIGHT_ENABLE_RHYTHM_CAPTURE),$(MINISIGHT_ENABLE_RHYTHM_TRANSPORT))
$(error partial rhythm build forbidden: capture and transport must match)
endif
ifneq ($(MINISIGHT_ENABLE_RHYTHM_CAPTURE),$(MINISIGHT_RHYTHM_LIVE_BUILD))
$(error mode disagrees with capture/transport flags)
endif
