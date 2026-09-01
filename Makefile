.PHONY: check install uninstall

check:
	bash -n bin/omarchy-trackpad-guard install.sh uninstall.sh

install: check
	./install.sh

uninstall:
	./uninstall.sh
