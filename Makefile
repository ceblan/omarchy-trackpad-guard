.PHONY: check install uninstall

check:
	bash -n bin/omarchy-trackpad-guard install.sh uninstall.sh
	scripts/check-constants.sh
	if command -v shellcheck >/dev/null 2>&1; then shellcheck bin/omarchy-trackpad-guard install.sh uninstall.sh scripts/check-constants.sh; fi

install: check
	./install.sh

uninstall:
	./uninstall.sh
