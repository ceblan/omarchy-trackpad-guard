#!/usr/bin/env bash

set -Eeuo pipefail

TARGET_BIN="$HOME/.local/bin/omarchy-trackpad-guard"
AUTOSTART_FILE="$HOME/.config/hypr/autostart.lua"
RULE_PATH="/etc/udev/rules.d/99-keyd-virtual-keyboard-trackpad-guard.rules"
UNIT_PATH="$HOME/.config/systemd/user/omarchy-trackpad-guard.service"
MARKER_START="-- omarchy-trackpad-guard:start"
MARKER_END="-- omarchy-trackpad-guard:end"
CURRENT_USER="$(id -un)"

# Match constants for the keyd virtual keyboard. Keep in sync with
# bin/omarchy-trackpad-guard, install.sh and rules/*.rules.in —
# `make check` enforces they stay identical.
KEYBOARD_NAME="keyd virtual keyboard"
KEYBOARD_VENDOR="0fac"
KEYBOARD_PRODUCT="0ade"
KEYBOARD_BUSTYPE="0003"

if (( EUID == 0 )); then
  printf 'uninstall: run this as your normal desktop user, not as root\n' >&2
  exit 1
fi

# Stop the systemd unit first: its shutdown runs the guard's cleanup, which
# re-enables the trackpad.
systemctl --user disable --now omarchy-trackpad-guard.service 2>/dev/null || true

# Fallback for pre-systemd or manually launched instances still holding the
# flock. Only kills when the pidfile exists, the PID is numeric and
# /proc/<pid>/cmdline contains exactly $TARGET_BIN.
# Escalation is required: bash resumes the guard's blocking read after the
# first SIGTERM trap (cleanup runs but the process survives), so TERM once
# for a graceful cleanup and again once traps are cleared, with KILL as last
# resort; the evtest coproc also inherits the flock fd, so its PID (a direct
# child) must be terminated too or the lock outlives the guard.
pid_file="${XDG_RUNTIME_DIR:-/tmp}/omarchy-trackpad-guard-${UID}.pid"
if [[ -r "$pid_file" ]]; then
  guard_pid="$(<"$pid_file")"
  if [[ "$guard_pid" =~ ^[0-9]+$ ]] && [[ -r "/proc/$guard_pid/cmdline" ]] && tr '\0' '\n' < "/proc/$guard_pid/cmdline" | grep -Fxq "$TARGET_BIN"; then
    child_pids="$(pgrep -P "$guard_pid" 2>/dev/null || true)"
    kill "$guard_pid" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$guard_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$guard_pid" 2>/dev/null; then
      kill "$guard_pid" 2>/dev/null || true
      for _ in {1..20}; do
        kill -0 "$guard_pid" 2>/dev/null || break
        sleep 0.1
      done
    fi
    if kill -0 "$guard_pid" 2>/dev/null; then
      kill -KILL "$guard_pid" 2>/dev/null || true
    fi
    for child_pid in $child_pids; do
      kill "$child_pid" 2>/dev/null || true
    done
    for child_pid in $child_pids; do
      for _ in {1..10}; do
        kill -0 "$child_pid" 2>/dev/null || break
        sleep 0.1
      done
    done
    for child_pid in $child_pids; do
      if kill -0 "$child_pid" 2>/dev/null; then
        kill -KILL "$child_pid" 2>/dev/null || true
        for _ in {1..10}; do
          kill -0 "$child_pid" 2>/dev/null || break
          sleep 0.1
        done
      fi
    done
  fi
fi

# The lock should be free after the stop, with or without a pidfile: the
# evtest coproc inherits the flock fd and can outlive both the guard and its
# pidfile. Only warn here — nothing further depends on the lock.
lock_file="${XDG_RUNTIME_DIR:-/tmp}/omarchy-trackpad-guard-${UID}.lock"
if [[ -e "$lock_file" ]]; then
  for _ in {1..30}; do
    flock -n "$lock_file" -c true 2>/dev/null && break
    sleep 0.1
  done
  if ! flock -n "$lock_file" -c true 2>/dev/null; then
    printf 'uninstall: warning: a previous guard instance still holds %s; find the holder with '\''fuser %s'\''\n' "$lock_file" "$lock_file" >&2
  fi
fi

# Stop sequence complete; now remove the unit files and any timeout drop-in
# created by the shell panel's slider, so a nondefault timeout cannot leak
# into a later reinstall.
rm -f -- "$UNIT_PATH"
rm -f -- "${UNIT_PATH}.d/override.conf"
rmdir -- "${UNIT_PATH}.d" 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true

# Remove the shell bar-widget plugin (best-effort).
PLUGIN_ID="ceblan.trackpad-guard"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
if [[ -d "$PLUGIN_DIR" ]]; then
  command -v omarchy >/dev/null 2>&1 && omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
  rm -rf "$PLUGIN_DIR"
  command -v omarchy-shell >/dev/null 2>&1 && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

# Defensive: strip any leftover marked autostart block from the Apple-era
# version (a no-op on clean machines).
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
  # Only the keyd uinput node can hold our ACL; it lives under
  # /sys/devices/virtual.
  case "$input_path" in
    /sys/devices/virtual/*) ;;
    *) continue ;;
  esac
  [[ -r "$input_path/name" && -r "$input_path/id/vendor" && -r "$input_path/id/product" && -r "$input_path/id/bustype" ]] || continue
  if [[ "$(<"$input_path/name")" == "$KEYBOARD_NAME" &&
        "$(<"$input_path/id/vendor")" == "${KEYBOARD_VENDOR,,}" &&
        "$(<"$input_path/id/product")" == "${KEYBOARD_PRODUCT,,}" &&
        "$(<"$input_path/id/bustype")" == "${KEYBOARD_BUSTYPE,,}" ]]; then
    keyboard_node="/dev/input/${event_path##*/}"
    sudo setfacl -x "u:$CURRENT_USER" "$keyboard_node" 2>/dev/null || true
    # setfacl -x leaves a residual mask entry behind; drop it only when no
    # other named ACL entries remain on the node, so uninstall is traceless
    # without clobbering ACLs owned by other software.
    if ! getfacl "$keyboard_node" 2>/dev/null | grep -Eq '^(user|group):[^:]'; then
      sudo setfacl -b "$keyboard_node" 2>/dev/null || true
    fi
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

printf 'Omarchy Trackpad Guard was removed (systemd unit, udev rule, ACL and binary). The evtest and acl packages were left installed.\n'
