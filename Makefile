.PHONY: check test install uninstall

SH_SCRIPTS := bin/omarchy-trackpad-guard install.sh uninstall.sh scripts/check-constants.sh tests/test-helper.sh tests/test-install.sh

check:
	@set -e; for f in $(SH_SCRIPTS); do bash -n "$$f" || exit 1; done
	if command -v shellcheck >/dev/null 2>&1; then shellcheck $(SH_SCRIPTS); else echo "check: shellcheck not found; skipping"; fi
	scripts/check-constants.sh
	if command -v omarchy >/dev/null 2>&1; then omarchy plugin validate shell-plugin; else echo "check: omarchy not found; skipping plugin validate"; fi
	if command -v qmllint >/dev/null 2>&1; then qmllint shell-plugin/Panel.qml; else echo "check: qmllint not found; skipping"; fi
	@! grep -Rn 'hl\.device' bin/ install.sh uninstall.sh shell-plugin/ \
		|| { echo "check: hl.device is forbidden in the native-DWT design (manual recovery lives in README only)"; exit 1; }

test:
	tests/test-helper.sh
	tests/test-install.sh

install: check
	./install.sh

uninstall:
	./uninstall.sh
