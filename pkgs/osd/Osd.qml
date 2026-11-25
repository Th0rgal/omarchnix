import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "OsdModel.js" as OsdModel

// macOS-style frosted-glass HUD capsule matching Omarchnix's Status Bar,
// Dock (`DockWindow.qml`), Spotlight (`Spotlight.qml`), and Touch ID (`TouchId.qml`).
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool surfaceMapped: false

  property string icon: ""
  property string iconKey: ""
  property string iconKind: "speaker"
  property bool isMuted: false
  property string message: ""
  property int value: 0
  property int maxValue: 100
  property bool hasProgress: true
  property int duration: 1350

  property real displayRatio: 0.0
  property bool barAnimEnabled: false
  property real nudgeOffset: 0.0

  readonly property bool mediaOsd: iconKey.indexOf("media") === 0
    || iconKey.indexOf("player") === 0
    || iconKind.indexOf("media-") === 0

  readonly property bool usesVectorIcon: iconKind !== "glyph"

  // Frosted glass tokens harmonized with `Spotlight.qml`, `DockWindow.qml`, and `TouchId.qml`
  readonly property bool isLight: (Commons.Color.bar.background.r + Commons.Color.bar.background.g + Commons.Color.bar.background.b) > 1.5
  readonly property string uiFontFamily: Commons.Style.font.menuFamily || "IBM Plex Sans"

  readonly property color cardSurface: Qt.rgba(
    Commons.Color.bar.background.r,
    Commons.Color.bar.background.g,
    Commons.Color.bar.background.b,
    isLight ? 0.44 : 0.38
  )
  // Keep border alpha >= 0.10 (> Hyprland `ignore_alpha = 0.05`) so the 1px outer
  // ring stays inside the compositor Kawase blur mask with zero bright-window halo.
  readonly property color cardBorder: Qt.rgba(
    Commons.Color.bar.text.r,
    Commons.Color.bar.text.g,
    Commons.Color.bar.text.b,
    isLight ? 0.10 : 0.12
  )
  readonly property color textPrimary: Commons.Color.bar.text
  readonly property color textMuted: Qt.rgba(textPrimary.r, textPrimary.g, textPrimary.b, 0.58)
  readonly property color trackBackground: Qt.rgba(textPrimary.r, textPrimary.g, textPrimary.b, isLight ? 0.13 : 0.16)
  readonly property color trackFillActive: textPrimary
  readonly property color trackFillMuted: Qt.rgba(textPrimary.r, textPrimary.g, textPrimary.b, isLight ? 0.25 : 0.28)

  readonly property int pillHeight: 46
  readonly property int padX: 18
  readonly property int iconGap: 13
  readonly property int readoutGap: 10
  readonly property int messageGap: 11
  readonly property int iconBoxWidth: 26
  readonly property int barWidth: 170
  readonly property int trackHeight: 6
  readonly property int maxMessageWidth: mediaOsd ? 330 : 210

  // Fixed readout width across 0%..100% and "Muted" so the HUD capsule never
  // jitters horizontally while holding down Volume / Brightness keys.
  readonly property int valueColumnWidth: Math.ceil(
    Math.max(
      pct100Metrics.advanceWidth,
      mutedMetrics.advanceWidth,
      hasProgress ? readoutMetrics.advanceWidth : 0
    )
  ) + 2

  readonly property int messageColumnWidth: Math.min(
    Math.ceil(messageMetrics.advanceWidth) + 2,
    maxMessageWidth
  )

  readonly property int contentWidth: {
    if (hasProgress) {
      return iconBoxWidth + iconGap + barWidth + readoutGap + valueColumnWidth
    }
    if (message === "") {
      return iconBoxWidth
    }
    return iconBoxWidth + messageGap + messageColumnWidth
  }

  onDisplayRatioChanged: {
    if (usesVectorIcon) {
      vectorCanvas.requestPaint()
      notchVectorCanvas.requestPaint()
    }
  }
  onIconKindChanged: {
    if (usesVectorIcon) {
      vectorCanvas.requestPaint()
      notchVectorCanvas.requestPaint()
    }
  }
  onIsMutedChanged: {
    if (usesVectorIcon) {
      vectorCanvas.requestPaint()
      notchVectorCanvas.requestPaint()
    }
  }
  onIsLightChanged: if (usesVectorIcon) vectorCanvas.requestPaint()
  onTextPrimaryChanged: if (usesVectorIcon) vectorCanvas.requestPaint()

  property var displayCutouts: parseCutouts(cutoutsFile.text())

  function parseCutouts(text) {
    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (e) {
      return []
    }
    var panels = parsed && Array.isArray(parsed.panels) ? parsed.panels : []
    var out = []
    for (var i = 0; i < panels.length; i++) {
      var p = panels[i] || {}
      var w = Number(p.width)
      var h = Number(p.height)
      var top = Number(p.top)
      var cw = Number(p.cutoutWidth)
      if (typeof p.connector !== "string" || p.connector === "") continue
      if (!(w > 0) || !(h > 0) || !(top > 0) || top >= h) continue
      out.push({ connector: p.connector, width: w, height: h, top: top, cutoutWidth: cw > 0 && cw < w ? cw : 304 })
    }
    return out
  }

  function notchForScreen(scr) {
    if (!scr || !(scr.width > 0) || !(scr.height > 0)) return ({ active: false, width: 0, height: 0 })
    var mon = Hyprland.monitorFor(scr)
    var pw = mon ? Number(mon.width) : 0
    var ph = mon ? Number(mon.height) : 0
    var tf = (mon && mon.lastIpcObject) ? (Number(mon.lastIpcObject.transform) || 0) : 0
    if (pw > 0 && ph > 0) {
      if (tf !== 0 && tf !== 4) return ({ active: false, width: 0, height: 0 })
      if ((pw > ph) !== (scr.width > scr.height)) return ({ active: false, width: 0, height: 0 })
    } else {
      var dpr = Number(scr.devicePixelRatio) > 0 ? Number(scr.devicePixelRatio) : 1
      pw = Math.round(scr.width * dpr)
      ph = Math.round(scr.height * dpr)
    }
    var name = String(scr.name || "")
    var list = root.displayCutouts || []
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (name.indexOf(c.connector) !== 0) continue
      if (Math.abs(pw - c.width) <= 4 && Math.abs(ph - c.height) <= 4) {
        return {
          active: true,
          height: Math.ceil(c.top * scr.width / c.width),
          width: Math.ceil(c.cutoutWidth * scr.width / c.width)
        }
      }
    }
    return ({ active: false, width: 0, height: 0 })
  }

  FileView {
    id: cutoutsFile
    path: "/usr/share/omarchy-platform/display-cutouts.json"
    blockLoading: true
    watchChanges: true
    printErrors: false
    onLoaded: root.displayCutouts = root.parseCutouts(text())
    onLoadFailed: root.displayCutouts = []
    onFileChanged: reload()
  }

  Behavior on displayRatio {
    enabled: root.barAnimEnabled
    NumberAnimation {
      duration: 105
      easing.type: Easing.OutCubic
    }
  }

  SequentialAnimation {
    id: maxNudgeAnim
    NumberAnimation { target: root; property: "nudgeOffset"; to: 2.5; duration: 48; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "nudgeOffset"; to: 0.0; duration: 85; easing.type: Easing.OutCubic }
  }

  SequentialAnimation {
    id: minNudgeAnim
    NumberAnimation { target: root; property: "nudgeOffset"; to: -2.5; duration: 48; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "nudgeOffset"; to: 0.0; duration: 85; easing.type: Easing.OutCubic }
  }

  function iconFor(name, percent) {
    return OsdModel.iconFor(name, percent)
  }

  function show(iconName, rawMessage, rawValue, rawMax, rawProgressText, rawDuration) {
    var wasOpen = root.opened
    var prevValue = root.value
    var prevMuted = root.isMuted
    var prevKind = root.iconKind

    var next = OsdModel.stateForShow(
      iconName,
      rawMessage,
      rawValue,
      rawMax,
      rawProgressText,
      rawDuration,
      Commons.I18n.formatNumber
    )

    var nextRatio = next.hasProgress ? Math.max(0.0, Math.min(1.0, next.value / next.maxValue)) : 0.0

    unmapTimer.stop()

    // Snap immediately when opening fresh or switching between HUD domains
    // (e.g. volume -> brightness); glide smoothly on consecutive updates while open.
    if (!wasOpen || !root.hasProgress || prevKind !== next.iconKind) {
      root.barAnimEnabled = false
      root.displayRatio = nextRatio
      Qt.callLater(function() {
        root.barAnimEnabled = true
      })
    } else {
      root.barAnimEnabled = true
      root.displayRatio = nextRatio

      // Subtle tactile boundary nudge when pressing raise at 100% or lower at 0%.
      if (next.hasProgress && !next.isMuted && !prevMuted) {
        if (prevValue >= next.maxValue && next.value >= next.maxValue) {
          maxNudgeAnim.restart()
        } else if (prevValue <= 0 && next.value <= 0) {
          minNudgeAnim.restart()
        }
      }
    }

    root.iconKey = next.iconKey
    root.iconKind = next.iconKind
    root.isMuted = next.isMuted
    root.maxValue = next.maxValue
    root.hasProgress = next.hasProgress
    root.value = next.value
    root.message = next.message
    root.icon = next.icon
    root.duration = next.duration

    root.surfaceMapped = true
    root.opened = true
    vectorCanvas.requestPaint()
    notchVectorCanvas.requestPaint()

    if (next.duration > 0) hideTimer.restart()
    else hideTimer.stop()
  }

  function open(payloadJson) {
    try {
      var p = JSON.parse(payloadJson || "{}")
      show(
        p.icon || "",
        p.message || "",
        p.value === undefined ? "" : String(p.value),
        p.max === undefined ? "100" : String(p.max),
        p.progressText || "",
        p.duration === undefined ? "1350" : String(p.duration)
      )
    } catch (e) {}
  }

  function close() {
    hideTimer.stop()
    root.opened = false
    unmapTimer.restart()
  }

  Timer {
    id: hideTimer
    interval: root.duration
    onTriggered: root.close()
  }

  Timer {
    id: unmapTimer
    interval: 170
    onTriggered: {
      if (!root.opened) {
        root.surfaceMapped = false
        root.nudgeOffset = 0.0
      }
    }
  }

  TextMetrics {
    id: readoutMetrics
    font.family: root.uiFontFamily
    font.pixelSize: 13
    font.weight: Font.DemiBold
    text: root.message
  }

  TextMetrics {
    id: pct100Metrics
    font: readoutMetrics.font
    text: Commons.I18n.formatNumber(100) + "%"
  }

  TextMetrics {
    id: mutedMetrics
    font: readoutMetrics.font
    text: "Muted"
  }

  TextMetrics {
    id: messageMetrics
    font.family: root.uiFontFamily
    font.pixelSize: 14
    font.weight: Font.Medium
    text: root.message
  }

  TextMetrics {
    id: glyphMetrics
    font.family: Style.font.family
    font.pixelSize: 20
    text: root.icon
  }

  ShellIpc {
    target: "osd"
    function show(payloadJson: string): string {
      root.open(payloadJson)
      return "ok"
    }
    function close(): string {
      root.close()
      return "ok"
    }
    function state(): string {
      return root.opened ? "open" : "closed"
    }
    function ping(): string {
      return "ok"
    }
  }

  OverlayWindow {
    id: panel
    shown: root.surfaceMapped
    shownKeyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "omarchy-osd"
    // Visual-only surface: never intercept pointer clicks on the desktop below.
    mask: Region {}

    readonly property var notchInfo: root.notchForScreen(panel.screen)
    readonly property bool notchActive: notchInfo.active === true
    readonly property int notchHeight: notchActive ? notchInfo.height : 0
    readonly property int notchWidth: notchActive ? notchInfo.width : 0

    // ---- Pure-Black Dynamic Island OSD Ears (notched MacBook displays) ----
    Item {
      id: notchOsd
      visible: panel.notchActive
      readonly property bool visibleState: panel.notchActive && panel.contentRevealed && root.opened
      readonly property int earSpan: root.hasProgress
        ? 98
        : Math.max(46, Math.min(148, root.messageColumnWidth + 24))
      readonly property int targetWidth: visibleState
        ? (panel.notchWidth + earSpan * 2)
        : panel.notchWidth

      y: 0
      height: panel.notchHeight
      width: targetWidth
      x: Math.round((parent.width - width) / 2 + root.nudgeOffset)
      opacity: visibleState ? 1.0 : 0.0

      Behavior on width {
        NumberAnimation { duration: 190; easing.type: Easing.OutCubic }
      }
      Behavior on opacity {
        NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
      }

      // Left concave top-outer fillet
      Canvas {
        width: 10
        height: 10
        anchors.right: notchOsdBody.left
        anchors.top: parent.top
        antialiasing: true
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.fillStyle = "#000000"
          ctx.beginPath()
          ctx.moveTo(width, 0)
          ctx.lineTo(0, 0)
          ctx.arcTo(width, 0, width, height, width)
          ctx.closePath()
          ctx.fill()
        }
      }

      // Right concave top-outer fillet
      Canvas {
        width: 10
        height: 10
        anchors.left: notchOsdBody.right
        anchors.top: parent.top
        antialiasing: true
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.fillStyle = "#000000"
          ctx.beginPath()
          ctx.moveTo(0, 0)
          ctx.lineTo(width, 0)
          ctx.arcTo(0, 0, 0, height, width)
          ctx.closePath()
          ctx.fill()
        }
      }

      Item {
        id: notchOsdBody
        anchors.fill: parent
        clip: true

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: -11
          anchors.bottom: parent.bottom
          radius: 11
          color: "#000000"
        }

        // Left ear: crisp white vector icon + tabular readout
        Row {
          anchors.left: parent.left
          anchors.leftMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          spacing: 7
          opacity: notchOsd.visibleState ? 1.0 : 0.0
          Behavior on opacity { NumberAnimation { duration: 120 } }

          Item {
            width: 22
            height: 22
            anchors.verticalCenter: parent.verticalCenter

            Canvas {
              id: notchVectorCanvas
              visible: root.usesVectorIcon
              width: 22
              height: 22
              anchors.centerIn: parent
              antialiasing: true

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.scale(22.0 / 26.0, 22.0 / 26.0)
                vectorCanvas.drawIcon(ctx, Qt.rgba(1, 1, 1, 1))
              }
            }

            Text {
              visible: !root.usesVectorIcon
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.icon
              font.family: Style.font.family
              font.pixelSize: 16
              color: "#ffffff"
            }
          }

          Text {
            visible: root.hasProgress && root.message !== ""
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.message
            font.family: root.uiFontFamily
            font.pixelSize: 12
            font.weight: Font.DemiBold
            font.features: ({ "tnum": 1 })
            color: root.isMuted ? "#8e8e93" : "#ffffff"
          }
        }

        // Right ear: sleek white pill progress track OR compact message
        Item {
          anchors.right: parent.right
          anchors.rightMargin: 12
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Math.max(0, notchOsd.earSpan - 18)
          opacity: notchOsd.visibleState ? 1.0 : 0.0
          Behavior on opacity { NumberAnimation { duration: 120 } }

          Rectangle {
            visible: root.hasProgress
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(76, parent.width)
            height: 5
            radius: 2.5
            color: "#33ffffff"
            clip: true

            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              height: parent.height
              radius: parent.radius
              width: Math.round(parent.width * root.displayRatio)
              color: root.isMuted ? "#66ffffff" : "#ffffff"
            }
          }

          Text {
            visible: !root.hasProgress && root.message !== ""
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width)
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: root.message
            font.family: root.uiFontFamily
            font.pixelSize: 12
            font.weight: Font.Medium
            color: "#ffffff"
            elide: Text.ElideRight
          }
        }
      }
    }

    BorderSurface {
      id: card
      visible: !panel.notchActive

      readonly property bool visibleState: panel.contentRevealed && root.opened

      width: card.borderLeft + root.padX + root.contentWidth + root.padX + card.borderRight
      height: root.pillHeight
      x: Math.round((parent.width - width) / 2 + root.nudgeOffset)
      // Sits cleanly above the auto-hide bottom Dock even when the Dock is revealed.
      y: Math.round(parent.height - height - Style.space(82) + (visibleState ? 0 : 4))
      radius: 18
      color: root.cardSurface
      borderSpec: Border.flat(root.cardBorder, 1)

      opacity: visibleState ? 1.0 : 0.0
      scale: visibleState ? 1.0 : 0.965

      Behavior on opacity {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
      Behavior on scale {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
      Behavior on y {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }

      Item {
        id: contentRow
        anchors.fill: parent
        anchors.leftMargin: card.borderLeft + root.padX
        anchors.rightMargin: card.borderRight + root.padX

        // Left Icon Column: SF-Symbols-style HiDPI vector Canvas + Nerd Font fallback
        Item {
          id: iconCell
          anchors.left: parent.left
          width: root.iconBoxWidth
          height: parent.height

          Canvas {
            id: vectorCanvas
            visible: root.usesVectorIcon
            width: 26
            height: 26
            anchors.centerIn: parent
            antialiasing: true

            function rgba(col, a) {
              var alpha = Math.max(0.0, Math.min(1.0, a))
              return "rgba("
                + Math.round(col.r * 255) + ", "
                + Math.round(col.g * 255) + ", "
                + Math.round(col.b * 255) + ", "
                + alpha + ")"
            }

            function smoothBand(x, lo, hi) {
              if (x <= lo) return 0.0
              if (x >= hi) return 1.0
              var t = (x - lo) / (hi - lo)
              return t * t * (3.0 - 2.0 * t)
            }

            function drawMuteSlash(ctx, fg) {
              ctx.save()
              ctx.lineCap = "round"
              // Carve a clean SF-Symbols silhouette gap through the icon glyph
              ctx.globalCompositeOperation = "destination-out"
              ctx.strokeStyle = "rgba(0, 0, 0, 1)"
              ctx.lineWidth = 4.4
              ctx.beginPath()
              ctx.moveTo(4.8, 5.2)
              ctx.lineTo(21.2, 20.8)
              ctx.stroke()

              ctx.globalCompositeOperation = "source-over"
              ctx.strokeStyle = rgba(fg, 0.92)
              ctx.lineWidth = 1.95
              ctx.beginPath()
              ctx.moveTo(4.8, 5.2)
              ctx.lineTo(21.2, 20.8)
              ctx.stroke()
              ctx.restore()
            }

            function drawRoundedRect(ctx, x, y, w, h, r) {
              var rr = Math.min(r, w / 2, h / 2)
              ctx.beginPath()
              ctx.moveTo(x + rr, y)
              ctx.lineTo(x + w - rr, y)
              ctx.quadraticCurveTo(x + w, y, x + w, y + rr)
              ctx.lineTo(x + w, y + h - rr)
              ctx.quadraticCurveTo(x + w, y + h, x + w - rr, y + h)
              ctx.lineTo(x + rr, y + h)
              ctx.quadraticCurveTo(x, y + h, x, y + h - rr)
              ctx.lineTo(x, y + rr)
              ctx.quadraticCurveTo(x, y, x + rr, y)
              ctx.closePath()
            }

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              drawIcon(ctx, root.textPrimary)
            }

            function drawIcon(ctx, fg) {
              var kind = root.iconKind
              var muted = root.isMuted
              var lvl = root.hasProgress ? root.displayRatio : 1.0

              ctx.lineCap = "round"
              ctx.lineJoin = "round"

              if (kind === "speaker") {
                var bodyAlpha = muted ? 0.68 : 0.96
                ctx.fillStyle = rgba(fg, bodyAlpha)
                ctx.strokeStyle = rgba(fg, bodyAlpha)
                ctx.lineWidth = 1.5

                // Rounded speaker driver + flared acoustic cone
                ctx.beginPath()
                ctx.moveTo(3.8, 10.2)
                ctx.lineTo(7.1, 10.2)
                ctx.lineTo(11.6, 6.2)
                ctx.lineTo(11.6, 19.8)
                ctx.lineTo(7.1, 15.8)
                ctx.lineTo(3.8, 15.8)
                ctx.closePath()
                ctx.fill()
                ctx.stroke()

                if (!muted) {
                  // Three progressive acoustic wave arcs (SF Symbols `speaker.wave.3.fill`)
                  var w1 = smoothBand(lvl, 0.005, 0.08)
                  var w2 = smoothBand(lvl, 0.30, 0.40)
                  var w3 = smoothBand(lvl, 0.63, 0.73)
                  var radii = [4.4, 7.3, 10.2]
                  var alphas = [w1, w2, w3]
                  var span = 0.22 * Math.PI
                  ctx.lineWidth = 1.85
                  for (var wi = 0; wi < 3; wi++) {
                    if (alphas[wi] <= 0.01) continue
                    ctx.strokeStyle = rgba(fg, 0.94 * alphas[wi])
                    ctx.beginPath()
                    ctx.arc(11.2, 13.0, radii[wi], -span, span, false)
                    ctx.stroke()
                  }
                } else {
                  drawMuteSlash(ctx, fg)
                }
              } else if (kind === "headphones") {
                var hpAlpha = muted ? 0.68 : 0.96
                ctx.strokeStyle = rgba(fg, hpAlpha)
                ctx.fillStyle = rgba(fg, hpAlpha)
                ctx.lineWidth = 2.0
                ctx.beginPath()
                ctx.arc(13.0, 13.2, 7.4, Math.PI, 0, false)
                ctx.stroke()

                drawRoundedRect(ctx, 4.2, 12.2, 3.6, 7.2, 1.8)
                ctx.fill()
                drawRoundedRect(ctx, 18.2, 12.2, 3.6, 7.2, 1.8)
                ctx.fill()

                if (muted) drawMuteSlash(ctx, fg)
              } else if (kind === "brightness") {
                // SF-Symbols `sun.max.fill` with subtle ray breathing
                ctx.fillStyle = rgba(fg, 0.96)
                ctx.beginPath()
                ctx.arc(13.0, 13.0, 4.2, 0, Math.PI * 2, false)
                ctx.fill()

                var rayInner = 6.9
                var rayOuter = 8.9 + 1.6 * lvl
                var rayAlpha = 0.48 + 0.48 * lvl
                ctx.strokeStyle = rgba(fg, rayAlpha)
                ctx.lineWidth = 1.85
                for (var ri = 0; ri < 8; ri++) {
                  var ang = ri * (Math.PI / 4.0)
                  var cs = Math.cos(ang)
                  var sn = Math.sin(ang)
                  ctx.beginPath()
                  ctx.moveTo(13.0 + cs * rayInner, 13.0 + sn * rayInner)
                  ctx.lineTo(13.0 + cs * rayOuter, 13.0 + sn * rayOuter)
                  ctx.stroke()
                }
              } else if (kind === "keyboard") {
                // macOS `light.max` keyboard backlight bar + 5 fanning glow rays
                ctx.fillStyle = rgba(fg, 0.95)
                drawRoundedRect(ctx, 4.5, 17.2, 17.0, 2.6, 1.3)
                ctx.fill()

                var kRayLen = 1.4 + 3.4 * lvl
                var kRayAlpha = 0.24 + 0.72 * lvl
                var fanAngles = [-0.98, -0.49, 0.0, 0.49, 0.98]
                ctx.strokeStyle = rgba(fg, kRayAlpha)
                ctx.lineWidth = 1.8
                for (var ki = 0; ki < fanAngles.length; ki++) {
                  var a = fanAngles[ki] - Math.PI / 2.0
                  var r0 = 5.4
                  var r1 = r0 + kRayLen
                  ctx.beginPath()
                  ctx.moveTo(13.0 + Math.cos(a) * r0, 16.4 + Math.sin(a) * r0)
                  ctx.lineTo(13.0 + Math.cos(a) * r1, 16.4 + Math.sin(a) * r1)
                  ctx.stroke()
                }
              } else if (kind === "mic") {
                var micAlpha = muted ? 0.68 : 0.96
                ctx.fillStyle = rgba(fg, micAlpha)
                ctx.strokeStyle = rgba(fg, micAlpha)
                drawRoundedRect(ctx, 9.9, 4.2, 6.2, 10.0, 3.1)
                ctx.fill()

                ctx.lineWidth = 1.85
                ctx.beginPath()
                ctx.arc(13.0, 11.2, 5.6, 0, Math.PI, false)
                ctx.stroke()

                ctx.beginPath()
                ctx.moveTo(13.0, 16.8)
                ctx.lineTo(13.0, 20.6)
                ctx.moveTo(9.6, 20.6)
                ctx.lineTo(16.4, 20.6)
                ctx.stroke()

                if (muted) drawMuteSlash(ctx, fg)
              } else if (kind === "media-play") {
                ctx.fillStyle = rgba(fg, 0.95)
                ctx.strokeStyle = rgba(fg, 0.95)
                ctx.lineWidth = 1.8
                ctx.beginPath()
                ctx.moveTo(8.5, 6.6)
                ctx.lineTo(19.2, 13.0)
                ctx.lineTo(8.5, 19.4)
                ctx.closePath()
                ctx.fill()
                ctx.stroke()
              } else if (kind === "media-pause") {
                ctx.fillStyle = rgba(fg, 0.95)
                drawRoundedRect(ctx, 7.2, 6.0, 4.0, 14.0, 1.6)
                ctx.fill()
                drawRoundedRect(ctx, 14.8, 6.0, 4.0, 14.0, 1.6)
                ctx.fill()
              } else if (kind === "media-next") {
                ctx.fillStyle = rgba(fg, 0.95)
                ctx.strokeStyle = rgba(fg, 0.95)
                ctx.lineWidth = 1.4
                ctx.beginPath()
                ctx.moveTo(5.6, 7.2)
                ctx.lineTo(14.4, 13.0)
                ctx.lineTo(5.6, 18.8)
                ctx.closePath()
                ctx.fill()
                ctx.stroke()
                drawRoundedRect(ctx, 16.6, 6.8, 2.8, 12.4, 1.3)
                ctx.fill()
              } else if (kind === "media-previous") {
                ctx.fillStyle = rgba(fg, 0.95)
                ctx.strokeStyle = rgba(fg, 0.95)
                ctx.lineWidth = 1.4
                drawRoundedRect(ctx, 6.6, 6.8, 2.8, 12.4, 1.3)
                ctx.fill()
                ctx.beginPath()
                ctx.moveTo(20.4, 7.2)
                ctx.lineTo(11.6, 13.0)
                ctx.lineTo(20.4, 18.8)
                ctx.closePath()
                ctx.fill()
                ctx.stroke()
              } else if (kind === "media-note") {
                ctx.fillStyle = rgba(fg, 0.95)
                ctx.strokeStyle = rgba(fg, 0.95)
                ctx.lineWidth = 2.0
                ctx.beginPath()
                ctx.moveTo(10.5, 17.5)
                ctx.lineTo(10.5, 7.4)
                ctx.lineTo(19.2, 5.6)
                ctx.lineTo(19.2, 15.7)
                ctx.stroke()
                ctx.beginPath()
                ctx.arc(8.3, 17.8, 2.6, 0, Math.PI * 2, false)
                ctx.fill()
                ctx.beginPath()
                ctx.arc(17.0, 16.0, 2.6, 0, Math.PI * 2, false)
                ctx.fill()
              }
            }
          }

          // Fallback Nerd Font glyph for custom `-i` callers
          Text {
            visible: !root.usesVectorIcon
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: root.icon
            font: glyphMetrics.font
            color: root.textPrimary
          }
        }

        // Center Liquid Capsule Progress Track (Volume / Brightness / Keyboard Backlight)
        Rectangle {
          id: progressTrack
          visible: root.hasProgress
          x: iconCell.width + root.iconGap
          width: root.barWidth
          height: root.trackHeight
          radius: root.trackHeight / 2
          anchors.verticalCenter: parent.verticalCenter
          color: root.trackBackground
          clip: true

          Rectangle {
            id: progressFill
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height
            radius: parent.radius
            width: Math.round(parent.width * root.displayRatio)
            color: root.isMuted ? root.trackFillMuted : root.trackFillActive

            Behavior on color {
              ColorAnimation { duration: 130 }
            }
          }
        }

        // Right Tabular Readout ("60%" / "Muted") or Text Message (Media / Mic / Output Switch)
        Text {
          textFormat: Text.PlainText
          visible: root.message !== ""
          x: root.hasProgress ? (parent.width - width) : (iconCell.width + root.messageGap)
          width: root.hasProgress ? root.valueColumnWidth : root.messageColumnWidth
          horizontalAlignment: root.hasProgress ? Text.AlignRight : Text.AlignLeft
          anchors.verticalCenter: parent.verticalCenter
          text: root.message
          font.family: root.uiFontFamily
          font.pixelSize: root.hasProgress ? 13 : 14
          font.weight: root.hasProgress ? Font.DemiBold : Font.Medium
          font.features: ({ "tnum": 1 })
          color: (root.hasProgress && root.isMuted) ? root.textMuted : root.textPrimary
          elide: Text.ElideRight
          maximumLineCount: 1

          Behavior on color {
            ColorAnimation { duration: 130 }
          }
        }
      }
    }
  }
}
