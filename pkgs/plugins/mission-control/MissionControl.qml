import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick

// macOS-style Mission Control overlay. One MonitorView per screen spreads out
// the windows of that monitor's active workspace; a Spaces bar on top shows
// every workspace on the monitor and supports drag-to-reorder.
//
//   omarchy-shell shell toggle io.github.joaovitor2763.mission-control '{}'
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Host contract: toggle() reads `opened`. It flips to false as soon as a
  // close starts so a second toggle during the close animation reopens.
  property bool opened: false
  // Keeps the windows mapped until the close animation has finished.
  property bool mapped: false
  // 0 = previews sit on top of the real windows, 1 = spread out.
  property real progress: 0

  readonly property string pluginId: (manifest && manifest.id) || "io.github.joaovitor2763.mission-control"
  readonly property string backgroundLink: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  readonly property string wsWallpapersConfigPath: Quickshell.env("HOME") + "/.config/omarchy/workspace-wallpapers.json"
  property string backgroundPath: ""
  property string defaultWorkspaceWallpaper: ""
  property var workspaceWallpapers: ({})
  property string pendingFocusKind: ""
  property string pendingFocusTarget: ""

  function parseWorkspaceWallpapers(raw) {
    var text = String(raw || "").trim()
    if (!text) return
    try {
      var obj = JSON.parse(text)
      if (obj && typeof obj === "object") {
        root.defaultWorkspaceWallpaper = typeof obj.default === "string" ? obj.default.trim() : ""
        var map = {}
        if (obj.workspaces && typeof obj.workspaces === "object") {
          for (var k in obj.workspaces) {
            var v = String(obj.workspaces[k] || "").trim()
            if (v) map[String(k)] = v
          }
        }
        root.workspaceWallpapers = map
      }
    } catch (e) {
    }
  }

  function wallpaperForWorkspace(wsId) {
    var key = String(wsId || "")
    var map = root.workspaceWallpapers || {}
    if (key && map[key]) return String(map[key])
    if (root.defaultWorkspaceWallpaper) return root.defaultWorkspaceWallpaper
    return root.backgroundPath
  }

  function open(payloadJson) {
    if (root.opened) return
    pendingFocusTimer.stop()
    root.pendingFocusKind = ""
    root.pendingFocusTarget = ""
    root.opened = true
    Hyprland.refreshToplevels()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshMonitors()
    backgroundProc.running = true
    // Give the refresh a moment so previews start from accurate geometry.
    openDelay.restart()
  }

  function close() {
    openDelay.stop()
    if (!root.mapped) {
      root.opened = false
      return
    }
    root.opened = false
    openAnim.stop()
    closeAnim.restart()
  }

  function closeImmediate() {
    openDelay.stop()
    openAnim.stop()
    closeAnim.stop()
    root.opened = false
    root.progress = 0
    root.mapped = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
    else
      root.close()
  }

  // Release WlrKeyboardFocus.Exclusive first so Hyprland's layer focus-restore
  // runs before we focus the chosen window or workspace, instead of yanking
  // focus back to the pre-overlay window afterward.
  function activateWindowAndDismiss(address) {
    root.pendingFocusKind = "window"
    root.pendingFocusTarget = String(address || "")
    root.dismiss()
    pendingFocusTimer.restart()
  }

  function switchWorkspaceAndDismiss(workspace, sameWorkspace) {
    root.pendingFocusKind = "workspace"
    root.pendingFocusTarget = String(workspace)
    if (!sameWorkspace) {
      if (root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
      root.closeImmediate()
    } else {
      root.dismiss()
    }
    pendingFocusTimer.restart()
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // Omarchy's Hyprland config is Lua, so dispatchers are Lua expressions.
  function dispatch(expression) {
    Hyprland.dispatch("hl.dsp." + expression)
  }

  function focusWindow(address) {
    var clean = String(address).replace(/^0x/, "")
    Hyprland.dispatch("function() "
      + "hl.dispatch(hl.dsp.focus({ window = 'address:0x" + clean + "' })) "
      + "hl.dispatch(hl.dsp.window.bring_to_top()) "
      + "end")
  }

  Timer {
    id: pendingFocusTimer
    interval: 35
    onTriggered: {
      var kind = root.pendingFocusKind
      var target = root.pendingFocusTarget
      root.pendingFocusKind = ""
      root.pendingFocusTarget = ""
      if (!target) return
      if (kind === "window") root.focusWindow(target)
      else if (kind === "workspace") root.focusWorkspace(target)
    }
  }

  function cleanAddress(address) {
    return String(address || "").replace(/^0x/i, "")
  }

  function luaWorkspaceArg(workspace) {
    var s = String(workspace)
    return /^\d+$/.test(s) ? String(Number(s)) : ("'" + s + "'")
  }

  function closeWindow(address) {
    var clean = cleanAddress(address)
    if (!clean) return
    dispatch("window.close({ window = 'address:0x" + clean + "' })")
  }

  function focusWorkspace(workspace) {
    dispatch("focus({ workspace = " + luaWorkspaceArg(workspace) + " })")
  }

  function moveWindow(address, workspace, ensureCeiling) {
    var clean = cleanAddress(address)
    if (!clean) return
    if (ensureCeiling && /^\d+$/.test(String(workspace))) {
      var targetId = Number(workspace)
      Hyprland.dispatch("function() "
        + "if _G.__omarchnix_spaces then _G.__omarchnix_spaces.add_space(" + targetId + ") end "
        + "hl.dispatch(hl.dsp.window.move({ workspace = " + targetId + ", follow = false, window = 'address:0x" + clean + "' })) "
        + "end")
      return
    }
    dispatch("window.move({ workspace = " + luaWorkspaceArg(workspace) + ", follow = false, window = 'address:0x" + clean + "' })")
  }

  function createSpace(targetId) {
    var id = Math.max(1, Math.floor(Number(targetId) || 1))
    Hyprland.dispatch("function() if _G.__omarchnix_spaces then _G.__omarchnix_spaces.add_space(" + id + ") end end")
  }

  function removeSpace(spaceId) {
    var id = Math.max(1, Math.floor(Number(spaceId) || 1))
    Hyprland.dispatch("function() if _G.__omarchnix_spaces then _G.__omarchnix_spaces.close_space(" + id + ") end end")
  }

  // Atomically renumber workspaces in-place via temporary free IDs so split
  // layouts, floating positions, fullscreen state, and focus stay intact.
  function reorderWorkspaces(pairs) {
    if (!pairs || pairs.length === 0) return
    var entries = pairs
      .filter(function(p) { return p.from !== p.to })
      .map(function(p) { return "{" + Number(p.from) + "," + Number(p.to) + "}" })
    if (entries.length === 0) return
    var lua = "function() "
      + "local moves = {" + entries.join(",") + "} "
      + "if _G.__omarchnix_spaces and _G.__omarchnix_spaces.reorder then "
      +   "_G.__omarchnix_spaces.reorder(moves) "
      +   "return "
      + "end "
      + "local items = {} "
      + "local next_tmp = 9001 "
      + "for _, m in ipairs(moves) do "
      +   "if hl.get_workspace(m[1]) then "
      +     "while hl.get_workspace(next_tmp) ~= nil do next_tmp = next_tmp + 1 end "
      +     "items[#items + 1] = { from = m[1], to = m[2], tmp = next_tmp } "
      +     "next_tmp = next_tmp + 1 "
      +   "end "
      + "end "
      + "for _, it in ipairs(items) do "
      +   "hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(it.from), id = it.tmp })) "
      + "end "
      + "for _, it in ipairs(items) do "
      +   "hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(it.tmp), id = it.to })) "
      + "end "
      + "end"
    Hyprland.dispatch(lua)
  }

  Timer {
    id: openDelay
    interval: 45
    onTriggered: {
      if (!root.opened) return
      closeAnim.stop()
      root.progress = 0
      root.mapped = true
      openAnim.restart()
    }
  }

  NumberAnimation {
    id: openAnim
    target: root
    property: "progress"
    to: 1
    duration: 420
    easing.type: Easing.OutQuint
  }

  SequentialAnimation {
    id: closeAnim
    NumberAnimation {
      target: root
      property: "progress"
      to: 0
      duration: 300
      easing.type: Easing.OutCubic
    }
    ScriptAction {
      script: root.mapped = false
    }
  }

  FileView {
    id: wsWallpapersFile
    path: root.wsWallpapersConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseWorkspaceWallpapers(text())
    onFileChanged: reload()
  }

  Process {
    id: backgroundProc
    command: ["readlink", "-f", root.backgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.backgroundPath = String(text || "").trim()
    }
  }

  Variants {
    model: Quickshell.screens

    MonitorView {
      required property var modelData
      screen: modelData
      controller: root
    }
  }
}
