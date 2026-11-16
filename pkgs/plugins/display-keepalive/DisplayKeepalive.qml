import Quickshell
import Quickshell.Wayland
import QtQuick

// Apple's display coprocessor (apple-dcp) drops the signal to an external
// display after a few seconds without a page flip, and Hyprland sends none
// while nothing on that screen changes: the monitor goes dark until the
// pointer moves. One near-transparent pixel per external screen, changed
// twice a second, gives the compositor a 1px damage region to present, which
// keeps the output alive for a fraction of the cost of redrawing every frame
// (`debug.vfr = false` + `debug.damage_tracking = 0`).
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Milliseconds between frames; the output drops after a few seconds.
  property int interval: 500
  property bool tick: false

  function isExternal(screen) {
    return screen && String(screen.name).indexOf("eDP") !== 0
  }

  readonly property var externalScreens: {
    var list = []
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (isExternal(Quickshell.screens[i])) list.push(Quickshell.screens[i])
    return list
  }

  Timer {
    interval: root.interval
    repeat: true
    running: root.externalScreens.length > 0
    onTriggered: root.tick = !root.tick
  }

  Variants {
    model: root.externalScreens

    PanelWindow {
      required property var modelData

      screen: modelData
      visible: true
      color: "transparent"
      implicitWidth: 1
      implicitHeight: 1
      anchors { top: true; left: true }
      exclusionMode: ExclusionMode.Ignore
      // Never takes the pointer.
      mask: Region {}

      WlrLayershell.namespace: "omarchnix-display-keepalive"
      // Above fullscreen windows too, so a paused video doesn't blank either.
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Rectangle {
        anchors.fill: parent
        color: root.tick ? Qt.rgba(0, 0, 0, 0.02) : Qt.rgba(1, 1, 1, 0.02)
      }
    }
  }
}
