import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import qs.Ui as Ui

Panel {
  id: root
  moduleName: "omarchnix.sharing"
  ipcTarget: "omarchnix.sharing"
  manageIpc: false

  readonly property var engine: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("omarchnix.sharing")
    : null

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function share(payloadJson: string): string {
      if (root.engine) root.engine.stageFilesJson(payloadJson)
      root.open()
      return "ok"
    }
    function sendClipboard(): string {
      if (root.engine) root.engine.sendClipboardToPhone("--all", "")
      return "ok"
    }
  }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool anyReceiving: engine ? engine.anyReceiving : false
  readonly property bool urgentPrompt: engine ? engine.hasUrgentPrompt : false
  readonly property bool hasActiveTransfer: engine ? engine.hasActiveTransfer : false
  readonly property real transferProgress: engine ? engine.activeTransferProgress : -1
  readonly property string transferLabel: engine ? engine.activeTransferLabel : ""
  readonly property var devices: engine ? engine.unifiedDevices : []
  readonly property var qsTransfer: engine ? engine.quicksharePromptTransfer : null
  readonly property var nearbyReq: engine ? engine.nearbyIncoming : null
  readonly property string nearbyText: engine ? engine.nearbyIncomingText : ""
  readonly property var qrSend: engine ? engine.qrSend : null
  readonly property string notice: engine ? engine.transientNotice : ""

  readonly property bool kcAvailable: engine ? engine.kdeconnectAvailable : false
  readonly property var kcConnected: engine ? engine.kdeconnectConnectedDevices : []
  readonly property var kcPairable: engine ? engine.kdeconnectPairableDevices : []
  readonly property var kcAllDevices: engine ? engine.kdeconnectDevices : []
  readonly property var kcPairPrompt: engine ? engine.kdeconnectPairPrompt : null
  readonly property var kcCustomIps: engine ? engine.kdeconnectCustomAddresses : []
  readonly property string kcMeshIp: engine ? engine.kdeconnectLocalMeshIp : ""
  readonly property string kcMeshIface: engine ? engine.kdeconnectLocalMeshIface : ""
  readonly property string kcLanIp: engine ? engine.kdeconnectLocalLanIp : ""

  readonly property var kcPaired: kcAllDevices.filter(d => d.paired)
  property string expandedPhone: ""
  property bool showPairSetup: false

  property real pulseAlpha: 1.0
  SequentialAnimation {
    running: root.urgentPrompt
    loops: Animation.Infinite
    NumberAnimation { target: root; property: "pulseAlpha"; from: 1.0; to: 0.42; duration: 750; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulseAlpha"; from: 0.42; to: 1.0; duration: 750; easing.type: Easing.InOutSine }
  }

  readonly property string barGlyph: (anyReceiving || urgentPrompt || hasActiveTransfer) ? "󰀃" : "󰈇"

  readonly property color barIconTint: {
    if (urgentPrompt) return urgentColor
    if (anyReceiving || hasActiveTransfer) return Commons.Color.accent
    return barForeground
  }

  readonly property string barTooltip: {
    if (urgentPrompt) return "Share: Action needed — click to review"
    if (hasActiveTransfer && transferLabel !== "") return "Share · " + transferLabel
    if (anyReceiving) {
      var activeList = []
      if (engine.airdropReceiving) activeList.push("AirDrop")
      if (engine.quickshareDiscoverable) activeList.push("Quick Share")
      if (engine.nearbyReceiving) activeList.push("LocalSend")
      var rem = engine.minRemainingSeconds > 0 ? (" · " + engine.formatCountdown(engine.minRemainingSeconds)) : ""
      return "Receiving (" + activeList.join(", ") + ")" + rem
    }
    if (kcConnected.length > 0) {
      var names = kcConnected.map(function(d) {
        return d.battery >= 0 ? (d.name + " " + d.battery + "%") : d.name
      })
      return "Share · Phone: " + names.join(", ") + " — Right-click: Receive 10m"
    }
    return "Share (AirDrop · Phone · Quick Share · LocalSend) — Right-click: Receive 10m"
  }

  readonly property string heroMeta: {
    if (!engine) return "STARTING"
    if (urgentPrompt) return "ACTION NEEDED"
    if (hasActiveTransfer) return "TRANSFERRING"
    if (engine.airdropBusy || (engine.airdropReceiving && !engine.airdropVisible)) return "WAKING AIRDROP RADIO…"
    if (anyReceiving) {
      var countdown = engine.minRemainingSeconds > 0 ? (" · " + engine.formatCountdown(engine.minRemainingSeconds)) : ""
      return "RECEIVING NEARBY" + countdown
    }
    if (kcConnected.length > 0) {
      return kcConnected.length === 1
        ? ("CONNECTED · " + String(kcConnected[0].name || "PHONE").toUpperCase())
        : ("CONNECTED · " + kcConnected.length + " PHONES")
    }
    return "AIRDROP · PHONE · QUICK SHARE · LOCALSEND"
  }

  property bool viewRegistered: false
  property bool steppedAsideForPicker: false

  function syncOpenState() {
    if (!engine || opened === viewRegistered) return
    viewRegistered = opened
    if (opened) engine.viewOpened()
    else engine.viewClosed()
  }

  function submitIpField() {
    if (!engine) return
    var val = String(ipField.text || "").trim()
    if (val === "") return
    if (engine.addKdeconnectAddress(val)) {
      ipField.text = ""
      keyCatcher.forceActiveFocus()
    }
  }

  onOpenedChanged: {
    syncOpenState()
    if (!opened && ipField.activeFocus) ipField.focus = false
  }
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
    text: root.barGlyph
    foreground: root.barIconTint
    active: root.anyReceiving || root.urgentPrompt || root.hasActiveTransfer
    activeColor: root.barIconTint
    opacity: root.urgentPrompt ? root.pulseAlpha : 1.0
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
    contentWidth: popup.fittedContentWidth(Style.space(352))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(650))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: ipField.activeFocus
      onCloseRequested: root.close()
      onActivateRequested: if (root.engine) root.engine.toggleReceiveAll()

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
          spacing: Style.space(12)

          PanelHero {
            Layout.fillWidth: true
            title: "Share"
            meta: root.heroMeta
            foreground: root.foreground
            iconComponent: Text {
              text: root.barGlyph
              color: root.urgentPrompt ? root.urgentColor : ((root.anyReceiving || root.hasActiveTransfer) ? Commons.Color.accent : root.foreground)
              font.family: root.fontFamily
              font.pixelSize: Style.space(26)
            }
            trailingControl: Ui.Button {
              bordered: true
              selected: root.anyReceiving
              foreground: root.foreground
              fontSize: Style.font.caption
              text: root.anyReceiving ? "Turn Off" : "Receive 10m"
              tooltipText: root.anyReceiving
                ? "Stop receiving across ephemeral nearby protocols"
                : "Make this device visible on AirDrop, Quick Share & LocalSend for 10 minutes"
              onClicked: if (root.engine) root.engine.toggleReceiveAll()
            }
          }

          // Individual ephemeral protocol toggles
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Ui.Button {
              visible: root.engine ? root.engine.airdropAvailable : true
              Layout.fillWidth: true
              bordered: true
              selected: root.engine
                ? (root.engine.airdropBusy ? root.engine.airdropPendingEnable : root.engine.airdropReceiving)
                : false
              foreground: root.foreground
              fontSize: Style.font.caption
              iconText: "󰀵"
              text: {
                if (root.engine && root.engine.airdropBusy) return "AirDrop…"
                if (!root.engine || !root.engine.airdropReceiving) return "AirDrop"
                if (!root.engine.airdropVisible) return "AirDrop…"
                return root.engine.airdropRemaining > 0
                  ? root.engine.formatCountdown(root.engine.airdropRemaining)
                  : "AirDrop"
              }
              tooltipText: (root.engine && root.engine.airdropBusy && root.engine.airdropPendingEnable)
                ? "Waking AWDL radio — click to cancel"
                : "Apple AirDrop (iPhone, iPad, Mac)"
              onClicked: if (root.engine) root.engine.toggleAirdrop()
            }

            Ui.Button {
              visible: root.engine ? root.engine.quickshareAvailable : true
              Layout.fillWidth: true
              bordered: true
              selected: root.engine ? root.engine.quickshareDiscoverable : false
              foreground: root.foreground
              fontSize: Style.font.caption
              iconText: "󰄜"
              text: {
                if (!root.engine || !root.engine.quickshareDiscoverable) return "Quick Share"
                return root.engine.quickshareRemaining > 0
                  ? root.engine.formatCountdown(root.engine.quickshareRemaining)
                  : "Quick Share"
              }
              tooltipText: "Android & Chromebook Quick Share"
              onClicked: if (root.engine) root.engine.toggleQuickshare()
            }

            Ui.Button {
              visible: root.engine ? root.engine.nearbyAvailable : true
              Layout.fillWidth: true
              bordered: true
              selected: root.engine ? root.engine.nearbyReceiving : false
              foreground: root.foreground
              fontSize: Style.font.caption
              iconText: "󰍹"
              text: {
                if (!root.engine || !root.engine.nearbyReceiving) return "LocalSend"
                return root.engine.nearbyRemaining > 0
                  ? root.engine.formatCountdown(root.engine.nearbyRemaining)
                  : "LocalSend"
              }
              tooltipText: "LocalSend cross-platform LAN sharing"
              onClicked: if (root.engine) root.engine.toggleNearby()
            }
          }

          // KDE Connect incoming / pending pairing card
          BorderSurface {
            visible: root.kcPairPrompt !== null
            Layout.fillWidth: true
            implicitHeight: kcPairCol.implicitHeight + Style.space(20)
            color: Style.selectedFillFor(root.foreground, Commons.Color.accent)
            borderSpec: Border.controlSpec("selected", root.foreground, Commons.Color.accent)
            radius: Style.cornerRadius

            ColumnLayout {
              id: kcPairCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: root.kcPairPrompt
                  ? ((root.kcPairPrompt.pairRequestedByPeer ? "Pair request from " : "Waiting for ") + String(root.kcPairPrompt.name || "Phone"))
                  : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                visible: !!(root.kcPairPrompt && root.kcPairPrompt.verificationKey)
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: root.kcPairPrompt && root.kcPairPrompt.verificationKey
                  ? ("Key: " + root.kcPairPrompt.verificationKey)
                  : ""
                color: Commons.Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                font.letterSpacing: 1
                elide: Text.ElideRight
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Ui.Button {
                  visible: !!(root.kcPairPrompt && root.kcPairPrompt.pairRequestedByPeer)
                  Layout.fillWidth: true
                  bordered: true
                  selected: true
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  text: "Accept"
                  onClicked: if (root.engine && root.kcPairPrompt) root.engine.acceptPhonePair(root.kcPairPrompt.id)
                }

                Ui.Button {
                  visible: !!(root.kcPairPrompt && root.kcPairPrompt.pairRequestedByPeer)
                  Layout.fillWidth: true
                  bordered: true
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  text: "Decline"
                  onClicked: if (root.engine && root.kcPairPrompt) root.engine.rejectPhonePair(root.kcPairPrompt.id)
                }

                Ui.Button {
                  visible: !!(root.kcPairPrompt && !root.kcPairPrompt.pairRequestedByPeer)
                  Layout.fillWidth: true
                  bordered: true
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  text: "Cancel"
                  onClicked: if (root.engine && root.kcPairPrompt) root.engine.rejectPhonePair(root.kcPairPrompt.id)
                }
              }
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

                Ui.Button {
                  visible: !!(root.qsTransfer && root.qsTransfer.direction === "inbound" && root.qsTransfer.state === "waiting_acceptance")
                  Layout.fillWidth: true
                  bordered: true
                  selected: true
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  text: "Accept"
                  onClicked: if (root.engine && root.qsTransfer) root.engine.respondQuickshare(root.qsTransfer.id, true)
                }

                Ui.Button {
                  visible: !!(root.qsTransfer && root.qsTransfer.direction === "inbound" && root.qsTransfer.state === "waiting_acceptance")
                  Layout.fillWidth: true
                  bordered: true
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  text: "Decline"
                  onClicked: if (root.engine && root.qsTransfer) root.engine.respondQuickshare(root.qsTransfer.id, false)
                }

                Ui.Button {
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

                Ui.Button {
                  Layout.fillWidth: true
                  bordered: true
                  selected: true
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  text: "Accept"
                  onClicked: if (root.engine) root.engine.acceptNearby()
                }

                Ui.Button {
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

                Ui.Button {
                  Layout.fillWidth: true
                  bordered: true
                  selected: true
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  text: "Copy"
                  onClicked: if (root.engine) root.engine.copyNearbyText()
                }

                Ui.Button {
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

              Ui.Button {
                Layout.fillWidth: true
                bordered: true
                foreground: root.foreground
                fontSize: Style.font.caption
                text: "Close QR"
                onClicked: if (root.engine) root.engine.stopQr()
              }
            }
          }

          // Active transfer progress card
          BorderSurface {
            visible: root.hasActiveTransfer
            Layout.fillWidth: true
            implicitHeight: transferCol.implicitHeight + Style.space(16)
            color: Style.selectedFillFor(root.foreground, Commons.Color.accent)
            borderSpec: Border.controlSpec("selected", root.foreground, Commons.Color.accent)
            radius: Style.cornerRadius

            ColumnLayout {
              id: transferCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(6)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.transferLabel !== ""
                    ? (root.transferProgress >= 0
                      ? (root.transferLabel + " (" + Math.round(root.transferProgress * 100) + "%)")
                      : root.transferLabel)
                    : "Transferring…"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideRight
                }

                Ui.Button {
                  bordered: true
                  foreground: root.foreground
                  fontSize: Style.font.caption
                  text: "Cancel"
                  onClicked: if (root.engine) root.engine.cancelActiveTransfer()
                }
              }

              Rectangle {
                id: progressTrack
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(4)
                radius: Style.space(2)
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
                clip: true

                Rectangle {
                  id: progressFill
                  height: parent.height
                  radius: parent.radius
                  color: Commons.Color.accent
                  width: root.transferProgress >= 0
                    ? Math.max(Style.space(4), parent.width * root.transferProgress)
                    : parent.width * 0.35
                  x: root.transferProgress >= 0 ? 0 : indeterminatePos

                  property real indeterminatePos: 0
                  SequentialAnimation on indeterminatePos {
                    running: root.hasActiveTransfer && root.transferProgress < 0
                    loops: Animation.Infinite
                    NumberAnimation { from: -progressTrack.width * 0.35; to: progressTrack.width; duration: 1100; easing.type: Easing.InOutQuad }
                  }
                }
              }
            }
          }

          // Transient status / progress notice
          RowLayout {
            visible: root.notice !== "" && !root.hasActiveTransfer
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.notice
              color: (root.engine && (root.engine.airdropError !== "" || root.engine.quickshareError !== "" || root.engine.kdeconnectError !== ""))
                ? root.urgentColor
                : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }

          // Pre-staged files card (summoned from Flea's right-click "Share Nearby…" action)
          BorderSurface {
            visible: !!(root.engine && root.engine.stagedFiles && root.engine.stagedFiles.length > 0)
            Layout.fillWidth: true
            implicitHeight: stagedRow.implicitHeight + Style.space(16)
            color: Style.selectedFillFor(root.foreground, Commons.Color.accent)
            borderSpec: Border.controlSpec("selected", root.foreground, Commons.Color.accent)
            radius: Style.cornerRadius

            RowLayout {
              id: stagedRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(8)

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.engine ? ("Ready to send: " + root.engine.stagedFilesSummary) : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: "Click Send on a paired phone or nearby device below"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Ui.Button {
                bordered: true
                foreground: root.foreground
                fontSize: Style.font.caption
                text: "Clear"
                onClicked: if (root.engine) root.engine.clearStagedFiles()
              }
            }
          }

          // ========================================== Paired Phones (KDE Connect)
          PanelSeparator {
            visible: root.kcAvailable
            Layout.fillWidth: true
            foreground: root.foreground
          }

          ColumnLayout {
            visible: root.kcAvailable
            Layout.fillWidth: true
            spacing: Style.space(6)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              PanelSectionHeader {
                Layout.fillWidth: true
                foreground: root.foreground
                text: root.kcPaired.length > 0
                  ? ("PAIRED PHONES (" + root.kcPaired.length + ")")
                  : "PAIRED PHONES"
              }

              Ui.Button {
                visible: root.showPairSetup
                bordered: true
                foreground: root.foreground
                fontSize: Style.font.caption
                iconText: "󰑐"
                tooltipText: "Rescan LAN & saved mesh IPs"
                onClicked: if (root.engine) root.engine.refreshKdeconnect()
              }

              Ui.Button {
                bordered: true
                selected: root.showPairSetup || root.kcPairable.length > 0
                foreground: root.foreground
                fontSize: Style.font.caption
                text: root.kcPairable.length > 0 && !root.showPairSetup
                  ? ("Pair (" + root.kcPairable.length + ")")
                  : "Pair / IP"
                tooltipText: "Pair iOS / Android devices on LAN or over lean-mesh IP"
                onClicked: {
                  root.showPairSetup = !root.showPairSetup
                  if (root.showPairSetup && root.engine) root.engine.refreshKdeconnect()
                }
              }
            }

            // Paired phones stay accessible when their network connection drops.
            Repeater {
              model: root.kcPaired

              BorderSurface {
                id: phoneCard
                required property var modelData
                readonly property bool expanded: root.expandedPhone === modelData.id
                Layout.fillWidth: true
                implicitHeight: devCol.implicitHeight + Style.space(16)
                color: "transparent"
                borderSpec: Border.controlSpec("normal", root.foreground, Commons.Color.accent)
                radius: Style.cornerRadius

                ColumnLayout {
                  id: devCol
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(8)
                  spacing: Style.space(6)

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(6)

                    Ui.Button {
                      Layout.fillWidth: true
                      foreground: root.foreground
                      selected: phoneCard.expanded
                      text: String(modelData.name || "Phone") + (modelData.connected ? " · Connected" : " · Offline")
                      tooltipText: "Phone details"
                      onClicked: root.expandedPhone = phoneCard.expanded ? "" : modelData.id
                    }

                    Text {
                      visible: modelData.battery !== undefined && modelData.battery >= 0
                      textFormat: Text.PlainText
                      text: (modelData.charging ? "󰂄 " : "") + String(modelData.battery) + "%"
                      color: modelData.charging ? Commons.Color.accent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(4)

                    Ui.Button {
                      visible: modelData.connected && modelData.caps.share
                      Layout.fillWidth: true
                      bordered: true
                      selected: !!(root.engine && root.engine.stagedFiles && root.engine.stagedFiles.length > 0)
                      foreground: root.foreground
                      fontSize: Style.font.caption
                      iconText: "󰈔"
                      text: "Send"
                      tooltipText: (root.engine && root.engine.stagedFiles && root.engine.stagedFiles.length > 0)
                        ? ("Send " + root.engine.stagedFilesSummary + " to " + modelData.name)
                        : ("Choose files to send to " + modelData.name)
                      onClicked: if (root.engine) root.engine.pickAndSendToPhone(modelData)
                    }

                  }

                  Text {
                    visible: phoneCard.expanded && !modelData.connected
                    Layout.fillWidth: true
                    text: "Open KDE Connect on your phone to reconnect."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.Wrap
                  }

                  RowLayout {
                    visible: phoneCard.expanded
                    Layout.fillWidth: true
                    Ui.Button {
                      visible: typeof modelData.clipboardEnabled === "boolean"
                      selected: modelData.clipboardEnabled === true
                      bordered: true
                      foreground: root.foreground
                      text: "Share clipboard · " + (selected ? "On" : "Off")
                      onClicked: root.engine.runKdeconnectCmd(["clipboard-setting", modelData.id, selected ? "off" : "on"])
                    }
                    Ui.Button {
                      visible: modelData.connected && modelData.caps.clipboard && modelData.clipboardEnabled === true
                      bordered: true
                      foreground: root.foreground
                      text: "Send clipboard"
                      onClicked: root.engine.sendClipboardToPhone(modelData.id, modelData.name)
                    }
                  }

                  RowLayout {
                    visible: phoneCard.expanded
                    Layout.fillWidth: true
                    Ui.Button {
                      visible: modelData.mirroring === true
                      bordered: true
                      foreground: root.foreground
                      text: "Open phone"
                      onClicked: root.engine.runKdeconnectCmd(["open-phone", modelData.id])
                    }
                    Ui.Button {
                      visible: !!(modelData.caps && modelData.caps.sftp)
                      bordered: true
                      foreground: root.foreground
                      fontSize: Style.font.caption
                      iconText: "󰉋"
                      tooltipText: "Browse " + String(modelData.name || "phone") + " storage in File Explorer"
                      onClicked: {
                        if (root.engine) root.engine.browsePhoneFiles(modelData.id, modelData.name)
                        root.close()
                      }
                    }

                    Ui.Button {
                      visible: !!(modelData.caps && modelData.caps.ring)
                      bordered: true
                      foreground: root.foreground
                      fontSize: Style.font.caption
                      iconText: "󰂞"
                      tooltipText: "Ring " + String(modelData.name || "phone")
                      onClicked: if (root.engine) root.engine.ringPhone(modelData.id, modelData.name)
                    }
                  }

                  RowLayout {
                    visible: phoneCard.expanded
                    Layout.fillWidth: true
                    Ui.Button {
                      visible: modelData.caps.notifications
                      bordered: true
                      foreground: root.foreground
                      text: "Reply…"
                      tooltipText: "Reply to a phone notification"
                      onClicked: root.engine.runKdeconnectCmd(["notifications", modelData.id])
                    }
                    Ui.Button {
                      visible: modelData.caps.messages
                      bordered: true
                      foreground: root.foreground
                      text: "Messages"
                      onClicked: root.engine.runKdeconnectCmd(["messages", modelData.id])
                    }
                    Ui.Button {
                      visible: modelData.caps.media
                      bordered: true
                      foreground: root.foreground
                      text: "Play / pause"
                      onClicked: root.engine.runKdeconnectCmd(["media", modelData.id])
                    }
                  }

                  Text {
                    visible: phoneCard.expanded && (modelData.recentFiles || []).length > 0
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: "Recently received\n" + (modelData.recentFiles || []).join("\n")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WrapAnywhere
                  }
                }
              }
            }

            // Compact hint when no phone is currently connected and setup is collapsed
            Text {
              visible: root.kcPaired.length === 0 && !root.showPairSetup
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: {
                if (root.kcPairable.length > 0) {
                  return "Found " + root.kcPairable[0].name + " — click Pair (" + root.kcPairable.length + ") above to connect."
                }
                return "Open KDE Connect on iOS or Android (LAN or lean-mesh) and click Pair / IP."
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            // Collapsible Pair & lean-mesh / LAN IP drawer
            BorderSurface {
              visible: root.showPairSetup
              Layout.fillWidth: true
              implicitHeight: pairSetupCol.implicitHeight + Style.space(18)
              color: "transparent"
              borderSpec: Border.controlSpec("normal", root.foreground, Commons.Color.accent)
              radius: Style.cornerRadius

              ColumnLayout {
                id: pairSetupCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(9)
                spacing: Style.space(8)

                // This laptop's lean-mesh & LAN addresses (click to copy)
                RowLayout {
                  visible: root.kcMeshIp !== "" || root.kcLanIp !== ""
                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  Ui.Button {
                    visible: root.kcMeshIp !== ""
                    Layout.fillWidth: true
                    bordered: true
                    foreground: root.foreground
                    fontSize: Style.font.caption
                    text: "Mesh: " + root.kcMeshIp
                    tooltipText: "Click to copy this device's " + (root.kcMeshIface || "lean-mesh") + " IP for KDE Connect on your phone"
                    onClicked: if (root.engine) root.engine.copyTextValue(root.kcMeshIp, root.kcMeshIp)
                  }

                  Ui.Button {
                    visible: root.kcLanIp !== ""
                    Layout.fillWidth: true
                    bordered: true
                    foreground: root.foreground
                    fontSize: Style.font.caption
                    text: "LAN: " + root.kcLanIp
                    tooltipText: "Click to copy this device's LAN IP"
                    onClicked: if (root.engine) root.engine.copyTextValue(root.kcLanIp, root.kcLanIp)
                  }
                }

                // Direct IPv4/IPv6 input for lean-mesh (10.88.x.x) or static LAN peers
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Ui.TextField {
                    id: ipField
                    Layout.fillWidth: true
                    foreground: root.foreground
                    font.pixelSize: Style.font.caption
                    verticalPadding: Style.space(5)
                    placeholderText: "Phone IP (10.88.x.x or LAN)"
                    onAccepted: root.submitIpField()
                    Keys.onEscapePressed: function(event) {
                      keyCatcher.forceActiveFocus()
                      event.accepted = true
                    }
                  }

                  Ui.Button {
                    bordered: true
                    selected: String(ipField.text || "").trim() !== ""
                    foreground: root.foreground
                    fontSize: Style.font.caption
                    text: "Add IP"
                    tooltipText: "Save phone IP in KDE Connect and discover over lean-mesh / LAN"
                    onClicked: root.submitIpField()
                  }
                }

                // Saved custom peer IPs
                Repeater {
                  model: root.kcCustomIps

                  RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Style.space(6)

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: "Saved IP · " + String(modelData)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }

                    Ui.Button {
                      bordered: true
                      foreground: root.foreground
                      fontSize: Style.font.caption
                      text: "Remove"
                      onClicked: if (root.engine) root.engine.removeKdeconnectAddress(String(modelData))
                    }
                  }
                }

                // Reachable unpaired devices ready to pair
                Repeater {
                  model: root.kcPairable

                  RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Style.space(6)

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: "󰄜  " + String(modelData.name || modelData.id) + " · Ready"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }

                    Ui.Button {
                      bordered: true
                      selected: true
                      foreground: root.foreground
                      fontSize: Style.font.caption
                      text: "Pair"
                      onClicked: if (root.engine) root.engine.pairPhone(modelData.id, modelData.name)
                    }
                  }
                }

                // Paired devices (connected or offline) unpair management
                Repeater {
                  model: root.kcAllDevices.filter(function(d) { return d && d.paired === true })

                  RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Style.space(6)

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: String(modelData.name || modelData.id) + (modelData.connected ? " · Connected" : " · Offline")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }

                    Ui.Button {
                      bordered: true
                      foreground: root.foreground
                      fontSize: Style.font.caption
                      text: "Unpair"
                      onClicked: if (root.engine) root.engine.unpairPhone(modelData.id, modelData.name)
                    }
                  }
                }
              }
            }
          }

          // ========================================== Ephemeral Nearby Discovery
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

              Ui.Button {
                required property var modelData
                Layout.fillWidth: true
                leftAlign: true
                bordered: false
                foreground: root.foreground
                iconText: modelData.icon
                text: modelData.name + "  ·  " + modelData.badge
                tooltipText: (root.engine && root.engine.stagedFiles && root.engine.stagedFiles.length > 0)
                  ? ("Click to send " + root.engine.stagedFilesSummary + " via " + modelData.badge)
                  : ("Click to choose files and send via " + modelData.badge)
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

            Ui.Button {
              Layout.fillWidth: true
              bordered: true
              foreground: root.foreground
              fontSize: Style.font.caption
              iconText: "󰈔"
              text: "Files"
              tooltipText: "Choose files to stage, then pick a device above to send"
              onClicked: if (root.engine) root.engine.pickAndStageFiles()
            }

            Ui.Button {
              visible: root.kcConnected.length > 0
              Layout.fillWidth: true
              bordered: true
              foreground: root.foreground
              fontSize: Style.font.caption
              iconText: "󰅌"
              text: "Clipboard"
              tooltipText: "Send current clipboard to connected phone"
              onClicked: if (root.engine) root.engine.sendClipboardToPhone("--all", "")
            }

            Ui.Button {
              visible: root.engine ? root.engine.quickshareAvailable : false
              Layout.fillWidth: true
              bordered: true
              foreground: root.foreground
              fontSize: Style.font.caption
              iconText: "󰐲"
              text: "QR"
              tooltipText: "Pick files and display a QR code for Android Quick Share"
              onClicked: if (root.engine) root.engine.pickAndQr()
            }

            Ui.Button {
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
}
