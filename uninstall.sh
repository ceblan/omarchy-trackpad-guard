#!/usr/bin/env bash

set -Eeuo pipefail

TARGET_BIN="$HOME/.local/bin/omarchy-trackpad-guard"
AUTOSTART_FILE="$HOME/.config/hypr/autostart.lua"
RULE_PATH="/etc/udev/rules.d/99-apple-internal-keyboard-trackpad-guard.rules"
MARKER_START="-- omarchy-trackpad-guard:start"
MARKER_END="-- omarchy-trackpad-guard:end"
CURRENT_USER="$(id -un)"

if (( EUID == 0 )); then
  printf 'uninstall: run this as your normal desktop user, not as root\n' >&2
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

if [[ -f "$AUTOSTART_FILE" ]]; then
  temp_autostart="$(mktemp)"
  trap 'rm -f -- "$temp_autostart"' EXIT
  awk -v marker_start="$MARKER_START" -v marker_end="$MARKER_END" '
    $0 == marker_start { inside = 1; next }
    $0 == marker_end { inside = 0; next }
    inside { next }
    index($0, "o.launch_on_start(") && index($0, "omarchy-trackpad-guard") { next }
    { print }
  ' "$AUTOSTART_FILE" > "$temp_autostart"
  install -m644 "$temp_autostart" "$AUTOSTART_FILE"
fi

for event_path in /sys/class/input/event*; do
  [[ -e "$event_path" ]] || continue
  input_path="$(readlink -f "$event_path/device")"
  [[ -r "$input_path/name" && -r "$input_path/id/vendor" && -r "$input_path/capabilities/abs" ]] || continue
  if [[ "$(<"$input_path/name")" == "Apple Inc. Apple Internal Keyboard / Trackpad" &&
        "$(<"$input_path/id/vendor")" == "05ac" &&
        "$(<"$input_path/capabilities/abs")" == "0" ]]; then
    sudo setfacl -x "u:$CURRENT_USER" "/dev/input/${event_path##*/}" 2>/dev/null || true
  fi
done

sudo rm -f -- "$RULE_PATH"
sudo udevadm control --reload-rules
rm -f -- "$TARGET_BIN"
rm -f -- "$pid_file" "${XDG_RUNTIME_DIR:-/tmp}/omarchy-trackpad-guard-${UID}.lock"

trackpad_name="$(omarchy-hw-touchpad 2>/dev/null || true)"
if [[ -n "$trackpad_name" && "$trackpad_name" != *[[:cntrl:]]* ]]; then
  quoted_name="${trackpad_name//\\/\\\\}"
  quoted_name="${quoted_name//\"/\\\"}"
  hyprctl eval "hl.device({ name = \"$quoted_name\", enabled = true })" >/dev/null 2>&1 || true
fi

hyprctl reload >/dev/null 2>&1 || true
printf 'Omarchy Trackpad Guard was removed. The evtest and acl packages were left installed.\n'
