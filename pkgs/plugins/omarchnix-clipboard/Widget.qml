import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "omarchnix.clipboard"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰅌"
    slotSize: Style.bar.statusSlot
    tooltipText: "Clipboard History (Cmd+Shift+V)"
    onPressed: function() {
      if (root.bar) root.bar.run("omarchy-shell shell toggle omarchy.clipboard")
    }
  }
}
