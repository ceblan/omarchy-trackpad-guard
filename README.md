# Omarchy Trackpad Guard

An Omarchy/Hyprland palm-rejection workaround for Apple MacBooks with very large internal trackpads.

While normal text keys are being pressed, the guard disables the trackpad. It re-enables the trackpad after one second of keyboard inactivity, so tap-to-click and physical clicking continue to work normally between typing bursts. Modifier shortcuts and navigation keys re-enable the trackpad immediately.

This is intended for Apple T2 MacBooks whose internal keyboard and trackpad both appear as `Apple Inc. Apple Internal Keyboard / Trackpad`. It dynamically discovers Linux input event numbers and the Hyprland touchpad name, so it does not hard-code `event4`, a username, or a device name from one installation.

## Install

Clone or download the repository on an Omarchy MacBook, then run:

```bash
cd omarchy-trackpad-guard
./install.sh
```

Do not run the installer with `sudo`. It asks for sudo only when installing the narrowly scoped udev rule. The installer:

1. Installs `evtest` and `acl` through `omarchy pkg add` if needed.
2. Installs the guard at `~/.local/bin/omarchy-trackpad-guard`.
3. Adds a device-specific udev rule for keyboard read access.
4. Adds a marked startup block to `~/.config/hypr/autostart.lua` after making a timestamped backup.
5. Reloads Hyprland and starts the guard for the current session.

Running `./install.sh` again safely updates the installation instead of adding duplicate startup entries.

## Adjust the delay

The default idle delay is one second. To change it, edit the marked entry in `~/.config/hypr/autostart.lua` to use `env`:

```lua
-- omarchy-trackpad-guard:start
o.launch_on_start("env TRACKPAD_GUARD_TIMEOUT=1.5 /home/your-user/.local/bin/omarchy-trackpad-guard")
-- omarchy-trackpad-guard:end
```

Then log out and back in, or stop and start the guard manually:

```bash
kill "$(<"${XDG_RUNTIME_DIR:-/tmp}/omarchy-trackpad-guard-${UID}.pid")"
uwsm-app -- env TRACKPAD_GUARD_TIMEOUT=1.5 "$HOME/.local/bin/omarchy-trackpad-guard"
```

## Uninstall

From the repository:

```bash
./uninstall.sh
```

This removes the startup entry, installed guard, udev rule, and current device ACL. It leaves `evtest` and `acl` installed because other software may use them.

## How it works

Hyprland's built-in `disable_while_typing` behavior may release a large trackpad sooner than is comfortable between words. This guard reads key events from the internal keyboard and controls only the detected Hyprland touchpad with the runtime `hl.device` API.

The trackpad is disabled only for ordinary text-key presses. It is restored:

- after the configured idle timeout;
- immediately for modifier shortcuts and navigation keys; and
- whenever the guard exits, including `SIGINT`, `SIGTERM`, logout, or a keyboard event-stream failure.

The implementation was informed by the approach discussed in [omacom/omarchy discussion #1273](https://github.com/omacom/omarchy/discussions/1273), but runs as the desktop user and does not grant passwordless sudo access to a root control script.

## Security note

Linux normally restricts raw keyboard input. The installer adds an ACL that lets the installing desktop user read only the built-in Apple keyboard event device. It distinguishes that keyboard from the identically named trackpad by requiring Apple vendor ID `05ac` and an absolute-axis capability value of zero.

Any process already running as that user can therefore read raw events from this keyboard. That is the unavoidable tradeoff for implementing this workaround in user space. The rule does not make the device world-readable and does not run the guard as root.

## Troubleshooting

Check that the guard is running:

```bash
pgrep -af omarchy-trackpad-guard
```

Check the keyboard ACL and discover which input node is in use:

```bash
for event in /sys/class/input/event*; do
  input="$(readlink -f "$event/device")"
  [[ -r "$input/name" ]] && printf '%s: %s\n' "${event##*/}" "$(<"$input/name")"
done
```

Check Hyprland configuration errors:

```bash
hyprctl configerrors
```

If your Apple keyboard has a different kernel name, run `sudo evtest`, note the exact built-in keyboard name, and override it when launching the guard:

```bash
TRACKPAD_GUARD_KEYBOARD_NAME='Exact kernel device name' ~/.local/bin/omarchy-trackpad-guard
```

The supplied udev rule will also need the same device-name adjustment before installation.

## Compatibility

- Omarchy with Lua-based Hyprland configuration
- Apple internal keyboard/trackpad devices exposed through Linux input events
- Bash 5, `evtest`, `acl`, `udev`, `uwsm-app`, and Omarchy hardware helpers

Other laptops may be adaptable, but the installer deliberately refuses broad keyboard matching.

## License

MIT
