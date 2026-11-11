import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "th0rgal.workspaces"

  readonly property int slots: 10
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/workspaces.json"
  property int persistentCount: 5

  function parseConfig(raw) {
    var text = String(raw || "").trim()
    if (!text) return
    try {
      var obj = JSON.parse(text)
      if (obj && typeof obj.persistentCount === "number") {
        var n = Math.floor(obj.persistentCount)
        if (n >= 1 && n <= root.slots) root.persistentCount = n
      }
    } catch (e) {
      console.warn("th0rgal.workspaces: failed to parse config: " + e)
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseConfig(text())
    onFileChanged: reload()
  }

  readonly property var monitor: {
    var window = root.QsWindow.window
    var screen = window ? window.screen : null
    return screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor
  }
  readonly property string monitorName: root.monitor ? root.monitor.name : ""

  function blockOf(id) {
    return Math.floor((id - 1) / root.slots)
  }

  function slotOf(id) {
    return (id - 1) % root.slots + 1
  }

  function activeWorkspaceId() {
    return root.monitor && root.monitor.activeWorkspace ? root.monitor.activeWorkspace.id : -1
  }

  readonly property int block: {
    var active = root.activeWorkspaceId()
    return active > 0 ? root.blockOf(active) : 0
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function workspaceIds() {
    var base = root.block * root.slots
    var ids = []
    for (var p = 1; p <= root.persistentCount; p++) ids.push(base + p)
    var guests = []
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id <= 0) continue
      if (root.blockOf(id) === root.block) {
        if (ids.indexOf(id) === -1) ids.push(id)
      } else if (values[i].monitor && values[i].monitor.name === root.monitorName) {
        guests.push(id)
      }
    }

    ids.sort(function(left, right) { return left - right })
    guests.sort(function(left, right) { return left - right })
    return ids.concat(guests)
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = " + Number(id) + " })"))
  }

  function toggleMissionControl() {
    if (!root.bar) return
    root.bar.run("omarchy-shell shell toggle io.github.joaovitor2763.mission-control '{}'")
  }

  property real wheelAccumulator: 0

  function scrollWorkspaces(delta) {
    var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
    root.wheelAccumulator = wheel.remainder
    if (wheel.steps === 0) return

    var ids = root.workspaceIds()
    var index = ids.indexOf(root.activeWorkspaceId())
    if (index === -1) return
    var target = ids[Util.clamp(index + wheel.steps, 0, ids.length - 1)]
    if (target !== ids[index]) root.focusWorkspace(target)
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      var switched = name === "workspacev2" && root.monitor !== null && root.monitor.focused
      if (switched || name === "moveworkspacev2" || name === "changeworkspaceid") {
        Hyprland.refreshMonitors()
        Hyprland.refreshWorkspaces()
      }
    }
  }

  // Forward-slanted `/` parallelogram with micro-rounded corners:
  //   TL = (x0 + skew, y0), TR = (x0 + w, y0), BR = (x0 + w - skew, y0 + h), BL = (x0, y0 + h)
  function slantedPath(x0, y0, w, h, skew, radius) {
    if (w <= 0 || h <= 0) return ""
    var s = Math.min(skew, Math.max(0, w * 0.4))
    var edgeLen = Math.hypot(s, h)
    var r = Math.min(radius, (w - s) * 0.35, edgeLen * 0.35)
    var ux = edgeLen > 0 ? s / edgeLen : 0
    var uy = edgeLen > 0 ? h / edgeLen : 1

    var tlx = x0 + s, tly = y0
    var trx = x0 + w, try_ = y0
    var brx = x0 + w - s, bry = y0 + h
    var blx = x0, bly = y0 + h

    if (r <= 0.05) {
      return "M " + tlx + " " + tly
        + " L " + trx + " " + try_
        + " L " + brx + " " + bry
        + " L " + blx + " " + bly + " Z"
    }

    return "M " + (tlx + r) + " " + tly
      + " L " + (trx - r) + " " + try_
      + " Q " + trx + " " + try_ + " " + (trx - r * ux) + " " + (try_ + r * uy)
      + " L " + (brx + r * ux) + " " + (bry - r * uy)
      + " Q " + brx + " " + bry + " " + (brx - r) + " " + bry
      + " L " + (blx + r) + " " + bly
      + " Q " + blx + " " + bly + " " + (blx + r * ux) + " " + (bly - r * uy)
      + " L " + (tlx - r * ux) + " " + (tly + r * uy)
      + " Q " + tlx + " " + tly + " " + (tlx + r) + " " + tly
      + " Z"
  }

  readonly property real slantOffset: root.vertical ? 0 : 4.5
  readonly property real parallelGap: 2.5
  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(3)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    // Negative spacing overlaps bounding boxes by `(slantOffset - parallelGap)` so
    // adjacent `/` slanted edges interlock with a uniform 2.5px parallel channel.
    columnSpacing: root.vertical ? 0 : Math.round(-(root.slantOffset - root.parallelGap))
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      Item {
        id: chip

        required property int modelData
        required property int index

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool shown: root.monitor !== null && root.monitor.activeWorkspace !== null && root.monitor.activeWorkspace.id === modelData
        readonly property int slot: root.slotOf(modelData)
        readonly property bool firstGuest: root.blockOf(modelData) !== root.block && index > 0 && root.blockOf(root.workspaceIds()[index - 1]) === root.block
        readonly property bool hovered: hitArea.containsMouse

        Layout.leftMargin: firstGuest && !root.vertical ? Style.space(6) : 0
        Layout.topMargin: firstGuest && root.vertical ? Style.space(6) : 0

        implicitWidth: root.vertical ? root.barSize : Style.space(24)
        implicitHeight: root.barSize

        property var registeredBar: null
        function syncClickRegistration() {
          if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(chip)
          registeredBar = root.bar
          if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(chip)
        }
        onVisibleChanged: if (!visible && root.bar) root.bar.hideTooltip(chip)
        Component.onCompleted: syncClickRegistration()
        Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(chip)

        Connections {
          target: root
          function onBarChanged() { chip.syncClickRegistration() }
        }

        readonly property color fg: root.bar ? root.bar.barForeground : Commons.Color.bar.text
        readonly property real verticalInset: root.vertical ? 2 : 3.5
        readonly property real pillHeight: Math.max(14, height - verticalInset * 2)
        property real pressScale: (hitArea.pressedButtons & (Qt.LeftButton | Qt.RightButton | Qt.MiddleButton)) ? 0.92 : 1.0

        Behavior on pressScale {
          NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
        }

        property color fillColor: chip.shown
          ? Qt.rgba(fg.r, fg.g, fg.b, chip.hovered ? 0.25 : 0.19)
          : chip.occupied
            ? Qt.rgba(fg.r, fg.g, fg.b, chip.hovered ? 0.14 : 0.08)
            : Qt.rgba(fg.r, fg.g, fg.b, chip.hovered ? 0.10 : 0.03)

        property color strokeColor: chip.shown
          ? Qt.rgba(fg.r, fg.g, fg.b, 0.30)
          : chip.occupied
            ? Qt.rgba(fg.r, fg.g, fg.b, chip.hovered ? 0.20 : 0.11)
            : Qt.rgba(fg.r, fg.g, fg.b, chip.hovered ? 0.15 : 0.05)

        property real textAlpha: chip.shown ? 1.0 : (chip.occupied ? 0.88 : (chip.hovered ? 0.80 : 0.44))

        Behavior on fillColor {
          ColorAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic }
        }
        Behavior on strokeColor {
          ColorAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic }
        }
        Behavior on textAlpha {
          NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic }
        }

        Item {
          anchors.fill: parent
          scale: chip.pressScale

          Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
              fillColor: chip.fillColor
              strokeColor: chip.strokeColor
              strokeWidth: 1
              PathSvg {
                path: root.slantedPath(
                  0.5,
                  chip.verticalInset,
                  Math.max(0, chip.width - 1),
                  chip.pillHeight,
                  root.slantOffset,
                  1.6
                )
              }
            }
          }

          Text {
            id: numberLabel
            anchors.centerIn: parent
            anchors.verticalCenterOffset: root.vertical
              ? 0
              : (labelMetrics.descent - labelMetrics.ascent + labelMetrics.tightBoundingRect("0").height) / 2
            textFormat: Text.PlainText
            text: chip.slot === root.slots ? "0" : String(chip.slot)
            color: Qt.rgba(chip.fg.r, chip.fg.g, chip.fg.b, chip.textAlpha)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Math.max(10, Style.font.body - 0.5)
            font.weight: chip.shown ? Font.DemiBold : (chip.occupied ? Font.Medium : Font.Normal)
            renderType: Text.NativeRendering
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }

          FontMetrics {
            id: labelMetrics
            font: numberLabel.font
          }
        }

        MouseArea {
          id: hitArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
          onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton || mouse.button === Qt.MiddleButton) {
              root.toggleMissionControl()
            } else if (chip.shown) {
              root.toggleMissionControl()
            } else {
              root.focusWorkspace(chip.modelData)
            }
          }
          onWheel: function(wheel) {
            root.scrollWorkspaces(wheel.angleDelta.y)
          }
        }
      }
    }
  }
}
