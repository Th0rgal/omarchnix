import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "omarchnix.sharing"
  ipcTarget: "omarchnix.sharing"
  manageIpc: true

  readonly property var engine: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("omarchnix.sharing")
    : null

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool anyReceiving: engine ? engine.anyReceiving : false
  readonly property bool urgentPrompt: engine ? engine.hasUrgentPrompt : false
  readonly property var devices: engine ? engine.unifiedDevices : []
  readonly property var qsTransfer: engine ? engine.quicksharePromptTransfer : null
  readonly property var nearbyReq: engine ? engine.nearbyIncoming : null
  readonly property string nearbyText: engine ? engine.nearbyIncomingText : ""
  readonly property var qrSend: engine ? engine.qrSend : null
  readonly property string notice: engine ? engine.transientNotice : ""

  readonly property color barIconTint: {
    if (urgentPrompt) return urgentColor
    if (anyReceiving) return Commons.Color.accent
    return barForeground
  }

  readonly property string barTooltip: {
    if (urgentPrompt) return "Share: Incoming transfer — click to review"
    if (anyReceiving) {
      var activeList = []
      if (engine.airdropReceiving) activeList.push("AirDrop")
      if (engine.quickshareDiscoverable) activeList.push("Quick Share")
      if (engine.nearbyReceiving) activeList.push("Nearby")
      var rem = engine.minRemainingSeconds > 0 ? (" · " + engine.formatCountdown(engine.minRemainingSeconds)) : ""
      return "Receiving (" + activeList.join(", ") + ")" + rem
    }
    return "Share (AirDrop · Quick Share · Nearby) — Right-click: Receive 10m"
  }

  readonly property string heroMeta: {
    if (!engine) return "STARTING"
    if (urgentPrompt) return "ACTION NEEDED"
    if (engine.airdropBusy || (engine.airdropReceiving && !engine.airdropVisible)) return "WAKING AIRDROP RADIO…"
    if (anyReceiving) {
      var countdown = engine.minRemainingSeconds > 0 ? (" · " + engine.formatCountdown(engine.minRemainingSeconds)) : ""
      return "RECEIVING NEARBY" + countdown
    }
    return "AIRDROP · QUICK SHARE · NEARBY"
  }

  property bool viewRegistered: false
  property bool steppedAsideForPicker: false

  function syncOpenState() {
    if (!engine || opened === viewRegistered) return
    viewRegistered = opened
    if (opened) engine.viewOpened()
    else engine.viewClosed()
  }

  onOpenedChanged: syncOpenState()
  onEngineChanged: { viewRegistered = false; syncOpenState() }
  Component.onCompleted: syncOpenState()
  Component.onDestruction: if (engine && viewRegistered) engine.viewClosed()

  Connections {
    target: root.engine
    function onRequestCloseForPicker() {
      if (root.opened) {
        root.steppedAsideForPicker = true
        root.close()
      }
    }
    function onRequestReopenAfterPicker() {
      if (root.steppedAsideForPicker) {
        root.steppedAsideForPicker = false
        root.open()
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    tooltipText: root.barTooltip
    iconComponent: Component {
      Item {
        ShareIcon {
          anchors.centerIn: parent
          iconSize: Style.space(14)
          color: root.barIconTint
          active: root.anyReceiving || root.urgentPrompt
        }
      }
    }
    onPressed: function(mouseBtn) {
      if (mouseBtn === Qt.RightButton) {
        if (root.engine) root.engine.toggleReceiveAll()
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
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: if (root.engine) root.engine.toggleReceiveAll()

      ColumnLayout {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          Layout.fillWidth: true
          title: "Share"
          meta: root.heroMeta
          foreground: root.foreground
          iconComponent: ShareIcon {
            iconSize: Style.space(28)
            color: root.anyReceiving ? Commons.Color.accent : root.foreground
            active: root.anyReceiving
          }
          trailingControl: Button {
            bordered: true
            selected: root.anyReceiving
            foreground: root.foreground
            fontSize: Style.font.caption
            text: root.anyReceiving ? "Turn Off" : "Receive 10m"
            tooltipText: root.anyReceiving
              ? "Stop receiving across all protocols"
              : "Make this Mac visible on AirDrop, Quick Share & LocalSend for 10 minutes"
            onClicked: if (root.engine) root.engine.toggleReceiveAll()
          }
        }

        // Individual protocol toggles
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Button {
            visible: root.engine ? root.engine.airdropAvailable : true
            Layout.fillWidth: true
            bordered: true
            selected: root.engine ? root.engine.airdropReceiving : false
            foreground: root.foreground
            fontSize: Style.font.caption
            iconText: "󰀵"
            text: {
              if (!root.engine || !root.engine.airdropReceiving) return "AirDrop"
              if (!root.engine.airdropVisible) return "AirDrop…"
              return root.engine.airdropRemaining > 0
                ? root.engine.formatCountdown(root.engine.airdropRemaining)
                : "AirDrop"
            }
            tooltipText: "Apple AirDrop (iPhone, iPad, Mac)"
            onClicked: if (root.engine) root.engine.toggleAirdrop()
          }

          Button {
            visible: root.engine ? root.engine.quickshareAvailable : true
            Layout.fillWidth: true
            bordered: true
            selected: root.engine ? root.engine.quickshareDiscoverable : false
            foreground: root.foreground
            fontSize: Style.font.caption
            iconText: "󰄜"
            text: {
              if (!root.engine || !root.engine.quickshareDiscoverable) return "Android"
              return root.engine.quickshareRemaining > 0
                ? root.engine.formatCountdown(root.engine.quickshareRemaining)
                : "Android"
            }
            tooltipText: "Android & Chromebook Quick Share"
            onClicked: if (root.engine) root.engine.toggleQuickshare()
          }

          Button {
            visible: root.engine ? root.engine.nearbyAvailable : true
            Layout.fillWidth: true
            bordered: true
            selected: root.engine ? root.engine.nearbyReceiving : false
            foreground: root.foreground
            fontSize: Style.font.caption
            iconText: "󰍹"
            text: {
              if (!root.engine || !root.engine.nearbyReceiving) return "Nearby"
              return root.engine.nearbyRemaining > 0
                ? root.engine.formatCountdown(root.engine.nearbyRemaining)
                : "Nearby"
            }
            tooltipText: "LocalSend cross-platform LAN sharing"
            onClicked: if (root.engine) root.engine.toggleNearby()
          }
        }

        // Quick Share active / incoming transfer card (including PIN verification)
        BorderSurface {
          visible: root.qsTransfer !== null
          Layout.fillWidth: true
          implicitHeight: qsTransferCol.implicitHeight + Style.space(20)
          color: Style.selectedFillFor(root.foreground, Commons.Color.accent)
          borderSpec: Border.controlSpec("selected", root.foreground, Commons.Color.accent)
          radius: Style.cornerRadius

          ColumnLayout {
            id: qsTransferCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            spacing: Style.space(6)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.qsTransfer
                ? ((root.qsTransfer.direction === "inbound" ? "From " : "To ") + String(root.qsTransfer.device_name || "Android device"))
                : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              visible: !!(root.qsTransfer && root.qsTransfer.pin_code)
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.qsTransfer && root.qsTransfer.pin_code ? ("PIN: " + root.qsTransfer.pin_code) : ""
              color: Commons.Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              font.letterSpacing: 2
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                visible: !!(root.qsTransfer && root.qsTransfer.direction === "inbound" && root.qsTransfer.state === "waiting_acceptance")
                Layout.fillWidth: true
                bordered: true
                selected: true
                foreground: root.foreground
                fontSize: Style.font.caption
                text: "Accept"
                onClicked: if (root.engine && root.qsTransfer) root.engine.respondQuickshare(root.qsTransfer.id, true)
              }

              Button {
                visible: !!(root.qsTransfer && root.qsTransfer.direction === "inbound" && root.qsTransfer.state === "waiting_acceptance")
                Layout.fillWidth: true
                bordered: true
                foreground: root.foreground
                fontSize: Style.font.caption
                text: "Decline"
                onClicked: if (root.engine && root.qsTransfer) root.engine.respondQuickshare(root.qsTransfer.id, false)
              }

              Button {
                visible: !!(root.qsTransfer && !(root.qsTransfer.direction === "inbound" && root.qsTransfer.state === "waiting_acceptance"))
                Layout.fillWidth: true
                bordered: true
                foreground: root.foreground
                fontSize: Style.font.caption
                text: "Cancel"
                onClicked: if (root.engine && root.qsTransfer) root.engine.cancelQuickshare(root.qsTransfer.id)
              }
            }
          }
        }

        // LocalSend incoming file prompt
        BorderSurface {
          visible: root.nearbyReq !== null
          Layout.fillWidth: true
          implicitHeight: nearbyReqCol.implicitHeight + Style.space(20)
          color: Style.selectedFillFor(root.foreground, Commons.Color.accent)
          borderSpec: Border.controlSpec("selected", root.foreground, Commons.Color.accent)
          radius: Style.cornerRadius

          ColumnLayout {
            id: nearbyReqCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            spacing: Style.space(6)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.nearbyReq ? (root.nearbyReq.sender + " · " + root.nearbyReq.summary) : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              wrapMode: Text.Wrap
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                Layout.fillWidth: true
                bordered: true
                selected: true
                foreground: root.foreground
                fontSize: Style.font.caption
                text: "Accept"
                onClicked: if (root.engine) root.engine.acceptNearby()
              }

              Button {
                Layout.fillWidth: true
                bordered: true
                foreground: root.foreground
                fontSize: Style.font.caption
                text: "Decline"
                onClicked: if (root.engine) root.engine.declineNearby()
              }
            }
          }
        }

        // LocalSend incoming text snippet
        BorderSurface {
          visible: root.nearbyText !== ""
          Layout.fillWidth: true
          implicitHeight: nearbyTextCol.implicitHeight + Style.space(20)
          color: Style.selectedFillFor(root.foreground, Commons.Color.accent)
          borderSpec: Border.controlSpec("selected", root.foreground, Commons.Color.accent)
          radius: Style.cornerRadius

          ColumnLayout {
            id: nearbyTextCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            spacing: Style.space(6)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.nearbyText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              maximumLineCount: 4
              elide: Text.ElideRight
              wrapMode: Text.WrapAnywhere
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                Layout.fillWidth: true
                bordered: true
                selected: true
                foreground: root.foreground
                fontSize: Style.font.caption
                text: "Copy"
                onClicked: if (root.engine) root.engine.copyNearbyText()
              }

              Button {
                Layout.fillWidth: true
                bordered: true
                foreground: root.foreground
                fontSize: Style.font.caption
                text: "Dismiss"
                onClicked: if (root.engine) root.engine.dismissNearbyText()
              }
            }
          }
        }

        // Android Quick Share QR Code invitation card
        BorderSurface {
          visible: root.qrSend !== null
          Layout.fillWidth: true
          implicitHeight: qrCol.implicitHeight + Style.space(20)
          color: Commons.Color.popups.background
          borderSpec: Border.controlSpec("selected", root.foreground, Commons.Color.accent)
          radius: Style.cornerRadius

          ColumnLayout {
            id: qrCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            spacing: Style.space(8)

            Rectangle {
              Layout.alignment: Qt.AlignHCenter
              Layout.preferredWidth: Style.space(176)
              Layout.preferredHeight: Style.space(176)
              radius: Style.cornerRadius
              color: "#ffffff"

              Image {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                source: root.qrSend ? String(root.qrSend.image || "") : ""
                fillMode: Image.PreserveAspectFit
                smooth: false
              }
            }

            Text {
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: root.qrSend && root.engine
                ? ("Scan on Android · " + root.engine.qrRemaining + "s")
                : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              Layout.fillWidth: true
              bordered: true
              foreground: root.foreground
              fontSize: Style.font.caption
              text: "Close QR"
              onClicked: if (root.engine) root.engine.stopQr()
            }
          }
        }

        // Transient status / progress notice
        RowLayout {
          visible: root.notice !== ""
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: root.notice
            color: (root.engine && (root.engine.airdropError !== "" || root.engine.quickshareError !== ""))
              ? root.urgentColor
              : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          Button {
            visible: !!(root.engine && (root.engine.airdropSending || root.engine.nearbyOutgoingId !== ""))
            bordered: true
            foreground: root.foreground
            fontSize: Style.font.caption
            text: "Cancel"
            onClicked: {
              if (!root.engine) return
              if (root.engine.airdropSending) root.engine.cancelAirdropSend()
              if (root.engine.nearbyOutgoingId !== "") root.engine.cancelNearbySend()
            }
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
        }

        PanelSectionHeader {
          Layout.fillWidth: true
          foreground: root.foreground
          text: root.devices.length > 0
            ? ("SEND TO NEARBY (" + root.devices.length + ")")
            : "SEND TO NEARBY"
        }

        // Unified discovered peer list
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(4)

          Repeater {
            model: root.devices

            Button {
              required property var modelData
              Layout.fillWidth: true
              leftAlign: true
              bordered: false
              foreground: root.foreground
              iconText: modelData.icon
              text: modelData.name + "  ·  " + modelData.badge
              tooltipText: "Click to choose files and send via " + modelData.badge
              onClicked: if (root.engine) root.engine.pickAndSend(modelData)
            }
          }

          Text {
            visible: root.devices.length === 0
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: (root.engine && root.engine.airdropReceiving)
              ? "Scanning AirDrop, Quick Share & LocalSend…"
              : "Looking on Quick Share & LocalSend. Turn on AirDrop above to also scan nearby Apple devices."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
        }

        // Compact utility actions
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Button {
            visible: root.engine ? root.engine.quickshareAvailable : false
            Layout.fillWidth: true
            bordered: true
            foreground: root.foreground
            fontSize: Style.font.caption
            iconText: "󰐲"
            text: "Send via QR"
            tooltipText: "Pick files and display a QR code for Android Quick Share"
            onClicked: if (root.engine) root.engine.pickAndQr()
          }

          Button {
            Layout.fillWidth: true
            bordered: true
            foreground: root.foreground
            fontSize: Style.font.caption
            iconText: "󰉋"
            text: "Downloads"
            tooltipText: "Open ~/Downloads"
            onClicked: {
              if (root.engine) root.engine.openDownloads()
              root.close()
            }
          }
        }
      }
    }
  }
}
