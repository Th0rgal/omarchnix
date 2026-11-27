import QtQuick

// Minimal adaptive Oura Ring glyph (clean ring band + subtle top bar cue) for the Omarchy status bar.
Item {
  id: root

  property real iconSize: 14
  property color color: "#ffffff"
  property color accentColor: "#30d158"
  property bool active: false

  implicitWidth: iconSize
  implicitHeight: iconSize
  width: iconSize
  height: iconSize

  onColorChanged: canvas.requestPaint()
  onAccentColorChanged: canvas.requestPaint()
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

      var cx = w * 0.5
      var cy = h * 0.56
      var r = Math.min(w, h) * 0.34
      var ringStroke = Math.max(1.6, Math.min(w, h) * 0.13)

      ctx.strokeStyle = root.color
      ctx.fillStyle = root.color
      ctx.lineCap = "round"
      ctx.lineJoin = "round"

      // Signature Oura top bar above the ring
      ctx.lineWidth = Math.max(1.3, ringStroke * 0.85)
      ctx.beginPath()
      ctx.moveTo(cx - r * 0.52, cy - r - ringStroke * 0.95)
      ctx.lineTo(cx + r * 0.52, cy - r - ringStroke * 0.95)
      ctx.stroke()

      // Clean ring band
      ctx.lineWidth = ringStroke
      ctx.beginPath()
      ctx.arc(cx, cy, r, 0, Math.PI * 2)
      ctx.stroke()

      // Subtle corner dot when Gesture Mode is actively streaming
      if (root.active) {
        ctx.fillStyle = root.accentColor
        ctx.beginPath()
        ctx.arc(w * 0.86, h * 0.16, Math.max(1.7, Math.min(w, h) * 0.115), 0, Math.PI * 2)
        ctx.fill()
      }
    }
  }
}
