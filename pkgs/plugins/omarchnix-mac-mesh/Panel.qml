import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import qs.Ui as Ui

Panel {
  id: root
  moduleName: "omarchnix.mac-mesh"
  ipcTarget: "omarchnix.mac-mesh"
  manageIpc: false

  readonly property var engine: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("omarchnix.mac-mesh")
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

  readonly property bool hasPending: engine ? engine.hasPending : false
  readonly property bool hasActive: engine ? engine.hasActive : false
  readonly property var pendingList: engine ? engine.pendingRequests : []
  readonly property var activeList: engine ? engine.activeLeases : []
  readonly property string errText: engine ? engine.lastError : ""

  property real pulseAlpha: 1.0
  SequentialAnimation {
    running: root.hasPending
    loops: Animation.Infinite
    NumberAnimation { target: root; property: "pulseAlpha"; from: 1.0; to: 0.42; duration: 750; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulseAlpha"; from: 0.42; to: 1.0; duration: 750; easing.type: Easing.InOutSine }
  }

  readonly property color barIconTint: {
    if (hasPending) return warnColor
    if (hasActive) return okColor
    return bar ? bar.barForeground : Commons.Color.foreground
  }

  readonly property string barGlyph: {
    if (hasPending) return "󰒃"
    if (hasActive) return "󰌘"
    return "󰖂"
  }

  readonly property string barTooltip: {
    if (hasPending) {
      return "Mac Tether: " + pendingList.length + " mission request(s) waiting for Touch ID"
    }
    if (hasActive && engine) {
      var rem = engine.minRemainingSeconds > 0 ? (" · " + engine.formatCountdown(engine.minRemainingSeconds)) : ""
      return "Mac Tether Active (" + activeList.length + ")" + rem + " — Right-click: Revoke All"
    }
    var umb = engine ? engine.umbrelTransportLabel : "Offline"
    var spk = engine ? engine.sparkTransportLabel : "Offline"
    return "Lean-Mesh · Umbrel: " + umb + " · Spark: " + spk + " · Tether Idle"
  }

  readonly property string heroMeta: {
    if (!engine || !engine.daemonOnline) return "DAEMON STARTING…"
    if (hasPending) return pendingList.length + " APPROVAL NEEDED"
    if (hasActive) {
      var c = engine.minRemainingSeconds > 0 ? (" · " + engine.formatCountdown(engine.minRemainingSeconds)) : ""
      return activeList.length + " ACTIVE LEASE" + (activeList.length > 1 ? "S" : "") + c
    }
    return engine.coreOnline ? "SOVEREIGN MESH READY" : "ORB CORE OFFLINE"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    tooltipText: root.barTooltip
    text: root.barGlyph
    foreground: root.barIconTint
    active: root.hasPending || root.hasActive
    activeColor: root.barIconTint
    opacity: root.hasPending ? root.pulseAlpha : 1.0
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
    contentWidth: popup.fittedContentWidth(Style.space(368))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Flickable {
        id: bodyFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height + 1

        ColumnLayout {
          id: column
          width: bodyFlick.width
          spacing: Style.space(10)

          PanelHero {
            Layout.fillWidth: true
            title: "Mac Mesh"
            meta: root.heroMeta
            foreground: root.foreground
            iconComponent: Text {
              text: root.barGlyph
              color: root.hasPending ? root.warnColor : (root.hasActive ? root.okColor : root.foreground)
              font.family: root.fontFamily
              font.pixelSize: Style.space(26)
            }
            trailingControl: Ui.Button {
              visible: root.hasActive
              bordered: true
              selected: true
              foreground: root.foreground
              fontSize: Style.font.caption
              text: "Revoke All"
              tooltipText: "Immediately sever all active mission tether leases"
              onClicked: if (root.engine) root.engine.revokeAll()
            }
          }

          // Three-plane Lean-Mesh topology status strip
          BorderSurface {
            Layout.fillWidth: true
            implicitHeight: planesCol.implicitHeight + Style.space(16)
            color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.05)
            borderSpec: Border.controlSpec("subtle", root.foreground, Commons.Color.accent)
            radius: Style.cornerRadius

            ColumnLayout {
              id: planesCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(4)

              RowLayout {
                Layout.fillWidth: true
                Text {
                  text: "Paloma Fleet (10.88.0.100)"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.fillWidth: true
                }
                Text {
                  text: (root.engine && root.engine.palomaUp) ? "Connected" : "Standby"
                  color: (root.engine && root.engine.palomaUp) ? root.okColor : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              RowLayout {
                Layout.fillWidth: true
                Text {
                  text: "Umbrel Home (10.88.50.20)"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.fillWidth: true
                }
                Text {
                  text: root.engine ? root.engine.umbrelTransportLabel : "Offline"
                  color: (root.engine && root.engine.personalUp) ? root.okColor : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              RowLayout {
                Layout.fillWidth: true
                Text {
                  text: "DGX Spark (10.88.50.30)"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.fillWidth: true
                }
                Text {
                  text: root.engine ? root.engine.sparkTransportLabel : "Offline"
                  color: (root.engine && root.engine.personalUp && root.engine.sparkTransportLabel !== "Standby") ? root.okColor : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              RowLayout {
                Layout.fillWidth: true
                Text {
                  text: "Tether Hub (10.88.200.1)"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.fillWidth: true
                }
                Text {
                  text: root.hasActive ? (root.activeList.length + " Active") : ((root.engine && root.engine.tetherUp) ? "Guarded" : "Starting")
                  color: root.hasActive ? Commons.Color.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
          }

          // Error banner if Touch ID or approval failed
          BorderSurface {
            visible: root.errText !== ""
            Layout.fillWidth: true
            implicitHeight: errTxt.implicitHeight + Style.space(14)
            color: Qt.rgba(root.urgentColor.r, root.urgentColor.g, root.urgentColor.b, 0.14)
            borderSpec: Border.controlSpec("selected", root.foreground, root.urgentColor)
            radius: Style.cornerRadius

            Text {
              id: errTxt
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(7)
              text: root.errText
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.urgentColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // Pending mission tether approval cards
          Repeater {
            model: root.pendingList

            delegate: BorderSurface {
              required property var modelData
              readonly property string reqId: String(modelData.id || "")
              readonly property string reqScope: String(modelData.requested_scope || "sandbox_ssh")
              readonly property bool isPreviewOnly: reqScope === "preview"
              readonly property string curTarget: root.engine ? root.engine.targetFor(modelData) : "sandbox"
              readonly property int curTtl: root.engine ? root.engine.ttlFor(modelData) : 60
              readonly property var agentPorts: Array.isArray(modelData.agent_ports) ? modelData.agent_ports : []

              Layout.fillWidth: true
              implicitHeight: pendCol.implicitHeight + Style.space(20)
              color: Style.selectedFillFor(root.foreground, root.warnColor)
              borderSpec: Border.controlSpec("selected", root.foreground, root.warnColor)
              radius: Style.cornerRadius

              ColumnLayout {
                id: pendCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(10)
                spacing: Style.space(6)

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: String(modelData.requester_label || modelData.mission_id || "Orb Mission")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.is_managed_vm ? "CLOUD VM" : String(modelData.host_id || "WORKER").toUpperCase()
                    color: root.warnColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  text: String(modelData.reason || "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: agentPorts.length > 0
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: "Forward to MacBook: localhost:" + agentPorts.join(", localhost:")
                  color: Commons.Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                // Target selector (`Sandbox` vs `Host (thomas)`) for SSH control requests
                RowLayout {
                  visible: !isPreviewOnly
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Ui.Button {
                    Layout.fillWidth: true
                    bordered: true
                    selected: curTarget === "sandbox"
                    foreground: root.foreground
                    fontSize: Style.font.caption
                    text: "Sandbox"
                    tooltipText: "Isolated orb-sandbox container (zero access to /home/thomas)"
                    onClicked: if (root.engine) root.engine.setTargetFor(reqId, "sandbox")
                  }

                  Ui.Button {
                    Layout.fillWidth: true
                    bordered: true
                    selected: curTarget === "thomas"
                    foreground: root.foreground
                    fontSize: Style.font.caption
                    text: "Host (thomas)"
                    tooltipText: "Confined thomas shell (~/.ssh, ~/.orb & Bitwarden masked; lateral mesh blocked)"
                    onClicked: if (root.engine) root.engine.setTargetFor(reqId, "thomas")
                  }
                }

                // Lease TTL selector
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Ui.Button {
                    Layout.fillWidth: true
                    bordered: true
                    selected: curTtl === 15
                    foreground: root.foreground
                    fontSize: Style.font.caption
                    text: "15m"
                    onClicked: if (root.engine) root.engine.setTtlFor(reqId, 15)
                  }

                  Ui.Button {
                    Layout.fillWidth: true
                    bordered: true
                    selected: curTtl === 60
                    foreground: root.foreground
                    fontSize: Style.font.caption
                    text: "1h"
                    onClicked: if (root.engine) root.engine.setTtlFor(reqId, 60)
                  }

                  Ui.Button {
                    Layout.fillWidth: true
                    bordered: true
                    selected: curTtl === 240
                    foreground: root.foreground
                    fontSize: Style.font.caption
                    text: "4h"
                    onClicked: if (root.engine) root.engine.setTtlFor(reqId, 240)
                  }
                }

                // Approve with Touch ID / Deny actions
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Ui.Button {
                    Layout.fillWidth: true
                    bordered: true
                    selected: true
                    enabled: !(root.engine && root.engine.busy)
                    foreground: root.foreground
                    fontSize: Style.font.caption
                    iconText: "󰈷"
                    text: (root.engine && root.engine.busy && root.engine.busyRequestId === reqId)
                      ? "Touch ID…"
                      : "Approve"
                    onClicked: if (root.engine) root.engine.approve(reqId, curTarget, curTtl)
                  }

                  Ui.Button {
                    Layout.fillWidth: true
                    bordered: true
                    enabled: !(root.engine && root.engine.busy)
                    foreground: root.foreground
                    fontSize: Style.font.caption
                    text: "Deny"
                    onClicked: if (root.engine) root.engine.deny(reqId)
                  }
                }
              }
            }
          }

          // Active approved leases
          Repeater {
            model: root.activeList

            delegate: BorderSurface {
              required property var modelData
              readonly property string leaseId: String(modelData.id || "")
              readonly property string effScope: String(modelData.effective_scope || "sandbox_ssh")
              readonly property var previewPorts: Array.isArray(modelData.bound_preview_ports)
                ? modelData.bound_preview_ports
                : (Array.isArray(modelData.agent_ports) ? modelData.agent_ports : [])
              readonly property int remSecs: root.engine
                ? Math.max(0, Math.ceil(Number(modelData.expires_at || 0) - root.engine.nowSec))
                : Number(modelData.remaining_secs || 0)

              Layout.fillWidth: true
              implicitHeight: actCol.implicitHeight + Style.space(20)
              color: Style.selectedFillFor(root.foreground, root.okColor)
              borderSpec: Border.controlSpec("selected", root.foreground, root.okColor)
              radius: Style.cornerRadius

              ColumnLayout {
                id: actCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(10)
                spacing: Style.space(6)

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: String(modelData.requester_label || modelData.mission_id || "Active Mission")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: root.engine ? root.engine.formatCountdown(remSecs) : ""
                    color: root.okColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: {
                    var badge = effScope === "host_ssh"
                      ? "HOST SSH (thomas · confined)"
                      : (effScope === "preview" ? "PREVIEW TUNNEL" : "SANDBOX SSH (orb-sandbox)")
                    return badge + " · " + String(modelData.overlay_ip || "")
                  }
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                // One-click browser launchers for forwarded Next.js / web preview ports
                RowLayout {
                  visible: previewPorts.length > 0
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Repeater {
                    model: previewPorts
                    delegate: Ui.Button {
                      required property var modelData
                      Layout.fillWidth: true
                      bordered: true
                      selected: true
                      foreground: root.foreground
                      fontSize: Style.font.caption
                      iconText: "󰖟"
                      text: "localhost:" + String(modelData)
                      tooltipText: "Open http://localhost:" + String(modelData) + " in browser"
                      onClicked: {
                        if (root.engine) root.engine.openPreviewPort(modelData)
                        root.close()
                      }
                    }
                  }
                }

                Ui.Button {
                  Layout.fillWidth: true
                  bordered: true
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  text: "Revoke Access"
                  onClicked: if (root.engine) root.engine.revoke(leaseId)
                }
              }
            }
          }

          // Idle empty-state note when no pending or active tethers exist
          Text {
            visible: !root.hasPending && !root.hasActive
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "No active MacBook tether leases. Missions requesting `request_macbook_tether` require Touch ID here; SSH leases auto-revoke on screen lock or lid close."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
