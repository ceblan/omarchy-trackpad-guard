#!/usr/bin/env bash
# Asserts that the keyboard match constants stay in sync across
# bin/omarchy-trackpad-guard (doctor), install.sh, uninstall.sh and the
# libinput quirks template, that their format is safe, and that the rendered
# quirks section is well-formed. Runs without sudo.

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

# Format validation: hex IDs must be 4 hex digits; the name must not contain
# control characters or characters that udev/quirks/sed interpret (globs,
# quotes, |, &, \).
for var in KEYBOARD_VENDOR KEYBOARD_PRODUCT KEYBOARD_BUSTYPE; do
  value="$(eval printf '%s' \"\$SYNCED_$var\")"
  [[ "${value,,}" =~ ^[0-9a-f]{4}$ ]] || fail "$var must be 4 hex digits, got: $value"
done
forbidden_name_chars='[][:cntrl:]"\\|&*?[]'
[[ -n "$SYNCED_KEYBOARD_NAME" && ! "$SYNCED_KEYBOARD_NAME" =~ $forbidden_name_chars ]] \
  || fail "KEYBOARD_NAME is empty or contains forbidden characters"

templates=(quirks/*.quirks.in)
[[ ${#templates[@]} -eq 1 && -f "${templates[0]}" ]] || fail "expected exactly one quirks/*.quirks.in template"
template="${templates[0]}"

# The template must carry the sentinels, the section named after the
# (capitalized) keyboard, the placeholders, and the pairing attribute.
grep -Fq '# >>> omarchy-trackpad-guard' "$template" || fail "$template lacks the opening sentinel"
grep -Fq '# <<< omarchy-trackpad-guard' "$template" || fail "$template lacks the closing sentinel"
section_name="${SYNCED_KEYBOARD_NAME^}"
grep -Fq "[$section_name]" "$template" || fail "$template section header must be [$section_name]"
grep -Fq 'MatchName=@XREMAP_NAME@' "$template" || fail "$template lacks the @XREMAP_NAME@ placeholder"
grep -Fq 'MatchVendor=0x@XREMAP_VENDOR@' "$template" || fail "$template lacks the @XREMAP_VENDOR@ placeholder"
grep -Fq 'MatchProduct=0x@XREMAP_PRODUCT@' "$template" || fail "$template lacks the @XREMAP_PRODUCT@ placeholder"
grep -Fq 'AttrKeyboardIntegration=internal' "$template" || fail "$template lacks AttrKeyboardIntegration=internal"

# Render exactly like install.sh does and validate the result statically.
rendered="$(mktemp)"
trap 'rm -f -- "$rendered"' EXIT
sed -e "s|@XREMAP_NAME@|$SYNCED_KEYBOARD_NAME|g" \
    -e "s|@XREMAP_VENDOR@|$SYNCED_KEYBOARD_VENDOR|g" \
    -e "s|@XREMAP_PRODUCT@|$SYNCED_KEYBOARD_PRODUCT|g" \
    "$template" > "$rendered"

grep -Eq "^MatchVendor=0x[0-9a-fA-F]{4}$" "$rendered" || fail "rendered MatchVendor is not 0x%04X"
grep -Eq "^MatchProduct=0x[0-9a-fA-F]{4}$" "$rendered" || fail "rendered MatchProduct is not 0x%04X"
grep -Fxq "MatchName=$SYNCED_KEYBOARD_NAME" "$rendered" || fail "rendered MatchName mismatch"
grep -Fxq 'MatchUdevType=keyboard' "$rendered" || fail "rendered quirk lacks MatchUdevType=keyboard"
grep -Fxq 'MatchBus=usb' "$rendered" || fail "rendered quirk lacks MatchBus=usb"
grep -Fxq 'AttrKeyboardIntegration=internal' "$rendered" || fail "rendered quirk lacks AttrKeyboardIntegration=internal"

# libinput 1.31 does not ship a `libinput quirks validate` in PATH on Arch;
# if it ever appears, prefer the real validator over the static checks.
if command -v libinput >/dev/null 2>&1; then
  libinput quirks validate "$rendered" >/dev/null 2>&1 \
    || fail "libinput quirks validate rejected the rendered template"
fi

printf 'check-constants: constants in sync, quirks template renders and validates\n'
