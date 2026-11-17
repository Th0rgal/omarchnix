import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import qs.Ui as Ui

// Bar icon for agent SSH grants. Hidden when there are none; green while one is valid,
// orange once one has expired (renew or revoke it from the popup).
Panel {
  id: root
  moduleName: "omarchnix.agent-grants"
  ipcTarget: "omarchnix.agent-grants"
  manageIpc: false

  readonly property var engine: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("omarchnix.agent-grants")
    : null

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function revokeAll(): string {
      if (root.engine) root.engine.revokeAll()
      return "ok"
    }
  }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool isLight: (Commons.Color.background.r + Commons.Color.background.g + Commons.Color.background.b) > 1.5
  readonly property color okColor: isLight ? "#248a3d" : "#30d158"
  readonly property color warnColor: isLight ? "#c93400" : "#ff9f0a"

  readonly property var grantList: engine ? engine.grants : []
  readonly property bool hasAny: grantList.length > 0
  readonly property bool hasActive: engine ? engine.hasActive : false
  readonly property bool hasExpired: hasAny && !hasActive
  readonly property string errText: engine ? engine.lastError : ""

  readonly property color tint: hasActive ? okColor : (hasExpired ? warnColor : (bar ? bar.barForeground : Commons.Color.foreground))
  readonly property string glyph: "󰌆"

  readonly property string barTooltip: {
    if (!engine) return "Agent Access"
    if (hasActive) {
      var n = engine.activeGrants.length
      return "Agent access: " + n + " grant" + (n > 1 ? "s" : "") + " · "
        + engine.formatCountdown(engine.minRemainingSeconds) + " left — right-click: revoke all"
    }
    return "Agent access expired — click to renew"
  }

  readonly property string heroMeta: {
    if (!engine) return "STARTING…"
    if (hasActive) return engine.activeGrants.length + " ACTIVE · " + engine.formatCountdown(engine.minRemainingSeconds)
    return "EXPIRED"
  }

  visible: hasAny
  implicitWidth: hasAny ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    tooltipText: root.barTooltip
    text: root.glyph
    foreground: root.tint
    active: root.hasActive
    activeColor: root.tint
    onPressed: function(mouseBtn) {
      if (mouseBtn === Qt.RightButton && root.hasActive && root.engine) {
        root.engine.revokeAll()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      ColumnLayout {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          Layout.fillWidth: true
          title: "Agent Access"
          meta: root.heroMeta
          foreground: root.foreground
          iconComponent: Text {
            text: root.glyph
            color: root.tint
            font.family: root.fontFamily
            font.pixelSize: Style.space(26)
          }
        }

        Repeater {
          model: root.grantList

          delegate: BorderSurface {
            id: row
            required property var modelData
            readonly property bool valid: root.engine
              ? (modelData.active && root.engine.remainingFor(modelData) > 0)
              : false
            readonly property bool working: root.engine ? root.engine.busyName === String(modelData.name) : false

            Layout.fillWidth: true
            implicitHeight: rowCol.implicitHeight + Style.space(16)
            color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.05)
            borderSpec: Border.controlSpec("subtle", root.foreground, Commons.Color.accent)
            radius: Style.cornerRadius

            ColumnLayout {
              id: rowCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(6)

              RowLayout {
                Layout.fillWidth: true
                Text {
                  text: String(row.modelData.name)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  Layout.fillWidth: true
                }
                Text {
                  text: row.valid && root.engine
                    ? root.engine.formatCountdown(root.engine.remainingFor(row.modelData)) + " left"
                    : "expired"
                  color: row.valid ? root.okColor : root.warnColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Text {
                Layout.fillWidth: true
                text: "as " + String(row.modelData.principals || "?")
                  + (row.modelData.hosts ? " · " + String(row.modelData.hosts).split(",").length + " host(s)" : "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)
                Item { Layout.fillWidth: true }
                Ui.Button {
                  bordered: true
                  enabled: !row.working
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  text: row.working ? "Touch YubiKey…" : "Renew 24h"
                  tooltipText: "Mint a fresh 24h certificate (one YubiKey touch)"
                  onClicked: if (root.engine) root.engine.renew(row.modelData.name)
                }
                Ui.Button {
                  bordered: true
                  selected: true
                  enabled: !row.working
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  text: "Revoke"
                  tooltipText: "Push a revocation list to this grant's hosts, then delete the key"
                  onClicked: if (root.engine) root.engine.revoke(row.modelData.name)
                }
              }
            }
          }
        }

        BorderSurface {
          visible: root.errText !== ""
          Layout.fillWidth: true
          implicitHeight: errTxt.implicitHeight + Style.space(14)
          color: Qt.rgba(root.urgentColor.r, root.urgentColor.g, root.urgentColor.b, 0.14)
          borderSpec: Border.controlSpec("selected", root.foreground, root.urgentColor)
          radius: Style.cornerRadius

          Text {
            id: errTxt
            anchors.fill: parent
            anchors.margins: Style.space(7)
            text: root.errText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }
      }
    }
  }
}
