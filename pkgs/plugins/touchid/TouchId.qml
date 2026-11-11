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

  property bool surfaceMapped: false
  property bool cardVisible: false
  property string authState: "waiting" // waiting | scanning | matched | no-match | retry
  property string appName: ""
  property string subtitle: ""
  property string retryReason: ""
  property int cancelPid: 0
  property bool ipcContextActive: false
  property bool previewActive: false

  property real scanProgress: 0.24
  property real pulseLevel: 0.0
  property real shakeOffset: 0.0
  property real matchScale: 1.0

  readonly property string monitorBinPath: "@TOUCHID_MONITOR_BIN@"
  readonly property bool isLight: (Commons.Color.background.r + Commons.Color.background.g + Commons.Color.background.b) > 1.5
  readonly property string uiFontFamily: Commons.Style.font.menuFamily || "IBM Plex Sans"

  readonly property color cardSurface: Qt.rgba(
    Commons.Color.background.r,
    Commons.Color.background.g,
    Commons.Color.background.b,
    isLight ? 0.88 : 0.84
  )
  readonly property color cardBorder: isLight ? "#22000000" : "#30ffffff"
  readonly property color innerHighlight: isLight ? "#55ffffff" : "#18ffffff"
  readonly property color textPrimary: Commons.Color.foreground
  readonly property color textMuted: Commons.Color.muted

  readonly property color colorAccent: Commons.Color.accent
  readonly property color colorScanning: isLight ? "#007aff" : "#64d2ff"
  readonly property color colorSuccess: isLight ? "#248a3d" : "#30d158"
  readonly property color colorError: isLight ? "#d70015" : "#ff453a"
  readonly property color colorWarn: isLight ? "#c93400" : "#ff9f0a"

  readonly property color activeStateColor: {
    if (authState === "matched") return colorSuccess
    if (authState === "no-match") return colorError
    if (authState === "retry") return colorWarn
    if (authState === "scanning") return colorScanning
    return colorAccent
  }

  readonly property string headerTitle: appName.length > 0 ? (appName + "  ·  Touch ID") : "Touch ID"

  readonly property string statusCaption: {
    if (authState === "scanning") return "Reading fingerprint…"
    if (authState === "matched") return "Verified"
    if (authState === "no-match") return "Try Again"
    if (authState === "retry") {
      if (retryReason === "verify-center-finger" || retryReason === "verify-swipe-too-short")
        return "Place finger flat on sensor"
      if (retryReason === "verify-remove-and-retry")
        return "Lift and rest finger again"
      return "Try Again"
    }
    return "Touch sensor to authenticate"
  }

  readonly property color statusColor: {
    if (authState === "matched") return colorSuccess
    if (authState === "no-match") return colorError
    if (authState === "retry") return colorWarn
    if (authState === "scanning") return colorScanning
    return textMuted
  }

  readonly property real effectiveScan: {
    if (authState === "waiting") return 0.16 + 0.24 * pulseLevel
    return scanProgress
  }

  onEffectiveScanChanged: fpCanvas.requestPaint()
  onAuthStateChanged: fpCanvas.requestPaint()
  onIsLightChanged: fpCanvas.requestPaint()

  Behavior on scanProgress {
    NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
  }

  SequentialAnimation {
    running: root.surfaceMapped && root.authState === "waiting"
    loops: Animation.Infinite
    NumberAnimation { target: root; property: "pulseLevel"; from: 0.0; to: 1.0; duration: 1200; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulseLevel"; from: 1.0; to: 0.0; duration: 1200; easing.type: Easing.InOutSine }
  }

  SequentialAnimation {
    id: shakeAnim
    NumberAnimation { target: root; property: "shakeOffset"; to: -9; duration: 48; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 9; duration: 64; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: -6; duration: 58; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 6; duration: 54; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: -2.5; duration: 46; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 0; duration: 46; easing.type: Easing.OutQuad }
  }

  SequentialAnimation {
    id: matchPopAnim
    NumberAnimation { target: root; property: "matchScale"; to: 1.07; duration: 130; easing.type: Easing.OutBack }
    NumberAnimation { target: root; property: "matchScale"; to: 1.0; duration: 170; easing.type: Easing.OutCubic }
  }

  function showSheet() {
    unmapTimer.stop()
    autoCloseTimer.stop()
    retryResetTimer.stop()
    root.shakeOffset = 0
    root.matchScale = 1.0
    root.surfaceMapped = true
    root.cardVisible = true
    sessionWatchdog.restart()
    fpCanvas.requestPaint()
  }

  function dismissSheet() {
    autoCloseTimer.stop()
    retryResetTimer.stop()
    sessionWatchdog.stop()
    previewStep1.stop()
    previewStep2.stop()
    previewStep3.stop()
    root.previewActive = false
    root.ipcContextActive = false
    root.cardVisible = false
    unmapTimer.restart()
  }

  function cancelSession() {
    var pid = root.cancelPid
    root.cancelPid = 0
    if (pid > 0) {
      Quickshell.execDetached(["kill", "-TERM", String(pid)])
    }
    root.dismissSheet()
  }

  function handleMonitorLine(line) {
    var trimmed = String(line || "").trim()
    if (!trimmed) return
    var ev = null
    try {
      ev = JSON.parse(trimmed)
    } catch (e) {
      return
    }
    if (!ev || !ev.event) return
    if (root.previewActive && ev.event !== "start") return

    if (ev.event === "suppressed") {
      if (root.surfaceMapped && !root.previewActive) {
        root.dismissSheet()
      }
      return
    }

    if (ev.event === "start") {
      root.previewActive = false
      previewStep1.stop()
      previewStep2.stop()
      previewStep3.stop()
      if (!root.ipcContextActive) {
        root.appName = String(ev.callerApp || "")
        root.subtitle = String(ev.callerSubtitle || "Touch sensor to authenticate")
        root.cancelPid = Number(ev.cancelPid || 0)
      }
      root.retryReason = ""
      root.authState = "waiting"
      root.scanProgress = 0.24
      root.showSheet()
      return
    }

    if (ev.event === "finger-down") {
      autoCloseTimer.stop()
      retryResetTimer.stop()
      root.authState = "scanning"
      root.scanProgress = 0.92
      if (!root.surfaceMapped) root.showSheet()
      return
    }

    if (ev.event === "finger-up") {
      if (root.authState === "scanning") {
        root.authState = "waiting"
        root.scanProgress = 0.24
      }
      return
    }

    if (ev.event === "match") {
      retryResetTimer.stop()
      autoCloseTimer.stop()
      root.authState = "matched"
      root.scanProgress = 1.0
      root.cancelPid = 0
      if (!root.surfaceMapped) root.showSheet()
      matchPopAnim.restart()
      autoCloseTimer.interval = 560
      autoCloseTimer.restart()
      return
    }

    if (ev.event === "no-match") {
      root.authState = "no-match"
      root.scanProgress = 1.0
      if (!root.surfaceMapped) root.showSheet()
      shakeAnim.restart()
      if (ev.done) {
        autoCloseTimer.interval = 950
        autoCloseTimer.restart()
      } else {
        retryResetTimer.restart()
      }
      return
    }

    if (ev.event === "retry") {
      root.retryReason = String(ev.reason || "")
      root.authState = "retry"
      root.scanProgress = 0.72
      if (!root.surfaceMapped) root.showSheet()
      shakeAnim.restart()
      if (ev.done) {
        autoCloseTimer.interval = 950
        autoCloseTimer.restart()
      } else {
        retryResetTimer.restart()
      }
      return
    }

    if (ev.event === "stop") {
      if (root.authState === "matched") return
      if (root.authState === "no-match" || root.authState === "retry") {
        autoCloseTimer.interval = 750
        autoCloseTimer.restart()
      } else {
        autoCloseTimer.interval = 180
        autoCloseTimer.restart()
      }
    }
  }

  Timer {
    id: unmapTimer
    interval: 170
    onTriggered: {
      if (!root.cardVisible) {
        root.surfaceMapped = false
        root.appName = ""
        root.subtitle = ""
        root.cancelPid = 0
        root.authState = "waiting"
        root.scanProgress = 0.24
      }
    }
  }

  Timer {
    id: autoCloseTimer
    interval: 560
    onTriggered: root.dismissSheet()
  }

  Timer {
    id: retryResetTimer
    interval: 900
    onTriggered: {
      if (root.surfaceMapped && (root.authState === "no-match" || root.authState === "retry")) {
        root.authState = "waiting"
        root.scanProgress = 0.24
      }
    }
  }

  Timer {
    id: sessionWatchdog
    interval: 38000
    onTriggered: root.dismissSheet()
  }

  Timer {
    id: monitorRestartTimer
    interval: 2000
    onTriggered: {
      if (!monitorProc.running) monitorProc.running = true
    }
  }

  // Preview demo sequence (`omarchy-shell touchid preview '{"app":"Orb","subtitle":"..."}'`)
  Timer {
    id: previewStep1
    interval: 800
    onTriggered: {
      if (!root.previewActive) return
      root.authState = "scanning"
      root.scanProgress = 0.92
      previewStep2.restart()
    }
  }

  Timer {
    id: previewStep2
    interval: 750
    onTriggered: {
      if (!root.previewActive) return
      root.authState = "matched"
      root.scanProgress = 1.0
      root.cancelPid = 0
      matchPopAnim.restart()
      previewStep3.restart()
    }
  }

  Timer {
    id: previewStep3
    interval: 700
    onTriggered: {
      if (!root.previewActive) return
      root.dismissSheet()
    }
  }

  Process {
    id: monitorProc
    command: [root.monitorBinPath]
    stdout: SplitParser {
      onRead: function(line) { root.handleMonitorLine(line) }
    }
    onExited: {
      monitorRestartTimer.restart()
    }
  }

  Component.onCompleted: {
    monitorProc.running = true
  }

  ShellIpc {
    target: "touchid"

    function begin(payloadJson: string): string {
      var p = {}
      try {
        p = JSON.parse(String(payloadJson || "{}"))
      } catch (e) {}
      root.previewActive = false
      root.ipcContextActive = true
      root.appName = String(p.app || "")
      root.subtitle = String(p.subtitle || "Touch sensor to authenticate")
      root.cancelPid = Number(p.pid || 0)
      if (!root.surfaceMapped || root.authState === "matched") {
        root.authState = "waiting"
        root.scanProgress = 0.24
      }
      root.showSheet()
      return "ok"
    }

    function end(payloadJson: string): string {
      var p = {}
      try {
        p = JSON.parse(String(payloadJson || "{}"))
      } catch (e) {}
      if (p && p.result === "matched") {
        root.authState = "matched"
        root.scanProgress = 1.0
        root.cancelPid = 0
        matchPopAnim.restart()
        autoCloseTimer.interval = 520
        autoCloseTimer.restart()
      } else {
        root.dismissSheet()
      }
      return "ok"
    }

    function cancel(): string {
      root.cancelSession()
      return "ok"
    }

    function preview(payloadJson: string): string {
      var p = {}
      try {
        p = JSON.parse(String(payloadJson || "{}"))
      } catch (e) {}
      root.previewActive = true
      root.ipcContextActive = false
      root.appName = String(p.app !== undefined ? p.app : "Orb")
      root.subtitle = String(p.subtitle !== undefined ? p.subtitle : "Approve 1 request: READ \"GITHUB_TOKEN\"")
      root.cancelPid = 0
      root.authState = "waiting"
      root.scanProgress = 0.24
      root.showSheet()
      previewStep1.restart()
      return "ok"
    }

    function state(): string {
      return JSON.stringify({
        opened: root.surfaceMapped,
        cardVisible: root.cardVisible,
        authState: root.authState,
        appName: root.appName,
        subtitle: root.subtitle,
        monitorRunning: monitorProc.running
      })
    }

    function ping(): string {
      return "ok"
    }
  }

  OverlayWindow {
    id: panel
    shown: root.surfaceMapped
    shownKeyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "omarchnix-touchid"

    // Click-through everywhere except the optional Cancel pill when active.
    mask: Region {
      item: cancelPill.visible ? cancelPill : emptyMask
    }

    Item {
      id: emptyMask
      width: 0
      height: 0
    }

    Rectangle {
      id: card
      width: 276
      height: contentColumn.implicitHeight + 36
      x: Math.round((parent.width - width) / 2 + root.shakeOffset)
      y: Math.round(parent.height * 0.30)
      radius: 22
      color: root.cardSurface
      border.width: 1
      border.color: root.cardBorder

      opacity: (panel.contentRevealed && root.cardVisible) ? 1.0 : 0.0
      scale: (panel.contentRevealed && root.cardVisible) ? 1.0 : 0.96

      Behavior on opacity {
        NumberAnimation { duration: 145; easing.type: Easing.OutCubic }
      }
      Behavior on scale {
        NumberAnimation { duration: 165; easing.type: Easing.OutCubic }
      }

      // Subtle inner top specular hairline for frosted glass depth
      Rectangle {
        anchors.top: parent.top
        anchors.topMargin: 1
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - 36
        height: 1
        color: root.innerHighlight
      }

      Column {
        id: contentColumn
        width: parent.width - 36
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 18
        spacing: 10

        // Circular Touch ID sensor well + vector biometric ridges
        Item {
          width: 68
          height: 68
          anchors.horizontalCenter: parent.horizontalCenter
          scale: root.matchScale

          // Soft ambient radial glow when finger is touching or verified
          Rectangle {
            anchors.centerIn: parent
            width: 74
            height: 74
            radius: 37
            color: "transparent"
            border.width: 4
            border.color: Qt.rgba(
              root.activeStateColor.r,
              root.activeStateColor.g,
              root.activeStateColor.b,
              root.authState === "waiting" ? 0.0 : 0.16
            )
            Behavior on border.color {
              ColorAnimation { duration: 180 }
            }
          }

          Rectangle {
            id: sensorWell
            anchors.fill: parent
            radius: 34
            color: root.isLight ? "#0d000000" : "#26000000"
            border.width: 1
            border.color: {
              if (root.authState === "waiting") {
                var a = 0.22 + 0.18 * root.pulseLevel
                return root.isLight ? Qt.rgba(0, 0, 0, a * 0.7) : Qt.rgba(1, 1, 1, a)
              }
              return Qt.rgba(
                root.activeStateColor.r,
                root.activeStateColor.g,
                root.activeStateColor.b,
                0.78
              )
            }
            Behavior on border.color {
              ColorAnimation { duration: 160 }
            }

            Canvas {
              id: fpCanvas
              width: 44
              height: 44
              anchors.centerIn: parent
              antialiasing: true

              function drawRank(ctx, cx, cy, u, rank) {
                ctx.beginPath()
                if (rank === 0) {
                  // Central biometric core ridge
                  ctx.moveTo(cx, cy - 0.10 * u)
                  ctx.quadraticCurveTo(cx + 0.03 * u, cy + 0.16 * u, cx - 0.02 * u, cy + 0.42 * u)
                } else if (rank === 1) {
                  // First inner arch loop with subtle lower-right break
                  var r1 = 0.19 * u
                  var ay1 = cy + 0.02 * u
                  ctx.arc(cx, ay1, r1, Math.PI, 0, false)
                  ctx.quadraticCurveTo(cx + r1, cy + 0.28 * u, cx + 0.15 * u, cy + 0.46 * u)
                  ctx.moveTo(cx - r1, ay1)
                  ctx.quadraticCurveTo(cx - r1, cy + 0.34 * u, cx - 0.14 * u, cy + 0.56 * u)
                } else if (rank === 2) {
                  // Second biometric loop split cleanly at upper-right pore
                  var r2 = 0.37 * u
                  var ay2 = cy + 0.04 * u
                  ctx.moveTo(cx - 0.31 * u, cy + 0.68 * u)
                  ctx.quadraticCurveTo(cx - r2, cy + 0.38 * u, cx - r2, ay2)
                  ctx.arc(cx, ay2, r2, Math.PI, 1.72 * Math.PI, false)
                  ctx.moveTo(cx + r2 * Math.cos(1.86 * Math.PI), ay2 + r2 * Math.sin(1.86 * Math.PI))
                  ctx.arc(cx, ay2, r2, 1.86 * Math.PI, 2.04 * Math.PI, false)
                  ctx.quadraticCurveTo(cx + r2, cy + 0.36 * u, cx + 0.30 * u, cy + 0.64 * u)
                } else if (rank === 3) {
                  // Third loop with organic upper-left break
                  var r3 = 0.55 * u
                  var ay3 = cy + 0.06 * u
                  ctx.moveTo(cx - 0.48 * u, cy + 0.74 * u)
                  ctx.quadraticCurveTo(cx - r3, cy + 0.42 * u, cx - r3, ay3)
                  ctx.arc(cx, ay3, r3, Math.PI, 1.24 * Math.PI, false)
                  ctx.moveTo(cx + r3 * Math.cos(1.36 * Math.PI), ay3 + r3 * Math.sin(1.36 * Math.PI))
                  ctx.arc(cx, ay3, r3, 1.36 * Math.PI, 2.02 * Math.PI, false)
                  ctx.quadraticCurveTo(cx + r3, cy + 0.40 * u, cx + 0.47 * u, cy + 0.72 * u)
                } else if (rank === 4) {
                  // Outer arch loop
                  var r4 = 0.73 * u
                  var ay4 = cy + 0.08 * u
                  ctx.moveTo(cx - 0.68 * u, cy + 0.60 * u)
                  ctx.quadraticCurveTo(cx - r4, cy + 0.34 * u, cx - r4, ay4)
                  ctx.arc(cx, ay4, r4, Math.PI, 1.62 * Math.PI, false)
                  ctx.moveTo(cx + r4 * Math.cos(1.74 * Math.PI), ay4 + r4 * Math.sin(1.74 * Math.PI))
                  ctx.arc(cx, ay4, r4, 1.74 * Math.PI, 2.0 * Math.PI, false)
                  ctx.quadraticCurveTo(cx + r4, cy + 0.34 * u, cx + 0.68 * u, cy + 0.58 * u)
                } else {
                  // Topmost crown ridge
                  var r5 = 0.90 * u
                  var ay5 = cy + 0.11 * u
                  ctx.arc(cx, ay5, r5, 1.22 * Math.PI, 1.78 * Math.PI, false)
                }
                ctx.stroke()
              }

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var w = width
                var h = height
                var cx = w * 0.5
                var cy = h * 0.5 + 1.5
                var u = Math.min(w, h) * 0.5

                // Circular biometric sensor pad clip
                ctx.save()
                ctx.beginPath()
                ctx.arc(cx, cy, 0.88 * u, 0, Math.PI * 2, false)
                ctx.clip()

                ctx.lineCap = "round"
                ctx.lineJoin = "round"
                ctx.lineWidth = 2.05

                // Pass 1: subtle resting ridge silhouette
                var baseAlpha = root.isLight ? 0.24 : 0.28
                ctx.strokeStyle = root.isLight
                  ? ("rgba(0, 0, 0, " + baseAlpha + ")")
                  : ("rgba(255, 255, 255, " + baseAlpha + ")")
                for (var i = 0; i < 6; i++) {
                  drawRank(ctx, cx, cy, u, i)
                }

                // Pass 2: progressive biometric illumination from core outward
                var col = root.activeStateColor
                var level = root.effectiveScan
                var r255 = Math.round(col.r * 255)
                var g255 = Math.round(col.g * 255)
                var b255 = Math.round(col.b * 255)

                for (var k = 0; k < 6; k++) {
                  var rankAlpha = Math.max(0.0, Math.min(1.0, level * 5.6 - k * 0.92))
                  if (rankAlpha <= 0.01) continue
                  ctx.strokeStyle = "rgba(" + r255 + ", " + g255 + ", " + b255 + ", " + (0.95 * rankAlpha) + ")"
                  drawRank(ctx, cx, cy, u, k)
                }

                ctx.restore()
              }
            }
          }
        }

        // Title + Context + Live Status
        Column {
          width: parent.width
          spacing: 4

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.headerTitle
            textFormat: Text.PlainText
            color: root.textPrimary
            font.family: root.uiFontFamily
            font.pixelSize: 14
            font.weight: Font.DemiBold
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: root.subtitle.trim().length > 0
            horizontalAlignment: Text.AlignHCenter
            text: root.subtitle
            textFormat: Text.PlainText
            color: root.textMuted
            font.family: root.uiFontFamily
            font.pixelSize: 12
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            lineHeight: 1.18
          }

          Text {
            width: parent.width
            topPadding: 3
            horizontalAlignment: Text.AlignHCenter
            text: root.statusCaption
            textFormat: Text.PlainText
            color: root.statusColor
            font.family: root.uiFontFamily
            font.pixelSize: 12
            font.weight: Font.Medium
            elide: Text.ElideRight

            Behavior on color {
              ColorAnimation { duration: 150 }
            }
          }
        }

        // Subtle Cancel pill (only shown when we own a cancellable verifier PID such as Orb / fprintd-verify)
        Rectangle {
          id: cancelPill
          visible: root.cancelPid > 0 && root.authState !== "matched"
          width: 88
          height: 26
          radius: 13
          anchors.horizontalCenter: parent.horizontalCenter
          color: cancelArea.containsMouse
            ? (root.isLight ? "#18000000" : "#26ffffff")
            : (root.isLight ? "#0e000000" : "#14ffffff")
          border.width: 1
          border.color: root.isLight ? "#14000000" : "#1cffffff"

          Text {
            anchors.centerIn: parent
            text: "Cancel"
            textFormat: Text.PlainText
            color: root.textPrimary
            font.family: root.uiFontFamily
            font.pixelSize: 12
            font.weight: Font.Medium
          }

          MouseArea {
            id: cancelArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.cancelSession()
          }
        }
      }
    }
  }
}
