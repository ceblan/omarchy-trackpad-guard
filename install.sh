#!/usr/bin/env bash
# omarchy-trackpad-guard installer (native-DWT design).
#
# Installs the one-shot helper and the shell panel, manages the libinput
# quirk that pairs the xremap virtual keyboard as internal (sentinel-owned;
# external equivalents are used but never adopted), and removes every
# artifact of the legacy evdev-grab daemon (unit, drop-ins, udev rule, ACLs,
# binary, pid/lock), preserving coexisting rules such as voxtype's.
#
# No packages are installed or removed; the new design needs neither evtest
# nor acl. sudo is only used for punctual writes under /etc.
#
# Test-only overrides (empty/production defaults): OTG_ROOT prefixes the
# /etc paths, OTG_SYSFS_ROOT prefixes /sys. Never set them on a real install.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OTG_ROOT="${OTG_ROOT:-}"
OTG_SYSFS_ROOT="${OTG_SYSFS_ROOT:-/sys}"

TARGET_BIN="$HOME/.local/bin/omarchy-trackpad-guard"
AUTOSTART_FILE="$HOME/.config/hypr/autostart.lua"
QUIRKS_FILE="$OTG_ROOT/etc/libinput/local-overrides.quirks"
QUIRKS_TEMPLATE="$SCRIPT_DIR/quirks/10-xremap-internal-keyboard.quirks.in"
RULES_DIR="$OTG_ROOT/etc/udev/rules.d"
RULE_PATH="$RULES_DIR/99-trackpad-guard-acl.rules"
LEGACY_RULE_PATHS=(
  "$RULES_DIR/99-keyd-virtual-keyboard-trackpad-guard.rules"
  "$RULES_DIR/99-xremap-virtual-keyboard-trackpad-guard.rules"
)
MARKER_START="-- omarchy-trackpad-guard:start"
MARKER_END="-- omarchy-trackpad-guard:end"
SENTINEL_START="# >>> omarchy-trackpad-guard (managed section; do not edit between markers)"
SENTINEL_END="# <<< omarchy-trackpad-guard"
CURRENT_USER="$(id -un)"
PLUGIN_ID="ceblan.trackpad-guard"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
UNIT_PATH="$HOME/.config/systemd/user/omarchy-trackpad-guard.service"

# Match constants for the xremap virtual keyboard (this machine's
# xremap.service convention via --vendor/--product/--output-device-name).
# Keep in sync with bin/omarchy-trackpad-guard, uninstall.sh and
# quirks/*.quirks.in — `make check` enforces they stay identical.
KEYBOARD_NAME="xremap virtual keyboard"
KEYBOARD_VENDOR="1234"
KEYBOARD_PRODUCT="9950"
KEYBOARD_BUSTYPE="0003"

SECTION_NAME="${KEYBOARD_NAME^}"
prog="install"

die() {
  printf '%s: %s\n' "$prog" "$*" >&2
  exit 1
}

note() {
  printf '%s: %s\n' "$prog" "$*"
}

# --- guards -------------------------------------------------------------------

if (( EUID == 0 )); then
  die "run this installer as your normal desktop user, not as root"
fi

[[ "$CURRENT_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "unsupported account name: $CURRENT_USER"
[[ -f "$QUIRKS_TEMPLATE" ]] || die "quirks template not found: $QUIRKS_TEMPLATE"

for hex_value in "$KEYBOARD_VENDOR" "$KEYBOARD_PRODUCT" "$KEYBOARD_BUSTYPE"; do
  [[ "${hex_value,,}" =~ ^[0-9a-f]{4}$ ]] || die "keyboard match IDs must be 4 hex digits, got: $hex_value"
done
forbidden_name_chars='[][:cntrl:]"\\|&*?[]'
if [[ -z "$KEYBOARD_NAME" || "$KEYBOARD_NAME" =~ $forbidden_name_chars ]]; then
  die "keyboard match name is empty or contains forbidden characters"
fi

for command_name in hyprctl lua luac systemctl omarchy sudo; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done

# --- node discovery (cached; reused by the reaper, ACL removal and trigger) ---

XREMAP_SYSNAME=""
XREMAP_NODE=""
TOUCHPAD_SYSNAME=""
TOUCHPAD_NODE=""

discover_nodes() {
  local event_path input_path name candidate normalized hypr_name
  for event_path in "$OTG_SYSFS_ROOT"/class/input/event*; do
    [[ -e "$event_path" ]] || continue
    input_path="$(readlink -f "$event_path/device")"
    # The xremap event source IS its uinput node: it must live under
    # /sys/devices/virtual; a physical device spoofing the IDs is rejected.
    case "$input_path" in
      "$OTG_SYSFS_ROOT"/devices/virtual/*) ;;
      *) continue ;;
    esac
    [[ -r "$input_path/name" && -r "$input_path/id/vendor" && -r "$input_path/id/product" && -r "$input_path/id/bustype" ]] || continue
    name="$(<"$input_path/name")"
    if [[ "$name" == "$KEYBOARD_NAME" &&
          "$(<"$input_path/id/vendor")" == "${KEYBOARD_VENDOR,,}" &&
          "$(<"$input_path/id/product")" == "${KEYBOARD_PRODUCT,,}" &&
          "$(<"$input_path/id/bustype")" == "${KEYBOARD_BUSTYPE,,}" ]]; then
      XREMAP_SYSNAME="${event_path##*/}"
      XREMAP_NODE="/dev/input/$XREMAP_SYSNAME"
      break
    fi
  done

  # The touchpad node only feeds legacy-ACL removal, its udev re-trigger and
  # the orphan reaper's argv validation; omarchy-hw-touchpad is optional.
  if ! command -v omarchy-hw-touchpad >/dev/null 2>&1; then
    note "note: omarchy-hw-touchpad not found; touchpad-specific legacy cleanup steps are skipped"
    return 0
  fi
  hypr_name="$(omarchy-hw-touchpad 2>/dev/null || true)"
  if [[ -z "$hypr_name" || "$hypr_name" == *[[:cntrl:]]* ]]; then
    note "note: could not resolve the Hyprland touchpad name; touchpad-specific legacy cleanup steps are skipped"
    return 0
  fi
  for event_path in "$OTG_SYSFS_ROOT"/class/input/event*; do
    [[ -e "$event_path" && -r "$event_path/device/name" ]] || continue
    candidate="$(<"$event_path/device/name")"
    normalized="${candidate,,}"
    normalized="${normalized// /-}"
    if [[ "$normalized" == "$hypr_name" ]]; then
      TOUCHPAD_SYSNAME="${event_path##*/}"
      TOUCHPAD_NODE="/dev/input/$TOUCHPAD_SYSNAME"
      break
    fi
  done
  [[ -n "$TOUCHPAD_NODE" ]] \
    || note "note: touchpad '$hypr_name' not mapped to a sysfs node; touchpad-specific legacy cleanup steps are skipped"
}

# --- legacy cleanup (§8.1) — identical copy in uninstall.sh -------------------

reap_orphan_grabbers() { # $1=lock-file — kill ONLY validated orphan holders
  local lock_file=$1 lock_real fd link pid a
  local -a holders=() validated=() unvalidated=() argv=()
  lock_real="$(readlink -f "$lock_file")"

  for fd in /proc/[0-9]*/fd/*; do
    [[ -e "$fd" ]] || continue
    link="$(readlink "$fd" 2>/dev/null)" || continue
    [[ "$link" == "$lock_real" || "$link" == "$lock_real (deleted)" ]] || continue
    pid="${fd#/proc/}"
    pid="${pid%%/*}"
    [[ "$pid" == "$$" ]] && continue
    holders+=("$pid")
  done
  (( ${#holders[@]} > 0 )) || return 0

  # dedupe
  local -A seen=()
  local -a unique_holders=()
  for pid in "${holders[@]}"; do
    [[ -n "${seen[$pid]:-}" ]] && continue
    seen[$pid]=1
    unique_holders+=("$pid")
  done

  for pid in "${unique_holders[@]}"; do
    [[ -r "/proc/$pid/cmdline" ]] || continue
    # validation 1: owned by the current user
    if [[ "$(stat -c '%u' "/proc/$pid" 2>/dev/null)" != "$UID" ]]; then
      unvalidated+=("$pid")
      continue
    fi
    # validation 2: argv is the legacy binary, or evtest pointed at exactly
    # the touchpad or xremap node discovered above. Never match by process
    # name alone (no `pkill evtest` semantics, ever).
    argv=()
    while IFS= read -r -d '' a; do argv+=("$a"); done < "/proc/$pid/cmdline"
    local ok=0 has_evtest=0 has_node=0
    for a in "${argv[@]}"; do
      if [[ "$a" == "$TARGET_BIN" ]]; then ok=1; break; fi
    done
    if (( ! ok )); then
      for a in "${argv[@]}"; do
        if [[ "$(basename -- "$a")" == "evtest" ]]; then has_evtest=1; fi
        if [[ -n "$TOUCHPAD_NODE" && "$a" == "$TOUCHPAD_NODE" ]]; then has_node=1; fi
        if [[ -n "$XREMAP_NODE" && "$a" == "$XREMAP_NODE" ]]; then has_node=1; fi
      done
      if (( has_evtest && has_node )); then ok=1; fi
    fi
    if (( ok )); then validated+=("$pid"); else unvalidated+=("$pid"); fi
  done

  if (( ${#validated[@]} > 0 )); then
    # An orphaned `evtest --grab` freezes the touchpad only while it holds
    # the grab fd; killing it closes the fd and the kernel drops the grab.
    for pid in "${validated[@]}"; do kill "$pid" 2>/dev/null || true; done
    local _i alive
    for _i in {1..20}; do
      alive=0
      for pid in "${validated[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
      (( alive == 0 )) && break
      sleep 0.1
    done
    for pid in "${validated[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    done
    note "reaped orphaned legacy grab process(es): ${validated[*]}"
  fi

  if (( ${#unvalidated[@]} > 0 )); then
    note "warning: $lock_file is also held by process(es) I cannot prove are ours: ${unvalidated[*]}"
    if command -v fuser >/dev/null 2>&1; then
      fuser -v "$lock_file" >&2 2>/dev/null || true
    fi
    note "warning: inspect them and kill them by hand if they are legacy guard leftovers"
  fi
}

cleanup_legacy() {
  # Evidence of a previous install — recorded BEFORE anything is removed, so
  # on clean machines every step below degrades to a silent no-op.
  local evidence=0
  [[ -f "$RULE_PATH" ]] && evidence=1
  local legacy_rule
  for legacy_rule in "${LEGACY_RULE_PATHS[@]}"; do
    [[ -f "$legacy_rule" ]] && evidence=1
  done
  local pid_file="${XDG_RUNTIME_DIR:-/tmp}/omarchy-trackpad-guard-${UID}.pid"
  local lock_file="${XDG_RUNTIME_DIR:-/tmp}/omarchy-trackpad-guard-${UID}.lock"
  [[ -e "$pid_file" ]] && evidence=1

  # 1. stop+disable the legacy unit (tolerant to absence)
  systemctl --user disable --now omarchy-trackpad-guard.service >/dev/null 2>&1 || true

  # 2. unit file, timeout drop-in, drop-in dir; daemon-reload
  if [[ -f "$UNIT_PATH" || -d "${UNIT_PATH}.d" ]]; then
    rm -f -- "$UNIT_PATH" "${UNIT_PATH}.d/override.conf"
    rmdir -- "${UNIT_PATH}.d" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    note "removed the legacy systemd unit and its drop-ins"
  fi

  # 3. kill legacy/manual guard instances: pidfile + exact argv match, with
  # TERM→TERM→KILL escalation and evtest children reaping (a coproc inherits
  # the lock fd and would outlive the guard).
  if [[ -r "$pid_file" ]]; then
    local guard_pid child_pids child_pid
    guard_pid="$(<"$pid_file")"
    if [[ "$guard_pid" =~ ^[0-9]+$ ]] && [[ -r "/proc/$guard_pid/cmdline" ]] \
        && tr '\0' '\n' < "/proc/$guard_pid/cmdline" | grep -Fxq "$TARGET_BIN"; then
      child_pids="$(pgrep -P "$guard_pid" 2>/dev/null || true)"
      kill "$guard_pid" 2>/dev/null || true
      for _ in {1..20}; do kill -0 "$guard_pid" 2>/dev/null || break; sleep 0.1; done
      if kill -0 "$guard_pid" 2>/dev/null; then
        kill "$guard_pid" 2>/dev/null || true
        for _ in {1..20}; do kill -0 "$guard_pid" 2>/dev/null || break; sleep 0.1; done
      fi
      if kill -0 "$guard_pid" 2>/dev/null; then
        kill -KILL "$guard_pid" 2>/dev/null || true
      fi
      for child_pid in $child_pids; do kill "$child_pid" 2>/dev/null || true; done
      for child_pid in $child_pids; do
        for _ in {1..10}; do kill -0 "$child_pid" 2>/dev/null || break; sleep 0.1; done
      done
      for child_pid in $child_pids; do
        if kill -0 "$child_pid" 2>/dev/null; then
          kill -KILL "$child_pid" 2>/dev/null || true
          for _ in {1..10}; do kill -0 "$child_pid" 2>/dev/null || break; sleep 0.1; done
        fi
      done
      note "stopped the legacy guard process (pid $guard_pid)"
    fi
  fi

  # 4a/5. node discovery (cached in XREMAP_*/TOUCHPAD_* for the reaper, the
  # ACL removal and the udev re-trigger below)
  discover_nodes

  # 4b/4c/4d. wait for the legacy flock; if it stays held, reap validated
  # orphan holders (a dead guard can leave an `evtest --grab` orphan that
  # inherited the lock fd and keeps the touchpad frozen)
  if [[ -e "$lock_file" ]]; then
    for _ in {1..30}; do
      flock -n "$lock_file" -c true 2>/dev/null && break
      sleep 0.1
    done
    if ! flock -n "$lock_file" -c true 2>/dev/null; then
      reap_orphan_grabbers "$lock_file"
    fi
  fi

  # 7. remove the old read ACLs — gated on evidence AND on the acl tools.
  # The new design does not depend on acl, so its absence never aborts: the
  # udev rule that re-applied the ACLs is deleted below and /dev is devtmpfs,
  # so leftovers self-heal at the next reboot.
  if (( evidence )); then
    if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
      local node
      for node in "$XREMAP_NODE" "$TOUCHPAD_NODE"; do
        [[ -n "$node" ]] || continue
        sudo setfacl -x "u:$CURRENT_USER" "$node" 2>/dev/null || true
        # setfacl -x leaves a residual mask; drop it only when no other named
        # ACL entries remain, so coexisting ACLs (e.g. voxtype's) survive.
        if ! getfacl "$node" 2>/dev/null | grep -Eq '^(user|group):[^:]'; then
          sudo setfacl -b "$node" 2>/dev/null || true
        fi
      done
    else
      note "warning: a previous install left read ACLs on ${XREMAP_NODE:-?} ${TOUCHPAD_NODE:-}, but the acl tools are not installed to remove them now."
      note "warning: they will NOT be re-applied (the udev rule is being removed) and vanish on their own at the next reboot (/dev is devtmpfs)."
      note "warning: to remove them now: install acl and re-run this script, or reboot."
    fi
  fi

  # 8. remove the udev rules (ours + legacy names), reload udev, then
  # re-trigger the affected nodes AFTER our rule is gone, so a coexisting
  # rule (voxtype) immediately re-applies its own ACL if the step above
  # touched it. Without evidence nothing here was ever applied; skip.
  local removed_rule=0
  if [[ -f "$RULE_PATH" ]]; then
    sudo rm -f -- "$RULE_PATH"
    removed_rule=1
    note "removed udev rule: $RULE_PATH"
  fi
  for legacy_rule in "${LEGACY_RULE_PATHS[@]}"; do
    if [[ -f "$legacy_rule" ]]; then
      sudo rm -f -- "$legacy_rule"
      removed_rule=1
      note "removed legacy udev rule: $legacy_rule"
    fi
  done
  if (( removed_rule )); then
    sudo udevadm control --reload-rules
  fi
  if (( evidence )); then
    local -a sysnames=()
    [[ -n "$XREMAP_SYSNAME" ]] && sysnames+=("$XREMAP_SYSNAME")
    [[ -n "$TOUCHPAD_SYSNAME" ]] && sysnames+=("$TOUCHPAD_SYSNAME")
    if (( ${#sysnames[@]} > 0 )); then
      local sysname
      for sysname in "${sysnames[@]}"; do
        sudo udevadm trigger --action=change --subsystem-match=input --sysname-match="$sysname" 2>/dev/null || true
      done
      sudo udevadm settle 2>/dev/null || true
    fi
    # 10. coherence without any device-toggle API: orphan grabs die with
    # their fds (step 3 + reaper), rules/ACLs are gone, and a reload re-applies
    # the file config. Best-effort: Hyprland may not be running here.
    if hyprctl -j getoption input:touchpad:tap-to-click >/dev/null 2>&1; then
      hyprctl reload >/dev/null 2>&1 || true
    fi
    note "if a pre-grab version left the touchpad dead, see 'Reviving a dead touchpad' in README.md"
  fi

  # 9. legacy binary, pidfile and lockfile
  rm -f -- "$TARGET_BIN" "$pid_file" "$lock_file"

  # 11. defensive sweep of the Apple-era autostart block (no-op when clean)
  if [[ -f "$AUTOSTART_FILE" ]] && grep -qF -- "$MARKER_START" "$AUTOSTART_FILE"; then
    local backup_path temp_autostart
    backup_path="${AUTOSTART_FILE}.bak.trackpad-guard.$(date +%s%N).$$"
    cp -a -- "$AUTOSTART_FILE" "$backup_path"
    temp_autostart="$(mktemp)"
    awk -v marker_start="$MARKER_START" -v marker_end="$MARKER_END" '
      $0 == marker_start { inside = 1; next }
      $0 == marker_end { inside = 0; next }
      inside { next }
      index($0, "o.launch_on_start(") && index($0, "omarchy-trackpad-guard") { next }
      { print }
    ' "$AUTOSTART_FILE" > "$temp_autostart"
    install -m644 "$temp_autostart" "$AUTOSTART_FILE"
    rm -f -- "$temp_autostart"
    note "removed leftover autostart block (backup: $backup_path)"
  fi

  if (( evidence )); then
    note "legacy daemon artifacts removed; your disable_while_typing / tap_to_click values in input.lua were not touched"
  fi
}

# --- quirks management (§7.2) ---------------------------------------------------

# Prints one line per ACTIVE quirks section: name, MatchName-ok, MatchV+P-ok,
# AttrKeyboardIntegration=internal-ok (tab-separated). Commented lines never
# count.
quirk_sections() { # $1=quirks-file
  awk -v want_name="$KEYBOARD_NAME" \
      -v want_vendor="0x${KEYBOARD_VENDOR}" \
      -v want_product="0x${KEYBOARD_PRODUCT}" '
    function flush() {
      if (have_section) printf "%s\t%d\t%d\t%d\n", name, mn, (mv && mp), attr
    }
    /^[ \t]*#/ { next }
    /^[ \t]*\[/ {
      flush()
      have_section = 1; mn = 0; mv = 0; mp = 0; attr = 0
      name = $0
      sub(/^[ \t]*\[/, "", name); sub(/\][ \t]*$/, "", name)
      next
    }
    have_section && /^[ \t]*[A-Za-z]/ {
      k = $0; sub(/[ \t]*=.*/, "", k)
      v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]*$/, "", v)
      if (k == "MatchName" && v == want_name) mn = 1
      if (k == "MatchVendor" && tolower(v) == tolower(want_vendor)) mv = 1
      if (k == "MatchProduct" && tolower(v) == tolower(want_product)) mp = 1
      if (k == "AttrKeyboardIntegration" && v == "internal") attr = 1
    }
    END { flush() }
  ' "$1"
}

# managed | external | conflict | absent
quirk_status() { # $1=quirks-file
  local file=$1
  [[ -f "$file" ]] || { printf 'absent'; return; }
  if grep -qF -- "$SENTINEL_START" "$file"; then printf 'managed'; return; fi
  local external=0 conflict=0 name mn mvp attr
  while IFS=$'\t' read -r name mn mvp attr; do
    if [[ "$attr" == "1" && ( "$mn" == "1" || "$mvp" == "1" ) ]]; then
      external=1
    elif [[ "$name" == "$SECTION_NAME" ]]; then
      conflict=1
    elif [[ "$mn" == "1" || "$mvp" == "1" ]]; then
      conflict=1
    fi
  done < <(quirk_sections "$file")
  if (( external )); then printf 'external'
  elif (( conflict )); then printf 'conflict'
  else printf 'absent'; fi
}

# The exact block between (and including) the sentinels.
extract_managed() { # $1=quirks-file
  awk -v ss="$SENTINEL_START" -v se="$SENTINEL_END" '
    $0 == ss { inside = 1; print; next }
    $0 == se { inside = 0; print; next }
    inside { print }
  ' "$1"
}

check_sentinel_sanity() { # $1=quirks-file
  local file=$1 ns ne first_start first_end
  ns="$(grep -cF -- "$SENTINEL_START" "$file")"
  ne="$(grep -cF -- "$SENTINEL_END" "$file")"
  if [[ "$ns" != "1" || "$ne" != "1" ]]; then
    die "malformed omarchy-trackpad-guard sentinels in $file ($ns start, $ne end); fix the file manually"
  fi
  first_start="$(grep -nF -- "$SENTINEL_START" "$file" | head -n1 | cut -d: -f1)"
  first_end="$(grep -nF -- "$SENTINEL_END" "$file" | head -n1 | cut -d: -f1)"
  if (( first_start >= first_end )); then
    die "misordered omarchy-trackpad-guard sentinels in $file; fix the file manually"
  fi
}

# The exact header install.sh writes when it creates the quirks file
# (identical copy in uninstall.sh; uninstall deletes the file only when the
# post-strip remainder is exactly this — user comments count as foreign
# content and always keep the file).
created_by_us_header() {
  printf '# Local libinput quirks overrides.\n'
  printf '# Created by omarchy-trackpad-guard: the section between its sentinels is\n'
  printf '# managed by the plugin; uninstall removes just that section (and this\n'
  printf '# file if nothing else remains).\n\n'
}

render_quirk_template() { # $1=dest
  sed -e "s|@XREMAP_NAME@|$KEYBOARD_NAME|g" \
      -e "s|@XREMAP_VENDOR@|$KEYBOARD_VENDOR|g" \
      -e "s|@XREMAP_PRODUCT@|$KEYBOARD_PRODUCT|g" \
      "$QUIRKS_TEMPLATE" > "$1"
}

backup_quirks() {
  [[ -f "$QUIRKS_FILE" ]] || return 0
  local backup="$QUIRKS_FILE.bak.trackpad-guard.$(date +%s%N).$$"
  sudo cp -a -- "$QUIRKS_FILE" "$backup"
  note "quirks backup: $backup"
}

relogin_notice() {
  note "the libinput quirk loads when the session starts: log out and back in for DWT pairing to take effect"
}

manage_quirk() {
  # No remap stack: the internal keyboard pairs natively; nothing to do.
  if [[ -z "$XREMAP_NODE" ]]; then
    note "no xremap virtual keyboard detected; skipping the libinput quirk (native pairing without a remap stack)"
    return 0
  fi

  local rendered status
  rendered="$(mktemp)"
  render_quirk_template "$rendered"

  status="$(quirk_status "$QUIRKS_FILE")"
  case "$status" in
    managed)
      check_sentinel_sanity "$QUIRKS_FILE"
      local rendered_block
      rendered_block="$(mktemp)"
      extract_managed "$rendered" > "$rendered_block"
      if diff <(extract_managed "$QUIRKS_FILE") "$rendered_block" >/dev/null 2>&1; then
        note "managed quirk section already up to date"
      else
        backup_quirks
        local new_content
        new_content="$(mktemp)"
        awk -v ss="$SENTINEL_START" -v se="$SENTINEL_END" -v block_file="$rendered_block" '
          $0 == ss {
            while ((getline line < block_file) > 0) print line
            inside = 1
            next
          }
          $0 == se { inside = 0; next }
          inside { next }
          { print }
        ' "$QUIRKS_FILE" > "$new_content"
        sudo install -m644 "$new_content" "$QUIRKS_FILE"
        rm -f -- "$new_content"
        note "managed quirk section updated in $QUIRKS_FILE"
        relogin_notice
      fi
      rm -f -- "$rendered_block"
      ;;
    external)
      note "external equivalent quirk found in $QUIRKS_FILE; using it and leaving it unmanaged (install/uninstall never touch it)"
      ;;
    conflict)
      printf '%s: CONFLICT: %s already has a section named [%s] (or one matching this keyboard) without the expected content.\n' "$prog" "$QUIRKS_FILE" "$SECTION_NAME" >&2
      printf '%s: refusing to overwrite it or to duplicate the section name. Reconcile it manually (merge the keys into it, or remove it and re-run ./install.sh).\n' "$prog" >&2
      printf '%s: conflicting file follows:\n' "$prog" >&2
      sed 's/^/  /' "$QUIRKS_FILE" >&2
      rm -f -- "$rendered"
      exit 1
      ;;
    absent)
      backup_quirks
      # Only the sentinel block is ever written to the file; the template's
      # preamble comments are developer documentation, not runtime content.
      local new_content block
      block="$(mktemp)"
      extract_managed "$rendered" > "$block"
      new_content="$(mktemp)"
      if [[ -f "$QUIRKS_FILE" ]]; then
        cat "$QUIRKS_FILE" > "$new_content"
        if [[ -s "$QUIRKS_FILE" ]] && [[ "$(tail -c1 "$QUIRKS_FILE" | wc -l)" -eq 0 ]]; then
          printf '\n' >> "$new_content"
        fi
        printf '\n' >> "$new_content"
        cat "$block" >> "$new_content"
        sudo install -m644 "$new_content" "$QUIRKS_FILE"
        note "managed quirk section appended to $QUIRKS_FILE"
      else
        {
          created_by_us_header
          cat "$block"
        } > "$new_content"
        sudo install -Dm644 "$new_content" "$QUIRKS_FILE"
        note "created $QUIRKS_FILE with the managed quirk section"
      fi
      rm -f -- "$new_content" "$block"
      relogin_notice
      ;;
  esac
  rm -f -- "$rendered"
}

# --- install --------------------------------------------------------------------

cleanup_legacy

install -Dm755 "$SCRIPT_DIR/bin/omarchy-trackpad-guard" "$TARGET_BIN"
note "installed helper: $TARGET_BIN"

manage_quirk

# Shell bar-widget plugin (bar icon + control panel). Best-effort.
if [[ -f "$SCRIPT_DIR/shell-plugin/manifest.json" ]] && command -v omarchy-shell >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/omarchy/plugins"
  rm -rf "$PLUGIN_DIR"
  cp -a "$SCRIPT_DIR/shell-plugin" "$PLUGIN_DIR"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 \
    || note "note: could not enable the shell plugin; run: omarchy plugin enable $PLUGIN_ID"
fi

# Final diagnostics: informational — an external quirk or a pending relogin
# is not a failure.
"$TARGET_BIN" doctor || true

printf '\nInstalled Omarchy Trackpad Guard (native-DWT design).\n'
printf '  Helper: %s\n' "$TARGET_BIN"
printf '  Panel:  %s (bar icon)\n' "$PLUGIN_DIR"
printf '  Quirk:  %s\n' "$QUIRKS_FILE"
printf 'The trackpad is protected by libinput'\''s native disable-while-typing; the panel toggles it and tap-to-click.\n'
printf 'The timeout slider no longer exists: Hyprland 0.56 does not expose a DWT timeout option.\n'
