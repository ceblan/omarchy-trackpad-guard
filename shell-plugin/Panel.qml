import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar icon + control panel for omarchy-trackpad-guard. The icon shows the
// daemon state; clicking it opens a popup with the daemon on/off switch, the
// Hyprland tap-to-click switch and the typing-idle timeout slider (0.5-3 s).
Panel {
  id: root

  moduleName: "ceblan.trackpad-guard"
  ipcTarget: "ceblan.trackpad-guard"

  // nf-md-trackpad glyph (U+F07F8) as a surrogate pair, so the source
  // survives editors that mangle private-use codepoints.
  readonly property string trackpadGlyph: "\uDB81\uDFF8"
  readonly property string unitName: "omarchy-trackpad-guard.service"
  readonly property string overridePath: ".config/systemd/user/omarchy-trackpad-guard.service.d/override.conf"

  property bool guardActive: false
  property bool tapToClick: false
  property real timeoutSeconds: 1.0
  property bool stateLoaded: false

  // The bar sizes widgets from the root's implicit size; the anchored icon
  // button does not contribute one, so expose its dimensions explicitly.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: root.refresh()

  onOpenedChanged: if (opened) root.refresh()

  function refresh() {
    if (!stateProc.running)
      stateProc.running = true
  }

  Process {
    id: stateProc
    command: ["bash", "-c",
      "state=$(systemctl --user is-active " + root.unitName + " 2>/dev/null); " +
      "tap=$(hyprctl getoption input:touchpad:tap-to-click 2>/dev/null | grep -oP '^bool: \\K\\w+' | head -n1); " +
      "to=$(grep -oP 'TRACKPAD_GUARD_TIMEOUT=\\K[0-9.]+' \"$HOME/" + root.overridePath + "\" 2>/dev/null | head -n1); " +
      "printf 'guard=%s\\ntap=%s\\ntimeout=%s\\n' \"${state:-inactive}\" \"${tap:-false}\" \"${to:-1.0}\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var kv = lines[i].split("=")
          if (kv.length !== 2)
            continue
          if (kv[0] === "guard")
            root.guardActive = kv[1] === "active"
          else if (kv[0] === "tap")
            root.tapToClick = kv[1] === "true" || kv[1] === "1"
          else if (kv[0] === "timeout") {
            var v = parseFloat(kv[1])
            if (!isNaN(v))
              root.timeoutSeconds = Math.min(3.0, Math.max(0.5, v))
          }
        }
        root.stateLoaded = true
      }
    }
  }

  // Applies run through a Process and state is refreshed when the command
  // COMPLETES — never on a fixed timer, which can read stale state (e.g.
  // before `hyprctl reload` finishes) and bounce the switches back.
  Process {
    id: applyProc
    onExited: root.refresh()
  }

  // argv must be fully built before calling this.
  function apply(argv) {
    if (applyProc.running)
      return
    applyProc.command = argv
    applyProc.running = true
  }

  function setGuard(on) {
    guardActive = on
    apply(["systemctl", "--user", on ? "start" : "stop", root.unitName])
  }

  // tap-to-click lives in ~/.config/hypr/input.lua (Lua parser: hyprctl
  // keyword is refused, and getoption only reflects config after a reload),
  // so the toggle edits the value there and reloads Hyprland: runtime effect,
  // persistence and getoption read-back in one step.
  function setTap(on) {
    tapToClick = on
    var val = on ? "true" : "false"
    apply(["bash", "-c",
      "sed -i -E 's/^(\\s*tap_to_click\\s*=\\s*)(true|false)/\\1" + val + "/' \"$HOME/.config/hypr/input.lua\" && hyprctl reload >/dev/null 2>&1"])
  }

  // Commit the slider: write the systemd drop-in and reload the manager.
  // Restart only when the unit is active, so a stopped guard stays stopped.
  function applyTimeout(v) {
    var val = v.toFixed(1)
    if (val === timeoutSeconds.toFixed(1))
      return
    timeoutSeconds = parseFloat(val)
    apply(["bash", "-c",
      "d=\"$HOME/.config/systemd/user/omarchy-trackpad-guard.service.d\"; " +
      "mkdir -p \"$d\" && printf '[Service]\\nEnvironment=TRACKPAD_GUARD_TIMEOUT=%s\\n' '" + val + "' > \"$d/override.conf\" && " +
      "systemctl --user daemon-reload && " +
      "if systemctl --user is-active --quiet " + root.unitName + "; then systemctl --user restart " + root.unitName + "; fi"])
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.trackpadGlyph
    dimmed: !root.guardActive
    tooltipText: root.guardActive
      ? "Trackpad Guard · " + root.timeoutSeconds.toFixed(1) + " s"
      : "Trackpad Guard · off"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: panelColumn
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(14)

        // Hero: glyph, title + state line, daemon toggle on the right.
        Item {
          width: parent.width
          height: Math.max(heroGlyph.implicitHeight, heroText.implicitHeight, daemonToggle.trackHeight)

          Text {
            id: heroGlyph
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.trackpadGlyph
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            color: Color.popups.text
            opacity: root.guardActive ? 1.0 : 0.4
          }

          Column {
            id: heroText
            anchors.left: heroGlyph.right
            anchors.leftMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Trackpad Guard"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              text: (root.guardActive ? "DAEMON ON" : "DAEMON OFF") + " · " + timeoutSlider.liveValue.toFixed(1) + " S"
              color: Color.popups.text
              opacity: 0.6
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          ToggleSwitch {
            id: daemonToggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.guardActive
            busy: applyProc.running
            onToggled: root.setGuard(!root.guardActive)

            PanelToolTip {
              visible: daemonToggle.containsMouse
              text: "Start/stop the guard daemon"
            }
          }
        }

        PanelSeparator { width: parent.width }

        // Tap-to-click row.
        Item {
          width: parent.width
          height: Math.max(tapLabel.implicitHeight, tapToggle.trackHeight)

          Text {
            id: tapLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "TAP TO CLICK"
            color: Color.popups.text
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          ToggleSwitch {
            id: tapToggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.tapToClick
            busy: applyProc.running
            onToggled: root.setTap(!root.tapToClick)

            PanelToolTip {
              visible: tapToggle.containsMouse
              text: "Hyprland tap-to-click on the internal touchpad"
            }
          }
        }

        PanelSeparator { width: parent.width }

        // Timeout slider.
        Item {
          width: parent.width
          height: timeoutHeader.implicitHeight

          Text {
            id: timeoutHeader
            anchors.left: parent.left
            text: "TIMEOUT AFTER KEYPRESS"
            color: Color.popups.text
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.right: parent.right
            text: timeoutSlider.liveValue.toFixed(1) + " s"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSlider {
          id: timeoutSlider
          width: parent.width
          bar: root.bar
          minimum: 0.5
          maximum: 3.0
          step: 0.1
          value: root.timeoutSeconds
          onReleased: function(v) { root.applyTimeout(v) }
        }
      }
    }
  }
}
