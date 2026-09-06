#!/usr/bin/env bash
# Sandbox harness for install.sh / uninstall.sh (upgrade / migration paths).
# Nothing touches the real /etc, /sys, systemd or Hyprland: OTG_ROOT and
# OTG_SYSFS_ROOT redirect every absolute path into a per-case sandbox and
# PATH-injected stubs (sudo, udevadm, systemctl, hyprctl, omarchy*,
# omarchy-hw-touchpad, fuser, evtest) log chronologically to $OTG_ORDER_LOG.
#
# Run directly or via `make test` (after tests/test-helper.sh).

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
UNINSTALL="$REPO_ROOT/uninstall.sh"
STUB_BIN="$TESTS_DIR/stub-bin"
FIXTURES="$TESTS_DIR/fixtures"

WORK_ROOT="$TESTS_DIR/tmp-install"
rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

pass=0
fail=0
declare -a failures=()

# Spawned fixture processes (fake guards, stub evtest) must never leak, even
# when the harness is interrupted mid-case. Each is launched with setsid (own
# process group, pgid == pid) so the trap can kill the WHOLE group — the
# evtest wrapper has a `sleep` child that would otherwise be orphaned.
declare -a spawned_pids=()
cleanup_spawned() {
  trap - EXIT INT TERM
  local p
  for p in "${spawned_pids[@]:-}"; do
    [[ -n "$p" ]] && kill -TERM -- "-$p" 2>/dev/null || true
  done
  for p in "${spawned_pids[@]:-}"; do
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && kill -KILL -- "-$p" 2>/dev/null || true
  done
  return 0
}
trap 'cleanup_spawned EXIT' EXIT
trap 'cleanup_spawned INT; exit 130' INT
trap 'cleanup_spawned TERM; exit 143' TERM

SB=""
ORDER_LOG=""
TCASE=""

_ok() { pass=$((pass + 1)); printf '  ok: %s\n' "$*"; }
_bad() { fail=$((fail + 1)); failures+=("$TCASE: $*"); printf '  FAIL: %s\n' "$*"; }

check() { # $1=description $2=actual $3=expected
  if [[ "$2" == "$3" ]]; then _ok "$1"; else _bad "$1 (want '$3', got '$2')"; fi
}
check_file() { # $1=description $2=path
  if [[ -f "$2" ]]; then _ok "$1"; else _bad "$1 (missing file $2)"; fi
}
check_no_file() { # $1=description $2=path
  if [[ -e "$2" ]]; then _bad "$1 (unexpected $2)"; else _ok "$1"; fi
}
check_dir() { # $1=description $2=path
  if [[ -d "$2" ]]; then _ok "$1"; else _bad "$1 (missing dir $2)"; fi
}
check_contains() { # $1=description $2=file $3=fixed-string
  if [[ -f "$2" ]] && grep -qF -- "$3" "$2"; then _ok "$1"; else _bad "$1 (missing '$3' in $2)"; fi
}
check_not_contains() { # $1=description $2=file $3=fixed-string
  if [[ -f "$2" ]] && grep -qF -- "$3" "$2"; then _bad "$1 (unexpected '$3' in $2)"; else _ok "$1"; fi
}
check_count() { # $1=description $2=file $3=fixed-string $4=count
  local n=0
  [[ -f "$2" ]] && n="$(grep -cF -- "$3" "$2")"
  check "$1" "$n" "$4"
}
check_order() { # $1=description $2=first-pattern $3=second-pattern (in ORDER_LOG)
  local l1 l2
  l1="$(grep -nF -- "$2" "$ORDER_LOG" 2>/dev/null | head -n1 | cut -d: -f1)"
  l2="$(grep -nF -- "$3" "$ORDER_LOG" 2>/dev/null | head -n1 | cut -d: -f1)"
  if [[ -n "$l1" && -n "$l2" && "$l1" -lt "$l2" ]]; then
    _ok "$1"
  else
    _bad "$1 ('$2'@${l1:-none} vs '$3'@${l2:-none})"
  fi
}

# --- sandbox ------------------------------------------------------------------

make_sysfs() { # $1=sysroot — xremap event19 (virtual) + touchpad event8
  local sys=$1
  mkdir -p "$sys/devices/virtual/input/input19/id" "$sys/devices/virtual/input/input19/event19"
  printf 'xremap virtual keyboard\n' > "$sys/devices/virtual/input/input19/name"
  printf '1234\n' > "$sys/devices/virtual/input/input19/id/vendor"
  printf '9950\n' > "$sys/devices/virtual/input/input19/id/product"
  printf '0003\n' > "$sys/devices/virtual/input/input19/id/bustype"
  ln -sfn "$sys/devices/virtual/input/input19" "$sys/devices/virtual/input/input19/event19/device"
  mkdir -p "$sys/class/input"
  ln -sfn "$sys/devices/virtual/input/input19/event19" "$sys/class/input/event19"

  mkdir -p "$sys/devices/platform/i8042/input8/id" "$sys/devices/platform/i8042/input8/event8"
  printf 'ASUF1208:00 2808:0218 Touchpad\n' > "$sys/devices/platform/i8042/input8/name"
  printf '2808\n' > "$sys/devices/platform/i8042/input8/id/vendor"
  printf '0218\n' > "$sys/devices/platform/i8042/input8/id/product"
  printf '0018\n' > "$sys/devices/platform/i8042/input8/id/bustype"
  ln -sfn "$sys/devices/platform/i8042/input8" "$sys/devices/platform/i8042/input8/event8/device"
  ln -sfn "$sys/devices/platform/i8042/input8/event8" "$sys/class/input/event8"
}

new_sandbox() { # $1=case-name
  TCASE=$1
  SB="$WORK_ROOT/$1"
  mkdir -p "$SB/home/.config/hypr" "$SB/xdg" "$SB/root/etc/udev/rules.d" "$SB/root/etc/libinput"
  cp "$FIXTURES/canonical.lua" "$SB/home/.config/hypr/input.lua"
  printf 'dwt=true\ntap=true\n' > "$SB/hyprctl-state"
  : > "$SB/hyprctl-errors"
  ORDER_LOG="$SB/order.log"
  : > "$ORDER_LOG"
  make_sysfs "$SB/sys"
  printf '%s\n' "--- $1"
}

TPATH_BASE="$STUB_BIN:/usr/bin:/bin"

run_install() { # extra env via OTG_EXTRA_PATH (prepended)
  env -i \
    PATH="${OTG_EXTRA_PATH:+$OTG_EXTRA_PATH:}$TPATH_BASE" \
    HOME="$SB/home" \
    XDG_RUNTIME_DIR="$SB/xdg" \
    OTG_ROOT="$SB/root" \
    OTG_SYSFS_ROOT="$SB/sys" \
    OTG_ORDER_LOG="$ORDER_LOG" \
    HYPRCTL_STUB_STATE="$SB/hyprctl-state" \
    HYPRCTL_STUB_LOG="$SB/hyprctl.log" \
    HYPRCTL_STUB_ERRORS="$SB/hyprctl-errors" \
    "$INSTALL" ${1:-}
}

run_uninstall() {
  env -i \
    PATH="${OTG_EXTRA_PATH:+$OTG_EXTRA_PATH:}$TPATH_BASE" \
    HOME="$SB/home" \
    XDG_RUNTIME_DIR="$SB/xdg" \
    OTG_ROOT="$SB/root" \
    OTG_SYSFS_ROOT="$SB/sys" \
    OTG_ORDER_LOG="$ORDER_LOG" \
    HYPRCTL_STUB_STATE="$SB/hyprctl-state" \
    HYPRCTL_STUB_LOG="$SB/hyprctl.log" \
    HYPRCTL_STUB_ERRORS="$SB/hyprctl-errors" \
    "$UNINSTALL"
}

rendered_template() { # render the quirks template like install.sh does
  sed -e 's|@XREMAP_NAME@|xremap virtual keyboard|g' \
      -e 's|@XREMAP_VENDOR@|1234|g' \
      -e 's|@XREMAP_PRODUCT@|9950|g' \
      "$REPO_ROOT/quirks/10-xremap-internal-keyboard.quirks.in"
}

QUIRKS() { printf '%s\n' "$SB/root/etc/libinput/local-overrides.quirks"; }

# --- 1: clean install -----------------------------------------------------------
new_sandbox "01-clean-install"
out="$(run_install 2>&1)"; rc=$?
check "install exit 0" "$rc" 0
check_file "helper installed" "$SB/home/.local/bin/omarchy-trackpad-guard"
[[ -x "$SB/home/.local/bin/omarchy-trackpad-guard" ]] && _ok "helper executable" || _bad "helper executable"
check_file "plugin manifest deployed" "$SB/home/.config/omarchy/plugins/ceblan.trackpad-guard/manifest.json"
check_file "plugin panel deployed" "$SB/home/.config/omarchy/plugins/ceblan.trackpad-guard/Panel.qml"
check_contains "quirk sentinel start" "$(QUIRKS)" "# >>> omarchy-trackpad-guard"
check_contains "quirk sentinel end" "$(QUIRKS)" "# <<< omarchy-trackpad-guard"
check_contains "quirk vendor" "$(QUIRKS)" "MatchVendor=0x1234"
check_contains "quirk product" "$(QUIRKS)" "MatchProduct=0x9950"
check_contains "quirk name" "$(QUIRKS)" "MatchName=xremap virtual keyboard"
check_contains "quirk attr" "$(QUIRKS)" "AttrKeyboardIntegration=internal"
check_contains "quirk section name" "$(QUIRKS)" "[Xremap virtual keyboard]"
case "$out" in *"log out and back in"*) _ok "relogin notice" ;; *) _bad "relogin notice" ;; esac
check_contains "plugin rescan" "$ORDER_LOG" "omarchy-shell shell rescanPlugins"
check_contains "plugin enable" "$ORDER_LOG" "omarchy plugin enable ceblan.trackpad-guard"
check_no_file "no systemd unit deployed" "$SB/home/.config/systemd/user/omarchy-trackpad-guard.service"

# --- 2: idempotency ---------------------------------------------------------------
new_sandbox "02-idempotent"
run_install >/dev/null 2>&1; rc=$?
check "first install exit 0" "$rc" 0
sha1="$(sha256sum "$(QUIRKS)" | cut -d' ' -f1)"
out="$(run_install 2>&1)"; rc=$?
check "second install exit 0" "$rc" 0
sha2="$(sha256sum "$(QUIRKS)" | cut -d' ' -f1)"
check "quirks byte-identical after reinstall" "$sha1" "$sha2"
check_count "single sentinel block" "$(QUIRKS)" "# >>> omarchy-trackpad-guard" 1
case "$out" in *"already up to date"*) _ok "second run reports up to date" ;; *) _bad "second run reports up to date" ;; esac
run_uninstall >/dev/null 2>&1; rc=$?
check "uninstall exit 0" "$rc" 0
check_no_file "quirks file removed (we created it)" "$(QUIRKS)"
run_install >/dev/null 2>&1; rc=$?
check "install-after-uninstall exit 0" "$rc" 0
sha3="$(sha256sum "$(QUIRKS)" | cut -d' ' -f1)"
check "cycle converges to same quirks content" "$sha1" "$sha3"

# --- 3: external equivalent is used but never adopted ------------------------------
new_sandbox "03-external-quirk"
cp "$FIXTURES/quirks-external.quirks" "$(QUIRKS)"
before="$(sha256sum "$(QUIRKS)" | cut -d' ' -f1)"
out="$(run_install 2>&1)"; rc=$?
check "install exit 0" "$rc" 0
check "quirks byte-identical after install" "$(sha256sum "$(QUIRKS)" | cut -d' ' -f1)" "$before"
case "$out" in *"external equivalent quirk"*) _ok "reported as external" ;; *) _bad "reported as external" ;; esac
out="$(run_uninstall 2>&1)"; rc=$?
check "uninstall exit 0" "$rc" 0
check "quirks byte-identical after uninstall" "$(sha256sum "$(QUIRKS)" | cut -d' ' -f1)" "$before"
case "$out" in *"external"*"untouched"*) _ok "uninstall reports external untouched" ;; *) _bad "uninstall reports external untouched" ;; esac

# --- 4: conflicting homonym aborts --------------------------------------------------
new_sandbox "04-conflict"
cat > "$(QUIRKS)" <<'EOF'
# hand-maintained variant without the pairing attribute
[Xremap virtual keyboard]
MatchUdevType=keyboard
MatchName=xremap virtual keyboard
EOF
before="$(sha256sum "$(QUIRKS)" | cut -d' ' -f1)"
out="$(run_install 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && _ok "install aborts on conflict" || _bad "install aborts on conflict (exit $rc)"
case "$out" in *CONFLICT:*) _ok "conflict message" ;; *) _bad "conflict message" ;; esac
check "file byte-identical" "$(sha256sum "$(QUIRKS)" | cut -d' ' -f1)" "$before"
check_count "no duplicated section name" "$(QUIRKS)" "[Xremap virtual keyboard]" 1

# --- 5: managed drift is rewritten between sentinels only ---------------------------
new_sandbox "05-managed-drift"
{
  printf '# pre-existing quirks file\n'
  printf '[Some other device]\nMatchName=foo\nAttrKeyboardIntegration=external\n\n'
  printf '# >>> omarchy-trackpad-guard (managed section; do not edit between markers)\n'
  printf '[Xremap virtual keyboard]\nMatchUdevType=keyboard\nAttrKeyboardIntegration=external\n'
  printf '# <<< omarchy-trackpad-guard\n'
  printf '\n[Unrelated]\nMatchName=bar\n'
} > "$(QUIRKS)"
out="$(run_install 2>&1)"; rc=$?
check "install exit 0" "$rc" 0
rendered_template | awk '
  /^# >>> omarchy-trackpad-guard/ { inside = 1 }
  inside { print }
  /^# <<< omarchy-trackpad-guard/ { inside = 0 }
' > "$SB/expected-block"
awk '
  /^# >>> omarchy-trackpad-guard/ { inside = 1 }
  inside { print }
  /^# <<< omarchy-trackpad-guard/ { inside = 0 }
' "$(QUIRKS)" > "$SB/actual-block"
if cmp -s "$SB/expected-block" "$SB/actual-block"; then _ok "managed block rewritten to template"; else _bad "managed block rewritten to template"; fi
check_contains "foreign section before intact" "$(QUIRKS)" "[Some other device]"
check_contains "foreign attr intact" "$(QUIRKS)" "AttrKeyboardIntegration=external"
check_contains "foreign section after intact" "$(QUIRKS)" "[Unrelated]"
check "backup created" "$(ls -1 "$(QUIRKS)".bak.trackpad-guard.* 2>/dev/null | wc -l)" 1
check_count "single sentinel block" "$(QUIRKS)" "# >>> omarchy-trackpad-guard" 1

# --- 6: sentinel deletion on uninstall ------------------------------------------------
new_sandbox "06-sentinel-removal"
# 6a: file we created -> removed entirely
run_install >/dev/null 2>&1
check_file "created by install" "$(QUIRKS)"
out="$(run_uninstall 2>&1)"; rc=$?
check "uninstall exit 0" "$rc" 0
check_no_file "created-by-us quirks file deleted" "$(QUIRKS)"
# 6b: foreign content around the managed block -> block removed, rest intact
{
  printf '# vendor quirks\n[Vendor]\nMatchName=zzz\n'
  printf '\n# >>> omarchy-trackpad-guard (managed section; do not edit between markers)\n'
  rendered_template | awk '/^# >>>/{i=1} i{print} /^# <<</{i=0}' | sed '1d'
  printf '\n[Other]\nMatchName=aaa\n'
} > "$(QUIRKS)"
out="$(run_uninstall 2>&1)"; rc=$?
check "uninstall exit 0 (6b)" "$rc" 0
[[ -f "$(QUIRKS)" ]] && _ok "file kept (foreign content)" || _bad "file kept (foreign content)"
check_not_contains "managed block gone" "$(QUIRKS)" "omarchy-trackpad-guard"
check_contains "foreign before intact" "$(QUIRKS)" "[Vendor]"
check_contains "foreign after intact" "$(QUIRKS)" "[Other]"
# 6c: created-by-us file plus ONE user comment -> file kept (comments are
# foreign content), sentinel block alone removed
new_sandbox "06c-user-comment-keeps-file"
run_install >/dev/null 2>&1
check_file "created by install" "$(QUIRKS)"
printf '# my own note about this file\n' >> "$(QUIRKS)"
out="$(run_uninstall 2>&1)"; rc=$?
check "uninstall exit 0 (6c)" "$rc" 0
check_file "file kept (user comment is foreign)" "$(QUIRKS)"
check_not_contains "sentinel start gone (6c)" "$(QUIRKS)" "# >>> omarchy-trackpad-guard"
check_not_contains "sentinel end gone (6c)" "$(QUIRKS)" "# <<< omarchy-trackpad-guard"
check_not_contains "managed section name gone (6c)" "$(QUIRKS)" "[Xremap virtual keyboard]"
check_contains "user comment intact" "$(QUIRKS)" "# my own note about this file"
check_contains "creation header intact" "$(QUIRKS)" "# Local libinput quirks overrides."

# --- 7: full legacy migration + validated orphan reaper --------------------------------
new_sandbox "07-legacy-full"
TARGET_BIN="$SB/home/.local/bin/omarchy-trackpad-guard"
mkdir -p "$SB/home/.local/bin" "$SB/home/.config/systemd/user/omarchy-trackpad-guard.service.d"
printf '[Unit]\nDescription=legacy\n' > "$SB/home/.config/systemd/user/omarchy-trackpad-guard.service"
printf '[Service]\nEnvironment=TRACKPAD_GUARD_TIMEOUT=3\n' > "$SB/home/.config/systemd/user/omarchy-trackpad-guard.service.d/override.conf"
printf '#!/bin/sh\necho legacy\n' > "$TARGET_BIN"
chmod +x "$TARGET_BIN"
printf 'legacy rule\n' > "$SB/root/etc/udev/rules.d/99-trackpad-guard-acl.rules"
printf 'legacy rule\n' > "$SB/root/etc/udev/rules.d/99-xremap-virtual-keyboard-trackpad-guard.rules"
# fake running guard: argv[0] == $TARGET_BIN
setsid bash -c 'exec -a "$1" sleep 300' _ "$TARGET_BIN" &
guard_pid=$!
spawned_pids+=("$guard_pid")
printf '%s\n' "$guard_pid" > "$SB/xdg/omarchy-trackpad-guard-${UID}.pid"
# orphan evtest holding the legacy flock (inherited fd), node = touchpad
LOCKF="$SB/xdg/omarchy-trackpad-guard-${UID}.lock"
exec {lockfd}>"$LOCKF"
flock "$lockfd"
setsid env OTG_STUB_SLEEP=300 "$STUB_BIN/evtest" --grab /dev/input/event8 <&"$lockfd" &
orphan_pid=$!
spawned_pids+=("$orphan_pid")
# a foreign evtest on ANOTHER node, no lock inheritance: must survive
setsid env OTG_STUB_SLEEP=300 "$STUB_BIN/evtest" --grab /dev/input/event99 </dev/null &
foreign_pid=$!
spawned_pids+=("$foreign_pid")
exec {lockfd}>&-
sleep 0.3  # let stubs start
kill -0 "$guard_pid" 2>/dev/null && _ok "fixture guard running" || _bad "fixture guard running"
flock -n "$LOCKF" -c true 2>/dev/null && _bad "fixture lock held" || _ok "fixture lock held"
out="$(run_install 2>&1)"; rc=$?
check "install exit 0" "$rc" 0
kill -0 "$guard_pid" 2>/dev/null && _bad "legacy guard killed" || _ok "legacy guard killed"
kill -0 "$orphan_pid" 2>/dev/null && _bad "orphan evtest reaped" || _ok "orphan evtest reaped"
kill -0 "$foreign_pid" 2>/dev/null && _ok "foreign evtest survived" || _bad "foreign evtest survived"
flock -n "$LOCKF" -c true 2>/dev/null && _ok "lock free after reaper" || _bad "lock free after reaper"
check_no_file "unit removed" "$SB/home/.config/systemd/user/omarchy-trackpad-guard.service"
check_no_file "drop-in removed" "$SB/home/.config/systemd/user/omarchy-trackpad-guard.service.d/override.conf"
check_no_file "our rule removed" "$SB/root/etc/udev/rules.d/99-trackpad-guard-acl.rules"
check_no_file "legacy rule removed" "$SB/root/etc/udev/rules.d/99-xremap-virtual-keyboard-trackpad-guard.rules"
check_contains "udev reload" "$ORDER_LOG" "udevadm control --reload-rules"
check_contains "trigger on xremap node" "$ORDER_LOG" "trigger --action=change --subsystem-match=input --sysname-match=event19"
check_contains "trigger on touchpad node" "$ORDER_LOG" "--sysname-match=event8"
check_contains "settle" "$ORDER_LOG" "udevadm settle"
check_order "trigger happens AFTER rule removal" "sudo rm -f -- $SB/root/etc/udev/rules.d/99-trackpad-guard-acl.rules" "sudo udevadm trigger --action=change --subsystem-match=input --sysname-match=event19"
check_contains "hyprctl reload (evidence existed)" "$SB/hyprctl.log" "reload"
case "$out" in *"Reviving a dead touchpad"*) _ok "README recovery pointer (no hl.device)" ;; *) _bad "README recovery pointer" ;; esac
check_no_file "pidfile removed" "$SB/xdg/omarchy-trackpad-guard-${UID}.pid"
check_file "helper reinstalled new" "$TARGET_BIN"
# the surviving foreign stub is reaped by the harness EXIT trap (group kill)

# --- 8: acl tools missing -> warn, continue, still remove rule -------------------------
new_sandbox "08-acl-gate"
printf 'legacy rule\n' > "$SB/root/etc/udev/rules.d/99-trackpad-guard-acl.rules"
# curated PATH without setfacl/getfacl (symlink farm of /usr/bin minus them)
CURATED="$SB/bin"
mkdir -p "$CURATED"
for f in /usr/bin/*; do
  b="${f##*/}"
  case "$b" in setfacl|getfacl) continue ;; esac
  ln -sfn "$f" "$CURATED/$b"
done
OTG_EXTRA_PATH=""
TPATH_BASE="$STUB_BIN:$CURATED"
out="$(run_install 2>&1)"; rc=$?
TPATH_BASE="$STUB_BIN:/usr/bin:/bin"
check "install exit 0 without acl tools" "$rc" 0
case "$out" in *"acl tools are not installed"*) _ok "residual-ACL warning" ;; *) _bad "residual-ACL warning" ;; esac
case "$out" in *"reboot"*) _ok "self-heal note" ;; *) _bad "self-heal note" ;; esac
check_no_file "rule removed anyway" "$SB/root/etc/udev/rules.d/99-trackpad-guard-acl.rules"
check_contains "udev trigger still ran" "$ORDER_LOG" "udevadm trigger"

# --- 8b: omarchy-hw-touchpad missing -> touchpad steps skipped, rest completes ---------
new_sandbox "08b-no-hw-touchpad"
printf 'legacy rule\n' > "$SB/root/etc/udev/rules.d/99-trackpad-guard-acl.rules"
# the tool exists on this host, so shadow BOTH the stub and the real one:
# stub dir copy minus it, then a curated /usr/bin farm also minus it
STUBS2="$SB/stubs"
cp -r "$STUB_BIN" "$STUBS2"
rm -f "$STUBS2/omarchy-hw-touchpad"
CURATED2="$SB/bin"
mkdir -p "$CURATED2"
for f in /usr/bin/*; do
  b="${f##*/}"
  [[ "$b" == "omarchy-hw-touchpad" ]] && continue
  ln -sfn "$f" "$CURATED2/$b"
done
OTG_EXTRA_PATH=""
TPATH_BASE="$STUBS2:$CURATED2"
out="$(run_install 2>&1)"; rc=$?
OTG_EXTRA_PATH=""
TPATH_BASE="$STUB_BIN:/usr/bin:/bin"
check "install exit 0 without omarchy-hw-touchpad" "$rc" 0
case "$out" in *"omarchy-hw-touchpad not found"*) _ok "skip notice" ;; *) _bad "skip notice" ;; esac
check_no_file "rule removed" "$SB/root/etc/udev/rules.d/99-trackpad-guard-acl.rules"
check_contains "xremap node still re-triggered" "$ORDER_LOG" "--sysname-match=event19"
check_not_contains "touchpad trigger skipped" "$ORDER_LOG" "--sysname-match=event8"

# --- 9: uninstall on a clean machine is a no-op ----------------------------------------
new_sandbox "09-clean-uninstall"
out="$(run_uninstall 2>&1)"; rc=$?
check "uninstall exit 0" "$rc" 0
check_no_file "no quirks file created" "$(QUIRKS)"
check_no_file "no helper created" "$SB/home/.local/bin/omarchy-trackpad-guard"
check_not_contains "no sudo calls" "$ORDER_LOG" "sudo "
check_not_contains "no udevadm calls" "$ORDER_LOG" "udevadm "
check_not_contains "no hyprctl reload" "$SB/hyprctl.log" "reload"

# --- 10: confinement — the host /etc and udev dirs are never touched --------------------
new_sandbox "10-confinement"
host_quirks_sha="$(sha256sum /etc/libinput/local-overrides.quirks 2>/dev/null | cut -d' ' -f1)"
host_rules_listing="$(ls -1 /etc/udev/rules.d/ 2>/dev/null | sort)"
printf 'legacy rule\n' > "$SB/root/etc/udev/rules.d/99-trackpad-guard-acl.rules"
run_install >/dev/null 2>&1; rc1=$?
run_uninstall >/dev/null 2>&1; rc2=$?
check "install exit 0" "$rc1" 0
check "uninstall exit 0" "$rc2" 0
check "host quirks untouched" "$(sha256sum /etc/libinput/local-overrides.quirks 2>/dev/null | cut -d' ' -f1)" "$host_quirks_sha"
check "host rules.d untouched" "$(ls -1 /etc/udev/rules.d/ 2>/dev/null | sort)" "$host_rules_listing"

# --- summary ----------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
if (( fail > 0 )); then
  printf 'failures:\n'
  printf '  - %s\n' "${failures[@]}"
  printf '\nwork preserved under %s\n' "$WORK_ROOT"
  exit 1
fi
rm -rf "$WORK_ROOT"
exit 0
