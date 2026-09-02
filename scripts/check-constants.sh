#!/usr/bin/env bash
# Asserts that the keyboard match constants stay in sync across
# bin/omarchy-trackpad-guard, install.sh, uninstall.sh and the udev rule
# template, that their format is safe for udev/sed interpolation, and that
# the rendered rule passes `udevadm verify`. Runs without sudo.

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  printf 'check-constants: %s\n' "$*" >&2
  exit 1
}

extract() {
  local file="$1" var="$2"
  grep -E "^${var}=" "$file" | head -n 1 | sed -E "s/^${var}=\"(.*)\"$/\1/"
}

scripts=(bin/omarchy-trackpad-guard install.sh uninstall.sh)

for var in KEYBOARD_NAME KEYBOARD_VENDOR KEYBOARD_PRODUCT KEYBOARD_BUSTYPE; do
  reference=""
  for script in "${scripts[@]}"; do
    value="$(extract "$script" "$var")"
    [[ -n "$value" ]] || fail "$script does not define $var"
    if [[ -z "$reference" ]]; then
      reference="$value"
    elif [[ "$value" != "$reference" ]]; then
      fail "$var diverges: '${reference}' vs '$value' in $script"
    fi
  done
  printf -v "SYNCED_$var" '%s' "$reference"
done

# Format validation (same rules the guard and installer enforce at runtime):
# hex IDs must be 4 lowercase-hex digits; the name must not contain control
# characters or characters that udev/sed interpret (globs, quotes, |, &, \).
for var in KEYBOARD_VENDOR KEYBOARD_PRODUCT KEYBOARD_BUSTYPE; do
  value="$(eval printf '%s' \"\$SYNCED_$var\")"
  [[ "${value,,}" =~ ^[0-9a-f]{4}$ ]] || fail "$var must be 4 hex digits, got: $value"
done
forbidden_name_chars='[][:cntrl:]"\\|&*?[]'
[[ -n "$SYNCED_KEYBOARD_NAME" && ! "$SYNCED_KEYBOARD_NAME" =~ $forbidden_name_chars ]] \
  || fail "KEYBOARD_NAME is empty or contains forbidden characters"

templates=(rules/*.rules.in)
[[ ${#templates[@]} -eq 1 && -f "${templates[0]}" ]] || fail "expected exactly one rules/*.rules.in template"
template="${templates[0]}"

grep -Fq "ATTRS{name}==\"$SYNCED_KEYBOARD_NAME\"" "$template" || fail "$template lacks exact ATTRS{name} match"
grep -Fq "ATTRS{id/vendor}==\"$SYNCED_KEYBOARD_VENDOR\"" "$template" || fail "$template lacks exact ATTRS{id/vendor} match"
grep -Fq "ATTRS{id/product}==\"$SYNCED_KEYBOARD_PRODUCT\"" "$template" || fail "$template lacks exact ATTRS{id/product} match"
grep -Fq "ATTRS{id/bustype}==\"$SYNCED_KEYBOARD_BUSTYPE\"" "$template" || fail "$template lacks exact ATTRS{id/bustype} match"

rendered="$(mktemp --suffix=.rules)"
trap 'rm -f -- "$rendered"' EXIT
sed -e "s|@SETFACL@|/usr/bin/setfacl|g" -e "s|@USER@|dummyuser|g" "$template" > "$rendered"
udevadm verify "$rendered" >/dev/null || fail "udevadm verify rejected the rendered rule"

printf 'check-constants: constants in sync, template matches, rendered rule verifies\n'
