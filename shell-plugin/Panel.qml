import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar icon + control panel for omarchy-trackpad-guard 2.0 (native-DWT design).
// No daemon: both switches call the one-shot helper, which edits
// ~/.config/hypr/input.lua structurally, reloads Hyprland and verifies with
// getoption. The switches track the EFFECTIVE Hyprland value; when the file
// disagrees (edited outside, no reload yet) a caption shows the divergence.
Panel {
  id: root

  moduleName: "ceblan.trackpad-guard"
  ipcTarget: "ceblan.trackpad-guard"

  // nf-md-trackpad glyph (U+F07F8) as a surrogate pair, so the source
  // survives editors that mangle private-use codepoints.
  readonly property string trackpadGlyph: "\uDB81\uDFF8"
  readonly property string helperPath: Quickshell.env("HOME") + "/.local/bin/omarchy-trackpad-guard"
  readonly property string inputLuaPath: Quickshell.env("HOME") + "/.config/hypr/input.lua"

  property bool dwtEnabled: false
  property bool tapToClick: false
  // File-side values: bool when the key is explicit, null when absent /
  // ambiguous / unreadable (the helper reports a non-boolean state then).
  property var dwtFile: null
  property var tapFile: null
  property string dwtState: ""
  property string tapState: ""
  property bool stateLoaded: false
  property string errorText: ""
  property string noteText: ""
  property bool setupIncomplete: false
  property bool helperMissing: false

  // The bar sizes widgets from the root's implicit size; the anchored icon
  // button does not contribute one, so expose its dimensions explicitly.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    root.refresh()
    if (!doctorProc.running)
      doctorProc.running = true
  }

  onOpenedChanged: if (opened) root.refresh()

  function refresh() {
    if (!stateProc.running && !root.helperMissing)
      stateProc.running = true
  }

  // Existence probe: a plugin deployed without ./install.sh has no helper.
  FileView {
    path: root.helperPath
    watchChanges: true
    printErrors: false
    onLoaded: root.helperMissing = false
    onLoadFailed: {
      root.helperMissing = true
      root.errorText = "helper no instalado; ejecuta ./install.sh"
    }
  }

  // External edits re-sync the panel; the helper re-parses the file, so the
  // file/runtime divergence shows up immediately. Used only as a trigger —
  // the file text itself is never parsed here.
  FileView {
    path: root.inputLuaPath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }

  Process {
    id: stateProc
    command: [root.helperPath, "get", "--json"]
    stdout: StdioCollector {
      id: stateStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: stateStderr
      waitForEnd: true
    }
    // Parse in onExited (collector text is final here); onStreamFinished can
    // race the exit signal on some processes.
    onExited: function(exitCode) {
      var ok = false
      if (exitCode === 0) {
        try {
          var data = JSON.parse(String(stateStdout.text || ""))
          root.dwtEnabled = data.dwt.effective === true
          root.tapToClick = data.tap.effective === true
          root.dwtFile = (typeof data.dwt.file === "boolean") ? data.dwt.file : null
          root.tapFile = (typeof data.tap.file === "boolean") ? data.tap.file : null
          root.dwtState = String(data.dwt.state || "error")
          root.tapState = String(data.tap.state || "error")
          root.stateLoaded = true
          ok = true
        } catch (e) {
          console.warn("trackpad-guard", "bad get --json output:", e)
        }
      }
      if (ok) {
        root.errorText = ""
      } else if (exitCode !== 0) {
        var err = String(stateStderr.text || "").trim()
        root.errorText = err !== "" ? err : "omarchy-trackpad-guard get failed (exit " + exitCode + ")"
      }
    }
  }

  // Applies run through a Process and state is refreshed when the command
  // COMPLETES — never on a fixed timer, which can read stale state (e.g.
  // before `hyprctl reload` finishes) and bounce the switches back.
  Process {
    id: applyProc
    stdout: StdioCollector {
      id: applyStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: applyStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var err = String(applyStderr.text || "").trim()
      if (exitCode !== 0) {
        root.errorText = err !== "" ? err.slice(0, 300) : "toggle failed (exit " + exitCode + ")"
      } else {
        root.errorText = ""
        // Convention with the helper: exit 0 with `warning:` lines on stderr
        // is a non-blocking note (e.g. new foreign configerrors) — amber,
        // never red.
        root.noteText = err.indexOf("warning:") === 0 ? err.slice(0, 300) : ""
      }
      root.refresh()
    }
  }

  // argv must be fully built before calling this. Direct argv, no shell.
  function apply(argv) {
    if (applyProc.running)
      return
    applyProc.command = argv
    applyProc.running = true
  }

  function setGuard(on) {
    dwtEnabled = on
    apply([root.helperPath, "set", "dwt", on ? "on" : "off"])
  }

  function setTap(on) {
    tapToClick = on
    apply([root.helperPath, "set", "tap", on ? "on" : "off"])
  }

  // One-shot setup probe per shell start: doctor exit code != 0 means the
  // setup is incomplete (e.g. no quirk pairing the xremap keyboard), which
  // the panel reports as a non-blocking amber note.
  Process {
    id: doctorProc
    command: [root.helperPath, "doctor"]
    stdout: StdioCollector {
      id: doctorStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: doctorStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.setupIncomplete = (exitCode !== 0)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.trackpadGlyph
    dimmed: !root.dwtEnabled
    tooltipText: root.dwtEnabled
      ? "Trackpad Guard · disable while typing on"
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

        // Hero: glyph, title + state line, DWT toggle on the right.
        Item {
          width: parent.width
          height: Math.max(heroGlyph.implicitHeight, heroText.implicitHeight, dwtToggle.trackHeight)

          Text {
            id: heroGlyph
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.trackpadGlyph
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            color: Color.popups.text
            opacity: root.dwtEnabled ? 1.0 : 0.4
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
              text: "DISABLE WHILE TYPING · " + (root.dwtEnabled ? "ON" : "OFF")
              color: Color.popups.text
              opacity: 0.6
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          ToggleSwitch {
            id: dwtToggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.dwtEnabled
            busy: applyProc.running
            // Gate until the first get lands (and the helper exists): the
            // switch would otherwise show a lying default and issue a blind
            // set.
            interactive: root.stateLoaded && !root.helperMissing
            onToggled: root.setGuard(!root.dwtEnabled)

            PanelToolTip {
              visible: dwtToggle.containsMouse
              text: "Native libinput disable-while-typing (palm guard) on the internal touchpad"
            }
          }
        }

        // Divergence / problem caption for the DWT row.
        Text {
          width: parent.width
          visible: root.dwtState === "pending" || root.dwtState === "ambiguous"
          text: root.dwtState === "ambiguous"
            ? "CLAVE DUPLICADA EN input.lua — CORRIGE A MANO"
            : "EN ARCHIVO: " + (root.dwtFile === true ? "ON" : "OFF") + " · PENDIENTE DE RELOAD"
          color: root.dwtState === "ambiguous" ? Color.urgent : Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap

          PanelToolTip {
            visible: dwtCaptionMouse.containsMouse
            text: root.dwtState === "ambiguous"
              ? "The key is active more than once; the helper fails closed and refuses to edit"
              : "input.lua was edited outside; the runtime value applies until the next reload or toggle"
          }
          MouseArea { id: dwtCaptionMouse; anchors.fill: parent; hoverEnabled: true }
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
            interactive: root.stateLoaded && !root.helperMissing
            onToggled: root.setTap(!root.tapToClick)

            PanelToolTip {
              visible: tapToggle.containsMouse
              text: "Hyprland tap-to-click on the internal touchpad"
            }
          }
        }

        // Divergence / problem caption for the tap row.
        Text {
          width: parent.width
          visible: root.tapState === "pending" || root.tapState === "ambiguous"
          text: root.tapState === "ambiguous"
            ? "CLAVE DUPLICADA EN input.lua — CORRIGE A MANO"
            : "EN ARCHIVO: " + (root.tapFile === true ? "ON" : "OFF") + " · PENDIENTE DE RELOAD"
          color: root.tapState === "ambiguous" ? Color.urgent : Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator { width: parent.width }

        // Loading state: shown until the first get --json succeeds.
        Text {
          width: parent.width
          visible: !root.stateLoaded && root.errorText === "" && !root.helperMissing
          text: "LEYENDO ESTADO…"
          color: Color.popups.text
          opacity: 0.5
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        // Setup note (amber): doctor found something incomplete (e.g. quirk
        // missing). Informational; the switches still work.
        Text {
          width: parent.width
          visible: root.setupIncomplete
          text: "QUIRK DE TECLADO INTERNO NO DETECTADO; DWT PUEDE NO ACTUAR — VER README"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Non-blocking note from the helper (amber): `warning:` lines that
        // came with exit 0 (e.g. new config errors outside input.lua).
        Text {
          width: parent.width
          visible: root.noteText !== ""
          text: root.noteText
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Error row (red): helper stderr on a failed toggle or refresh.
        Text {
          width: parent.width
          visible: root.errorText !== ""
          text: "Error: " + root.errorText
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
