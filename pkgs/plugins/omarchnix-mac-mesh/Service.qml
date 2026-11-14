import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string ctlBin: "@MAC_MESHCTL_BIN@"
  readonly property string xdgOpenBin: "@XDG_OPEN_BIN@"

  property var snapshot: null
  property bool daemonOnline: false
  property bool coreOnline: false
  property string lastError: ""
  property bool busy: false
  property string busyRequestId: ""
  property double nowSec: Math.floor(Date.now() / 1000)

  // Per-request operator UI overrides before clicking Approve (`target`: "sandbox"|"thomas", `ttl`: 15|60|240)
  property var draftTargets: ({})
  property var draftTtls: ({})

  readonly property var pendingRequests: snapshot && Array.isArray(snapshot.pending) ? snapshot.pending : []
  readonly property var activeLeases: snapshot && Array.isArray(snapshot.active) ? snapshot.active : []
  readonly property var planes: snapshot && snapshot.planes ? snapshot.planes : ({})

  readonly property bool palomaUp: !!(planes.paloma && planes.paloma.up)
  readonly property bool personalUp: !!(planes.personal && planes.personal.up)
  readonly property bool tetherUp: !!(planes.tether && planes.tether.up)

  readonly property string umbrelTransportLabel: {
    if (!personalUp) return "Offline"
    var roam = planes.personal && planes.personal.roam ? planes.personal.roam.umbrel : null
    if (roam && roam.path_kind === "direct_lan") return "Direct LAN"
    if (roam && roam.path_kind === "control_plane_relay") return "Relay (:51890)"
    return "Connected"
  }

  readonly property string sparkTransportLabel: {
    if (!personalUp) return "Offline"
    var roam = planes.personal && planes.personal.roam ? planes.personal.roam["dgx-spark"] : null
    if (roam && roam.path_kind === "direct_lan") return "Direct LAN"
    if (roam && roam.path_kind === "control_plane_relay") return "Relay (:51890)"
    return roam ? "Connected" : "Standby"
  }

  readonly property bool hasPending: pendingRequests.length > 0
  readonly property bool hasActive: activeLeases.length > 0
  readonly property bool hasActiveHostSsh: activeLeases.some(function(item) {
    return String(item.effective_scope || "") === "host_ssh"
  })

  readonly property int minRemainingSeconds: {
    if (!hasActive) return -1
    var best = -1
    for (var i = 0; i < activeLeases.length; i++) {
      var exp = Number(activeLeases[i].expires_at || 0)
      var rem = Math.max(0, Math.ceil(exp - nowSec))
      if (best < 0 || rem < best) best = rem
    }
    return best
  }

  function formatCountdown(secs) {
    var s = Math.max(0, Math.floor(Number(secs || 0)))
    if (s >= 3600) {
      var h = Math.floor(s / 3600)
      var m = Math.floor((s % 3600) / 60)
      return h + "h" + (m > 0 ? (" " + m + "m") : "")
    }
    var mins = Math.floor(s / 60)
    var remS = s % 60
    if (mins > 0) return mins + "m " + (remS < 10 ? "0" : "") + remS + "s"
    return remS + "s"
  }

  function targetFor(req) {
    if (!req) return "sandbox"
    var rid = String(req.id || "")
    if (draftTargets[rid]) return String(draftTargets[rid])
    return String(req.requested_scope || "") === "host_ssh" ? "thomas" : "sandbox"
  }

  function setTargetFor(reqId, target) {
    var next = Object.assign({}, draftTargets)
    next[String(reqId)] = String(target)
    draftTargets = next
  }

  function ttlFor(req) {
    if (!req) return 60
    var rid = String(req.id || "")
    if (draftTtls[rid]) return Number(draftTtls[rid])
    return Number(req.ttl_minutes || 60)
  }

  function setTtlFor(reqId, mins) {
    var next = Object.assign({}, draftTtls)
    next[String(reqId)] = Number(mins)
    draftTtls = next
  }

  function approve(reqId, target, ttlMins) {
    if (busy || actionProc.running) return
    busy = true
    busyRequestId = String(reqId)
    lastError = ""
    actionProc.command = [
      ctlBin,
      "approve",
      String(reqId),
      "--target",
      String(target || "sandbox"),
      "--ttl",
      String(ttlMins || 60),
      "--session-scoped",
      "true"
    ]
    actionProc.running = true
  }

  function deny(reqId) {
    if (busy || actionProc.running) return
    busy = true
    busyRequestId = String(reqId)
    lastError = ""
    actionProc.command = [ctlBin, "deny", String(reqId)]
    actionProc.running = true
  }

  function revoke(reqId) {
    if (busy || actionProc.running) return
    busy = true
    busyRequestId = String(reqId)
    lastError = ""
    actionProc.command = [ctlBin, "revoke", String(reqId)]
    actionProc.running = true
  }

  function revokeAll() {
    if (busy || actionProc.running) return
    busy = true
    busyRequestId = "*"
    lastError = ""
    actionProc.command = [ctlBin, "revoke-all"]
    actionProc.running = true
  }

  function openPreviewPort(port) {
    var p = Number(port || 0)
    if (p <= 0) return
    Quickshell.execDetached([xdgOpenBin, "http://localhost:" + String(p)])
  }

  function notifyLockState(locked) {
    Quickshell.execDetached([ctlBin, locked ? "lock-event" : "unlock-event"])
  }

  // Watch `omarchy.lock` service if loaded inside Quickshell so locking via `omarchy-shell`
  // immediately revokes active SSH tethers without waiting for the 2s daemon poll.
  readonly property var lockService: shell && typeof shell.serviceFor === "function"
    ? shell.serviceFor("omarchy.lock")
    : null
  readonly property bool shellLocked: !!(lockService && (lockService.locked === true || lockService.active === true))

  onShellLockedChanged: {
    notifyLockState(shellLocked)
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.hasActive
    onTriggered: root.nowSec = Math.floor(Date.now() / 1000)
  }

  Process {
    id: watchProc
    command: [root.ctlBin, "watch"]
    running: root.ctlBin !== "" && root.ctlBin.charAt(0) !== "@"
    stdout: SplitParser {
      onRead: function(line) {
        var trimmed = String(line || "").trim()
        if (!trimmed) return
        try {
          var s = JSON.parse(trimmed)
          if (s.daemon_offline) {
            root.daemonOnline = false
            return
          }
          root.snapshot = s
          root.daemonOnline = true
          root.coreOnline = !!s.core_online
          root.nowSec = Number(s.now || Math.floor(Date.now() / 1000))
        } catch (e) {}
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var trimmed = String(text || "").trim()
        if (!trimmed) return
        try {
          var r = JSON.parse(trimmed)
          if (r && r.ok === false && r.error) {
            root.lastError = String(r.error)
          }
        } catch (e) {}
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err) root.lastError = err
      }
    }
    onExited: function(code) {
      root.busy = false
      root.busyRequestId = ""
      if (code === 0) root.lastError = ""
    }
  }
}
