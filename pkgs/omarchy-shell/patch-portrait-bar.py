#!/usr/bin/env python3
"""Patch Omarchy shell Bar.qml with responsive portrait/compact mode.

In portrait or narrow horizontal bars (screen.height > screen.width or width < 720):
- Hide the center island (clock, indicators, world clock, weather) so items never collide.
- Auto-hide the right-side status icons behind a compact chevron toggle on the right edge.
- When expanded, hide the left-side menu/workspaces so the right status icons get the full bar width.
"""

import pathlib
import sys


def replace_once(src: str, old: str, new: str, label: str) -> str:
    count = src.count(old)
    if count != 1:
        raise RuntimeError(f"Expected 1 match for {label}, found {count}")
    return src.replace(old, new, 1)


def main() -> None:
    out_dir = pathlib.Path(sys.argv[1])
    bar_qml = out_dir / "shell" / "plugins" / "bar" / "Bar.qml"
    src = bar_qml.read_text(encoding="utf-8")

    # 1. Add portraitCompact & portraitRightExpanded state on BarPanel (barWindow)
    src = replace_once(
        src,
        "    readonly property bool centerBesideRight: BarModel.centerBesideRight(root.displayCutouts, root.position, screen.name, screen.width, screen.height, screen.devicePixelRatio, panelMode)",
        """    readonly property bool centerBesideRight: BarModel.centerBesideRight(root.displayCutouts, root.position, screen.name, screen.width, screen.height, screen.devicePixelRatio, panelMode)
    readonly property bool portraitCompact: !root.vertical && screen !== null && (screen.height > screen.width || (width > 0 && width < 720))
    property bool portraitRightExpanded: false
    onPortraitCompactChanged: if (!portraitCompact) portraitRightExpanded = false""",
        "BarPanel portraitCompact property",
    )

    # 2. Update horizontalBar layout: hide center island in portraitCompact,
    #    auto-hide right icons behind a toggle button, and hide left modules when expanded.
    old_hbar = """        CenterModules {
          anchors.fill: parent
          window: barWindow
          pool: horizontalPool
          drawn: !barWindow.centerBesideRight
        }

        LeftModules {
          window: barWindow
          pool: horizontalPool
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        RightModules {
          window: barWindow
          pool: horizontalPool
          id: rightModules
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        // Where a display notch covers the middle of the bar, the center
        // sections run on just left of the right one. They keep their regions,
        // so settings pushes, drag and drop, and panel routing still address
        // them. The gap lets a drop at the seam land in the section the pointer
        // is nearer to.
        CenterSections {
          window: barWindow
          pool: horizontalPool
          active: barWindow.centerBesideRight"""

    new_hbar = """        CenterModules {
          anchors.fill: parent
          window: barWindow
          pool: horizontalPool
          drawn: !barWindow.centerBesideRight && !barWindow.portraitCompact
        }

        LeftModules {
          window: barWindow
          pool: horizontalPool
          visible: !barWindow.portraitCompact || !barWindow.portraitRightExpanded
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        RightModules {
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
          active: barWindow.centerBesideRight && !barWindow.portraitCompact"""

    src = replace_once(src, old_hbar, new_hbar, "horizontalBar layout")
    bar_qml.write_text(src, encoding="utf-8")


if __name__ == "__main__":
    main()
