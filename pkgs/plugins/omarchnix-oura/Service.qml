import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string ctlBin: "@OURACTL_BIN@"

  property var snapshot: null
  property bool daemonOnline: false
  property bool busy: false
  property string lastError: ""

  readonly property bool connected: !!(snapshot && snapshot.connected)
  readonly property string daemonState: snapshot && snapshot.state ? String(snapshot.state) : "offline"
  readonly property string ringName: snapshot && snapshot.ring_name ? String(snapshot.ring_name) : "Oura Ring"
  readonly property string firmware: snapshot && snapshot.firmware ? String(snapshot.firmware) : ""
  readonly property int batteryPercent: snapshot && snapshot.battery_percent !== null && snapshot.battery_percent !== undefined
    ? Number(snapshot.battery_percent) : -1
  readonly property bool charging: !!(snapshot && snapshot.charging)
  readonly property int latestHr: snapshot && snapshot.latest_hr !== null && snapshot.latest_hr !== undefined
    ? Number(snapshot.latest_hr) : -1
  readonly property int liveHr: snapshot && snapshot.live_hr !== null && snapshot.live_hr !== undefined
    ? Number(snapshot.live_hr) : -1
  readonly property bool liveHrActive: !!(snapshot && snapshot.live_hr_active)
  readonly property int spo2Percent: snapshot && snapshot.spo2_percent !== null && snapshot.spo2_percent !== undefined
    ? Number(snapshot.spo2_percent) : -1
  readonly property double lastSyncUnix: snapshot && snapshot.last_sync_unix ? Number(snapshot.last_sync_unix) : 0

  readonly property bool gesturesEnabled: !!(snapshot && snapshot.gestures_enabled)
  readonly property bool gesturesConnecting: daemonState === "connecting_gestures"
  readonly property bool gesturesActive: daemonState === "gestures"
  property bool pendingGestureClick: false
  readonly property int gesturesRemainingSec: snapshot ? Number(snapshot.gestures_remaining_sec || 0) : 0
  readonly property var attitude: snapshot && snapshot.attitude ? snapshot.attitude : ({ h_deg: 0, v_deg: 0, lin_g: 0, calibrated: false, calibration_stage: null })
  readonly property string lastGesture: snapshot && snapshot.last_gesture ? String(snapshot.last_gesture) : ""
  readonly property var gestureConfig: snapshot && snapshot.gesture_config ? snapshot.gesture_config : ({
    swipe_accel_g: 0.75,
    lift_accel_g: 0.65,
    require_lift_to_arm: true,
    invert_h: false,
    auto_off_minutes: 20
  })
  readonly property var trends: snapshot && snapshot.trends ? snapshot.trends : ({
    hourly_hr: [],
    hr_min: null,
    hr_avg: null,
    hr_max: null,
    overnight_hrv_ms: null,
    skin_temp_c: null,
    total_events: 0
  })
  readonly property string snapshotError: snapshot && snapshot.last_error ? String(snapshot.last_error) : ""

  function formatCountdown(secs) {
    var s = Math.max(0, Math.floor(Number(secs || 0)))
    var mins = Math.floor(s / 60)
    var rem = s % 60
    if (mins > 0) return mins + "m " + (rem < 10 ? "0" : "") + rem + "s"
    return rem + "s"
  }

  function formatAge(unixSec) {
    if (!unixSec || unixSec <= 0) return "Never synced"
    var diff = Math.max(0, Math.floor(Date.now() / 1000) - unixSec)
    if (diff < 60) return "Just now"
    if (diff < 3600) return Math.floor(diff / 60) + "m ago"
    if (diff < 86400) return Math.floor(diff / 3600) + "h ago"
    return Math.floor(diff / 86400) + "d ago"
  }

  function runCtl(args) {
    if (actionProc.running) {
      actionProc.running = false
    }
    busy = true
    lastError = ""
    actionProc.command = [ctlBin].concat(args)
    actionProc.running = true
  }

  function toggleGestures() {
    pendingGestureClick = true
    pendingClearTimer.restart()
    runCtl(["gestures", "toggle"])
  }
  function setGestures(enabled) {
    pendingGestureClick = enabled
    if (enabled) pendingClearTimer.restart()
    else pendingClearTimer.stop()
    runCtl(["gestures", enabled ? "on" : "off"])
  }
  function zeroNeutral() { runCtl(["zero"]) }
  function calibrate() { runCtl(["calibrate"]) }
  function syncNow() { runCtl(["sync"]) }
  function measureLiveHr(secs) { runCtl(["live-hr", "--seconds", String(secs || 15)]) }

  function updateConfig(opts) {
    var args = ["config"]
    if (opts.invert_h !== undefined) args.push("--invert-h=" + (opts.invert_h ? "true" : "false"))
    if (opts.require_lift_to_arm !== undefined) {
      args.push("--require-lift-to-arm=" + (opts.require_lift_to_arm ? "true" : "false"))
    }
    if (opts.swipe_accel_g !== undefined) args.push("--swipe-accel-g=" + String(opts.swipe_accel_g))
    if (opts.lift_accel_g !== undefined) args.push("--lift-accel-g=" + String(opts.lift_accel_g))
    if (opts.auto_off_minutes !== undefined) args.push("--auto-off-minutes=" + String(opts.auto_off_minutes))
    runCtl(args)
  }

  Timer {
    id: pendingClearTimer
    interval: 2500
    repeat: false
    onTriggered: root.pendingGestureClick = false
  }

  Process {
    id: subProc
    command: [root.ctlBin, "subscribe"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        if (!text) return
        try {
          var next = JSON.parse(text)
          root.snapshot = next
          root.daemonOnline = true
          if (next && (next.state === "connecting_gestures" || next.state === "gestures" || next.last_error)) {
            root.pendingGestureClick = false
            pendingClearTimer.stop()
          }
        } catch (e) {}
      }
    }
    onExited: function() {
      root.daemonOnline = false
      reconnectTimer.restart()
    }
  }

  Timer {
    id: reconnectTimer
    interval: 2500
    repeat: false
    onTriggered: {
      if (!subProc.running) subProc.running = true
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.busy = false
        var text = String(this.text || "").trim()
        if (!text) return
        try {
          var parsed = JSON.parse(text)
          // Never overwrite live subProc state with actionProc's pre-dispatch snapshot!
          if (!root.daemonOnline && parsed.snapshot) root.snapshot = parsed.snapshot
          if (!parsed.ok && parsed.error) root.lastError = String(parsed.error)
        } catch (e) {}
      }
    }
    onExited: function(code) {
      root.busy = false
      if (code !== 0 && root.lastError === "") {
        root.lastError = "ourad unavailable"
      }
    }
  }
}
