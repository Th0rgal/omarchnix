import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Effects
import qs.Commons

// Workspace slot in the Spaces bar: either an active/populated workspace
// (wallpaper plus live miniatures of its windows) or an unused intermediate
// workspace number rendered as a dashed drop target. Click to switch; drag
// occupied Spaces horizontally to reorder or move into an unused number; drop
// a dragged window here to move it to that workspace number.
Item {
  id: thumb

  required property int spaceId
  required property var monitorView
  required property int spaceIndex

  readonly property var liveWorkspace: monitorView.workspaceById(spaceId)
  readonly property bool active: monitorView.isSpaceActive(spaceIndex, spaceId)

  readonly property var liveWindows: {
    var seen = {}
    var result = []
    var all = Hyprland.toplevels.values
    for (var i = 0; i < all.length; i++) {
      var t = all[i]
      if (!t || !t.wayland) continue
      var addr = String(t.address || "")
      if (monitorView.isWindowMovedAwayFrom(addr, thumb.spaceId)) continue
      var o = t.lastIpcObject
      if (t.workspace && t.workspace.id === thumb.spaceId && o && o.at && o.size && !o.hidden) {
        seen[addr] = true
        result.push(t)
      }
    }
    var incoming = monitorView.optimisticWindowsForSpace(thumb.spaceId)
    for (var j = 0; j < incoming.length; j++) {
      var inc = incoming[j]
      var incAddr = String(inc.address || "")
      if (incAddr && !seen[incAddr] && inc.lastIpcObject && inc.lastIpcObject.at && inc.lastIpcObject.size) {
        seen[incAddr] = true
        result.push(inc)
      }
    }
    return result
  }

  readonly property bool hasLiveSpace: liveWorkspace !== null || liveWindows.length > 0 || active
  property var frozenIsPlaceholder: null
  readonly property bool isPlaceholder: false
  readonly property string spaceName: monitorView.labelForSpaceId(spaceId)
  readonly property var workspace: liveWorkspace || ({ id: spaceId, name: spaceName })

  readonly property bool windowDropHover: monitorView.dropTarget === spaceId
  readonly property bool spaceDropHover: {
    var from = monitorView.spaceDragIndex
    var to = monitorView.spaceDropIndex
    return from >= 0 && from !== spaceIndex && to === spaceIndex && isPlaceholder
  }
  readonly property bool dropHover: windowDropHover || spaceDropHover
  readonly property bool absorbedByShift: {
    if (!isPlaceholder) return false
    var from = monitorView.spaceDragIndex
    var to = monitorView.spaceDropIndex
    if (from < 0 || to < 0 || from === to) return false
    var absorb = monitorView.computeSpaceAbsorbIndex(from, to)
    return absorb === spaceIndex && (absorb !== to || monitorView.spaceReordering)
  }

  readonly property real step: width + monitorView.spacesSpacing
  readonly property real k: width / Math.max(1, monitorView.width)
  readonly property int radius: Math.min(monitorView.radius, 10)

  property bool pointerDragging: false
  property bool settling: false
  property real dragX: 0
  property real dragY: 0
  property var frozenThumbWindows: null

  readonly property real shiftX: {
    var from = monitorView.spaceDragIndex
    var to = monitorView.spaceDropIndex
    if (from < 0 || to < 0 || from === to || from === spaceIndex) return 0
    var absorb = monitorView.computeSpaceAbsorbIndex(from, to)
    if (to < from && spaceIndex >= to && spaceIndex < absorb) return step
    if (to > from && spaceIndex <= to && spaceIndex > absorb) return -step
    return 0
  }

  readonly property var windows: thumb.monitorView.spaceReordering && thumb.frozenThumbWindows !== null
    ? thumb.frozenThumbWindows
    : thumb.liveWindows

  z: pointerDragging || settling ? 100 : (shiftX !== 0 ? 2 : 1)

  Timer {
    id: settleTimer
    interval: 150
    onTriggered: thumb.settling = false
  }

  Connections {
    target: thumb.monitorView
    function onSpaceDragFreeze() {
      thumb.frozenThumbWindows = thumb.liveWindows
      thumb.frozenIsPlaceholder = !thumb.hasLiveSpace
    }
    function onSpaceDragReset() {
      settleTimer.stop()
      thumb.pointerDragging = false
      thumb.settling = false
      thumb.frozenThumbWindows = null
      thumb.frozenIsPlaceholder = null
      thumb.dragX = 0
      thumb.dragY = 0
    }
  }

  // Subtle vacated-slot outline left behind when lifting an occupied Space
  Canvas {
    id: vacatedWell
    anchors.fill: parent
    visible: (thumb.pointerDragging || thumb.settling)
      && thumb.monitorView.spaceDragIndex === thumb.spaceIndex
      && thumb.monitorView.spaceDropIndex !== thumb.spaceIndex
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var lw = 1.5
      var x = lw / 2
      var y = lw / 2
      var w = width - lw
      var h = height - lw
      if (w <= 0 || h <= 0) return
      var r = Math.min(thumb.radius, w / 2, h / 2)
      ctx.fillStyle = "rgba(255, 255, 255, 0.025)"
      ctx.strokeStyle = "rgba(255, 255, 255, 0.16)"
      ctx.lineWidth = lw
      ctx.setLineDash([5, 4])
      ctx.beginPath()
      ctx.moveTo(x + r, y)
      ctx.lineTo(x + w - r, y)
      ctx.arcTo(x + w, y, x + w, y + r, r)
      ctx.lineTo(x + w, y + h - r)
      ctx.arcTo(x + w, y + h, x + w - r, y + h, r)
      ctx.lineTo(x + r, y + h)
      ctx.arcTo(x, y + h, x, y + h - r, r)
      ctx.lineTo(x, y + r)
      ctx.arcTo(x, y, x + r, y, r)
      ctx.closePath()
      ctx.fill()
      ctx.stroke()
    }
  }

  Item {
    id: card
    width: thumb.width
    height: thumb.height
    x: (thumb.pointerDragging || thumb.settling) ? thumb.dragX : thumb.shiftX
    y: (thumb.pointerDragging || thumb.settling) ? thumb.dragY : 0
    opacity: thumb.absorbedByShift ? 0 : 1
    scale: thumb.pointerDragging
      ? 1.08
      : (thumb.dropHover ? 1.06 : ((mouse.containsMouse || closeMouse.containsMouse) ? (thumb.isPlaceholder ? 1.04 : 1.06) : 1))

    Behavior on x {
      enabled: !thumb.pointerDragging && !thumb.monitorView.suppressSpaceAnim
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }
    Behavior on y {
      enabled: !thumb.pointerDragging && !thumb.monitorView.suppressSpaceAnim
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }
    Behavior on scale {
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }
    Behavior on opacity {
      NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
    }

    RectangularShadow {
      visible: thumb.monitorView.controller.mapped && !thumb.isPlaceholder
      anchors.fill: parent
      radius: thumb.radius
      blur: thumb.pointerDragging ? 26 : 18
      offset.y: thumb.pointerDragging ? 8 : 4
      color: Qt.rgba(0, 0, 0, thumb.pointerDragging ? 0.6 : 0.45)
    }

    // Empty / unused workspace number visualization
    Rectangle {
      visible: thumb.isPlaceholder
      anchors.fill: parent
      radius: thumb.radius
      color: thumb.dropHover
        ? Qt.rgba(1, 1, 1, 0.14)
        : (mouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.03))

      Behavior on color { ColorAnimation { duration: 120 } }

      Canvas {
        id: dashedBorder
        anchors.fill: parent
        visible: thumb.isPlaceholder && !thumb.dropHover
        property color strokeColor: mouse.containsMouse
          ? Qt.rgba(1, 1, 1, 0.42)
          : Qt.rgba(1, 1, 1, 0.22)
        onStrokeColorChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onVisibleChanged: if (visible) requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var lw = 1.5
          var x = lw / 2
          var y = lw / 2
          var w = width - lw
          var h = height - lw
          if (w <= 0 || h <= 0) return
          var r = Math.min(thumb.radius, w / 2, h / 2)
          ctx.strokeStyle = strokeColor
          ctx.lineWidth = lw
          ctx.setLineDash([5, 4])
          ctx.beginPath()
          ctx.moveTo(x + r, y)
          ctx.lineTo(x + w - r, y)
          ctx.arcTo(x + w, y, x + w, y + r, r)
          ctx.lineTo(x + w, y + h - r)
          ctx.arcTo(x + w, y + h, x + w - r, y + h, r)
          ctx.lineTo(x + r, y + h)
          ctx.arcTo(x, y + h, x, y + h - r, r)
          ctx.lineTo(x, y + r)
          ctx.arcTo(x, y, x + r, y, r)
          ctx.closePath()
          ctx.stroke()
        }
      }

      Text {
        anchors.centerIn: parent
        text: thumb.spaceName
        textFormat: Text.PlainText
        color: "white"
        opacity: thumb.dropHover ? 0.55 : (mouse.containsMouse ? 0.34 : 0.16)
        font.family: thumb.monitorView.fontFamily
        font.pixelSize: Math.round(thumb.height * 0.28)
        font.weight: Font.Medium

        Behavior on opacity { NumberAnimation { duration: 120 } }
      }
    }

    // Occupied / active workspace live miniature
    Item {
      id: content
      anchors.fill: parent
      visible: false
      layer.enabled: thumb.monitorView.controller.mapped && !thumb.isPlaceholder

      Rectangle {
        anchors.fill: parent
        color: thumb.monitorView.background
      }

      Image {
        anchors.fill: parent
        readonly property string bgPath: thumb.monitorView.controller.wallpaperForWorkspace(thumb.spaceId)
        source: bgPath ? "file://" + bgPath : ""
        sourceSize.width: 320
        sourceSize.height: 208
        fillMode: Image.PreserveAspectCrop
        verticalAlignment: bgPath.indexOf("bologna-dome") >= 0 ? Image.AlignTop : Image.AlignVCenter
        asynchronous: true
        cache: true
        mipmap: false
      }

      Repeater {
        model: ScriptModel {
          objectProp: "address"
          values: thumb.isPlaceholder ? [] : thumb.windows
        }

        ScreencopyView {
          required property var modelData
          readonly property var o: modelData ? modelData.lastIpcObject : null

          x: ((o && o.at ? o.at[0] : 0) - (thumb.monitorView.monitor ? thumb.monitorView.monitor.x : 0)) * thumb.k
          y: ((o && o.at ? o.at[1] : 0) - (thumb.monitorView.monitor ? thumb.monitorView.monitor.y : 0)) * thumb.k
          width: Math.max(1, (o && o.size ? o.size[0] : 100) * thumb.k)
          height: Math.max(1, (o && o.size ? o.size[1] : 100) * thumb.k)
          captureSource: thumb.monitorView.controller.mapped && modelData ? modelData.wayland : null
          live: true
        }
      }
    }

    Rectangle {
      id: mask
      anchors.fill: parent
      radius: thumb.radius
      visible: false
      layer.enabled: thumb.monitorView.controller.mapped && !thumb.isPlaceholder
    }

    MultiEffect {
      visible: thumb.monitorView.controller.mapped && !thumb.isPlaceholder
      anchors.fill: parent
      source: content
      maskEnabled: true
      maskSource: mask
      maskThresholdMin: 0.5
      maskSpreadAtMin: 1.0
    }

    Rectangle {
      visible: !thumb.isPlaceholder || thumb.dropHover
      anchors.fill: parent
      anchors.margins: -3
      radius: thumb.radius > 0 ? thumb.radius + 3 : 0
      color: "transparent"
      border.width: thumb.active || thumb.dropHover || thumb.pointerDragging ? 3 : 1
      border.color: thumb.active || thumb.dropHover || thumb.pointerDragging
        ? thumb.monitorView.accent
        : Qt.rgba(1, 1, 1, 0.22)
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.bottom
      anchors.topMargin: 8
      text: thumb.monitorView.previewSpaceLabel(thumb.spaceIndex, thumb.spaceName)
      textFormat: Text.PlainText
      color: "white"
      opacity: thumb.spaceDropHover
        ? 0
        : (thumb.active || thumb.pointerDragging || thumb.windowDropHover
            ? 1
            : (thumb.isPlaceholder ? (mouse.containsMouse ? 0.8 : 0.42) : 0.75))
      font.family: thumb.monitorView.fontFamily
      font.pixelSize: Style.font.body
      font.weight: thumb.active || thumb.pointerDragging || thumb.windowDropHover ? Font.DemiBold : Font.Normal
    }
  }

  MouseArea {
    id: mouse

    property point startPos
    property bool moved: false

    anchors.fill: parent
    hoverEnabled: true
    enabled: thumb.monitorView.p > 0.5 && !thumb.monitorView.spaceReordering
    acceptedButtons: Qt.LeftButton
    cursorShape: thumb.pointerDragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor

    onPressed: function(m) {
      startPos = mapToItem(thumb.monitorView.contentItem, m.x, m.y)
      moved = false
    }

    onPositionChanged: function(m) {
      if (thumb.isPlaceholder || !pressed || !(m.buttons & Qt.LeftButton)) return
      var g = mapToItem(thumb.monitorView.contentItem, m.x, m.y)
      var dx = g.x - startPos.x
      var dy = g.y - startPos.y
      if (!moved && Math.sqrt(dx * dx + dy * dy) > 8) {
        moved = true
        settleTimer.stop()
        thumb.settling = false
        thumb.pointerDragging = true
        thumb.monitorView.beginSpaceDrag(thumb.spaceIndex)
      }
      if (thumb.pointerDragging) {
        thumb.dragX = dx
        thumb.dragY = Math.max(-18, Math.min(24, dy * 0.35))
        thumb.monitorView.updateSpaceDrag(thumb.spaceIndex, dx)
      }
    }

    onReleased: function(m) {
      if (moved) {
        var from = thumb.monitorView.spaceDragIndex
        var to = thumb.monitorView.spaceDropIndex
        thumb.pointerDragging = false
        thumb.settling = true
        if (from >= 0 && to >= 0 && from !== to) {
          thumb.dragX = (to - from) * thumb.step
          thumb.dragY = 0
          thumb.monitorView.commitSpaceDrag()
        } else {
          thumb.monitorView.cancelSpaceDrag()
          thumb.dragX = 0
          thumb.dragY = 0
          settleTimer.restart()
        }
        return
      }
      thumb.monitorView.switchTo(thumb.spaceId)
    }

    onCanceled: {
      if (moved) {
        thumb.pointerDragging = false
        thumb.settling = true
        thumb.monitorView.cancelSpaceDrag()
        thumb.dragX = 0
        thumb.dragY = 0
        settleTimer.restart()
      }
    }
  }

  // macOS-style top-left close pill for empty Spaces when hovered
  Rectangle {
    id: closeButton
    readonly property bool canClose: thumb.windows.length === 0
      && thumb.monitorView.spaceIds.length > 1
      && !thumb.pointerDragging
      && !thumb.settling
      && !thumb.monitorView.spaceReordering
    visible: opacity > 0.01
    opacity: canClose && (mouse.containsMouse || closeMouse.containsMouse) ? 1 : 0
    width: 22
    height: 22
    radius: 11
    x: card.x - 8
    y: card.y - 8
    z: 20
    color: closeMouse.containsMouse ? Qt.rgba(0.95, 0.28, 0.28, 0.96) : Qt.rgba(0.14, 0.14, 0.16, 0.88)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.28)

    Behavior on opacity { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
    Behavior on color { ColorAnimation { duration: 100 } }

    Text {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -0.5
      text: "×"
      textFormat: Text.PlainText
      color: "white"
      font.family: thumb.monitorView.fontFamily
      font.pixelSize: 15
      font.weight: Font.Medium
    }

    MouseArea {
      id: closeMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: closeButton.canClose && thumb.monitorView.p > 0.5
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton
      onClicked: function(m) {
        m.accepted = true
        thumb.monitorView.closeEmptySpace(thumb.spaceId)
      }
    }
  }
}
