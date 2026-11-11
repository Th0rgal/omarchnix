import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string murmureBin: "@MURMURE_BIN@"
  readonly property string murmureSocketPath: {
    var explicitSock = Quickshell.env("MURMURE_SOCKET")
    if (explicitSock && explicitSock !== "") return explicitSock
    var rt = Quickshell.env("XDG_RUNTIME_DIR")
    if (rt && rt !== "") return rt + "/murmure.sock"
    return Quickshell.env("HOME") + "/.local/share/murmure/murmure.sock"
  }
  readonly property string uiFont: Commons.Style.font.menuFamily || "IBM Plex Sans"
  readonly property string monoFont: Commons.Style.font.monoFamily || "Lilex Nerd Font"

  property bool surfaceMapped: false
  property bool pillVisible: false
  property bool langMenuOpen: false
  property string dictState: "idle"   // idle | recording | transcribing
  property string phase: "idle"       // idle | recording | transcribing | message
  property string statusMessage: ""
  property string language: "en"
  property string shortcutLabel: "Fn + Right ⇧"
  property string livePreview: ""
  property var levels: [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  ]
  property var languages: [
    { code: "fr", name: "Français" },
    { code: "en", name: "English" },
    { code: "de", name: "Deutsch" },
    { code: "es", name: "Español" },
    { code: "it", name: "Italiano" },
    { code: "pt", name: "Português" },
    { code: "nl", name: "Nederlands" },
    { code: "pl", name: "Polski" },
    { code: "el", name: "Ελληνικά" },
    { code: "ar", name: "العربية" },
    { code: "ja", name: "日本語" },
    { code: "zh", name: "中文" },
    { code: "vi", name: "Tiếng Việt" },
    { code: "ko", name: "한국어" }
  ]

  property real waveTime: 0.0
  property real spinnerAngle: 0.0

  Timer {
    id: animTick
    interval: 33
    repeat: true
    running: root.surfaceMapped && root.phase === "transcribing"
    onTriggered: {
      root.waveTime += 0.23
      root.spinnerAngle = (root.spinnerAngle + 14) % 360
      spinnerCanvas.requestPaint()
    }
  }

  Timer {
    id: unmapTimer
    interval: 150
    onTriggered: {
      if (!root.pillVisible) {
        root.surfaceMapped = false
        root.langMenuOpen = false
      }
    }
  }

  Timer {
    id: watchRestartTimer
    interval: 1500
    onTriggered: {
      if (!watchSock.connected) watchSock.connected = true
    }
  }

  function runCmd(args) {
    Quickshell.execDetached([root.murmureBin].concat(args))
  }

  function handleWatchLine(line) {
    var trimmed = String(line || "").trim()
    if (!trimmed) return
    var ev = null
    try {
      ev = JSON.parse(trimmed)
    } catch (e) {
      return
    }
    if (!ev) return

    if (ev.event === "levels") {
      if (ev.levels && ev.levels.length === 30) {
        root.levels = ev.levels
      }
      if (ev.livePreview !== undefined) {
        root.livePreview = String(ev.livePreview || "")
      }
      return
    }

    if (ev.event === "state") {
      root.dictState = String(ev.state || "idle")
      root.phase = String(ev.phase || "idle")
      root.statusMessage = String(ev.message || "")
      if (ev.language) root.language = String(ev.language)
      if (ev.shortcutLabel) root.shortcutLabel = String(ev.shortcutLabel)
      if (ev.livePreview !== undefined) root.livePreview = String(ev.livePreview || "")
      if (ev.levels && ev.levels.length === 30) root.levels = ev.levels
      if (ev.languages && ev.languages.length > 0) root.languages = ev.languages

      var show = Boolean(ev.visible) || root.phase !== "idle"
      if (show) {
        unmapTimer.stop()
        root.surfaceMapped = true
        root.pillVisible = true
      } else {
        root.pillVisible = false
        root.langMenuOpen = false
        unmapTimer.restart()
      }
    }
  }

  Socket {
    id: watchSock
    path: root.murmureSocketPath
    connected: true
    onConnectedChanged: {
      if (connected) {
        write('{"op":"watch"}\n')
        flush()
      } else {
        watchRestartTimer.restart()
      }
    }
    onError: function(_err) {
      connected = false
      watchRestartTimer.restart()
    }
    parser: SplitParser {
      onRead: function(line) { root.handleWatchLine(line) }
    }
  }

  ShellIpc {
    target: "murmure"

    function toggle(): string {
      root.runCmd(["toggle"])
      return "ok"
    }

    function cancel(): string {
      root.runCmd(["cancel"])
      return "ok"
    }

    function commit(): string {
      root.runCmd(["commit"])
      return "ok"
    }

    function settings(): string {
      root.runCmd(["settings"])
      return "ok"
    }

    function state(): string {
      return JSON.stringify({
        state: root.dictState,
        phase: root.phase,
        language: root.language,
        visible: root.pillVisible
      })
    }
  }

  OverlayWindow {
    id: panel
    shown: root.surfaceMapped
    shownKeyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "omarchnix-murmure"

    mask: Region {
      item: pillHitBox.visible ? pillHitBox : emptyMask
    }

    Item {
      id: emptyMask
      width: 0
      height: 0
    }

    Item {
      id: pillHitBox
      visible: root.surfaceMapped
      width: Math.max(mainCapsule.width, previewCapsule.visible ? previewCapsule.width : 0, langPopup.visible ? langPopup.width : 0) + 12
      height: mainCapsule.height + 14
        + (previewCapsule.visible ? previewCapsule.height + 6 : 0)
        + (langPopup.visible ? langPopup.height + 8 : 0)
      x: Math.round((parent.width - width) / 2)
      y: Math.round(parent.height - height - 36)

      opacity: (panel.contentRevealed && root.pillVisible) ? 1.0 : 0.0
      scale: (panel.contentRevealed && root.pillVisible) ? 1.0 : 0.96

      Behavior on opacity {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
      Behavior on scale {
        NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
      }

      // Floating language chooser menu (above pill when language badge clicked)
      Rectangle {
        id: langPopup
        visible: root.langMenuOpen
        width: 248
        height: langGrid.implicitHeight + 14
        anchors.bottom: previewCapsule.visible ? previewCapsule.top : pillWrap.top
        anchors.bottomMargin: 6
        anchors.horizontalCenter: parent.horizontalCenter
        radius: 12
        color: "#f2181818"
        border.width: 1
        border.color: "#3d3d3d"

        Grid {
          id: langGrid
          columns: 2
          spacing: 4
          anchors.centerIn: parent

          Repeater {
            model: root.languages
            delegate: Rectangle {
              required property var modelData
              width: 114
              height: 24
              radius: 6
              color: {
                if (modelData.code === root.language) return "#33ffffff"
                if (langItemArea.containsMouse) return "#1fffffff"
                return "transparent"
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: (modelData.code === root.language ? "✓ " : "   ") + modelData.name
                textFormat: Text.PlainText
                color: modelData.code === root.language ? "#ffffff" : "#cccccc"
                font.family: root.uiFont
                font.pixelSize: 11
                font.weight: modelData.code === root.language ? Font.DemiBold : Font.Normal
                elide: Text.ElideRight
                width: parent.width - 12
              }

              MouseArea {
                id: langItemArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.language = modelData.code
                  root.langMenuOpen = false
                  root.runCmd(["language", modelData.code])
                }
              }
            }
          }
        }
      }

      // Live scrolling VAD chunk transcript preview capsule
      Rectangle {
        id: previewCapsule
        visible: root.livePreview.length > 0
        width: Math.min(280, previewText.implicitWidth + 22)
        height: 24
        radius: 12
        anchors.bottom: pillWrap.top
        anchors.bottomMargin: 4
        anchors.horizontalCenter: parent.horizontalCenter
        color: "#f01c1c1c"
        border.width: 1
        border.color: "#3d3d3d"

        Text {
          id: previewText
          width: Math.min(258, implicitWidth)
          anchors.centerIn: parent
          text: root.livePreview
          textFormat: Text.PlainText
          color: "#e0e0e0"
          font.family: root.monoFont
          font.pixelSize: 12
          font.underline: true
          elide: Text.ElideLeft
          maximumLineCount: 1
        }
      }

      // Main Murmure Pill + Top Language Badge
      Item {
        id: pillWrap
        width: mainCapsule.width
        height: mainCapsule.height + 10
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter

        Rectangle {
          id: mainCapsule
          width: 208
          height: 42
          radius: 21
          anchors.bottom: parent.bottom
          anchors.horizontalCenter: parent.horizontalCenter
          color: "#161616"
          border.width: 1
          border.color: "#3d3d3d"

          Row {
            anchors.centerIn: parent
            spacing: 6

            // Cancel (×) button
            Rectangle {
              width: 28
              height: 28
              radius: 14
              anchors.verticalCenter: parent.verticalCenter
              color: cancelMouse.containsMouse ? "#595959" : "#454545"

              Text {
                anchors.centerIn: parent
                text: "✕"
                color: "#ffffff"
                font.family: root.uiFont
                font.pixelSize: 12
                font.weight: Font.Bold
              }

              MouseArea {
                id: cancelMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.runCmd(["cancel"])
              }
            }

            // Center waveform / transcribing dots / status message
            Item {
              width: 128
              height: 28
              anchors.verticalCenter: parent.verticalCenter

              // Recording: 30 live scrolling bars
              Row {
                visible: root.phase === "recording"
                anchors.centerIn: parent
                spacing: 2.2

                Repeater {
                  model: 30
                  delegate: Rectangle {
                    required property int index
                    width: 2
                    radius: 1
                    color: "#ffffff"
                    anchors.verticalCenter: parent.verticalCenter
                    height: {
                      var lv = (root.levels && index < root.levels.length) ? Number(root.levels[index]) : 0
                      return Math.max(2, Math.min(26, 2 + lv * 24))
                    }
                    Behavior on height {
                      NumberAnimation { duration: 38; easing.type: Easing.Linear }
                    }
                  }
                }
              }

              // Transcribing: 30 sinusoidal pulsing dots
              Row {
                visible: root.phase === "transcribing"
                anchors.centerIn: parent
                spacing: 2.2

                Repeater {
                  model: 30
                  delegate: Rectangle {
                    required property int index
                    width: 2.2
                    height: 2.2
                    radius: 1.1
                    color: "#ffffff"
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: 0.25 + 0.75 * Math.max(0, Math.sin(root.waveTime - index * 0.35))
                  }
                }
              }

              // Flash / error message
              Text {
                visible: root.phase === "message"
                width: parent.width
                anchors.centerIn: parent
                horizontalAlignment: Text.AlignHCenter
                text: root.statusMessage
                textFormat: Text.PlainText
                color: "#d9d9d9"
                font.family: root.uiFont
                font.pixelSize: 11
                font.weight: Font.Medium
                elide: Text.ElideRight
              }
            }

            // Commit (✓ / spinner) button
            Rectangle {
              width: 28
              height: 28
              radius: 14
              anchors.verticalCenter: parent.verticalCenter
              color: commitMouse.containsMouse && root.phase === "recording" ? "#e8e8e8" : "#ffffff"

              Text {
                visible: root.phase !== "transcribing"
                anchors.centerIn: parent
                text: "✓"
                color: "#000000"
                font.family: root.uiFont
                font.pixelSize: 13
                font.weight: Font.Bold
              }

              Canvas {
                id: spinnerCanvas
                visible: root.phase === "transcribing"
                width: 14
                height: 14
                anchors.centerIn: parent
                antialiasing: true
                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()
                  ctx.translate(7, 7)
                  ctx.rotate(root.spinnerAngle * Math.PI / 180.0)
                  ctx.beginPath()
                  ctx.arc(0, 0, 5.2, 0, Math.PI * 1.45, false)
                  ctx.lineWidth = 1.8
                  ctx.lineCap = "round"
                  ctx.strokeStyle = "#000000"
                  ctx.stroke()
                }
              }

              MouseArea {
                id: commitMouse
                anchors.fill: parent
                enabled: root.phase === "recording"
                hoverEnabled: true
                cursorShape: root.phase === "recording" ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.runCmd(["commit"])
              }
            }
          }
        }

        // Top floating language badge ("FR", "EN", ...)
        Rectangle {
          id: langBadge
          width: Math.max(26, langBadgeText.implicitWidth + 12)
          height: 15
          radius: 7.5
          anchors.top: parent.top
          anchors.topMargin: 2
          anchors.horizontalCenter: parent.horizontalCenter
          color: langMouse.containsMouse ? "#262626" : "#161616"
          border.width: 1
          border.color: "#3d3d3d"

          Text {
            id: langBadgeText
            anchors.centerIn: parent
            text: root.language.toUpperCase()
            textFormat: Text.PlainText
            color: "#b3b3b3"
            font.family: root.uiFont
            font.pixelSize: 9
            font.weight: Font.DemiBold
          }

          MouseArea {
            id: langMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.langMenuOpen = !root.langMenuOpen
          }
        }
      }
    }
  }
}
