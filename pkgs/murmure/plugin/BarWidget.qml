import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "th0rgal.murmure"

  readonly property string murmureBin: "@MURMURE_BIN@"
  readonly property var service: (bar && bar.shell && bar.shell.serviceFor) ? bar.shell.serviceFor("th0rgal.murmure") : null
  property string fallbackDictState: "idle"
  property string fallbackLangCode: "en"
  property string fallbackShortcutLabel: "Fn + Right ⇧"
  readonly property string dictState: service ? String(service.dictState || "idle") : fallbackDictState
  readonly property string langCode: service ? String(service.language || "en") : fallbackLangCode
  readonly property string shortcutLabel: service ? String(service.shortcutLabel || "Fn + Right ⇧") : fallbackShortcutLabel

  readonly property string tooltipLabel: {
    if (dictState === "recording") {
      return "Murmure: Recording (" + langCode.toUpperCase() + ") — Click to finish"
    }
    if (dictState === "transcribing") {
      return "Murmure: Transcribing…"
    }
    return "Murmure (" + langCode.toUpperCase() + " · " + shortcutLabel + ") — Click: Settings · Right-click: Dictate"
  }

  visible: root.dictState !== "idle"
  implicitWidth: visible ? 24 : 0
  implicitHeight: 22

  Timer {
    id: watchRestart
    interval: 2500
    onTriggered: {
      if (!root.service && !barWatchProc.running) barWatchProc.running = true
    }
  }

  onServiceChanged: {
    if (root.service && barWatchProc.running) {
      barWatchProc.running = false
    } else if (!root.service && !barWatchProc.running) {
      barWatchProc.running = true
    }
  }

  Process {
    id: barWatchProc
    command: [root.murmureBin, "watch"]
    stdout: SplitParser {
      onRead: function(line) {
        var s = String(line || "").trim()
        if (!s || s.indexOf('"state"') === -1) return
        try {
          var ev = JSON.parse(s)
          if (ev && ev.event === "state") {
            if (ev.state) root.fallbackDictState = String(ev.state)
            if (ev.language) root.fallbackLangCode = String(ev.language)
            if (ev.shortcutLabel) root.fallbackShortcutLabel = String(ev.shortcutLabel)
          }
        } catch (e) {}
      }
    }
    onExited: {
      if (!root.service) watchRestart.restart()
    }
  }

  Component.onCompleted: {
    if (!root.service) barWatchProc.running = true
  }

  // Subtle 5-bar macOS Murmure waveform icon
  Row {
    anchors.centerIn: parent
    spacing: 2

    Repeater {
      model: [5, 10, 14, 9, 5]
      delegate: Rectangle {
        required property int modelData
        width: 1.7
        height: root.dictState === "recording" ? Math.min(15, modelData + 2) : modelData
        radius: 0.85
        anchors.verticalCenter: parent.verticalCenter
        color: {
          if (root.dictState === "recording") return "#ff453a"
          if (root.dictState === "transcribing") return Commons.Color.accent
          return barMouse.containsMouse ? Commons.Color.foreground : Commons.Color.muted
        }
        Behavior on color { ColorAnimation { duration: 140 } }
      }
    }
  }

  MouseArea {
    id: barMouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onEntered: {
      if (root.bar && root.bar.showTooltip) root.bar.showTooltip(root, root.tooltipLabel)
    }
    onExited: {
      if (root.bar && root.bar.hideTooltip) root.bar.hideTooltip(root)
    }
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        Quickshell.execDetached([root.murmureBin, "toggle"])
      } else if (root.dictState === "recording") {
        Quickshell.execDetached([root.murmureBin, "toggle"])
      } else {
        Quickshell.execDetached([root.murmureBin, "settings"])
      }
    }
  }
}
