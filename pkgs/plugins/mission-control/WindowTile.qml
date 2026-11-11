import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons

// One live window preview. It interpolates between the window's real
// geometry (progress 0) and its spread-out slot (progress 1), so opening and
// closing look like the windows themselves move.
Item {
  id: tile

  required property var toplevel
  required property var monitorView
  property var rect: null
  property bool selected: false
  property bool dimmed: false
  readonly property bool hovered: mouse.containsMouse

  readonly property var ipc: toplevel ? toplevel.lastIpcObject : null
  readonly property real p: monitorView.p
  readonly property bool settled: p > 0.9 && !dragging && !dropped
  readonly property bool highlighted: (selected || hovered) && settled

  // Real on-screen geometry, relative to this monitor
  readonly property real realX: (ipc && ipc.at ? ipc.at[0] : 0) - (monitorView.monitor ? monitorView.monitor.x : 0)
  readonly property real realY: (ipc && ipc.at ? ipc.at[1] : 0) - (monitorView.monitor ? monitorView.monitor.y : 0)
  readonly property real realWidth: ipc && ipc.size ? ipc.size[0] : 100
  readonly property real realHeight: ipc && ipc.size ? ipc.size[1] : 100

  // Spread-out geometry, animated when the layout changes underneath
  property real gridX: rect ? rect.x : realX
  property real gridY: rect ? rect.y : realY
  property real gridWidth: rect ? rect.w : realWidth
  property real gridHeight: rect ? rect.h : realHeight

  Behavior on gridX { enabled: tile.p === 1 && !tile.dragging; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
  Behavior on gridY { enabled: tile.p === 1 && !tile.dragging; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
  Behavior on gridWidth { enabled: tile.p === 1 && !tile.dragging; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
  Behavior on gridHeight { enabled: tile.p === 1 && !tile.dragging; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

  readonly property real baseX: realX + (gridX - realX) * p
  readonly property real baseY: realY + (gridY - realY) * p
  readonly property real baseWidth: realWidth + (gridWidth - realWidth) * p
  readonly property real baseHeight: realHeight + (gridHeight - realHeight) * p

  // Cursor-anchored drag state so grabbing any corner or bottom edge of a
  // large window keeps that exact point pinned under the cursor as it shrinks.
  property bool dragging: false
  property bool dropped: false
  property real grabRx: 0.5
  property real grabRy: 0.5
  property real pointerX: 0
  property real pointerY: 0
  property real settleX: 0
  property real settleY: 0

  Behavior on settleX { enabled: !tile.dragging; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
  Behavior on settleY { enabled: !tile.dragging; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

  readonly property real dragScale: Math.min(0.45, Math.max(0.22, (monitorView.thumbWidth * 1.85) / Math.max(1, baseWidth)))
  readonly property real liveDragX: (pointerX - baseWidth * 0.5 - (grabRx - 0.5) * baseWidth * scale) - baseX
  readonly property real liveDragY: (pointerY - baseHeight * 0.5 - (grabRy - 0.5) * baseHeight * scale) - baseY

  readonly property real radius: monitorView.radius * p

  visible: !dropped
  x: baseX + (dragging ? liveDragX : settleX)
  y: baseY + (dragging ? liveDragY : settleY)
  width: baseWidth
  height: baseHeight
  z: dragging ? 100 : (selected ? 2 : 1)
  opacity: dropped ? 0 : (dimmed ? 0.25 : 1)
  scale: dragging ? dragScale : (highlighted ? 1.03 : 1.0)

  Behavior on opacity { enabled: !tile.dropped; NumberAnimation { duration: 150 } }
  Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

  function snapBackFromDrag() {
    if (!tile.dragging) return
    tile.settleX = tile.liveDragX
    tile.settleY = tile.liveDragY
    tile.dragging = false
    tile.settleX = 0
    tile.settleY = 0
  }

  RectangularShadow {
    anchors.fill: parent
    radius: tile.radius
    blur: 30
    offset.y: 8
    color: Qt.rgba(0, 0, 0, 0.45 * tile.p)
  }

  Rectangle {
    anchors.fill: parent
    radius: tile.radius
    color: tile.monitorView.background
  }

  ScreencopyView {
    id: preview
    anchors.fill: parent
    captureSource: tile.monitorView.controller.mapped && !tile.dropped && tile.toplevel ? tile.toplevel.wayland : null
    live: true
    visible: false
  }

  Rectangle {
    id: mask
    anchors.fill: parent
    radius: tile.radius
    visible: false
    layer.enabled: true
  }

  MultiEffect {
    anchors.fill: parent
    source: preview
    maskEnabled: true
    maskSource: mask
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
  }

  Rectangle {
    anchors.fill: parent
    anchors.margins: -4
    radius: tile.radius > 0 ? tile.radius + 4 : 0
    color: "transparent"
    border.width: 3
    border.color: tile.monitorView.accent
    opacity: tile.highlighted ? 1 : 0

    Behavior on opacity { NumberAnimation { duration: 120 } }
  }

  // App icon badge, bottom center
  Image {
    id: icon

    readonly property var entry: {
      DesktopEntries.applications.values // re-run when the entry index updates
      return DesktopEntries.heuristicLookup((tile.ipc && tile.ipc["class"]) || "")
    }
    readonly property string path: entry && entry.icon ? Quickshell.iconPath(entry.icon, true) : ""

    visible: path.length > 0 && !tile.dragging && !tile.dropped
    source: path
    width: Math.min(56, Math.max(28, tile.height * 0.16))
    height: width
    sourceSize.width: 128
    sourceSize.height: 128
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.verticalCenter: parent.bottom
    opacity: tile.p
  }

  // Title under the tile, shown for the hovered/selected window
  Rectangle {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.bottom
    anchors.topMargin: icon.visible ? icon.height / 2 + 8 : 10
    width: Math.min(title.implicitWidth + 24, Math.max(tile.width, 220))
    height: 26
    radius: Math.min(tile.monitorView.radius, height / 2)
    color: Qt.rgba(0, 0, 0, 0.6)
    opacity: tile.highlighted ? 1 : 0

    Behavior on opacity { NumberAnimation { duration: 120 } }

    Text {
      id: title
      anchors.centerIn: parent
      width: Math.min(implicitWidth, parent.width - 24)
      text: tile.toplevel ? tile.toplevel.title : ""
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: "white"
      font.family: tile.monitorView.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  MouseArea {
    id: mouse

    property point start
    property bool moved: false

    anchors.fill: parent
    hoverEnabled: true
    enabled: tile.p > 0.5 && !tile.dropped
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: tile.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor

    onPressed: function(m) {
      start = mapToItem(tile.monitorView.contentItem, m.x, m.y)
      moved = false
      var curCenterX = tile.baseX + tile.settleX + tile.baseWidth * 0.5
      var curCenterY = tile.baseY + tile.settleY + tile.baseHeight * 0.5
      var rx = 0.5 + (start.x - curCenterX) / Math.max(1, tile.baseWidth * tile.scale)
      var ry = 0.5 + (start.y - curCenterY) / Math.max(1, tile.baseHeight * tile.scale)
      tile.grabRx = Math.max(0.05, Math.min(0.95, rx))
      tile.grabRy = Math.max(0.05, Math.min(0.95, ry))
      tile.pointerX = start.x
      tile.pointerY = start.y
    }

    onPositionChanged: function(m) {
      if (!pressed || !(m.buttons & Qt.LeftButton)) return
      var g = mapToItem(tile.monitorView.contentItem, m.x, m.y)
      var dx = g.x - start.x, dy = g.y - start.y
      if (!moved && Math.sqrt(dx * dx + dy * dy) > 8) {
        moved = true
        tile.settleX = 0
        tile.settleY = 0
        tile.dragging = true
      }
      if (tile.dragging) {
        tile.pointerX = g.x
        tile.pointerY = g.y
        tile.monitorView.dropTarget = tile.monitorView.dropTargetAt(tile.monitorView.contentItem, g.x, g.y)
      }
    }

    onReleased: function(m) {
      if (tile.dragging) {
        var g = mapToItem(tile.monitorView.contentItem, m.x, m.y)
        var target = tile.monitorView.dropTargetAt(tile.monitorView.contentItem, g.x, g.y)
        if (target === null) target = tile.monitorView.dropTarget
        tile.monitorView.dropTarget = null
        var currentWsId = tile.toplevel && tile.toplevel.workspace ? tile.toplevel.workspace.id : -1
        if (target !== null && String(target) !== String(currentWsId)) {
          tile.dropped = true
          tile.dragging = false
          tile.monitorView.moveWindow(tile.toplevel, target)
          return
        }
        tile.snapBackFromDrag()
        return
      }
      if (m.button === Qt.MiddleButton) tile.monitorView.closeWindow(tile.toplevel)
      else tile.monitorView.activate(tile.toplevel)
    }

    onCanceled: {
      if (tile.dragging) {
        tile.monitorView.dropTarget = null
        tile.snapBackFromDrag()
      }
    }
  }

  // Close button, top-left on hover
  Rectangle {
    width: 24
    height: 24
    radius: 12
    x: -8
    y: -8
    color: closeMouse.containsMouse ? Commons.Color.urgent : Qt.rgba(0.15, 0.15, 0.15, 0.9)
    border.color: Qt.rgba(1, 1, 1, 0.25)
    visible: (tile.hovered || closeMouse.containsMouse) && tile.settled

    Text {
      anchors.centerIn: parent
      text: "✕"
      color: "white"
      font.pixelSize: 11
    }

    MouseArea {
      id: closeMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.monitorView.closeWindow(tile.toplevel)
    }
  }
}
