import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string omdropBin: "@OMDROP_BIN@"
  readonly property string quickshareBin: "@QUICKSHARE_BIN@"
  readonly property string nearbyHelperBin: "@NEARBY_HELPER_BIN@"
  readonly property string fileSelectBin: "@FILE_SELECT_BIN@"
  readonly property string notifyBin: "@NOTIFY_BIN@"
  readonly property string xdgOpenBin: "@XDG_OPEN_BIN@"
  readonly property string wlCopyBin: "@WL_COPY_BIN@"

  readonly property bool airdropAvailable: omdropBin !== "" && omdropBin.charAt(0) !== "@"
  readonly property bool quickshareAvailable: quickshareBin !== "" && quickshareBin.charAt(0) !== "@"
  readonly property bool nearbyAvailable: nearbyHelperBin !== "" && nearbyHelperBin.charAt(0) !== "@"

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string defaultDownloadsDir: homeDir !== "" ? (homeDir + "/Downloads") : "/tmp"

  signal requestCloseForPicker()
  signal requestReopenAfterPicker()

  property int openViewCount: 0
  readonly property bool anyViewOpen: openViewCount > 0

  function viewOpened() {
    openViewCount++
    if (openViewCount === 1) {
      if (airdropAvailable) refreshAirdropStatus()
      if (nearbyReady) sendNearby({ command: "discovery_start" })
    }
  }

  function viewClosed() {
    if (openViewCount > 0) openViewCount--
    if (openViewCount === 0) {
      if (nearbyReady) sendNearby({ command: "discovery_stop" })
      if (!nearbyReceiving && !nearbyTransferActive && nearbyBackend.running) {
        sendNearby({ command: "shutdown" })
      }
      if (qrSend) stopQr()
    }
  }

  // ------------------------------------------------------------------ AirDrop
  property bool airdropReceiving: false
  property bool airdropVisible: false
  property bool airdropBusy: false
  property int airdropRemaining: -1
  property string airdropDeviceName: ""
  property string airdropError: ""
  property var airdropPeers: []
  property var airdropPeerNames: ({})
  property bool airdropStatusStale: false

  readonly property bool airdropScanning: anyViewOpen && airdropReceiving && airdropVisible

  function refreshAirdropStatus() {
    if (!airdropAvailable) return
    if (airdropStatusProc.running) airdropStatusStale = true
    else airdropStatusProc.running = true
  }

  function applyAirdropStatus(raw) {
    try {
      var s = JSON.parse(String(raw || ""))
      airdropReceiving = !!s.receiving
      airdropVisible = s.visible === true
      airdropRemaining = (s.remaining === null || s.remaining === undefined) ? -1 : Number(s.remaining)
      airdropDeviceName = String(s.name || "")
      if (airdropReceiving && airdropVisible) airdropError = ""
    } catch (e) {}
  }

  function setAirdrop(enable) {
    if (!airdropAvailable || airdropBusy || airdropToggleProc.running) return
    if (Boolean(enable) === airdropReceiving) return
    airdropBusy = true
    airdropError = ""
    airdropToggleProc.command = enable
      ? [omdropBin, "on", "10m"]
      : [omdropBin, "off"]
    airdropToggleProc.running = true
  }

  function toggleAirdrop() {
    setAirdrop(!airdropReceiving)
  }

  Process {
    id: airdropStatusProc
    command: [root.omdropBin, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (!root.airdropStatusStale) root.applyAirdropStatus(text)
    }
    onExited: {
      if (root.airdropStatusStale) {
        root.airdropStatusStale = false
        airdropStatusProc.running = true
      }
    }
  }

  Process {
    id: airdropToggleProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.airdropError = text.trim()
    }
    onExited: function(code) {
      root.airdropBusy = false
      if (code === 0) root.airdropError = ""
      root.refreshAirdropStatus()
    }
  }

  // Poll AirDrop status every 3s ONLY while waiting for AWDL radio visibility.
  Timer {
    interval: 3000
    repeat: true
    running: root.airdropAvailable && root.airdropReceiving && !root.airdropVisible
    onTriggered: root.refreshAirdropStatus()
  }

  // Poll AirDrop peers ONLY while the panel is open and AirDrop is visible.
  Timer {
    interval: 2500
    repeat: true
    running: root.airdropScanning
    triggeredOnStart: true
    onTriggered: {
      if (!airdropPeersProc.running) airdropPeersProc.running = true
      if (!airdropNamesProc.running) airdropNamesProc.running = true
    }
  }

  onAirdropScanningChanged: {
    if (!airdropScanning && airdropNamesProc.running) {
      airdropNamesProc.signal(15)
    }
  }

  Process {
    id: airdropPeersProc
    command: [root.omdropBin, "peers", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(text)
          if (!Array.isArray(arr)) return
          root.airdropPeers = arr.map(function(p) {
            var mac = String(p.mac || "")
            return {
              mac: mac,
              rssi: p.rssi,
              name: String(p.name || root.airdropPeerNames[mac] || "")
            }
          })
        } catch (e) {}
      }
    }
  }

  Process {
    id: airdropNamesProc
    command: [root.omdropBin, "peers", "--json", "-n", "--stream"]
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var row = JSON.parse(String(line || "").trim())
          if (row && row.mac && row.name) {
            var next = Object.assign({}, root.airdropPeerNames)
            next[String(row.mac)] = String(row.name)
            root.airdropPeerNames = next
            root.airdropPeers = root.airdropPeers.map(function(p) {
              return p.mac === String(row.mac)
                ? { mac: p.mac, rssi: p.rssi, name: String(row.name) }
                : p
            })
          }
        } catch (e) {}
      }
    }
  }

  // --------------------------------------------------------------- Quick Share
  property var quickshareSnapshot: null
  property bool quickshareOnline: false
  property bool quickshareWantActive: false
  property bool qrPending: false
  property double nowSec: Date.now() / 1000
  property string quickshareError: ""

  readonly property var quickshareDevices: quickshareSnapshot && Array.isArray(quickshareSnapshot.devices)
    ? quickshareSnapshot.devices : []
  readonly property var quickshareTransfers: quickshareSnapshot && Array.isArray(quickshareSnapshot.transfers)
    ? quickshareSnapshot.transfers : []
  readonly property bool quickshareDiscoverable: quickshareOnline && !!quickshareSnapshot && quickshareSnapshot.visible === true
    && (quickshareSnapshot.visibility_expires_at === null || quickshareSnapshot.visibility_expires_at > nowSec)
  readonly property int quickshareRemaining: quickshareDiscoverable && quickshareSnapshot.visibility_expires_at !== null
    ? Math.max(0, Math.ceil(quickshareSnapshot.visibility_expires_at - nowSec)) : -1
  readonly property bool quickshareHasActiveTransfer: quickshareTransfers.some(function(t) {
    return ["completed", "rejected", "cancelled", "failed"].indexOf(String(t.state || "")) === -1
  })
  readonly property var qrSend: quickshareOnline && quickshareSnapshot && quickshareSnapshot.qr_send
    && quickshareSnapshot.qr_send.expires_at > nowSec ? quickshareSnapshot.qr_send : null
  readonly property int qrRemaining: qrSend ? Math.max(0, Math.ceil(qrSend.expires_at - nowSec)) : 0

  readonly property bool shouldWatchQuickshare: quickshareAvailable && (
    anyViewOpen || quickshareWantActive || quickshareDiscoverable || quickshareHasActiveTransfer || qrPending || qrSend !== null
  )

  Process {
    id: quickshareWatch
    command: [root.quickshareBin, "watch"]
    running: root.shouldWatchQuickshare
    stdout: SplitParser {
      onRead: function(line) {
        var s = String(line || "").trim()
        if (!s) return
        try {
          var snap = JSON.parse(s)
          if (snap && snap.version === 1) {
            root.quickshareSnapshot = snap
            root.quickshareOnline = true
            root.nowSec = Date.now() / 1000
            if (!snap.visible && !root.qrPending) {
              // Once backend confirms visibility ended, release sticky flag.
              if (root.quickshareWantActive && snap.visibility_expires_at === null) {
                root.quickshareWantActive = false
              }
            }
          }
        } catch (e) {}
      }
    }
    onExited: {
      root.quickshareOnline = false
      if (root.shouldWatchQuickshare) quickshareReconnect.restart()
    }
  }

  Timer {
    id: quickshareReconnect
    interval: 2000
    onTriggered: if (root.shouldWatchQuickshare && !quickshareWatch.running) quickshareWatch.running = true
  }

  Component {
    id: qsCmdComponent
    Process {
      id: qsTask
      property string payload: ""
      property string kind: "cmd"
      onStarted: {
        if (!stdinEnabled) return
        write(payload + "\n")
        payload = ""
        stdinEnabled = false
      }
      stderr: StdioCollector { id: qsErr; waitForEnd: true }
      onExited: function(code) {
        if (kind === "qr-send") root.qrPending = false
        if (code !== 0 && qsErr.text.trim() !== "") {
          root.quickshareError = qsErr.text.trim()
        }
        Qt.callLater(function() { qsTask.destroy() })
      }
    }
  }

  function runQuickshareCmd(args, stdinValue, kind) {
    if (!quickshareAvailable) return
    var hasStdin = stdinValue !== undefined
    var task = qsCmdComponent.createObject(root, {
      command: [quickshareBin].concat(args),
      stdinEnabled: hasStdin,
      payload: hasStdin ? JSON.stringify(stdinValue) : "",
      kind: kind || "cmd"
    })
    task.running = true
  }

  function setQuickshare(enable) {
    if (!quickshareAvailable) return
    quickshareError = ""
    if (enable) quickshareWantActive = true
    else quickshareWantActive = false
    runQuickshareCmd(["visible", enable ? "600" : "0"])
  }

  function toggleQuickshare() {
    setQuickshare(!quickshareDiscoverable)
  }

  function respondQuickshare(transferId, accept) {
    runQuickshareCmd([accept ? "accept" : "reject", String(transferId)])
  }

  function cancelQuickshare(transferId) {
    runQuickshareCmd(["cancel", String(transferId)])
  }

  function stopQr() {
    qrPending = false
    if (qrSend && qrSend.id) {
      runQuickshareCmd(["qr-stop", String(qrSend.id)])
    }
  }

  // -------------------------------------------------------- Nearby (LocalSend)
  property bool nearbyReceiving: false
  property int nearbyRemaining: -1
  property bool nearbyReady: false
  property var nearbyDevices: []
  property var nearbyIncoming: null
  property string nearbyIncomingText: ""
  property string nearbyIncomingSender: ""
  property bool nearbyTransferActive: false
  property string nearbyStatus: ""
  property real nearbyProgress: 0
  property string nearbyOutgoingId: ""
  property int nearbySeq: 0

  readonly property bool shouldRunNearby: nearbyAvailable && (
    nearbyReceiving || anyViewOpen || nearbyTransferActive || nearbyIncoming !== null
  )

  function sendNearby(cmdObj) {
    if (!nearbyBackend.running) return
    nearbyBackend.write(JSON.stringify(cmdObj) + "\n")
  }

  function setNearby(enable) {
    if (!nearbyAvailable) return
    if (enable) {
      nearbyReceiving = true
      nearbyRemaining = 600
      if (nearbyReady && anyViewOpen) sendNearby({ command: "discovery_start" })
    } else {
      nearbyReceiving = false
      nearbyRemaining = -1
      if (!anyViewOpen && !nearbyTransferActive && nearbyBackend.running) {
        sendNearby({ command: "shutdown" })
      }
    }
  }

  function toggleNearby() {
    setNearby(!nearbyReceiving)
  }

  function upsertNearbyDevice(list, dev) {
    if (!dev || !dev.fingerprint || !dev.alias) return list
    var next = list.slice()
    var row = {
      alias: String(dev.alias),
      version: String(dev.version || "2.1"),
      deviceModel: String(dev.deviceModel || ""),
      deviceType: String(dev.deviceType || "desktop"),
      fingerprint: String(dev.fingerprint),
      port: Number(dev.port || 53317),
      protocol: String(dev.protocol || "https"),
      download: dev.download === true,
      ip: String(dev.ip || "")
    }
    var idx = -1
    for (var i = 0; i < next.length; i++) {
      if (next[i].fingerprint === row.fingerprint) { idx = i; break }
    }
    if (idx >= 0) next[idx] = row
    else next.push(row)
    next.sort(function(a, b) { return a.alias.localeCompare(b.alias) })
    return next
  }

  function handleNearbyEvent(ev) {
    if (!ev || !ev.event) return
    if (ev.event === "ready") {
      nearbyReady = true
      if (anyViewOpen) sendNearby({ command: "discovery_start" })
    } else if (ev.event === "peer_snapshot") {
      var list = []
      var raw = Array.isArray(ev.devices) ? ev.devices : []
      for (var i = 0; i < raw.length; i++) list = upsertNearbyDevice(list, raw[i])
      nearbyDevices = list
    } else if (ev.event === "device") {
      nearbyDevices = upsertNearbyDevice(nearbyDevices, ev.device)
    } else if (ev.event === "incoming_request") {
      var files = Array.isArray(ev.files) ? ev.files : []
      var summary = files.length === 0 ? "File transfer"
        : (files.length === 1 ? String(files[0].name || "File") : (String(files[0].name || "File") + " + " + (files.length - 1) + " more"))
      nearbyIncoming = {
        requestId: String(ev.requestId || ""),
        sender: String(ev.sender || "Nearby device"),
        summary: summary
      }
      if (!anyViewOpen && notifyBin !== "" && notifyBin.charAt(0) !== "@") {
        Quickshell.execDetached([notifyBin, "--app-name", "Share", "Incoming transfer", nearbyIncoming.sender + " wants to send " + summary])
      }
    } else if (ev.event === "incoming_text") {
      nearbyIncomingText = String(ev.text || "")
      nearbyIncomingSender = String(ev.sender || "Nearby device")
      if (!anyViewOpen && notifyBin !== "" && notifyBin.charAt(0) !== "@") {
        Quickshell.execDetached([notifyBin, "--app-name", "Share", "Text received", "From " + nearbyIncomingSender])
      }
    } else if (ev.event === "incoming_expired" || ev.event === "incoming_declined" || ev.event === "incoming_accepted") {
      if (nearbyIncoming && nearbyIncoming.requestId === String(ev.requestId || "")) {
        nearbyIncoming = null
      }
    } else if (ev.event === "incoming_progress" || ev.event === "outgoing_progress") {
      nearbyTransferActive = true
      nearbyProgress = ev.total > 0 ? (Number(ev.bytes || 0) / Number(ev.total)) : 0
      nearbyStatus = (ev.event === "incoming_progress" ? "Receiving " : "Sending ") + String(ev.name || "file") + "…"
    } else if (ev.event === "outgoing_preparing") {
      nearbyTransferActive = true
      nearbyProgress = 0
      nearbyStatus = "Preparing " + String(ev.name || "files") + "…"
    } else if (ev.event === "incoming_done" || ev.event === "outgoing_done") {
      nearbyTransferActive = false
      nearbyProgress = 1
      nearbyOutgoingId = ""
      nearbyStatus = ev.event === "incoming_done" ? "Received in ~/Downloads" : "Sent"
      statusClearTimer.restart()
    } else if (ev.event === "incoming_failed" || ev.event === "outgoing_failed" || ev.event === "incoming_cancelled" || ev.event === "outgoing_cancelled") {
      nearbyTransferActive = false
      nearbyOutgoingId = ""
      nearbyStatus = String(ev.message || "Transfer stopped")
      statusClearTimer.restart()
    }
  }

  function acceptNearby() {
    if (!nearbyIncoming) return
    var reqId = nearbyIncoming.requestId
    nearbyIncoming = null
    nearbyTransferActive = true
    nearbyStatus = "Receiving…"
    sendNearby({ command: "accept", request_id: reqId })
  }

  function declineNearby() {
    if (!nearbyIncoming) return
    var reqId = nearbyIncoming.requestId
    nearbyIncoming = null
    sendNearby({ command: "decline", request_id: reqId })
  }

  function dismissNearbyText() {
    nearbyIncomingText = ""
    nearbyIncomingSender = ""
  }

  function copyNearbyText() {
    if (nearbyIncomingText === "" || wlCopyBin === "" || wlCopyBin.charAt(0) === "@") return
    var task = qsCmdComponent.createObject(root, {
      command: [wlCopyBin],
      stdinEnabled: true,
      payload: nearbyIncomingText,
      kind: "copy"
    })
    task.running = true
    nearbyStatus = "Copied to clipboard"
    dismissNearbyText()
    statusClearTimer.restart()
  }

  Process {
    id: nearbyBackend
    command: [root.nearbyHelperBin]
    running: root.shouldRunNearby
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        try { root.handleNearbyEvent(JSON.parse(String(line || ""))) } catch (e) {}
      }
    }
    onExited: {
      root.nearbyReady = false
      root.nearbyDevices = []
      root.nearbyTransferActive = false
    }
  }

  // ------------------------------------------------ Unified state & countdowns
  readonly property bool anyReceiving: airdropReceiving || quickshareDiscoverable || nearbyReceiving

  readonly property var quicksharePromptTransfer: {
    for (var i = 0; i < quickshareTransfers.length; i++) {
      var t = quickshareTransfers[i]
      if (t && ["completed", "rejected", "cancelled", "failed"].indexOf(String(t.state || "")) === -1) {
        return t
      }
    }
    return null
  }

  readonly property bool hasUrgentPrompt: (
    (quicksharePromptTransfer !== null && String(quicksharePromptTransfer.state) === "waiting_acceptance")
    || nearbyIncoming !== null
    || nearbyIncomingText !== ""
  )

  readonly property int minRemainingSeconds: {
    var vals = []
    if (airdropReceiving && airdropRemaining > 0) vals.push(airdropRemaining)
    if (quickshareDiscoverable && quickshareRemaining > 0) vals.push(quickshareRemaining)
    if (nearbyReceiving && nearbyRemaining > 0) vals.push(nearbyRemaining)
    if (vals.length === 0) return -1
    var m = vals[0]
    for (var i = 1; i < vals.length; i++) if (vals[i] < m) m = vals[i]
    return m
  }

  function formatCountdown(secs) {
    if (secs === undefined || secs === null || secs < 0) return ""
    var m = Math.floor(secs / 60)
    var s = secs % 60
    return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.anyReceiving || root.qrSend !== null || root.anyViewOpen
    onTriggered: {
      root.nowSec = Date.now() / 1000
      if (root.airdropReceiving && root.airdropRemaining > 0) {
        root.airdropRemaining--
        if (root.airdropRemaining <= 0) {
          root.airdropRemaining = -1
          root.airdropReceiving = false
          root.airdropVisible = false
          root.refreshAirdropStatus()
        }
      }
      if (root.nearbyReceiving && root.nearbyRemaining > 0) {
        root.nearbyRemaining--
        if (root.nearbyRemaining <= 0) {
          root.setNearby(false)
        }
      }
    }
  }

  function toggleReceiveAll() {
    if (anyReceiving) {
      if (airdropReceiving) setAirdrop(false)
      if (quickshareDiscoverable) setQuickshare(false)
      if (nearbyReceiving) setNearby(false)
    } else {
      if (airdropAvailable) setAirdrop(true)
      if (quickshareAvailable) setQuickshare(true)
      if (nearbyAvailable) setNearby(true)
    }
  }

  readonly property var unifiedDevices: {
    var out = []
    for (var i = 0; i < airdropPeers.length; i++) {
      var ap = airdropPeers[i]
      if (!ap || !ap.name) continue
      out.push({
        key: "airdrop:" + ap.mac,
        protocol: "airdrop",
        badge: "AirDrop",
        icon: "󰀵",
        name: ap.name,
        mac: ap.mac
      })
    }
    for (var j = 0; j < quickshareDevices.length; j++) {
      var qd = quickshareDevices[j]
      if (!qd || !qd.id) continue
      out.push({
        key: "quickshare:" + qd.id,
        protocol: "quickshare",
        badge: "Quick Share",
        icon: "󰄜",
        name: String(qd.name || "Android device"),
        peerId: String(qd.id)
      })
    }
    for (var k = 0; k < nearbyDevices.length; k++) {
      var nd = nearbyDevices[k]
      if (!nd || !nd.fingerprint) continue
      out.push({
        key: "nearby:" + nd.fingerprint,
        protocol: "nearby",
        badge: "Nearby",
        icon: nd.deviceType === "mobile" ? "󰄜" : "󰍹",
        name: nd.alias,
        rawDevice: nd
      })
    }
    return out
  }

  // ------------------------------------------------ File selection & Outgoing
  property var pendingTargetPeer: null
  property bool pendingQrMode: false
  property string airdropSendStatus: ""
  property bool airdropSending: false

  readonly property string transientNotice: {
    if (airdropError !== "") return airdropError
    if (quickshareError !== "") return quickshareError
    if (airdropSendStatus !== "") return airdropSendStatus
    if (nearbyStatus !== "") return nearbyStatus
    return ""
  }

  Timer {
    id: statusClearTimer
    interval: 3500
    onTriggered: {
      if (!root.airdropSending) root.airdropSendStatus = ""
      if (!root.nearbyTransferActive) root.nearbyStatus = ""
    }
  }

  function pickAndSend(peer) {
    if (!peer || filePicker.running || fileSelectBin === "" || fileSelectBin.charAt(0) === "@") return
    pendingTargetPeer = peer
    pendingQrMode = false
    requestCloseForPicker()
    filePicker.running = true
  }

  function pickAndQr() {
    if (!quickshareAvailable || filePicker.running || fileSelectBin === "" || fileSelectBin.charAt(0) === "@") return
    pendingTargetPeer = null
    pendingQrMode = true
    quickshareWantActive = true
    requestCloseForPicker()
    filePicker.running = true
  }

  Process {
    id: filePicker
    command: [root.fileSelectBin, "--title", "Choose files to share", "--multiple"]
    stdout: StdioCollector { id: pickerOut; waitForEnd: true }
    onExited: function(code) {
      var target = root.pendingTargetPeer
      var wantQr = root.pendingQrMode
      root.pendingTargetPeer = null
      root.pendingQrMode = false
      root.requestReopenAfterPicker()
      if (code !== 0) return
      var files = String(pickerOut.text || "").split("\n").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
      if (files.length === 0) return

      if (wantQr) {
        root.qrPending = true
        root.runQuickshareCmd(["qr-send"], files, "qr-send")
        return
      }
      if (!target) return

      if (target.protocol === "airdrop") {
        root.airdropSending = true
        root.airdropSendStatus = "Sending to " + target.name + "…"
        airdropSendProc.command = [root.omdropBin, "send", "--to", target.mac].concat(files)
        airdropSendProc.running = true
      } else if (target.protocol === "quickshare") {
        root.quickshareWantActive = true
        root.runQuickshareCmd(["send", target.peerId], files, "send")
      } else if (target.protocol === "nearby" && target.rawDevice) {
        root.nearbySeq++
        root.nearbyOutgoingId = "out-" + Date.now() + "-" + root.nearbySeq
        root.nearbyTransferActive = true
        root.nearbyStatus = "Sending to " + target.name + "…"
        root.sendNearby({
          command: "send_files",
          transfer_id: root.nearbyOutgoingId,
          device: target.rawDevice,
          paths: files
        })
      }
    }
  }

  Process {
    id: airdropSendProc
    stdout: SplitParser {
      onRead: function(line) {
        var t = String(line || "").trim()
        if (t !== "") root.airdropSendStatus = t
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var t = String(line || "").trim()
        if (t !== "" && t.indexOf("waiting up to") === -1) root.airdropSendStatus = t
      }
    }
    onExited: function(code) {
      root.airdropSending = false
      root.airdropSendStatus = code === 0 ? "Sent via AirDrop" : (root.airdropSendStatus || "AirDrop send failed")
      statusClearTimer.restart()
    }
  }

  function cancelAirdropSend() {
    if (airdropSendProc.running) {
      airdropSendProc.signal(15)
      airdropSending = false
      airdropSendStatus = "Cancelled"
      statusClearTimer.restart()
    }
  }

  function cancelNearbySend() {
    if (nearbyOutgoingId !== "") {
      sendNearby({ command: "cancel_outgoing", transfer_id: nearbyOutgoingId })
    }
  }

  function openDownloads() {
    if (xdgOpenBin === "" || xdgOpenBin.charAt(0) === "@") return
    Quickshell.execDetached([xdgOpenBin, defaultDownloadsDir])
  }

  Component.onCompleted: {
    if (airdropAvailable) refreshAirdropStatus()
  }
}
