#!/usr/bin/env python3
"""Patch Omarchy shell BarModel.js, Bar.qml, and clock/BarWidget.qml for the
MacBook Dynamic Island notch capsule and split bar layout.

On notched top-bar displays (e.g. MacBook Air M2 eDP-1 at 2560x1664):
- Match the bar height to the physical notch height via BarModel.notchFloor.
- Render a pure-black (#000000) Dynamic Island notch capsule flush with y=0,
  with concave top fillets and rounded bottom corners, expanding horizontally
  into live ears for Murmure dictation (waveform + REC/Transcribing) and
  MPRIS Media (album art + animated equalizer bars, click to play/pause).
- Keep `centerBegin` widgets (indicators, appearance) directly to the left of
  the notch capsule and `centerEnd` widgets (world clock, weather) directly to
  its right.
- Move `center` (clock/date) to the far right edge of the bar with abbreviated
  weekday (`dddd` -> `ddd`), and place `right` status icons immediately to its
  left.
- Non-notched displays (external monitors, VMs) keep the standard centered
  layout and full clock format untouched.
"""

import pathlib
import sys


def replace_once(src: str, old: str, new: str, label: str) -> str:
    count = src.count(old)
    if count != 1:
        raise RuntimeError(f"Expected 1 match for {label}, found {count}")
    return src.replace(old, new, 1)


def patch_bar_model(out_dir: pathlib.Path) -> None:
    model_js = out_dir / "shell" / "plugins" / "bar" / "BarModel.js"
    src = model_js.read_text(encoding="utf-8")

    # 1. Preserve optional physical `cutoutWidth` in parseCutouts.
    src = replace_once(
        src,
        "    cutouts.push({ connector: panel.connector, width: width, height: height, top: top })",
        """    var cutoutWidth = Number(panel.cutoutWidth)
    cutouts.push({
      connector: panel.connector,
      width: width,
      height: height,
      top: top,
      cutoutWidth: cutoutWidth > 0 && cutoutWidth < width ? cutoutWidth : 0
    })""",
        "BarModel.parseCutouts cutoutWidth",
    )

    # 2. Add cutoutWidth(...) helper mirroring cutoutTop(...).
    src = replace_once(
        src,
        """// The height a top bar on this screen must reach to cover its cutout, or a""",
        """// The width of the top cutout on this screen, in logical pixels, or 0.
function cutoutWidth(cutouts, screenName, logicalWidth, logicalHeight, devicePixelRatio, mode) {
  var name = String(screenName || "")
  var logical = Number(logicalWidth)
  var logicalTall = Number(logicalHeight)
  if (!(logical > 0) || !(logicalTall > 0)) return 0
  var width = Number(mode && mode.width)
  var height = Number(mode && mode.height)
  if (width > 0 && height > 0) {
    var transform = Number(mode.transform) || 0
    if (transform !== 0 && transform !== 4) return 0
    if ((width > height) !== (logical > logicalTall)) return 0
  } else {
    var scale = Number(devicePixelRatio) > 0 ? Number(devicePixelRatio) : 1
    width = Math.round(logical * scale)
    height = Math.round(logicalTall * scale)
  }
  var list = Array.isArray(cutouts) ? cutouts : []
  for (var i = 0; i < list.length; i++) {
    var panel = list[i]
    if (name.indexOf(panel.connector) !== 0) continue
    if (Math.abs(width - panel.width) <= 4 && Math.abs(height - panel.height) <= 4) {
      var phys = Number(panel.cutoutWidth) > 0 ? Number(panel.cutoutWidth) : 304
      return Math.ceil(phys * logical / width)
    }
  }
  return 0
}

// The height a top bar on this screen must reach to cover its cutout, or a""",
        "BarModel.cutoutWidth helper",
    )

    # 3. Export cutoutWidth in module.exports.
    src = replace_once(
        src,
        "    cutoutTop: cutoutTop,",
        """    cutoutTop: cutoutTop,
    cutoutWidth: cutoutWidth,""",
        "BarModel.js module.exports cutoutWidth",
    )

    model_js.write_text(src, encoding="utf-8")


def patch_bar_qml(out_dir: pathlib.Path) -> None:
    bar_qml = out_dir / "shell" / "plugins" / "bar" / "Bar.qml"
    src = bar_qml.read_text(encoding="utf-8")

    # 0. Import Mpris so the notch capsule can render live Media ears.
    src = replace_once(
        src,
        "import Quickshell.Wayland",
        "import Quickshell.Wayland\nimport Quickshell.Services.Mpris",
        "Bar.qml Mpris import",
    )

    # 1. Expose notchWidth and notchSplitLayout on BarPanel (barWindow).
    src = replace_once(
        src,
        """    readonly property bool portraitCompact: !root.vertical && screen !== null && (screen.height > screen.width || (width > 0 && width < 720))
    property bool portraitRightExpanded: false
    onPortraitCompactChanged: if (!portraitCompact) portraitRightExpanded = false""",
        """    readonly property bool portraitCompact: !root.vertical && screen !== null && (screen.height > screen.width || (width > 0 && width < 720))
    readonly property int notchWidth: BarModel.cutoutWidth(root.displayCutouts, screen.name, screen.width, screen.height, screen.devicePixelRatio, panelMode)
    readonly property bool notchSplitLayout: centerBesideRight && !portraitCompact
    property bool portraitRightExpanded: false
    onPortraitCompactChanged: if (!portraitCompact) portraitRightExpanded = false""",
        "BarPanel notchSplitLayout properties",
    )

    # 2. Update RightModules anchoring and replace centerBesideRight CenterSections
    #    with pure-black Dynamic Island notch capsule (with Murmure & Media ears)
    #    plus split notch layout (centerBegin left, centerEnd right, clock far right).
    old_block = """        RightModules {
          window: barWindow
          pool: horizontalPool
          id: rightModules
          visible: !barWindow.portraitCompact || barWindow.portraitRightExpanded
          anchors.right: barWindow.portraitCompact ? portraitRightToggle.left : parent.right
          anchors.rightMargin: barWindow.portraitCompact ? Style.space(4) : Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        Item {
          id: portraitRightToggle
          visible: barWindow.portraitCompact
          width: visible ? Math.max(24, barWindow.thickness) : 0
          height: barWindow.thickness
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter

          Rectangle {
            anchors.centerIn: parent
            width: Math.max(22, barWindow.thickness - 4)
            height: Math.max(18, barWindow.thickness - 6)
            radius: Style.cornerRadius
            color: toggleHover.hovered || barWindow.portraitRightExpanded
              ? Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, barWindow.portraitRightExpanded ? 0.18 : 0.12)
              : "transparent"

            Text {
              anchors.centerIn: parent
              text: barWindow.portraitRightExpanded ? "›" : "‹"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Math.max(14, Style.font.body + 2)
              font.weight: Font.DemiBold
            }
          }

          HoverHandler { id: toggleHover }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: barWindow.portraitRightExpanded = !barWindow.portraitRightExpanded
          }
        }

        // Where a display notch covers the middle of the bar, the center
        // sections run on just left of the right one. They keep their regions,
        // so settings pushes, drag and drop, and panel routing still address
        // them. The gap lets a drop at the seam land in the section the pointer
        // is nearer to.
        CenterSections {
          window: barWindow
          pool: horizontalPool
          active: barWindow.centerBesideRight && !barWindow.portraitCompact
          besideRight: true
          anchors.right: rightModules.left
          anchors.rightMargin: Style.space(4)
          anchors.top: parent.top
          anchors.bottom: parent.bottom
        }"""

    new_block = """        // Pure-black Dynamic Island notch capsule flush with y=0, expanding
        // smoothly into left/right ears for Murmure dictation and MPRIS Media.
        Item {
          id: notchSpacer
          visible: barWindow.notchSplitLayout
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.bottom: parent.bottom

          readonly property var murmureSvc: (root.shell && typeof root.shell.serviceFor === "function")
            ? root.shell.serviceFor("th0rgal.murmure") : null
          readonly property string murmureState: murmureSvc ? String(murmureSvc.dictState || "idle") : "idle"
          readonly property string murmureLang: murmureSvc ? String(murmureSvc.language || "en").toUpperCase() : "EN"
          readonly property var murmureLevels: (murmureSvc && murmureSvc.levels) ? murmureSvc.levels : []
          readonly property bool murmureActive: barWindow.notchSplitLayout && (murmureState === "recording" || murmureState === "transcribing")

          readonly property var mprisList: Mpris.players ? Mpris.players.values : []
          readonly property var playingPlayer: {
            if (!barWindow.notchSplitLayout) return null
            var list = mprisList || []
            for (var i = 0; i < list.length; i++) {
              var p = list[i]
              if (p && p.isPlaying) return p
            }
            return null
          }
          readonly property bool mediaActive: !murmureActive && playingPlayer !== null
          readonly property string mediaArtUrl: playingPlayer ? String(playingPlayer.trackArtUrl || "") : ""
          readonly property string mediaTitle: playingPlayer ? String(playingPlayer.trackTitle || "") : ""
          readonly property string mediaArtist: playingPlayer ? String(playingPlayer.trackArtist || "") : ""
          readonly property string mediaTooltip: {
            if (!playingPlayer) return ""
            if (mediaTitle && mediaArtist) return mediaTitle + " — " + mediaArtist
            return mediaTitle || String(playingPlayer.identity || "Now Playing")
          }

          readonly property int earWidth: {
            if (!barWindow.notchSplitLayout) return 0
            if (murmureActive) return murmureState === "recording" ? 54 : 42
            if (mediaActive) return 38
            return 0
          }
          readonly property int targetWidth: barWindow.notchSplitLayout
            ? (barWindow.notchWidth + earWidth * 2)
            : 0

          width: targetWidth
          Behavior on width {
            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
          }

          property real eqPhase: 0.0
          Timer {
            interval: 85
            repeat: true
            running: notchSpacer.mediaActive || notchSpacer.murmureActive
            onTriggered: notchSpacer.eqPhase = (notchSpacer.eqPhase + 0.48) % (Math.PI * 20)
          }

          function syncNotchPeekEdge() {
            if (barWindow.notchSplitLayout)
              barWindow.peekEdge = BarModel.nextPeekEdge(barWindow.peekEdge, x, root.centerSectionRevealHeld)
          }

          onXChanged: syncNotchPeekEdge()
          onVisibleChanged: syncNotchPeekEdge()
          Component.onCompleted: syncNotchPeekEdge()

          Connections {
            target: root
            function onCenterSectionRevealHeldChanged() { notchSpacer.syncNotchPeekEdge() }
          }

          // Left concave top-outer fillet so the black capsule melts into the top bezel.
          Canvas {
            id: leftFillet
            visible: notchSpacer.visible
            width: 10
            height: 10
            anchors.right: capsuleBody.left
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

          // Right concave top-outer fillet.
          Canvas {
            id: rightFillet
            visible: notchSpacer.visible
            width: 10
            height: 10
            anchors.left: capsuleBody.right
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

          // Pure-black capsule body (flat top at y=0, 11px rounded bottom corners).
          Item {
            id: capsuleBody
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

            // ---- LEFT EAR: Murmure waveform OR Media album art ----
            Item {
              id: leftEar
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Math.max(0, Math.floor((parent.width - barWindow.notchWidth) / 2) - 10)
              visible: width >= 18
              clip: true

              // Murmure left ear: pulsing red dot + 6-bar waveform (recording) OR spinning arc (transcribing)
              Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                spacing: 5
                visible: notchSpacer.murmureActive
                opacity: notchSpacer.murmureActive ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 150 } }

                Rectangle {
                  width: 6
                  height: 6
                  radius: 3
                  anchors.verticalCenter: parent.verticalCenter
                  visible: notchSpacer.murmureState === "recording"
                  color: "#ff453a"
                  opacity: 0.55 + 0.45 * Math.sin(notchSpacer.eqPhase * 1.1)
                }

                Row {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 2
                  visible: notchSpacer.murmureState === "recording"
                  Repeater {
                    model: 6
                    Rectangle {
                      width: 2.5
                      radius: 1.25
                      anchors.verticalCenter: parent.verticalCenter
                      color: "#ffffff"
                      opacity: 0.92
                      height: {
                        var lv = notchSpacer.murmureLevels
                        var raw = (lv && lv.length > 0)
                          ? Number(lv[Math.min(lv.length - 1, Math.floor(index * lv.length / 6))] || 0)
                          : 0
                        var wave = 0.25 + 0.55 * Math.abs(Math.sin(notchSpacer.eqPhase * 1.4 + index * 0.9))
                        var v = Math.max(raw, wave * 0.35)
                        return Math.max(4, Math.min(16, Math.round(4 + v * 12)))
                      }
                      Behavior on height { NumberAnimation { duration: 70 } }
                    }
                  }
                }

                // Transcribing spinner ring
                Canvas {
                  id: transcribeSpinner
                  visible: notchSpacer.murmureState === "transcribing"
                  width: 16
                  height: 16
                  anchors.verticalCenter: parent.verticalCenter
                  antialiasing: true

                  property real angle: notchSpacer.eqPhase * 1.6
                  onAngleChanged: if (visible) requestPaint()

                  onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var cx = width / 2
                    var cy = height / 2
                    var r = 5.5
                    ctx.lineWidth = 2.0
                    ctx.lineCap = "round"
                    ctx.strokeStyle = "rgba(255, 255, 255, 0.22)"
                    ctx.beginPath()
                    ctx.arc(cx, cy, r, 0, Math.PI * 2, false)
                    ctx.stroke()

                    ctx.strokeStyle = "#ffd60a"
                    ctx.beginPath()
                    ctx.arc(cx, cy, r, angle, angle + Math.PI * 1.15, false)
                    ctx.stroke()
                  }
                }
              }

              // Media left ear: rounded 20x20 album art (with note fallback)
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                width: 20
                height: 20
                radius: 5
                color: "#1e1e22"
                clip: true
                visible: notchSpacer.mediaActive
                opacity: notchSpacer.mediaActive ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 150 } }

                Image {
                  anchors.fill: parent
                  source: notchSpacer.mediaArtUrl
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  visible: status === Image.Ready
                }

                Text {
                  anchors.centerIn: parent
                  text: "󰎈"
                  color: "#d4d4d8"
                  font.family: root.fontFamily
                  font.pixelSize: 12
                  visible: notchSpacer.mediaArtUrl === ""
                }
              }
            }

            // ---- RIGHT EAR: Murmure label OR Media equalizer ----
            Item {
              id: rightEar
              anchors.right: parent.right
              anchors.rightMargin: 10
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Math.max(0, Math.floor((parent.width - barWindow.notchWidth) / 2) - 10)
              visible: width >= 18
              clip: true

              // Murmure right ear: compact language badge (recording) OR 3-dot wave (transcribing)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                visible: notchSpacer.murmureActive && notchSpacer.murmureState === "recording"
                opacity: visible ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 150 } }
                text: notchSpacer.murmureLang
                textFormat: Text.PlainText
                color: "#ffffff"
                font.family: Style.font.menuFamily || root.fontFamily
                font.pixelSize: 11
                font.weight: Font.DemiBold
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                spacing: 3.5
                visible: notchSpacer.murmureActive && notchSpacer.murmureState === "transcribing"
                opacity: visible ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 150 } }

                Repeater {
                  model: 3
                  Rectangle {
                    width: 4
                    height: 4
                    radius: 2
                    color: "#ffd60a"
                    property real pulse: 0.5 + 0.5 * Math.sin(notchSpacer.eqPhase * 1.5 - index * 0.95)
                    opacity: 0.35 + 0.65 * pulse
                    scale: 0.8 + 0.35 * pulse
                  }
                }
              }

              // Media right ear: 4 animated equalizer bars
              Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                spacing: 2.5
                visible: notchSpacer.mediaActive
                opacity: notchSpacer.mediaActive ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 150 } }

                Repeater {
                  model: 4
                  Rectangle {
                    width: 2.5
                    radius: 1.25
                    anchors.verticalCenter: parent.verticalCenter
                    color: "#30d158"
                    height: Math.round(4 + 10 * (0.2 + 0.8 * Math.abs(Math.sin(notchSpacer.eqPhase + index * 1.15))))
                    Behavior on height { NumberAnimation { duration: 75 } }
                  }
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              enabled: notchSpacer.mediaActive || notchSpacer.murmureActive
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              hoverEnabled: true
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onEntered: {
                if (notchSpacer.mediaActive && notchSpacer.mediaTooltip !== "")
                  root.showTooltip(capsuleBody, notchSpacer.mediaTooltip)
              }
              onExited: root.hideTooltip(capsuleBody)
              onClicked: function(mouse) {
                if (notchSpacer.murmureActive) {
                  if (notchSpacer.murmureSvc && typeof notchSpacer.murmureSvc.toggleDictation === "function")
                    notchSpacer.murmureSvc.toggleDictation()
                  return
                }
                if (notchSpacer.mediaActive && notchSpacer.playingPlayer) {
                  if (mouse.button === Qt.RightButton) {
                    if (notchSpacer.playingPlayer.canGoNext) notchSpacer.playingPlayer.next()
                  } else {
                    if (notchSpacer.playingPlayer.canTogglePlaying) notchSpacer.playingPlayer.togglePlaying()
                  }
                }
              }
            }
          }
        }

        ModuleList {
          id: notchCenterBegin
          keys: barWindow.notchSplitLayout ? root.layoutWidgets.sections.centerBegin : []
          window: barWindow.notchSplitLayout ? barWindow : null
          pool: horizontalPool
          region: "centerBegin"
          fixedEdge: "end"
          visible: barWindow.notchSplitLayout
          anchors.right: notchSpacer.left
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
        }

        ModuleList {
          id: notchCenterEnd
          keys: barWindow.notchSplitLayout ? root.layoutWidgets.sections.centerEnd : []
          window: barWindow.notchSplitLayout ? barWindow : null
          pool: horizontalPool
          region: "centerEnd"
          fixedEdge: "start"
          visible: barWindow.notchSplitLayout
          anchors.left: notchSpacer.right
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
        }

        CenterBox {
          id: notchCenterBox
          window: barWindow
          pool: horizontalPool
          active: barWindow.notchSplitLayout
          fixedEdge: "end"
          crossSize: parent.height
          visible: barWindow.notchSplitLayout
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.top: parent.top
          anchors.bottom: parent.bottom
        }

        RightModules {
          window: barWindow
          pool: horizontalPool
          id: rightModules
          visible: !barWindow.portraitCompact || barWindow.portraitRightExpanded
          anchors.right: barWindow.portraitCompact
            ? portraitRightToggle.left
            : (barWindow.notchSplitLayout ? notchCenterBox.left : parent.right)
          anchors.rightMargin: barWindow.portraitCompact
            ? Style.space(4)
            : (barWindow.notchSplitLayout ? Style.space(6) : Style.space(8))
          anchors.verticalCenter: parent.verticalCenter
        }

        Item {
          id: portraitRightToggle
          visible: barWindow.portraitCompact
          width: visible ? Math.max(24, barWindow.thickness) : 0
          height: barWindow.thickness
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter

          Rectangle {
            anchors.centerIn: parent
            width: Math.max(22, barWindow.thickness - 4)
            height: Math.max(18, barWindow.thickness - 6)
            radius: Style.cornerRadius
            color: toggleHover.hovered || barWindow.portraitRightExpanded
              ? Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, barWindow.portraitRightExpanded ? 0.18 : 0.12)
              : "transparent"

            Text {
              anchors.centerIn: parent
              text: barWindow.portraitRightExpanded ? "›" : "‹"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Math.max(14, Style.font.body + 2)
              font.weight: Font.DemiBold
            }
          }

          HoverHandler { id: toggleHover }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: barWindow.portraitRightExpanded = !barWindow.portraitRightExpanded
          }
        }"""

    src = replace_once(src, old_block, new_block, "horizontalBar notch split layout")
    bar_qml.write_text(src, encoding="utf-8")


def patch_clock_widget(out_dir: pathlib.Path) -> None:
    clock_qml = out_dir / "shell" / "plugins" / "panels" / "clock" / "BarWidget.qml"
    src = clock_qml.read_text(encoding="utf-8")

    # On notched displays the clock sits at the far right edge (`fixedEdge === "end"`).
    # Abbreviate full weekday names (`dddd` -> `ddd`, e.g. "wed 25 nov 14:58") to keep
    # the right side of the notch compact while external monitors keep the full format.
    src = replace_once(
        src,
        "  readonly property string activeFormat: configuredFormat",
        '  readonly property string activeFormat: !vertical && root.fixedEdge === "end"\n'
        '    ? configuredFormat.replace(/dddd/g, "ddd")\n'
        "    : configuredFormat",
        "clock BarWidget compact weekday on notched screens",
    )

    clock_qml.write_text(src, encoding="utf-8")


def main() -> None:
    out_dir = pathlib.Path(sys.argv[1])
    patch_bar_model(out_dir)
    patch_bar_qml(out_dir)
    patch_clock_widget(out_dir)


if __name__ == "__main__":
    main()
