import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import qs.Ui as Ui

Panel {
  id: root
  moduleName: "omarchnix.oura"
  ipcTarget: "omarchnix.oura"
  manageIpc: false

  readonly property var engine: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("omarchnix.oura")
    : null

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleGestures(): string {
      if (root.engine) root.engine.toggleGestures()
      return "ok"
    }
  }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool isLight: (Commons.Color.background.r + Commons.Color.background.g + Commons.Color.background.b) > 1.5
  readonly property color okColor: isLight ? "#248a3d" : "#30d158"
  readonly property color accentCyan: isLight ? "#0a7ea4" : "#3fe0ff"
  readonly property color warnColor: isLight ? "#c93400" : "#ff9f0a"
  readonly property color cardBg: isLight ? Qt.rgba(0, 0, 0, 0.05) : Qt.rgba(1, 1, 1, 0.06)
  readonly property color cardBorder: isLight ? Qt.rgba(0, 0, 0, 0.10) : Qt.rgba(1, 1, 1, 0.11)

  readonly property bool online: engine ? engine.daemonOnline : false
  readonly property bool gesturesOn: engine ? engine.gesturesEnabled : false
  readonly property bool gesturesConnecting: engine ? (engine.gesturesConnecting || engine.pendingGestureClick) : false
  readonly property bool gesturesActive: engine ? engine.gesturesActive : false
  readonly property bool liveHrOn: engine ? engine.liveHrActive : false
  readonly property int battery: engine ? engine.batteryPercent : -1
  readonly property bool charging: engine ? engine.charging : false
  readonly property int displayHr: engine ? (engine.liveHrActive && engine.liveHr > 0 ? engine.liveHr : engine.latestHr) : -1
  readonly property var attitude: engine ? engine.attitude : ({ h_deg: 0, v_deg: 0, lin_g: 0, calibrated: false, calibration_stage: null })
  readonly property var gcfg: engine ? engine.gestureConfig : ({ swipe_accel_g: 0.75, lift_accel_g: 0.65, require_lift_to_arm: true, invert_h: false })
  readonly property var trends: engine ? engine.trends : ({ hourly_hr: [] })
  readonly property string errMsg: engine ? (engine.lastError || engine.snapshotError) : ""

  property real pulseAlpha: 1.0
  SequentialAnimation {
    running: root.liveHrOn || root.gesturesConnecting || (root.attitude && root.attitude.calibration_stage !== null)
    loops: Animation.Infinite
    NumberAnimation { target: root; property: "pulseAlpha"; from: 1.0; to: 0.45; duration: 650; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulseAlpha"; from: 0.45; to: 1.0; duration: 650; easing.type: Easing.InOutSine }
  }

  readonly property color barIconTint: {
    if (gesturesActive) return accentCyan
    if (gesturesConnecting) return warnColor
    if (liveHrOn) return okColor
    return bar ? bar.barForeground : Commons.Color.foreground
  }

  readonly property string barTooltip: {
    if (!online) return "Oura Ring · Daemon starting…"
    var parts = ["Oura Ring"]
    if (battery >= 0) parts.push((charging ? "⚡" : "") + battery + "%")
    if (displayHr > 0) parts.push(displayHr + " bpm")
    if (gesturesOn && engine) {
      parts.push("Gestures ON (" + engine.formatCountdown(engine.gesturesRemainingSec) + ")")
    } else {
      parts.push("Right-click: Toggle Gestures")
    }
    return parts.join(" · ")
  }

  readonly property string heroMeta: {
    if (!online) return "DAEMON STARTING…"
    if (engine && engine.daemonState === "syncing") return "SYNCING RING…"
    if (engine && engine.daemonState === "connecting_gestures") return "CONNECTING ACM…"
    if (liveHrOn) return "MEASURING LIVE HR…"
    if (gesturesOn && engine) return "GESTURES ACTIVE · " + engine.formatCountdown(engine.gesturesRemainingSec)
    return engine ? engine.formatAge(engine.lastSyncUnix).toUpperCase() : "IDLE"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    tooltipText: root.barTooltip
    active: root.gesturesOn || root.liveHrOn
    activeColor: root.barIconTint
    opacity: (root.liveHrOn || (root.attitude && root.attitude.calibration_stage !== null)) ? root.pulseAlpha : 1.0
    iconComponent: Component {
      Item {
        OuraIcon {
          anchors.centerIn: parent
          iconSize: Style.space(14)
          color: root.barIconTint
          accentColor: root.accentCyan
          active: root.gesturesOn
        }
      }
    }
    onPressed: function(mouseBtn) {
      if (mouseBtn === Qt.RightButton && root.engine) {
        root.engine.toggleGestures()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(364))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      ColumnLayout {
        id: column
        width: parent.width
        spacing: Style.space(10)

      // ---- Hero Header ----
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        OuraIcon {
          iconSize: Style.space(18)
          color: root.gesturesOn ? root.accentCyan : root.foreground
          accentColor: root.accentCyan
          active: root.gesturesOn
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            text: root.engine ? root.engine.ringName : "Oura Ring"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.space(13)
            font.weight: Font.DemiBold
          }
          Text {
            text: root.heroMeta
            color: root.gesturesOn ? root.accentCyan : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.space(9.5)
            font.letterSpacing: 0.7
          }
        }

        // Battery badge
        Rectangle {
          visible: root.battery >= 0
          radius: Style.space(6)
          color: root.cardBg
          border.width: 1
          border.color: root.cardBorder
          implicitWidth: batText.implicitWidth + Style.space(12)
          implicitHeight: Style.space(24)

          Text {
            id: batText
            anchors.centerIn: parent
            text: (root.charging ? "⚡ " : "") + root.battery + "%"
            color: root.battery <= 20 ? root.warnColor : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            font.weight: Font.Medium
          }
        }

        // Sync button
        Rectangle {
          radius: Style.space(6)
          color: syncMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14) : root.cardBg
          border.width: 1
          border.color: root.cardBorder
          implicitWidth: syncLbl.implicitWidth + Style.space(14)
          implicitHeight: Style.space(24)

          Text {
            id: syncLbl
            anchors.centerIn: parent
            text: (root.engine && root.engine.daemonState === "syncing") ? "Syncing…" : "Sync"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.space(10.5)
            font.weight: Font.Medium
          }

          MouseArea {
            id: syncMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.engine) root.engine.syncNow()
          }
        }
      }

      // ---- Error Banner ----
      Rectangle {
        visible: root.errMsg !== ""
        Layout.fillWidth: true
        radius: Style.space(6)
        color: Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.14)
        border.width: 1
        border.color: Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.35)
        implicitHeight: errLbl.implicitHeight + Style.space(10)

        Text {
          id: errLbl
          anchors.fill: parent
          anchors.margins: Style.space(5)
          text: root.errMsg
          color: root.warnColor
          font.family: root.fontFamily
          font.pixelSize: Style.space(10)
          wrapMode: Text.Wrap
        }
      }

      // ---- Vitals Row (HR / HRV / Temp) ----
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        // Heart Rate card
        Rectangle {
          Layout.fillWidth: true
          radius: Style.space(8)
          color: root.cardBg
          border.width: 1
          border.color: root.liveHrOn ? root.okColor : root.cardBorder
          implicitHeight: Style.space(56)

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(2)

            RowLayout {
              Layout.fillWidth: true
              Text {
                text: root.liveHrOn ? "LIVE HR" : "HEART RATE"
                color: root.liveHrOn ? root.okColor : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.space(9)
                font.letterSpacing: 0.6
                Layout.fillWidth: true
              }
              Text {
                text: root.liveHrOn ? "●" : "Live"
                color: root.liveHrOn ? root.okColor : root.accentCyan
                font.family: root.fontFamily
                font.pixelSize: Style.space(9.5)
                font.weight: Font.DemiBold
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.engine && !root.liveHrOn) root.engine.measureLiveHr(15)
                }
              }
            }

            Text {
              text: root.displayHr > 0 ? (root.displayHr + " bpm") : "--"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.space(16)
              font.weight: Font.Bold
            }
          }
        }

        // Overnight HRV card
        Rectangle {
          Layout.fillWidth: true
          radius: Style.space(8)
          color: root.cardBg
          border.width: 1
          border.color: root.cardBorder
          implicitHeight: Style.space(56)

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(2)

            Text {
              text: "HRV (RMSSD)"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(9)
              font.letterSpacing: 0.6
            }
            Text {
              text: (root.trends && root.trends.overnight_hrv_ms) ? (root.trends.overnight_hrv_ms + " ms") : "--"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.space(16)
              font.weight: Font.Bold
            }
          }
        }

        // Skin Temp card
        Rectangle {
          Layout.fillWidth: true
          radius: Style.space(8)
          color: root.cardBg
          border.width: 1
          border.color: root.cardBorder
          implicitHeight: Style.space(56)

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(2)

            Text {
              text: "SKIN TEMP"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(9)
              font.letterSpacing: 0.6
            }
            Text {
              text: (root.trends && root.trends.skin_temp_c) ? (Number(root.trends.skin_temp_c).toFixed(1) + "°C") : "--"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.space(16)
              font.weight: Font.Bold
            }
          }
        }
      }

      // ---- Today's HR Trend Chart ----
      Rectangle {
        Layout.fillWidth: true
        radius: Style.space(8)
        color: root.cardBg
        border.width: 1
        border.color: root.cardBorder
        implicitHeight: Style.space(106)

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(4)

          RowLayout {
            Layout.fillWidth: true
            Text {
              text: "TODAY'S HEART RATE"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(9.5)
              font.letterSpacing: 0.7
              Layout.fillWidth: true
            }
            Text {
              text: (root.trends && root.trends.hr_min && root.trends.hr_max)
                ? ("min " + root.trends.hr_min + " · avg " + root.trends.hr_avg + " · max " + root.trends.hr_max)
                : "No samples yet today"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(9.5)
            }
          }

          Canvas {
            id: trendCanvas
            Layout.fillWidth: true
            Layout.fillHeight: true
            antialiasing: true

            property var bars: (root.trends && Array.isArray(root.trends.hourly_hr)) ? root.trends.hourly_hr : []
            onBarsChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var w = width
              var h = height
              if (w <= 0 || h <= 0) return

              var padL = 2
              var padR = 2
              var padT = 6
              var padB = 14
              var plotW = w - padL - padR
              var plotH = h - padT - padB

              // Subtle 6h vertical grid + hour labels
              ctx.strokeStyle = root.isLight ? "rgba(0,0,0,0.08)" : "rgba(255,255,255,0.08)"
              ctx.fillStyle = root.isLight ? "rgba(0,0,0,0.45)" : "rgba(255,255,255,0.45)"
              ctx.font = Math.round(Style.space(8.5)) + "px " + root.fontFamily
              ctx.lineWidth = 1
              var ticks = [0, 6, 12, 18, 23]
              for (var ti = 0; ti < ticks.length; ti++) {
                var hrTick = ticks[ti]
                var tx = padL + (hrTick / 23.0) * plotW
                ctx.beginPath()
                ctx.moveTo(tx, padT)
                ctx.lineTo(tx, padT + plotH)
                ctx.stroke()
                var lbl = hrTick === 0 ? "00" : (hrTick < 10 ? "0" + hrTick : String(hrTick))
                ctx.fillText(lbl, Math.min(w - 14, Math.max(0, tx - 5)), h - 2)
              }

              if (!bars || bars.length === 0) return

              var yMin = 42
              var yMax = 115
              for (var i = 0; i < bars.length; i++) {
                if (bars[i].p5 < yMin) yMin = Math.max(30, bars[i].p5 - 4)
                if (bars[i].p95 > yMax) yMax = Math.min(200, bars[i].p95 + 6)
              }
              var span = Math.max(20, yMax - yMin)
              var yFor = function(bpm) {
                return padT + plotH - ((bpm - yMin) / span) * plotH
              }

              // Draw p5..p95 vertical capsules per hour
              var barW = Math.max(3, (plotW / 24.0) * 0.48)
              ctx.fillStyle = root.isLight ? "rgba(10,126,164,0.28)" : "rgba(63,224,255,0.28)"
              for (var j = 0; j < bars.length; j++) {
                var b = bars[j]
                var bx = padL + (b.hour / 23.0) * plotW - barW * 0.5
                var yTop = yFor(b.p95)
                var yBot = yFor(b.p5)
                var bh = Math.max(3, yBot - yTop)
                ctx.fillRect(bx, yTop, barW, bh)
              }

              // Draw mean curve
              ctx.strokeStyle = root.accentCyan
              ctx.lineWidth = 1.6
              ctx.beginPath()
              for (var k = 0; k < bars.length; k++) {
                var bk = bars[k]
                var px = padL + (bk.hour / 23.0) * plotW
                var py = yFor(bk.mean)
                if (k === 0) ctx.moveTo(px, py)
                else ctx.lineTo(px, py)
              }
              ctx.stroke()

              // Draw mean dots
              ctx.fillStyle = root.accentCyan
              for (var m = 0; m < bars.length; m++) {
                var bm = bars[m]
                ctx.beginPath()
                ctx.arc(padL + (bm.hour / 23.0) * plotW, yFor(bm.mean), 2.1, 0, Math.PI * 2)
                ctx.fill()
              }
            }
          }
        }
      }

      // ---- Gesture Navigation Card ----
      Rectangle {
        Layout.fillWidth: true
        radius: Style.space(8)
        color: root.cardBg
        border.width: 1
        border.color: root.gesturesOn ? Qt.rgba(root.accentCyan.r, root.accentCyan.g, root.accentCyan.b, 0.45) : root.cardBorder
        implicitHeight: gestureCol.implicitHeight + Style.space(16)

        ColumnLayout {
          id: gestureCol
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(8)

          // Header + Toggle Switch
          RowLayout {
            Layout.fillWidth: true

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(1)
              Text {
                text: root.gesturesConnecting
                  ? "SPACE GESTURES · CONNECTING…"
                  : (root.gesturesActive ? "SPACE GESTURES · ACTIVE" : "SPACE GESTURES")
                color: root.gesturesConnecting
                  ? root.warnColor
                  : (root.gesturesActive ? root.accentCyan : root.foreground)
                font.family: root.fontFamily
                font.pixelSize: Style.space(10)
                font.weight: Font.DemiBold
                font.letterSpacing: 0.7
              }
              Text {
                text: {
                  if (root.gesturesConnecting) return "Waking BLE link (click switch to cancel)…"
                  if (root.gesturesActive && root.engine) {
                    if (root.attitude && root.attitude.nav_armed) {
                      var remS = (Number(root.attitude.nav_armed_ms || 0) / 1000.0).toFixed(1)
                      return "ARMED (" + remS + "s) · Brisk slap ↔ to switch Spaces"
                    }
                    var hz = root.attitude && root.attitude.acm_hz ? (root.attitude.acm_hz + " Hz · ") : ""
                    return hz + "Palm-up + lift ↑ to open Mission Control"
                  }
                  return "Click to connect ring & enable air gestures"
                }
                color: root.gesturesConnecting
                  ? root.warnColor
                  : ((root.attitude && root.attitude.nav_armed) ? root.okColor : root.dim)
                font.family: root.fontFamily
                font.pixelSize: Style.space(9.5)
              }
            }

            Rectangle {
              radius: Style.space(11)
              implicitWidth: Style.space(42)
              implicitHeight: Style.space(22)
              opacity: root.gesturesConnecting ? root.pulseAlpha : 1.0
              color: root.gesturesActive
                ? root.accentCyan
                : (root.gesturesConnecting
                  ? root.warnColor
                  : (root.isLight ? Qt.rgba(0, 0, 0, 0.16) : Qt.rgba(1, 1, 1, 0.18)))

              Rectangle {
                width: Style.space(16)
                height: Style.space(16)
                radius: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                x: (root.gesturesOn || root.gesturesConnecting)
                  ? parent.width - width - Style.space(3)
                  : Style.space(3)
                color: "#ffffff"
                Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.engine) {
                  var wantOn = !(root.gesturesOn || root.gesturesConnecting)
                  root.engine.setGestures(wantOn)
                }
              }
            }
          }

          // Ring Runner-style Attitude Reticle + Live Readout (visible when Gesture Mode is active)
          RowLayout {
            visible: root.gesturesActive
            Layout.fillWidth: true
            spacing: Style.space(10)

            Canvas {
              id: reticleCanvas
              implicitWidth: Style.space(88)
              implicitHeight: Style.space(88)
              antialiasing: true

              property real axG: root.attitude ? Number(root.attitude.accel_h_g || 0) : 0
              property real ayG: root.attitude ? Number(root.attitude.accel_up_g || 0) : 0
              property real swipeG: root.gcfg ? Number(root.gcfg.swipe_accel_g || 0.75) : 0.75
              property bool armed: !!(root.attitude && root.attitude.nav_armed)
              property bool inverted: !!(root.attitude && root.attitude.palm_inverted)

              onAxGChanged: requestPaint()
              onAyGChanged: requestPaint()
              onSwipeGChanged: requestPaint()
              onArmedChanged: requestPaint()
              onInvertedChanged: requestPaint()

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var w = width
                var h = height
                var cx = w * 0.5
                var cy = h * 0.5
                var maxR = Math.min(w, h) * 0.45
                var maxG = 1.4

                // Outer ring (green when Armed, amber when Palm-Up ready to lift, cyan in Standby)
                ctx.strokeStyle = armed
                  ? root.okColor
                  : (inverted ? root.warnColor : (root.isLight ? "rgba(10,126,164,0.38)" : "rgba(63,224,255,0.38)"))
                ctx.lineWidth = armed ? 1.8 : 1.2
                ctx.beginPath()
                ctx.arc(cx, cy, maxR, 0, Math.PI * 2)
                ctx.stroke()

                // Swipe acceleration threshold ring
                var rSw = Math.min(maxR, (swipeG / maxG) * maxR)
                ctx.strokeStyle = root.isLight ? "rgba(10,126,164,0.25)" : "rgba(63,224,255,0.25)"
                ctx.lineWidth = 1
                ctx.beginPath()
                ctx.arc(cx, cy, rSw, 0, Math.PI * 2)
                ctx.stroke()

                // Crosshairs
                ctx.strokeStyle = root.isLight ? "rgba(0,0,0,0.12)" : "rgba(255,255,255,0.12)"
                ctx.beginPath()
                ctx.moveTo(cx - maxR, cy)
                ctx.lineTo(cx + maxR, cy)
                ctx.moveTo(cx, cy - maxR)
                ctx.lineTo(cx, cy + maxR)
                ctx.stroke()

                // Live acceleration impulse dot (axG = left/right, ayG = up/down)
                var dx = Math.max(-1, Math.min(1, axG / maxG)) * maxR
                var dy = -Math.max(-1, Math.min(1, ayG / maxG)) * maxR
                ctx.fillStyle = armed ? root.okColor : (inverted ? root.warnColor : root.accentCyan)
                ctx.beginPath()
                ctx.arc(cx + dx, cy + dy, 4.5, 0, Math.PI * 2)
                ctx.fill()
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)

              Text {
                text: {
                  var st = root.attitude ? root.attitude.calibration_stage : null
                  if (st === "hold_neutral") return "HOLD PALM-DOWN (1.5s)…"
                  if (st === "tilt_right") return "TILT / FLICK RIGHT ONCE…"
                  if (root.attitude && root.attitude.nav_armed) return "ARMED · Slap ↔ to switch"
                  if (root.attitude && root.attitude.palm_inverted) return "PALM UP · Lift ↑ for MC"
                  if (root.engine && root.engine.lastGesture) {
                    return "Last: " + root.engine.lastGesture.replace(/_/g, " ")
                  }
                  return "Standby (palm down)"
                }
                color: (root.attitude && root.attitude.calibration_stage)
                  ? root.warnColor
                  : ((root.attitude && root.attitude.nav_armed) ? root.okColor : root.foreground)
                font.family: root.fontFamily
                font.pixelSize: Style.space(10.5)
                font.weight: Font.Medium
              }

              Text {
                text: "↔ " + Number(root.attitude ? (root.attitude.accel_h_g || 0) : 0).toFixed(2) + "g · ↑ "
                  + Number(root.attitude ? (root.attitude.accel_up_g || 0) : 0).toFixed(2) + "g · "
                  + (root.attitude && root.attitude.acm_hz ? (root.attitude.acm_hz + " Hz") : "0 Hz")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.space(9.5)
              }

              RowLayout {
                spacing: Style.space(6)

                Rectangle {
                  radius: Style.space(5)
                  color: zeroMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14) : root.cardBg
                  border.width: 1
                  border.color: root.cardBorder
                  implicitWidth: zeroLbl.implicitWidth + Style.space(12)
                  implicitHeight: Style.space(22)
                  Text {
                    id: zeroLbl
                    anchors.centerIn: parent
                    text: "Zero"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(10)
                  }
                  MouseArea {
                    id: zeroMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.engine) root.engine.zeroNeutral()
                  }
                }

                Rectangle {
                  radius: Style.space(5)
                  color: calMouse.containsMouse ? Qt.rgba(root.accentCyan.r, root.accentCyan.g, root.accentCyan.b, 0.22) : root.cardBg
                  border.width: 1
                  border.color: Qt.rgba(root.accentCyan.r, root.accentCyan.g, root.accentCyan.b, 0.4)
                  implicitWidth: calLbl.implicitWidth + Style.space(12)
                  implicitHeight: Style.space(22)
                  Text {
                    id: calLbl
                    anchors.centerIn: parent
                    text: "Calibrate"
                    color: root.accentCyan
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(10)
                  }
                  MouseArea {
                    id: calMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.engine) root.engine.calibrate()
                  }
                }
              }
            }
          }

          // Quick Settings Row (Invert H, Big Tilt MC, Threshold H)
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            // Invert horizontal toggle pill
            Rectangle {
              radius: Style.space(5)
              color: (root.gcfg && root.gcfg.invert_h)
                ? Qt.rgba(root.accentCyan.r, root.accentCyan.g, root.accentCyan.b, 0.18)
                : root.cardBg
              border.width: 1
              border.color: (root.gcfg && root.gcfg.invert_h) ? root.accentCyan : root.cardBorder
              implicitWidth: invLbl.implicitWidth + Style.space(12)
              implicitHeight: Style.space(22)

              Text {
                id: invLbl
                anchors.centerIn: parent
                text: "Invert ↔"
                color: (root.gcfg && root.gcfg.invert_h) ? root.accentCyan : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.space(9.5)
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.engine) root.engine.updateConfig({ invert_h: !(root.gcfg && root.gcfg.invert_h) })
              }
            }

            // Lift-to-Arm Mission Control gate toggle pill
            Rectangle {
              radius: Style.space(5)
              color: (root.gcfg && root.gcfg.require_lift_to_arm)
                ? Qt.rgba(root.accentCyan.r, root.accentCyan.g, root.accentCyan.b, 0.18)
                : root.cardBg
              border.width: 1
              border.color: (root.gcfg && root.gcfg.require_lift_to_arm) ? root.accentCyan : root.cardBorder
              implicitWidth: mcLbl.implicitWidth + Style.space(12)
              implicitHeight: Style.space(22)

              Text {
                id: mcLbl
                anchors.centerIn: parent
                text: "Lift ↑ MC"
                color: (root.gcfg && root.gcfg.require_lift_to_arm) ? root.accentCyan : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.space(9.5)
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.engine) {
                  root.engine.updateConfig({ require_lift_to_arm: !(root.gcfg && root.gcfg.require_lift_to_arm) })
                }
              }
            }

            Item { Layout.fillWidth: true }

            // Swipe acceleration threshold stepper (in g)
            Text {
              text: "Force " + Number(root.gcfg ? (root.gcfg.swipe_accel_g || 0.75) : 0.75).toFixed(2) + "g"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(9.5)
            }
            Rectangle {
              radius: Style.space(4)
              color: root.cardBg
              border.width: 1
              border.color: root.cardBorder
              implicitWidth: Style.space(20)
              implicitHeight: Style.space(20)
              Text {
                anchors.centerIn: parent
                text: "−"
                color: root.foreground
                font.pixelSize: Style.space(11)
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.engine) {
                  var cur = Number(root.gcfg ? (root.gcfg.swipe_accel_g || 0.75) : 0.75)
                  root.engine.updateConfig({ swipe_accel_g: Math.max(0.45, Math.round((cur - 0.1) * 100) / 100) })
                }
              }
            }
            Rectangle {
              radius: Style.space(4)
              color: root.cardBg
              border.width: 1
              border.color: root.cardBorder
              implicitWidth: Style.space(20)
              implicitHeight: Style.space(20)
              Text {
                anchors.centerIn: parent
                text: "+"
                color: root.foreground
                font.pixelSize: Style.space(11)
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.engine) {
                  var cur = Number(root.gcfg ? (root.gcfg.swipe_accel_g || 0.75) : 0.75)
                  root.engine.updateConfig({ swipe_accel_g: Math.min(1.6, Math.round((cur + 0.1) * 100) / 100) })
                }
              }
            }
          }
        }
      }
    }
    }
  }
}
