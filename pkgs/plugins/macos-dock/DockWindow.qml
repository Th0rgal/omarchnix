import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "DockModel.js" as DockModel

// Clean macOS-style frosted glass dock window (active & pinned apps only — no
// launcher button). High-DPI raster PNGs decode at full native resolution with
// GPU mipmapping; SVGs rasterize at 256x256 for Retina sharpness.
PanelWindow {
  id: window
  Binding { target: window.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
  Binding { target: window.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

  property var dock: null

  readonly property string position: dock ? dock.position : "bottom"
  readonly property bool vertical: dock ? dock.vertical : false
  readonly property var monitor: Hyprland.monitorFor(screen)
  readonly property var workspace: monitor ? monitor.activeWorkspace : null
  readonly property int workspaceId: workspace ? workspace.id : -1
  readonly property int appCount: dock ? dock.itemModel.count : 0

  readonly property int fullscreenMode: {
    var mode = 0
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      if (!toplevel.workspace || toplevel.workspace.id !== workspaceId) continue
      var ipc = toplevel.lastIpcObject
      mode = Math.max(mode, ipc && ipc.fullscreen ? ipc.fullscreen : 0)
    }
    return mode
  }

  readonly property bool shown: !!dock
    && appCount > 0
    && workspaceId >= 1
    && (dock.allWorkspaces || dock.isFloating(workspaceId))

  readonly property bool autohide: !!dock && (dock.autohide || fullscreenMode >= 1)
  property bool revealed: false
  readonly property bool menuOpen: menuItem !== null || settingsMenu
  readonly property bool tucked: autohide && !(revealed || menuOpen || dragging)
  readonly property bool contentShown: shown && !tucked

  readonly property int gap: Style.spacing.sm
  readonly property int pillPadX: 10
  readonly property int pillPadTop: 8
  readonly property int pillPadBottom: 10
  readonly property int iconSize: Math.round(42 * Style.fontScale)
  readonly property int slotWidth: iconSize + 12
  readonly property int slotHeight: iconSize + 12
  readonly property real idleOpacity: 0.68
  readonly property int popupRoom: Style.spacing.popupRowHeight * 5 + Style.spacing.sm * 2 + Style.normalBorderWidth * 2 + gap * 3
  readonly property int popOrigin: position === "top" ? Item.Top
    : position === "left" ? Item.Left
    : position === "right" ? Item.Right
    : Item.Bottom

  property Item hoveredSlot: null
  property int hoveredAppIndex: -1
  property string hoveredTitle: ""
  property string hoveredSubtitle: ""

  property int dragIndex: -1
  property int dropIndex: -1
  property real dragOffset: 0
  readonly property bool dragging: dragIndex >= 0
  property bool animateShifts: true
  property bool hoverStale: false
  property point dropPoint

  property var menuItem: null
  property Item menuSlot: null
  property bool settingsMenu: false

  onWorkspaceIdChanged: if (dock) dock.readMode(workspaceId)
  onShownChanged: {
    if (shown) return
    closeMenu()
    window.revealed = false
    window.hoveredSlot = null
    window.hoveredAppIndex = -1
  }
  Component.onCompleted: if (dock) dock.readMode(workspaceId)

  function openMenu(item, slot) {
    window.settingsMenu = false
    window.menuItem = item
    window.menuSlot = slot
  }

  function openSettingsMenu(slot) {
    window.menuItem = null
    window.settingsMenu = true
    window.menuSlot = slot
  }

  function settleShifts() {
    window.animateShifts = false
    Qt.callLater(function() { window.animateShifts = true })
  }

  function endDrag() {
    window.settleShifts()
    window.hoverStale = true
    window.dragIndex = -1
    window.dropIndex = -1
    window.dragOffset = 0
  }

  function closeMenu() {
    window.menuItem = null
    window.settingsMenu = false
    window.menuSlot = null
    if (window.autohide) hideTimer.restart()
  }

  function popupX(slot, popup) {
    var target = slot || body
    var center = target.mapToItem(window.contentItem, target.width / 2, 0).x
    if (window.position === "left") return body.x + body.width + window.gap
    if (window.position === "right") return body.x - window.gap - popup.width
    return Math.max(window.gap, Math.min(window.width - popup.width - window.gap, Math.round(center - popup.width / 2)))
  }

  function popupY(slot, popup, extraLift) {
    var lift = extraLift || 0
    var target = slot || body
    var center = target.mapToItem(window.contentItem, 0, target.height / 2).y
    if (window.position === "top") return body.y + body.height + window.gap + lift
    if (window.position === "bottom") return body.y - window.gap - lift - popup.height
    return Math.max(window.gap, Math.min(window.height - popup.height - window.gap, Math.round(center - popup.height / 2)))
  }

  color: "transparent"
  WlrLayershell.namespace: "omarchy-dock"
  WlrLayershell.layer: window.fullscreenMode >= 2 ? WlrLayer.Overlay : WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: 0

  anchors {
    top: window.position !== "bottom"
    bottom: window.position !== "top"
    left: window.position !== "right"
    right: window.position !== "left"
  }

  implicitWidth: window.vertical ? window.gap + window.slotWidth + window.pillPadX * 2 + window.popupRoom : 0
  implicitHeight: window.vertical ? 0 : window.gap + window.slotHeight + window.pillPadTop + window.pillPadBottom + window.popupRoom

  mask: Region {
    item: window.contentShown ? body : null

    Region { item: window.shown && window.autohide ? edgeTrigger : null }
    Region { item: menu.visible ? menu : null }
  }

  onAutohideChanged: window.revealed = false

  Timer {
    id: hideTimer
    interval: 180
    onTriggered: {
      if (!bodyHover.hovered && !edgeHover.hovered && !window.menuOpen && !window.dragging) {
        window.revealed = false
        window.hoveredSlot = null
        window.hoveredAppIndex = -1
      }
    }
  }

  Item {
    id: edgeTrigger

    readonly property int depth: 5
    readonly property int spanLength: window.vertical ? window.height : window.width

    x: window.position === "left" ? 0
      : window.position === "right" ? window.width - depth
      : Math.round((window.width - spanLength) / 2)
    y: window.position === "top" ? 0
      : window.position === "bottom" ? window.height - depth
      : Math.round((window.height - spanLength) / 2)
    width: window.vertical ? depth : spanLength
    height: window.vertical ? spanLength : depth

    HoverHandler {
      id: edgeHover
      onHoveredChanged: {
        if (hovered) window.revealed = true
        else hideTimer.restart()
      }
    }
  }

  HyprlandFocusGrab {
    active: window.menuOpen
    windows: [window]
    onCleared: window.closeMenu()
  }

  BorderSurface {
    id: body

    LayoutMirroring.enabled: false
    LayoutMirroring.childrenInherit: true

    width: slotsFlow.implicitWidth + window.pillPadX * 2
    height: slotsFlow.implicitHeight + (window.vertical ? window.pillPadX * 2 : (window.pillPadTop + window.pillPadBottom))
    radius: 18
    // Match `Bar.qml`'s exact `glassBackground` (`Math.min(background.a, 0.35)`
    // over Hyprland's `omarchy-glass` blur) so the dock glass is neither darker
    // nor lighter than the top status bar in Dark or Light mode.
    color: Qt.rgba(
      Commons.Color.bar.background.r,
      Commons.Color.bar.background.g,
      Commons.Color.bar.background.b,
      Math.min(Commons.Color.bar.background.a, 0.35)
    )
    borderSpec: Border.flat(
      Qt.rgba(
        Commons.Color.bar.text.r,
        Commons.Color.bar.text.g,
        Commons.Color.bar.text.b,
        0.08
      ),
      1
    )

    // Right-clicking the glass margin (or Shift+right-clicking) opens dock settings.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.RightButton
      onClicked: window.openSettingsMenu(body)
    }

    property real tuck: window.tucked ? (window.vertical ? width : height) + window.gap + 8 : 0

    Behavior on tuck {
      id: tuckMotion
      enabled: window.shown
      NumberAnimation {
        duration: Style.duration(tuckMotion.targetValue > 0 ? 140 : 190)
        easing.type: Easing.OutCubic
      }
    }

    x: window.position === "left" ? window.gap - tuck
      : window.position === "right" ? window.width - width - window.gap + tuck
      : Math.round((window.width - width) / 2)
    y: window.position === "top" ? window.gap - tuck
      : window.position === "bottom" ? window.height - height - window.gap + tuck
      : Math.round((window.height - height) / 2)

    opacity: window.shown ? 1 : 0

    HoverHandler {
      id: bodyHover
      onHoveredChanged: {
        if (!hovered) {
          window.hoveredSlot = null
          window.hoveredAppIndex = -1
          if (window.autohide) hideTimer.restart()
        }
      }
      onPointChanged: {
        if (!window.hoverStale || window.dragging) return
        var at = point.position
        if (Math.hypot(at.x - window.dropPoint.x, at.y - window.dropPoint.y) > Style.space(4)) window.hoverStale = false
      }
    }

    Grid {
      id: slotsFlow
      x: window.pillPadX
      y: window.vertical ? window.pillPadX : window.pillPadTop
      columns: window.vertical ? 1 : Math.max(1, appRepeater.count)

      Repeater {
        id: appRepeater
        model: window.dock ? window.dock.itemModel : null

        delegate: AppSlot {}
      }
    }
  }

  BorderSurface {
    id: hoverTooltip

    readonly property bool active: window.contentShown
      && !window.menuOpen
      && !window.dragging
      && window.hoveredSlot !== null
      && window.hoveredTitle !== ""

    visible: opacity > 0.01
    opacity: active ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(90); easing.type: Easing.OutCubic } }

    width: tooltipRow.implicitWidth + Style.spacing.md * 2
    height: tooltipRow.implicitHeight + 8
    x: window.popupX(window.hoveredSlot, hoverTooltip)
    y: window.popupY(window.hoveredSlot, hoverTooltip, 4)
    radius: 9
    color: Qt.rgba(
      Commons.Color.popups.background.r,
      Commons.Color.popups.background.g,
      Commons.Color.popups.background.b,
      0.92
    )
    borderSpec: Border.flat(
      Qt.rgba(
        Commons.Color.popups.text.r,
        Commons.Color.popups.text.g,
        Commons.Color.popups.text.b,
        0.12
      ),
      1
    )

    Row {
      id: tooltipRow
      anchors.centerIn: parent
      spacing: Style.spacing.xs

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: window.hoveredTitle
        color: Commons.Color.popups.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
        font.weight: Font.Medium
      }

      Text {
        visible: window.hoveredSubtitle !== ""
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "· " + window.hoveredSubtitle
        color: Commons.Color.popups.text
        opacity: 0.6
        font.family: Style.font.menuFamily
        font.pixelSize: Math.max(10, Style.font.body - 1)
      }
    }
  }

  component AppSlot: Item {
    id: appSlot

    required property int index
    required property string key
    readonly property var modelData: window.dock ? window.dock.itemFor(key) : null
    readonly property bool launching: !!window.dock && window.dock.isLaunching(key)
    readonly property bool lifted: window.dragIndex === index
    readonly property bool hovered: slotMouse.containsMouse && !window.hoverStale && !window.dragging
    readonly property bool neighborHovered: !hovered && !window.dragging && window.hoveredAppIndex >= 0 && Math.abs(index - window.hoveredAppIndex) === 1
    property point pressPoint
    property bool dragged: false
    readonly property int windowCount: modelData ? modelData.windows.length : 0
    readonly property bool focusedApp: {
      if (!modelData || !modelData.windows) return false
      for (var i = 0; i < modelData.windows.length; i++) {
        if (modelData.windows[i].toplevel && modelData.windows[i].toplevel.activated)
          return true
      }
      return false
    }
    property real pulse: 1

    readonly property string tooltipTitle: window.dock && modelData ? window.dock.labelFor(modelData) : ""
    readonly property string tooltipSubtitle: window.dock && modelData ? window.dock.spacesLabelFor(modelData) : ""
    readonly property string resolvedIcon: window.dock && modelData ? String(window.dock.iconFor(modelData) || "") : ""
    readonly property bool isSvgIcon: resolvedIcon.slice(-4).toLowerCase() === ".svg"

    width: window.slotWidth
    height: window.slotHeight

    onHoveredChanged: {
      if (hovered) {
        window.hoveredSlot = appSlot
        window.hoveredAppIndex = appSlot.index
        window.hoveredTitle = appSlot.tooltipTitle
        window.hoveredSubtitle = appSlot.tooltipSubtitle
      } else if (window.hoveredSlot === appSlot) {
        window.hoveredSlot = null
        window.hoveredAppIndex = -1
      }
    }

    onTooltipTitleChanged: if (window.hoveredSlot === appSlot) window.hoveredTitle = tooltipTitle
    onTooltipSubtitleChanged: if (window.hoveredSlot === appSlot) window.hoveredSubtitle = tooltipSubtitle

    readonly property int slotSpan: window.vertical ? window.slotHeight : window.slotWidth
    readonly property real shift: !window.dragging ? 0
      : lifted ? window.dragOffset
      : (window.dragIndex < index && index <= window.dropIndex) ? -slotSpan
      : (window.dropIndex <= index && index < window.dragIndex) ? slotSpan
      : 0
    property real displayedShift: shift

    Behavior on displayedShift {
      enabled: window.animateShifts && window.dragging && !appSlot.lifted
      NumberAnimation { duration: Style.duration(150); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }

    z: lifted ? 2 : (hovered ? 1 : 0)

    function bodyPoint(event) {
      return appSlot.mapToItem(body, event.x, event.y)
    }

    MouseArea {
      id: slotMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

      onPressed: function(event) {
        appSlot.dragged = false
        if (event.button === Qt.LeftButton) appSlot.pressPoint = appSlot.bodyPoint(event)
      }

      onPositionChanged: function(event) {
        if (!(slotMouse.pressedButtons & Qt.LeftButton)) return
        var point = appSlot.bodyPoint(event)
        var delta = window.vertical ? point.y - appSlot.pressPoint.y : point.x - appSlot.pressPoint.x
        if (Math.hypot(point.x - appSlot.pressPoint.x, point.y - appSlot.pressPoint.y) > Style.space(4)) appSlot.dragged = true
        if (!window.dragging) {
          if (Math.abs(delta) < Style.space(6)) return
          window.closeMenu()
          window.dropIndex = appSlot.index
          window.dragIndex = appSlot.index
        }
        if (!appSlot.lifted) return
        window.dragOffset = delta
        window.dropIndex = DockModel.dropIndex(appSlot.index, delta, appSlot.slotSpan, appRepeater.count)
      }

      onReleased: function(event) {
        if (!appSlot.lifted) return
        window.dropPoint = appSlot.mapToItem(body, event.x, event.y)
        var from = window.dragIndex
        var to = window.dropIndex
        appSlot.dragged = true
        window.endDrag()
        window.dock.moveItem(from, to)
      }

      onCanceled: if (appSlot.lifted) window.endDrag()

      onClicked: function(event) {
        if (appSlot.dragged) {
          appSlot.dragged = false
          return
        }
        if (event.button === Qt.RightButton) {
          if (event.modifiers & Qt.ShiftModifier) window.openSettingsMenu(appSlot)
          else window.openMenu(appSlot.modelData, appSlot)
          return
        }
        window.closeMenu()
        if (event.button === Qt.MiddleButton) window.dock.launch(appSlot.modelData)
        else window.dock.activate(appSlot.modelData)
      }
    }

    Item {
      anchors.fill: parent
      transform: Translate {
        x: window.vertical ? 0 : appSlot.displayedShift
        y: window.vertical ? appSlot.displayedShift : 0
      }

      Image {
        x: Math.round((parent.width - window.iconSize) / 2)
        y: Math.round((parent.height - window.iconSize) / 2) - 2
        width: window.iconSize
        height: window.iconSize
        // Rasterize SVGs at 256x256 for Retina crispness; decode high-DPI PNGs
        // at native resolution with hardware trilinear mipmaps (avoiding Qt's
        // QImageReader box-shrink aliasing on diagonal edges like Brave's lion).
        sourceSize: appSlot.isSvgIcon ? Qt.size(256, 256) : undefined
        source: appSlot.resolvedIcon
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
        antialiasing: true
        opacity: appSlot.launching ? appSlot.pulse : (appSlot.windowCount > 0 ? 1 : window.idleOpacity)
        scale: appSlot.lifted || appSlot.hovered ? 1.16 : (appSlot.neighborHovered ? 1.05 : 1)
        transformOrigin: window.popOrigin

        Behavior on scale { NumberAnimation { duration: Style.duration(130); easing.type: Easing.OutCubic } }
      }

      Rectangle {
        visible: appSlot.windowCount > 0 || appSlot.launching
        width: appSlot.focusedApp ? 5 : 4
        height: 4
        radius: 2
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 0
        color: Commons.Color.bar.text
        opacity: appSlot.focusedApp ? 0.92 : 0.48

        Behavior on width { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
      }
    }

    SequentialAnimation {
      running: appSlot.launching && !Style.reduceMotion
      loops: Animation.Infinite
      onRunningChanged: if (!running) appSlot.pulse = 1

      NumberAnimation { target: appSlot; property: "pulse"; from: 1; to: window.idleOpacity; duration: Style.duration(500); easing.type: Easing.InOutSine }
      NumberAnimation { target: appSlot; property: "pulse"; to: 1; duration: Style.duration(500); easing.type: Easing.InOutSine }
    }
  }

  BorderSurface {
    id: menu

    readonly property var item: window.menuItem
    readonly property bool hasEntry: !!item && !!window.dock && !!window.dock.entryFor(item)
    readonly property bool running: !!item && item.windows.length > 0

    visible: window.contentShown && (!!item || window.settingsMenu)
    width: Math.max(Style.space(140), menuColumn.implicitWidth) + padding * 2
    height: menuColumn.implicitHeight + padding * 2
    x: window.popupX(window.menuSlot, menu)
    y: window.popupY(window.menuSlot, menu, 0)
    radius: Style.cornerRadius
    color: Commons.Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    padding: Style.spacing.sm

    Column {
      id: menuColumn
      x: menu.contentLeftInset
      y: menu.contentTopInset
      width: menu.width - menu.contentLeftInset - menu.contentRightInset

      Repeater {
        model: [["top", Commons.I18n.t("dock.positionTop")], ["bottom", Commons.I18n.t("dock.positionBottom")], ["left", Commons.I18n.t("dock.positionLeft")], ["right", Commons.I18n.t("dock.positionRight")]]

        delegate: PopupMenuRow {
          required property var modelData

          visible: window.settingsMenu
          text: modelData[1]
          checked: window.position === modelData[0]
          onTriggered: {
            Util.execDetached("omarchy-dock position " + modelData[0])
            window.closeMenu()
          }
        }
      }

      PopupMenuRow {
        visible: window.settingsMenu
        text: Commons.I18n.t("dock.autoHide")
        checked: window.autohide
        onTriggered: {
          Util.execDetached("omarchy-dock autohide " + (window.autohide ? "off" : "on"))
          window.closeMenu()
        }
      }

      PopupMenuRow {
        visible: menu.hasEntry && menu.running
        text: Commons.I18n.t("dock.newWindow")
        onTriggered: {
          window.dock.launch(menu.item)
          window.closeMenu()
        }
      }

      PopupMenuRow {
        visible: menu.hasEntry
        text: menu.item && menu.item.pinned ? Commons.I18n.t("dock.removeFromDock") : Commons.I18n.t("dock.keepInDock")
        onTriggered: {
          window.dock.setPinned(menu.item.key, !menu.item.pinned)
          window.closeMenu()
        }
      }

      PopupMenuRow {
        visible: menu.running
        text: Commons.I18n.t("dock.quit")
        onTriggered: {
          window.dock.quit(menu.item)
          window.closeMenu()
        }
      }
    }
  }
}
