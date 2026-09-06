#!/usr/bin/env bash
# Harness for the omarchy-trackpad-guard helper (bin/omarchy-trackpad-guard).
# Pure bash: fixtures in tests/fixtures/, stubs in tests/stub-bin/.
# Each test runs with a private HOME / XDG_RUNTIME_DIR and a stub hyprctl that
# serves effective state from a file; nothing touches the real machine config.
#
# Run directly or via `make test`.

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HELPER="$REPO_ROOT/bin/omarchy-trackpad-guard"
STUB_BIN="$TESTS_DIR/stub-bin"
POKE_BIN="$TESTS_DIR/stub-luac-poke"
FIXTURES="$TESTS_DIR/fixtures"

WORK_ROOT="$TESTS_DIR/tmp"
rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

pass=0
fail=0
declare -a failures=()

tname=""
THOME=""
INPUT=""
STATE=""
POST=""
ERRS=""
ERRSR=""

note() { printf '    %s\n' "$*"; }

_ok() { pass=$((pass + 1)); printf '  ok: %s\n' "$*"; }
_bad() { fail=$((fail + 1)); failures+=("$tname: $*"); printf '  FAIL: %s\n' "$*"; }

check() { # $1=description $2=actual $3=expected
  if [[ "$2" == "$3" ]]; then _ok "$1"; else _bad "$1 (want '$3', got '$2')"; fi
}

check_contains() { # $1=description $2=file $3=fixed-string
  if grep -qF -- "$3" "$2" 2>/dev/null; then _ok "$1"; else _bad "$1 (missing '$3' in $2)"; fi
}

check_not_contains() { # $1=description $2=file $3=fixed-string
  if grep -qF -- "$3" "$2" 2>/dev/null; then _bad "$1 (unexpected '$3' in $2)"; else _ok "$1"; fi
}

check_files_equal() { # $1=description $2=fileA $3=fileB
  if cmp -s "$2" "$3"; then _ok "$1"; else _bad "$1 ($2 differs from $3)"; fi
}

reload_count() {
  grep -c '^hyprctl reload$' "$THOME/log" 2>/dev/null || true
}

new_test() { # $1=name
  tname=$1
  THOME="$WORK_ROOT/$tname"
  mkdir -p "$THOME/home/.config/hypr" "$THOME/xdg" "$THOME/state"
  : > "$THOME/log"
  INPUT="$THOME/home/.config/hypr/input.lua"
  STATE="$THOME/state/hyprctl"
  POST="$THOME/state/post"
  ERRS="$THOME/state/errors"
  ERRSR="$THOME/state/errors-reload"
  printf 'dwt=true\ntap=true\n' > "$STATE"
  : > "$ERRS"
  printf '%s\n' "--- $tname"
}

fixture() { # $1=fixture-name → copies into $INPUT
  cp "$FIXTURES/$1" "$INPUT"
}

# Run the helper in the test sandbox. Extra env via OTG_TEST_ENV (unused by
# default; the DOWN case sets HYPRCTL_STUB_DOWN via a dedicated wrapper).
hargs() {
  env -i \
    PATH="$TPATH" \
    HOME="$THOME/home" \
    XDG_RUNTIME_DIR="$THOME/xdg" \
    HYPRCTL_STUB_STATE="$STATE" \
    HYPRCTL_STUB_LOG="$THOME/log" \
    HYPRCTL_STUB_POST="$POST" \
    HYPRCTL_STUB_ERRORS="$ERRS" \
    HYPRCTL_STUB_ERRORS_ON_RELOAD="$ERRSR" \
    ${LUAC_POKE_FILE:+LUAC_POKE_FILE="$LUAC_POKE_FILE"} \
    ${LUAC_POKE_COUNT:+LUAC_POKE_COUNT="$LUAC_POKE_COUNT"} \
    "$HELPER" "$@"
}

hargs_down() {
  env -i \
    PATH="$TPATH" \
    HOME="$THOME/home" \
    XDG_RUNTIME_DIR="$THOME/xdg" \
    HYPRCTL_STUB_STATE="$STATE" \
    HYPRCTL_STUB_LOG="$THOME/log" \
    HYPRCTL_STUB_DOWN=1 \
    "$HELPER" "$@"
}

TPATH="$STUB_BIN:/usr/bin:/bin"

# --- 1: canonical replace, single reload, comments intact -------------------
new_test "01-canonical-replace"
fixture canonical.lua
printf 'dwt=false\ntap=true\n' > "$POST"
out="$(hargs set dwt off)"; rc=$?
check "exit 0" "$rc" 0
check "stdout reports final state" "$out" "disable_while_typing=false"
check_contains "token replaced" "$INPUT" "            disable_while_typing = false,"
check_contains "comment above intact" "$INPUT" "-- Disable the touchpad while typing"
check_contains "sibling key intact" "$INPUT" "tap_to_click = true,"
check "exactly one reload" "$(reload_count)" 1
luac -p "$INPUT" 2>/dev/null && _ok "result compiles" || _bad "result compiles"

# --- 2: key only inside a comment -> insert active line ----------------------
new_test "02-comment-only"
fixture comment-only.lua
printf 'dwt=true\ntap=true\n' > "$POST"
out="$(hargs set dwt on)"; rc=$?
check "exit 0" "$rc" 0
check_contains "active line inserted" "$INPUT" "            disable_while_typing = true,"
check_contains "comment preserved" "$INPUT" "-- disable_while_typing = false"
check "one active occurrence" "$(grep -cE '^[[:space:]]*disable_while_typing =' "$INPUT")" 1
luac -p "$INPUT" 2>/dev/null && _ok "result compiles" || _bad "result compiles"

# --- 3: touchpad block without the key -> insert after opening --------------
new_test "03-insert-into-touchpad"
fixture touchpad-no-key.lua
printf 'dwt=true\ntap=false\n' > "$POST"
hargs set tap off >/dev/null; rc=$?
check "exit 0" "$rc" 0
check_contains "tap_to_click inserted" "$INPUT" "            tap_to_click = false,"
check_contains "existing entry intact" "$INPUT" "clickfinger_behavior = true,"
luac -p "$INPUT" 2>/dev/null && _ok "result compiles" || _bad "result compiles"

# --- 4: input without touchpad -> insert touchpad sub-block -----------------
new_test "04-insert-touchpad-block"
fixture input-no-touchpad.lua
hargs set dwt on >/dev/null; rc=$?
check "exit 0" "$rc" 0
check_contains "touchpad sub-block inserted" "$INPUT" "        touchpad = { disable_while_typing = true },"
check_contains "sibling intact" "$INPUT" 'kb_layout = "es",'
luac -p "$INPUT" 2>/dev/null && _ok "result compiles" || _bad "result compiles"

# --- 5: no input anywhere -> append hl.config with authorship comment -------
new_test "05-append-hl-config"
fixture no-input.lua
hargs set tap on >/dev/null; rc=$?
check "exit 0" "$rc" 0
check_contains "authorship comment" "$INPUT" "-- Added by omarchy-trackpad-guard"
check_contains "appended block" "$INPUT" "hl.config({ input = { touchpad = { tap_to_click = true } } })"
check "single occurrence" "$(grep -c 'hl.config' "$INPUT")" 1
luac -p "$INPUT" 2>/dev/null && _ok "result compiles" || _bad "result compiles"

# --- 6: duplicate active key in two hl.config blocks -> exit 5, intact ------
new_test "06-duplicate-fails-closed"
fixture duplicate.lua
cp "$INPUT" "$THOME/state/preimage.lua"
hargs set dwt off >/dev/null 2>&1; rc=$?
check "exit 5" "$rc" 5
check_files_equal "file byte-identical" "$INPUT" "$THOME/state/preimage.lua"
check "no reload" "$(reload_count)" 0

# --- 7: key in block comment / string -> treated as absent ------------------
new_test "07-comment-and-string-ignored"
fixture comment-string.lua
hargs set dwt on >/dev/null; rc=$?
check "exit 0" "$rc" 0
check "single active occurrence" "$(grep -cE '^[[:space:]]*disable_while_typing = true,' "$INPUT")" 1
luac -p "$INPUT" 2>/dev/null && _ok "result compiles" || _bad "result compiles"

# --- 8: pre-existing broken syntax -> exit 4, intact ------------------------
new_test "08-broken-syntax"
fixture broken.lua
cp "$INPUT" "$THOME/state/preimage.lua"
hargs set dwt on >/dev/null 2>&1; rc=$?
check "exit 4" "$rc" 4
check_files_equal "file byte-identical" "$INPUT" "$THOME/state/preimage.lua"
check "no reload" "$(reload_count)" 0

# --- 9: read-only file -> exit 4, nothing written ---------------------------
new_test "09-readonly"
fixture canonical.lua
chmod 444 "$INPUT"
hargs set dwt off >/dev/null 2>&1; rc=$?
check "exit 4" "$rc" 4
check_contains "unchanged" "$INPUT" "disable_while_typing = true,"
check "no reload" "$(reload_count)" 0
chmod 644 "$INPUT"

# --- 10: symlinked input.lua -> real target edited, symlink preserved -------
new_test "10-symlink"
mkdir -p "$THOME/real"
cp "$FIXTURES/canonical.lua" "$THOME/real/input.lua"
chmod 640 "$THOME/real/input.lua"
rm -f "$INPUT"
ln -s "$THOME/real/input.lua" "$INPUT"
printf 'dwt=false\ntap=true\n' > "$POST"
hargs set dwt off >/dev/null; rc=$?
check "exit 0" "$rc" 0
[[ -L "$INPUT" ]] && _ok "still a symlink" || _bad "still a symlink"
check_contains "real target edited" "$THOME/real/input.lua" "disable_while_typing = false,"
check "mode preserved" "$(stat -c '%a' "$THOME/real/input.lua")" 640

# --- 11: two concurrent sets serialize on the lock --------------------------
new_test "11-concurrent"
fixture canonical.lua
printf 'dwt=false\ntap=false\n' > "$POST"
hargs set dwt off >/dev/null 2>&1 & p1=$!
hargs set tap off >/dev/null 2>&1 & p2=$!
wait "$p1"; rc1=$?
wait "$p2"; rc2=$?
check "first exit 0" "$rc1" 0
check "second exit 0" "$rc2" 0
check_contains "dwt written" "$INPUT" "disable_while_typing = false,"
check_contains "tap written" "$INPUT" "tap_to_click = false,"
check "one reload per operation" "$(reload_count)" 2
luac -p "$INPUT" 2>/dev/null && _ok "result compiles" || _bad "result compiles"

# --- 12: getoption never confirms -> exit 7, byte-identical restore ---------
new_test "12-verify-fails-rollback"
fixture canonical.lua
cp "$INPUT" "$THOME/state/preimage.lua"
printf 'dwt=true\ntap=true\n' > "$POST"   # reload does NOT apply the edit
hargs set dwt off >/dev/null 2>&1; rc=$?
check "exit 7" "$rc" 7
check_files_equal "file restored byte-identical" "$INPUT" "$THOME/state/preimage.lua"
check "apply + rollback reloads" "$(reload_count)" 2

# --- 13: Hyprland down -> exit 3, intact ------------------------------------
new_test "13-hyprland-down"
fixture canonical.lua
cp "$INPUT" "$THOME/state/preimage.lua"
hargs_down set dwt off >/dev/null 2>&1; rc=$?
check "set exit 3" "$rc" 3
hargs_down get >/dev/null 2>&1; rc=$?
check "get exit 3" "$rc" 3
check_files_equal "file intact" "$INPUT" "$THOME/state/preimage.lua"
check "no reload" "$(reload_count)" 0

# --- 14: inline single-line block -> intra-line token replace ---------------
new_test "14-inline-block"
fixture inline.lua
printf 'dwt=false\ntap=true\n' > "$POST"
hargs set dwt off >/dev/null; rc=$?
check "exit 0" "$rc" 0
check_contains "intra-line edit" "$INPUT" "touchpad = { disable_while_typing = false, tap_to_click = true }"
luac -p "$INPUT" 2>/dev/null && _ok "result compiles" || _bad "result compiles"

# --- 14b: inline block, absent key -> inline insertion ----------------------
new_test "14b-inline-insert"
fixture inline-empty.lua
hargs set dwt on >/dev/null; rc=$?
check "exit 0" "$rc" 0
check_contains "inline insertion" "$INPUT" "touchpad = { disable_while_typing = true, }"
luac -p "$INPUT" 2>/dev/null && _ok "result compiles" || _bad "result compiles"

# --- 15: key in a wrong location -> exit 5, intact --------------------------
new_test "15-wrong-location"
fixture wrong-location.lua
cp "$INPUT" "$THOME/state/preimage.lua"
hargs set dwt on >/dev/null 2>&1; rc=$?
check "exit 5" "$rc" 5
check_files_equal "file intact" "$INPUT" "$THOME/state/preimage.lua"

# --- 16: no-op -> exit 0, no reload, intact ---------------------------------
new_test "16-no-op"
fixture canonical.lua
cp "$INPUT" "$THOME/state/preimage.lua"
out="$(hargs set dwt on)"; rc=$?
check "exit 0" "$rc" 0
check "stdout" "$out" "disable_while_typing=true"
check "no reload" "$(reload_count)" 0
check_files_equal "file intact" "$INPUT" "$THOME/state/preimage.lua"

# --- 17: file/runtime divergence -> get reports pending; set syncs w/o edit -
new_test "17-divergence-pending"
fixture canonical.lua
printf 'dwt=false\ntap=true\n' > "$STATE"   # runtime diverges from file (true)
cp "$INPUT" "$THOME/state/preimage.lua"
json="$(hargs get --json)"; rc=$?
check "get exit 0" "$rc" 0
if command -v jq >/dev/null 2>&1; then
  check "dwt state pending" "$(printf '%s' "$json" | jq -r '.dwt.state')" "pending"
  check "dwt file true" "$(printf '%s' "$json" | jq -r '.dwt.file')" "true"
  check "dwt effective false" "$(printf '%s' "$json" | jq -r '.dwt.effective')" "false"
else
  printf '%s' "$json" | grep -q '"state":"pending"' && _ok "dwt state pending" || _bad "dwt state pending"
fi
printf 'dwt=true\ntap=true\n' > "$POST"   # reload applies the file value
out="$(hargs set dwt on)"; rc=$?
check "set exit 0" "$rc" 0
check "no backup created (no edit)" "$(ls -1 "$INPUT".bak.trackpad-guard.* 2>/dev/null | wc -l)" 0
check "one reload" "$(reload_count)" 1
check_files_equal "file byte-identical" "$INPUT" "$THOME/state/preimage.lua"

# --- 18: duplicate key -> get reports ambiguous, exit 0 ---------------------
new_test "18-get-ambiguous"
fixture duplicate.lua
json="$(hargs get --json)"; rc=$?
check "get exit 0" "$rc" 0
if command -v jq >/dev/null 2>&1; then
  check "dwt state ambiguous" "$(printf '%s' "$json" | jq -r '.dwt.state')" "ambiguous"
else
  printf '%s' "$json" | grep -q '"state":"ambiguous"' && _ok "dwt state ambiguous" || _bad "dwt state ambiguous"
fi

# --- 19: external same-size edit mid-flight -> exit 6, external kept --------
new_test "19-external-concurrent-edit"
fixture canonical.lua
printf 'dwt=false\ntap=true\n' > "$POST"
export LUAC_POKE_FILE="$INPUT"
LUAC_POKE_FILE="$INPUT"
LUAC_POKE_COUNT="$THOME/state/pokecount"
TPATH="$POKE_BIN:$STUB_BIN:/usr/bin:/bin"
hargs set dwt off >/dev/null 2>&1; rc=$?
TPATH="$STUB_BIN:/usr/bin:/bin"
unset LUAC_POKE_FILE
check "exit 6" "$rc" 6
check "editor saw the race twice" "$(cat "$LUAC_POKE_COUNT")" 2
check_not_contains "external version kept (no key edit)" "$INPUT" "disable_while_typing = false"
check "no reload" "$(reload_count)" 0
check "backup kept for inspection" "$(ls -1 "$INPUT".bak.trackpad-guard.* 2>/dev/null | wc -l)" 2

# --- 20: pre-existing configerrors, unchanged by reload -> exit 0 -----------
new_test "20-preexisting-configerrors"
fixture canonical.lua
printf 'dwt=false\ntap=false\n' > "$POST"
printf 'error in autostart.lua: something pre-existing\n' > "$ERRS"
printf 'error in autostart.lua: something pre-existing\n' > "$ERRSR"
hargs set tap off >/dev/null 2>&1; rc=$?
check "exit 0 (pre-existing errors never block)" "$rc" 0
check_contains "edit applied" "$INPUT" "tap_to_click = false,"
check "one reload" "$(reload_count)" 1

# --- 21a: new configerror mentioning input.lua -> exit 7 + rollback ---------
new_test "21a-new-inputlua-error"
fixture canonical.lua
printf 'dwt=false\ntap=true\n' > "$POST"
cp "$INPUT" "$THOME/state/preimage.lua"
printf 'error in /home/x/.config/hypr/input.lua: bad thing\n' > "$ERRSR"
hargs set dwt off >/dev/null 2>&1; rc=$?
check "exit 7" "$rc" 7
check_files_equal "file restored" "$INPUT" "$THOME/state/preimage.lua"
check "apply + rollback reloads" "$(reload_count)" 2

# --- 21b: new configerror about another file -> exit 0 with warning ---------
new_test "21b-new-foreign-error"
fixture canonical.lua
printf 'dwt=false\ntap=true\n' > "$POST"
printf 'error in autostart.lua: appeared after reload\n' > "$ERRSR"
errout="$(hargs set dwt off 2>&1 >/dev/null)"; rc=$?
check "exit 0" "$rc" 0
check_contains "edit applied" "$INPUT" "disable_while_typing = false,"
case "$errout" in
  warning:*) _ok "warning on stderr" ;;
  *) _bad "warning on stderr (got: $errout)" ;;
esac

# --- 22: absent key + default-true runtime -> get reports absent ------------
new_test "22-absent-reported"
fixture touchpad-no-key.lua
json="$(hargs get --json)"; rc=$?
check "get exit 0" "$rc" 0
if command -v jq >/dev/null 2>&1; then
  check "tap state absent" "$(printf '%s' "$json" | jq -r '.tap.state')" "absent"
  check "tap effective true" "$(printf '%s' "$json" | jq -r '.tap.effective')" "true"
else
  printf '%s' "$json" | grep -q '"state":"absent"' && _ok "tap state absent" || _bad "tap state absent"
fi

# --- 23: absent key made explicit by set -> sync ----------------------------
new_test "23-absent-set-explicit"
fixture touchpad-no-key.lua
printf 'dwt=true\ntap=false\n' > "$POST"
hargs set tap off >/dev/null; rc=$?
check "exit 0" "$rc" 0
check_contains "explicit false written" "$INPUT" "tap_to_click = false,"
json="$(hargs get --json)"
if command -v jq >/dev/null 2>&1; then
  check "tap state sync" "$(printf '%s' "$json" | jq -r '.tap.state')" "sync"
fi

# --- 24: multiple canonical touchpad blocks, key absent -> exit 5 (advisory)
new_test "24-multi-touchpad-ambiguous"
fixture multi-touchpad.lua
cp "$INPUT" "$THOME/state/preimage.lua"
hargs set dwt on >/dev/null 2>&1; rc=$?
check "exit 5" "$rc" 5
check_files_equal "file intact" "$INPUT" "$THOME/state/preimage.lua"

# --- 25: multiple canonical input blocks, no touchpad -> exit 5 (advisory) --
new_test "25-multi-input-ambiguous"
fixture multi-input.lua
cp "$INPUT" "$THOME/state/preimage.lua"
hargs set dwt on >/dev/null 2>&1; rc=$?
check "exit 5" "$rc" 5
check_files_equal "file intact" "$INPUT" "$THOME/state/preimage.lua"

# --- 26: bracket string keys are canonical-aware (advisory) -----------------
new_test "26-bracket-keys"
fixture bracket-keys.lua
json="$(hargs get --json)"
if command -v jq >/dev/null 2>&1; then
  check "dwt file true via bracket key" "$(printf '%s' "$json" | jq -r '.dwt.file')" "true"
fi
printf 'dwt=false\ntap=true\n' > "$POST"
hargs set dwt off >/dev/null; rc=$?
check "exit 0" "$rc" 0
check_contains "bracket value replaced in place" "$INPUT" '["disable_while_typing"] = false,'
check "single occurrence" "$(grep -c 'disable_while_typing' "$INPUT")" 1
luac -p "$INPUT" 2>/dev/null && _ok "result compiles" || _bad "result compiles"

# --- 27: non-literal value -> exit 5, intact --------------------------------
new_test "27-nonliteral"
fixture nonliteral.lua
cp "$INPUT" "$THOME/state/preimage.lua"
hargs set dwt off >/dev/null 2>&1; rc=$?
check "exit 5" "$rc" 5
check_files_equal "file intact" "$INPUT" "$THOME/state/preimage.lua"

# --- summary ------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
if (( fail > 0 )); then
  printf 'failures:\n'
  printf '  - %s\n' "${failures[@]}"
  printf '\nwork preserved under %s\n' "$WORK_ROOT"
  exit 1
fi
rm -rf "$WORK_ROOT"
exit 0
