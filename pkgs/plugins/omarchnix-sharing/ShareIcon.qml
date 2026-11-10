import QtQuick

Item {
  id: root

  property real iconSize: 14
  property color color: "#ffffff"
  property bool active: false

  implicitWidth: iconSize
  implicitHeight: iconSize
  width: iconSize
  height: iconSize

  onColorChanged: canvas.requestPaint()
  onActiveChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width
      var h = height
      if (w <= 0 || h <= 0) return

      var stroke = Math.max(1.35, Math.min(w, h) * 0.115)
      ctx.strokeStyle = root.color
      ctx.fillStyle = root.color
      ctx.lineWidth = stroke
      ctx.lineCap = "round"
      ctx.lineJoin = "round"

      // Clean macOS-style square.and.arrow.up glyph
      var trayLeft = w * 0.20
      var trayRight = w * 0.80
      var trayTop = h * 0.44
      var trayBottom = h * 0.86
      var radius = Math.min(w, h) * 0.12
      var gapHalf = w * 0.16
      var cx = w * 0.5

      ctx.beginPath()
      ctx.moveTo(cx - gapHalf, trayTop)
      ctx.lineTo(trayLeft + radius, trayTop)
      ctx.arcTo(trayLeft, trayTop, trayLeft, trayTop + radius, radius)
      ctx.lineTo(trayLeft, trayBottom - radius)
      ctx.arcTo(trayLeft, trayBottom, trayLeft + radius, trayBottom, radius)
      ctx.lineTo(trayRight - radius, trayBottom)
      ctx.arcTo(trayRight, trayBottom, trayRight, trayBottom - radius, radius)
      ctx.lineTo(trayRight, trayTop + radius)
      ctx.arcTo(trayRight, trayTop, trayRight - radius, trayTop, radius)
      ctx.lineTo(cx + gapHalf, trayTop)
      ctx.stroke()

      // Upward stem + chevron
      var arrowTop = h * 0.12
      var arrowBottom = h * 0.62
      var wing = w * 0.19

      ctx.beginPath()
      ctx.moveTo(cx, arrowBottom)
      ctx.lineTo(cx, arrowTop)
      ctx.stroke()

      ctx.beginPath()
      ctx.moveTo(cx - wing, arrowTop + wing * 0.92)
      ctx.lineTo(cx, arrowTop)
      ctx.lineTo(cx + wing, arrowTop + wing * 0.92)
      ctx.stroke()

      if (root.active) {
        ctx.beginPath()
        ctx.arc(w * 0.84, h * 0.20, Math.max(1.6, Math.min(w, h) * 0.10), 0, Math.PI * 2)
        ctx.fill()
      }
    }
  }
}
