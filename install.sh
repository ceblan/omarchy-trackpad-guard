#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_BIN="$HOME/.local/bin/omarchy-trackpad-guard"
AUTOSTART_FILE="$HOME/.config/hypr/autostart.lua"
RULE_TEMPLATE="$SCRIPT_DIR/rules/99-apple-internal-keyboard-trackpad-guard.rules.in"
RULE_PATH="/etc/udev/rules.d/99-apple-internal-keyboard-trackpad-guard.rules"
MARKER_START="-- omarchy-trackpad-guard:start"
MARKER_END="-- omarchy-trackpad-guard:end"
CURRENT_USER="$(id -un)"

die() {
  printf 'install: %s\n' "$*" >&2
  exit 1
}

if (( EUID == 0 )); then
  die "run this installer as your normal desktop user, not as root"
fi

[[ "$CURRENT_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "unsupported account name: $CURRENT_USER"
[[ -f "$AUTOSTART_FILE" ]] || die "Omarchy Hyprland autostart file not found: $AUTOSTART_FILE"
[[ -f "$RULE_TEMPLATE" ]] || die "udev rule template not found"

for command_name in omarchy sudo udevadm hyprctl omarchy-hw-touchpad uwsm-app; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done

if ! command -v evtest >/dev/null 2>&1; then
  printf 'Installing evtest through Omarchy...\n'
  omarchy pkg add evtest
fi

if ! command -v setfacl >/dev/null 2>&1; then
  printf 'Installing acl through Omarchy...\n'
  omarchy pkg add acl
fi

SETFACL_PATH="$(command -v setfacl)"
[[ "$SETFACL_PATH" == /* ]] || die "could not resolve setfacl to an absolute path"

install -Dm755 "$SCRIPT_DIR/bin/omarchy-trackpad-guard" "$TARGET_BIN"

temp_rule="$(mktemp)"
temp_autostart="$(mktemp)"
cleanup() {
  rm -f -- "$temp_rule" "$temp_autostart"
}
trap cleanup EXIT

sed -e "s|@SETFACL@|$SETFACL_PATH|g" -e "s|@USER@|$CURRENT_USER|g" "$RULE_TEMPLATE" > "$temp_rule"
sudo install -Dm644 "$temp_rule" "$RULE_PATH"
sudo udevadm control --reload-rules

keyboard_sysname=""
for event_path in /sys/class/input/event*; do
  [[ -e "$event_path" ]] || continue
  input_path="$(readlink -f "$event_path/device")"
  [[ -r "$input_path/name" && -r "$input_path/id/vendor" && -r "$input_path/capabilities/abs" ]] || continue
  if [[ "$(<"$input_path/name")" == "Apple Inc. Apple Internal Keyboard / Trackpad" &&
        "$(<"$input_path/id/vendor")" == "05ac" &&
        "$(<"$input_path/capabilities/abs")" == "0" ]]; then
    keyboard_sysname="${event_path##*/}"
    break
  fi
done

[[ -n "$keyboard_sysname" ]] || die "could not find the built-in Apple keyboard event device"
sudo udevadm trigger --action=change --subsystem-match=input --sysname-match="$keyboard_sysname"

backup_path="${AUTOSTART_FILE}.bak.trackpad-guard.$(date +%Y%m%d%H%M%S)"
cp -a -- "$AUTOSTART_FILE" "$backup_path"

awk -v marker_start="$MARKER_START" -v marker_end="$MARKER_END" '
  $0 == marker_start { inside = 1; next }
  $0 == marker_end { inside = 0; next }
  inside { next }
  index($0, "o.launch_on_start(") && index($0, "omarchy-trackpad-guard") { next }
  { print }
' "$AUTOSTART_FILE" > "$temp_autostart"

escaped_target="${TARGET_BIN//\\/\\\\}"
escaped_target="${escaped_target//\"/\\\"}"
{
  printf '\n%s\n' "$MARKER_START"
  printf '%s\n' '-- Disable the MacBook trackpad while typing; re-enable it after 1 second.'
  printf 'o.launch_on_start("%s")\n' "$escaped_target"
  printf '%s\n' "$MARKER_END"
} >> "$temp_autostart"
install -m644 "$temp_autostart" "$AUTOSTART_FILE"

hyprctl reload >/dev/null
config_errors="$(hyprctl configerrors)"
if [[ -n "$config_errors" ]]; then
  printf 'Hyprland reported configuration errors:\n%s\n' "$config_errors" >&2
  exit 1
fi

pid_file="${XDG_RUNTIME_DIR:-/tmp}/omarchy-trackpad-guard-${UID}.pid"
if [[ -r "$pid_file" ]]; then
  guard_pid="$(<"$pid_file")"
  if [[ "$guard_pid" =~ ^[0-9]+$ ]] && [[ -r "/proc/$guard_pid/cmdline" ]] && tr '\0' '\n' < "/proc/$guard_pid/cmdline" | grep -Fxq "$TARGET_BIN"; then
    kill "$guard_pid" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$guard_pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
fi
uwsm-app -- "$TARGET_BIN" >/dev/null 2>&1 &
disown

printf '\nInstalled Omarchy Trackpad Guard.\n'
printf '  Guard:  %s\n' "$TARGET_BIN"
printf '  Rule:   %s\n' "$RULE_PATH"
printf '  Backup: %s\n' "$backup_path"
printf 'The trackpad now stays disabled until typing has been idle for 1 second.\n'
