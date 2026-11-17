import QtQuick
import Quickshell
import Quickshell.Io

// Agent SSH grants (orb-grant): polls `orb-grant json`, runs renew/revoke.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string grantBin: "@ORB_GRANT_BIN@"
  readonly property bool configured: grantBin !== "" && grantBin.charAt(0) !== "@"

  property var grants: []
  property double nowSec: Math.floor(Date.now() / 1000)
  property string busyName: ""
  property string lastError: ""

  readonly property var activeGrants: grants.filter(function(g) { return g.active && Number(g.expires_at) > nowSec })
  readonly property bool hasActive: activeGrants.length > 0
  readonly property bool busy: busyName !== ""

  readonly property int minRemainingSeconds: {
    var best = -1
    for (var i = 0; i < activeGrants.length; i++) {
      var rem = Math.max(0, Math.ceil(Number(activeGrants[i].expires_at) - nowSec))
      if (best < 0 || rem < best) best = rem
    }
    return best
  }

  function remainingFor(grant) {
    return Math.max(0, Math.ceil(Number(grant.expires_at || 0) - nowSec))
  }

  function formatCountdown(secs) {
    var s = Math.max(0, Math.floor(Number(secs || 0)))
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m"
    if (m > 0) return m + "m"
    return s + "s"
  }

  function refresh() {
    if (configured && !pollProc.running) pollProc.running = true
  }

  function run(name, args) {
    if (!configured || busy) return
    busyName = String(name)
    lastError = ""
    actionProc.command = [grantBin].concat(args)
    actionProc.running = true
  }

  // Renewing asks for one YubiKey touch; the button says so.
  function renew(name) { run(name, ["renew", String(name), "24"]) }
  function revoke(name) { run(name, ["revoke", String(name)]) }
  function revokeAll() {
    for (var i = 0; i < activeGrants.length; i++) {
      if (busy) return
      revoke(activeGrants[i].name)
    }
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.configured
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Countdown ticks only while something is shown.
  Timer {
    interval: 1000
    repeat: true
    running: root.hasActive
    onTriggered: root.nowSec = Math.floor(Date.now() / 1000)
  }

  Process {
    id: pollProc
    command: [root.grantBin, "json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(String(text || "").trim())
          root.grants = Array.isArray(s.grants) ? s.grants : []
          root.nowSec = Number(s.now || Math.floor(Date.now() / 1000))
        } catch (e) {}
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: true
    }
    onExited: function(code) {
      if (code !== 0) {
        var lines = String(actionErr.text || "").trim().split("\n")
        root.lastError = lines.length ? lines[lines.length - 1] : ("orb-grant exited " + code)
      }
      root.busyName = ""
      root.refresh()
    }
  }
}
