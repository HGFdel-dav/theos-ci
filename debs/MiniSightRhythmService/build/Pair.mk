# Run from any directory: make -f .../MiniSightRhythmService/build/Pair.mk live-check
SERVICE := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
PLUGIN := $(abspath $(SERVICE)/../MiniSight)
PAIR_MAKEFILE := $(SERVICE)/build/Pair.mk
THEOS_PACKAGE_SCHEME ?= roothide
include $(SERVICE)/build/Flags.mk
.PHONY: contract source-check live-check live-package single-package
contract:
	python3 $(SERVICE)/scripts/check_contract.py --service $(SERVICE) --mode $(MINISIGHT_RHYTHM_MODE) --capture $(MINISIGHT_ENABLE_RHYTHM_CAPTURE) --transport $(MINISIGHT_ENABLE_RHYTHM_TRANSPORT)
source-check:
	$(MAKE) -f $(PAIR_MAKEFILE) MINISIGHT_RHYTHM_MODE=SOURCE contract
live-check:
	$(MAKE) -f $(PAIR_MAKEFILE) MINISIGHT_RHYTHM_MODE=LIVE contract
# Future separately approved CI runner ONLY; never install/respring.
live-package:
	$(MAKE) -f $(PAIR_MAKEFILE) MINISIGHT_RHYTHM_MODE=LIVE single-package
single-package: contract
	python3 $(SERVICE)/scripts/package_pair.py --service $(SERVICE) --output "$(MINISIGHT_PACKAGE_OUTPUT)" --mode $(MINISIGHT_RHYTHM_MODE) --scheme "$(THEOS_PACKAGE_SCHEME)" --build
