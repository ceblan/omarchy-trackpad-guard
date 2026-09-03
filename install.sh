#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_BIN="$HOME/.local/bin/omarchy-trackpad-guard"
AUTOSTART_FILE="$HOME/.config/hypr/autostart.lua"
RULE_TEMPLATE="$SCRIPT_DIR/rules/99-trackpad-guard-acl.rules.in"
RULE_PATH="/etc/udev/rules.d/99-trackpad-guard-acl.rules"
MARKER_START="-- omarchy-trackpad-guard:start"
MARKER_END="-- omarchy-trackpad-guard:end"
CURRENT_USER="$(id -un)"

# Match constants for the xremap virtual keyboard. Keep in sync with
# bin/omarchy-trackpad-guard, uninstall.sh and rules/*.rules.in —
# `make check` enforces they stay identical.
KEYBOARD_NAME="xremap virtual keyboard"
KEYBOARD_VENDOR="1234"
KEYBOARD_PRODUCT="9950"
KEYBOARD_BUSTYPE="0003"

die() {
  printf 'install: %s\n' "$*" >&2
  exit 1
}

if (( EUID == 0 )); then
  die "run this installer as your normal desktop user, not as root"
fi

[[ "$CURRENT_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "unsupported account name: $CURRENT_USER"
[[ -f "$RULE_TEMPLATE" ]] || die "udev rule template not found"

# Refuse malformed match constants before they reach the udev rule: udev
# treats *, ? and [...] as match globs (a wildcard would widen the ACL beyond
# one exact node), quotes/control characters would corrupt the rule syntax
# parsed by root-udevd, and |, & and \ would break the sed rendering below.
for hex_value in "$KEYBOARD_VENDOR" "$KEYBOARD_PRODUCT" "$KEYBOARD_BUSTYPE"; do
  [[ "${hex_value,,}" =~ ^[0-9a-f]{4}$ ]] || die "keyboard match IDs must be 4 hex digits, got: $hex_value"
done
forbidden_name_chars='[][:cntrl:]"\\|&*?[]'
if [[ -z "$KEYBOARD_NAME" || "$KEYBOARD_NAME" =~ $forbidden_name_chars ]]; then
  die "keyboard match name is empty or contains forbidden characters"
fi

for command_name in omarchy sudo udevadm omarchy-hw-touchpad systemctl pgrep flock; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done

# xremap is a hard dependency in practice — without its virtual keyboard
# there is no readable keyboard node — but the discovery loop below already
# dies when the node is absent, so here we only warn: the source of truth is
# "the node exists and is readable", not the service name. This also keeps
# the installer working on stack variants (e.g. xremap launched differently).
if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet xremap; then
  printf 'install: warning: xremap.service is not active; the xremap virtual keyboard may not exist\n' >&2
fi

# Resolve the touchpad's sysfs input name for the second udev rule: the
# guard holds an exclusive evdev grab on this node while typing, so the
# ACL must land on exactly this interface. omarchy-hw-touchpad prints the
# Hyprland name (the sysfs name lowercased, spaces as dashes); the rule
# matches the raw sysfs name.
touchpad_hypr_name="$(omarchy-hw-touchpad)" || die "could not identify the Hyprland touchpad"
[[ -n "$touchpad_hypr_name" && "$touchpad_hypr_name" != *[[:cntrl:]]* ]] || die "unsafe Hyprland touchpad name: $touchpad_hypr_name"
touchpad_sysfs_name=""
touchpad_sysname=""
for event_path in /sys/class/input/event*; do
  [[ -e "$event_path" && -r "$event_path/device/name" ]] || continue
  candidate="$(<"$event_path/device/name")"
  normalized="${candidate,,}"
  normalized="${normalized// /-}"
  if [[ "$normalized" == "$touchpad_hypr_name" ]]; then
    touchpad_sysfs_name="$candidate"
    touchpad_sysname="${event_path##*/}"
    break
  fi
done
[[ -n "$touchpad_sysfs_name" ]] || die "could not map Hyprland touchpad '$touchpad_hypr_name' to a sysfs input node"
# The name lands verbatim inside ATTRS{name}=="..."; reject characters that
# udev would treat as match globs or that would corrupt the rule/sed syntax.
if [[ "$touchpad_sysfs_name" =~ $forbidden_name_chars ]]; then
  die "touchpad sysfs name contains forbidden characters: $touchpad_sysfs_name"
fi

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

sed -e "s|@SETFACL@|$SETFACL_PATH|g" -e "s|@USER@|$CURRENT_USER|g" -e "s|@TOUCHPAD_NAME@|$touchpad_sysfs_name|g" "$RULE_TEMPLATE" > "$temp_rule"
sudo install -Dm644 "$temp_rule" "$RULE_PATH"

# Defensive migration from previous versions: remove legacy rule names if a
# previous install left them behind (no-ops on clean machines). The keyd-era
# rule would keep an ACL on a node that no longer exists; the intermediate
# xremap-only rule predates the touchpad ACL and is superseded by RULE_PATH.
for legacy_rule in \
  /etc/udev/rules.d/99-keyd-virtual-keyboard-trackpad-guard.rules \
  /etc/udev/rules.d/99-xremap-virtual-keyboard-trackpad-guard.rules; do
  if [[ -f "$legacy_rule" ]]; then
    sudo rm -f -- "$legacy_rule"
    printf 'Removed legacy udev rule: %s\n' "$legacy_rule"
  fi
done

sudo udevadm control --reload-rules

keyboard_sysname=""
for event_path in /sys/class/input/event*; do
  [[ -e "$event_path" ]] || continue
  input_path="$(readlink -f "$event_path/device")"
  # The event source IS xremap's uinput node: it must live under
  # /sys/devices/virtual. A physical device spoofing these IDs is rejected.
  case "$input_path" in
    /sys/devices/virtual/*) ;;
    *) continue ;;
  esac
  [[ -r "$input_path/name" && -r "$input_path/id/vendor" && -r "$input_path/id/product" && -r "$input_path/id/bustype" ]] || continue
  if [[ "$(<"$input_path/name")" == "$KEYBOARD_NAME" &&
        "$(<"$input_path/id/vendor")" == "${KEYBOARD_VENDOR,,}" &&
        "$(<"$input_path/id/product")" == "${KEYBOARD_PRODUCT,,}" &&
        "$(<"$input_path/id/bustype")" == "${KEYBOARD_BUSTYPE,,}" ]]; then
    keyboard_sysname="${event_path##*/}"
    break
  fi
done

[[ -n "$keyboard_sysname" ]] || die "could not find the xremap virtual keyboard event device (is xremap running?)"
sudo udevadm trigger --action=change --subsystem-match=input --sysname-match="$keyboard_sysname"

# Do not rely on the guard's retry loop for the RUN+=setfacl race: wait for
# the udev queue and fail the install explicitly if the ACL did not land.
sudo udevadm settle
keyboard_node="/dev/input/$keyboard_sysname"
if ! getfacl "$keyboard_node" 2>/dev/null | grep -Fxq "user:$CURRENT_USER:r--"; then
  die "udev rule did not grant read access on $keyboard_node; inspect $RULE_PATH"
fi

# Same trigger+verify for the touchpad rule: without this ACL the guard
# cannot grab the node and every grab attempt would warn and skip.
sudo udevadm trigger --action=change --subsystem-match=input --sysname-match="$touchpad_sysname"
sudo udevadm settle
touchpad_node="/dev/input/$touchpad_sysname"
if ! getfacl "$touchpad_node" 2>/dev/null | grep -Fxq "user:$CURRENT_USER:r--"; then
  die "udev rule did not grant read access on $touchpad_node; inspect $RULE_PATH"
fi

# Defensive migration from the Apple-era version: strip any leftover marked
# autostart block (a no-op on clean machines; the file itself may not exist).
if [[ -f "$AUTOSTART_FILE" ]] && grep -qF -- "$MARKER_START" "$AUTOSTART_FILE"; then
  backup_path="${AUTOSTART_FILE}.bak.trackpad-guard.$(date +%Y%m%d%H%M%S)"
  cp -a -- "$AUTOSTART_FILE" "$backup_path"
  awk -v marker_start="$MARKER_START" -v marker_end="$MARKER_END" '
    $0 == marker_start { inside = 1; next }
    $0 == marker_end { inside = 0; next }
    inside { next }
    index($0, "o.launch_on_start(") && index($0, "omarchy-trackpad-guard") { next }
    { print }
  ' "$AUTOSTART_FILE" > "$temp_autostart"
  install -m644 "$temp_autostart" "$AUTOSTART_FILE"
  printf 'Removed leftover autostart block (backup: %s)\n' "$backup_path"
fi

# Stop a live legacy/manual guard before starting the unit: it holds the
# flock, and without this the new service would exit 0 ("another instance is
# already running") and Restart=on-failure would not bring it back. Only
# kills when the pidfile exists, the PID is numeric and /proc/<pid>/cmdline
# contains exactly $TARGET_BIN.
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

# The lock must be free before the unit starts, with or without a pidfile:
# the evtest coproc inherits the flock fd and can outlive both the guard and
# its pidfile, and starting the unit with the lock held would make the new
# guard exit 0 ("another instance is already running") and stay down silently.
lock_file="${XDG_RUNTIME_DIR:-/tmp}/omarchy-trackpad-guard-${UID}.lock"
if [[ -e "$lock_file" ]]; then
  for _ in {1..30}; do
    flock -n "$lock_file" -c true 2>/dev/null && break
    sleep 0.1
  done
  if ! flock -n "$lock_file" -c true 2>/dev/null; then
    die "a previous guard instance still holds $lock_file; find the holder with 'fuser $lock_file', kill it, and re-run ./install.sh"
  fi
fi

install -Dm644 "$SCRIPT_DIR/systemd/omarchy-trackpad-guard.service" "$HOME/.config/systemd/user/omarchy-trackpad-guard.service"
systemctl --user daemon-reload
systemctl --user enable omarchy-trackpad-guard.service
systemctl --user restart omarchy-trackpad-guard.service

# Shell bar-widget plugin (bar icon + control panel). User-level and
# best-effort: the guard above is the critical part.
PLUGIN_ID="ceblan.trackpad-guard"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
if [[ -f "$SCRIPT_DIR/shell-plugin/manifest.json" ]] && command -v omarchy-shell >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/omarchy/plugins"
  rm -rf "$PLUGIN_DIR"
  cp -a "$SCRIPT_DIR/shell-plugin" "$PLUGIN_DIR"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 \
    || printf 'install: note: could not enable the shell plugin; run: omarchy plugin enable %s\n' "$PLUGIN_ID"
fi

printf '\nInstalled Omarchy Trackpad Guard.\n'
printf '  Guard:  %s\n' "$TARGET_BIN"
printf '  Rule:   %s\n' "$RULE_PATH"
printf '  Unit:   %s\n' "$HOME/.config/systemd/user/omarchy-trackpad-guard.service"
printf '  Panel:  %s (bar icon)\n' "$PLUGIN_DIR"
printf 'The trackpad is now grabbed (frozen) while you type and released after 1 second of idle.\n'
printf 'Check it with: systemctl --user status omarchy-trackpad-guard\n'
