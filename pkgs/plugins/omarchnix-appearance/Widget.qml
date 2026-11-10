import QtQuick
import Quickshell
import qs.Commons as Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "omarchnix.appearance"

  readonly property bool isLight:
    (0.2126 * Commons.Color.background.r + 0.7152 * Commons.Color.background.g + 0.0722 * Commons.Color.background.b) > 0.5

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.isLight ? "󰖙" : "󰖔"
    slotSize: Commons.Style.bar.statusSlot
    tooltipText: root.isLight
      ? "Appearance: Light — click for Dark (Right-click: Theme Picker)"
      : "Appearance: Dark — click for Light (Right-click: Theme Picker)"
    onPressed: function(mouseButton) {
      if (!root.bar) return
      if (mouseButton === Qt.RightButton) {
        root.bar.run("omarchy-shell shell summon omarchy.image-picker '{\"source\":\"themes\"}'")
      } else {
        root.bar.run("omarchnix theme toggle")
      }
    }
  }
}
