import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/workspace-wallpapers.json"
  readonly property string backgroundLink: home + "/.local/state/omarchy/current/background"

  property string defaultWallpaper: home + "/Pictures/Wallpapers/bologna-dome.webp"
  property var workspaceMap: ({
    "1": home + "/Pictures/Wallpapers/singapore.webp",
    "2": home + "/Pictures/Wallpapers/bologna-dome.webp",
    "3": home + "/Pictures/Wallpapers/kazakhstan-charyn-canyon-peaks.webp",
    "4": home + "/Pictures/Wallpapers/shanghai-tower-twilight-spiral.webp",
    "5": home + "/Pictures/Wallpapers/zambezi-violet-twilight.webp",
    "6": home + "/Pictures/Wallpapers/spiral-brick-vault-archway.webp",
    "7": home + "/Pictures/Wallpapers/lisbon-greenhouse-canopy-top.webp",
    "8": home + "/Pictures/Wallpapers/lisbon-greenhouse-canopy-bottom.webp"
  })

  readonly property var allPaths: {
    var seen = {}
    var list = []
    function add(p) {
      var s = String(p || "").trim()
      if (s && !seen[s]) {
        seen[s] = true
        list.push(s)
      }
    }
    var map = root.workspaceMap || {}
    for (var k in map) add(map[k])
    add(root.defaultWallpaper)
    return list
  }

  function pathForWorkspace(wsId) {
    var key = String(wsId || "")
    var map = root.workspaceMap || {}
    if (key && map[key]) return String(map[key])
    return root.defaultWallpaper
  }

  function parseConfig(raw) {
    var text = String(raw || "").trim()
    if (!text) return
    try {
      var obj = JSON.parse(text)
      if (obj && typeof obj === "object") {
        if (typeof obj.default === "string" && obj.default.trim() !== "") {
          root.defaultWallpaper = obj.default.trim()
        }
        if (obj.workspaces && typeof obj.workspaces === "object") {
          var nextMap = {}
          for (var k in obj.workspaces) {
            var v = String(obj.workspaces[k] || "").trim()
            if (v) nextMap[String(k)] = v
          }
          root.workspaceMap = nextMap
        }
      }
    } catch (e) {
      console.warn("workspace-wallpapers: failed to parse config: " + e)
    }
  }

  property string linkedBackgroundPath: ""
  property string pendingLinkTarget: ""
  property var polarityMap: ({})
  property string probedPathsKey: ""

  function shouldSyncBackgroundLink(targetPath) {
    var clean = String(targetPath || "").trim()
    if (!clean) return false
    if (!linkedBackgroundPath) return true
    if (clean === linkedBackgroundPath) return false
    var nextPol = polarityMap[clean]
    var curPol = polarityMap[linkedBackgroundPath]
    if (nextPol && curPol) return nextPol !== curPol
    return false
  }

  function syncCurrentBackgroundLink(targetPath, forceSync) {
    var clean = String(targetPath || "").trim()
    if (!clean) return
    if (!forceSync && !shouldSyncBackgroundLink(clean)) return
    pendingLinkTarget = clean
    if (!linkProc.running) startLinkUpdate()
  }

  function startLinkUpdate() {
    var nextTarget = pendingLinkTarget
    if (!nextTarget) return
    pendingLinkTarget = ""
    linkProc.targetWritten = nextTarget
    linkProc.command = ["ln", "-sfn", nextTarget, root.backgroundLink]
    linkProc.running = true
  }

  function refreshPolarities() {
    var paths = root.allPaths || []
    var key = paths.join("\n")
    if (!key || key === root.probedPathsKey) return
    if (polarityProc.running) return
    root.probedPathsKey = key
    polarityProc.pathsSnapshot = paths.slice()
    polarityProc.command = [
      "bash",
      "-c",
      [
        'cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy"',
        'cache_file="$cache_dir/wallpaper-polarity.tsv"',
        'mkdir -p "$cache_dir"',
        'cur=$(readlink -f -- "$1" 2>/dev/null || true)',
        'printf "LINK\\t%s\\n" "$cur"',
        'shift',
        'declare -A cached=()',
        'if [ -f "$cache_file" ]; then',
        '  while IFS=$\'\\t\' read -r cp cm cval; do',
        '    [ -n "$cp" ] && [ -n "$cm" ] && [ -n "$cval" ] && cached["$cp|$cm"]="$cval"',
        '  done < "$cache_file"',
        'fi',
        'dirty=0',
        'add_pol() {',
        '  local p="$1"',
        '  [ -f "$p" ] || return 0',
        '  local mt k val d l',
        '  mt=$(stat -c "%Y:%s" -- "$p" 2>/dev/null || echo "0")',
        '  k="$p|$mt"',
        '  val="${cached[$k]:-}"',
        '  if [ -z "$val" ]; then',
        '    d=$(omarchy-bar-text-color top 28 "#e6edf3" "#0b0e14" --background "$p" 2>/dev/null || echo "#e6edf3")',
        '    l=$(omarchy-bar-text-color top 28 "#1f2328" "#ffffff" --background "$p" 2>/dev/null || echo "#1f2328")',
        '    val="$d|$l"',
        '    cached["$k"]="$val"',
        '    dirty=1',
        '  fi',
        '  printf "POL\\t%s\\t%s\\n" "$p" "$val"',
        '}',
        '[ -n "$cur" ] && add_pol "$cur"',
        'for p in "$@"; do',
        '  [ "$p" = "$cur" ] && continue',
        '  add_pol "$p"',
        'done',
        'if [ "$dirty" = "1" ]; then',
        '  tmp="$cache_file.$$"',
        '  for k in "${!cached[@]}"; do',
        '    printf "%s\\t%s\\t%s\\n" "${k%|*}" "${k##*|}" "${cached[$k]}"',
        '  done > "$tmp" && mv -f "$tmp" "$cache_file" || rm -f "$tmp"',
        'fi'
      ].join("\n"),
      "_",
      root.backgroundLink
    ].concat(paths)
    polarityProc.running = true
  }

  property var preloadedPaths: []

  function syncPreloadedPaths() {
    var nextList = root.allPaths || []
    if (nextList.join("\n") !== (root.preloadedPaths || []).join("\n")) {
      root.preloadedPaths = nextList.slice()
    }
  }

  onAllPathsChanged: {
    syncPreloadedPaths()
    refreshPolarities()
  }

  Component.onCompleted: {
    syncPreloadedPaths()
    refreshPolarities()
  }

  Process {
    id: polarityProc
    property var pathsSnapshot: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var nextPol = {}
        for (var k in root.polarityMap) nextPol[k] = root.polarityMap[k]
        var detectedLink = root.linkedBackgroundPath
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i]
          if (!line) continue
          var parts = line.split("\t")
          if (parts[0] === "LINK") {
            detectedLink = String(parts[1] || "").trim()
          } else if (parts[0] === "POL" && parts.length >= 3) {
            nextPol[parts[1]] = parts[2]
          }
        }
        root.polarityMap = nextPol
        if (detectedLink) {
          root.linkedBackgroundPath = detectedLink
        }
        var activeTarget = root.pathForWorkspace(
          (Hyprland.focusedMonitor && Hyprland.focusedMonitor.activeWorkspace && Hyprland.focusedMonitor.activeWorkspace.id > 0)
            ? Hyprland.focusedMonitor.activeWorkspace.id
            : 1
        )
        if (!root.linkedBackgroundPath) {
          root.syncCurrentBackgroundLink(activeTarget, true)
        } else if (root.shouldSyncBackgroundLink(activeTarget)) {
          root.syncCurrentBackgroundLink(activeTarget, true)
        }
      }
    }
    onExited: {
      var latestKey = (root.allPaths || []).join("\n")
      if (latestKey !== root.probedPathsKey) root.refreshPolarities()
    }
  }

  Process {
    id: linkProc
    property string targetWritten: ""
    onExited: function(exitCode) {
      if (exitCode === 0 && linkProc.targetWritten !== "") {
        root.linkedBackgroundPath = linkProc.targetWritten
      }
      if (root.pendingLinkTarget !== "") root.startLinkUpdate()
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseConfig(text())
    onFileChanged: reload()
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: true
      color: "#0b0e14"
      updatesEnabled: true
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore

      WlrLayershell.namespace: "omarchnix-workspace-wallpaper"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      readonly property HyprlandMonitor monitor: Hyprland.monitorFor(screen)
      property int fastWsId: 0

      readonly property int monitorWsId: (monitor && monitor.activeWorkspace && monitor.activeWorkspace.id > 0 && monitor.activeWorkspace.id < 9000)
        ? monitor.activeWorkspace.id
        : 1

      readonly property int activeWsId: fastWsId > 0 ? fastWsId : monitorWsId
      readonly property string targetPath: root.pathForWorkspace(activeWsId)

      readonly property int decodeWidth: width > 0 ? Math.ceil(width * screen.devicePixelRatio) : 0
      readonly property int decodeHeight: height > 0 ? Math.ceil(height * screen.devicePixelRatio) : 0

      // Preload all unique configured wallpapers (`root.allPaths`) into resident
      // GPU textures at startup (`visible: true` retains `QSGImageNode` + RHI
      // texture; `opacity: 0` after a 2-frame occluded warm-up lets SceneGraph
      // cull inactive layers at 0 FPS with zero disk/WebP decode on switch).
      property string currentPath: ""
      property string previousPath: ""
      property real fadeProgress: 1.0
      property var readyMap: ({})

      onMonitorWsIdChanged: {
        if (monitorWsId > 0 && fastWsId !== monitorWsId) {
          fastWsId = monitorWsId
        }
      }

      Connections {
        target: Hyprland
        function onRawEvent(event) {
          if (!event) return
          var name = String(event.name || "")
          var data = String(event.data || "")
          if (name === "workspacev2") {
            if (panel.monitor && !panel.monitor.focused && Hyprland.monitors.values.length > 1) return
            var comma = data.indexOf(",")
            var rawId = comma >= 0 ? data.slice(0, comma) : data
            var parsed = parseInt(rawId, 10)
            if (parsed > 0 && parsed < 9000) {
              panel.fastWsId = parsed
            }
          } else if (name === "focusedmonv2") {
            var sep = data.indexOf(",")
            if (sep > 0) {
              var monName = data.slice(0, sep)
              var wsPart = parseInt(data.slice(sep + 1), 10)
              if (panel.monitor && panel.monitor.name === monName && wsPart > 0 && wsPart < 9000) {
                panel.fastWsId = wsPart
              }
            }
          }
        }
      }

      function markPathReady(p, ready) {
        if (!p) return
        if (Boolean(readyMap[p]) === ready) return
        var copy = {}
        for (var k in readyMap) copy[k] = readyMap[k]
        copy[p] = ready
        readyMap = copy
        if (ready && p === currentPath && fadeProgress < 1.0 && !fadeAnim.running) {
          fadeAnim.start()
        }
      }

      Component.onCompleted: {
        fastWsId = monitorWsId
        currentPath = targetPath
        previousPath = ""
        fadeProgress = 1.0
        if (!monitor || monitor.focused) root.syncCurrentBackgroundLink(targetPath)
      }

      onTargetPathChanged: {
        if (!targetPath || targetPath === currentPath) return
        fadeAnim.stop()
        if (currentPath === "" || readyMap[targetPath]) {
          currentPath = targetPath
          previousPath = ""
          fadeProgress = 1.0
        } else {
          previousPath = currentPath
          currentPath = targetPath
          fadeProgress = 0.0
        }
        if (!monitor || monitor.focused) root.syncCurrentBackgroundLink(targetPath)
      }

      NumberAnimation {
        id: fadeAnim
        target: panel
        property: "fadeProgress"
        from: 0
        to: 1
        duration: 80
        easing.type: Easing.OutQuad
        onStopped: {
          if (panel.fadeProgress >= 0.999) {
            panel.fadeProgress = 1.0
            panel.previousPath = ""
          }
        }
      }

      Item {
        id: stage
        anchors.fill: parent

        Repeater {
          model: root.preloadedPaths

          Image {
            id: wallImg
            required property var modelData
            readonly property string wallPath: String(modelData || "")
            readonly property bool isCurrent: wallPath !== "" && wallPath === panel.currentPath
            readonly property bool isPrevious: wallPath !== "" && wallPath === panel.previousPath && panel.fadeProgress < 1.0
            property bool gpuWarmDone: false

            anchors.fill: parent
            source: (panel.decodeWidth > 0 && wallPath !== "") ? ("file://" + wallPath) : ""
            sourceSize.width: panel.decodeWidth
            sourceSize.height: panel.decodeHeight
            fillMode: Image.PreserveAspectCrop
            horizontalAlignment: Image.AlignHCenter
            verticalAlignment: wallPath.indexOf("bologna-dome") >= 0 ? Image.AlignTop : Image.AlignVCenter
            asynchronous: true
            cache: false
            smooth: true
            mipmap: false
            visible: wallPath !== ""
            z: isCurrent ? 2 : (isPrevious ? 1 : 0)
            opacity: isCurrent
              ? (status === Image.Ready ? (panel.previousPath !== "" ? panel.fadeProgress : 1.0) : 0.0)
              : (isPrevious
                  ? 1.0
                  : ((status === Image.Ready && !gpuWarmDone) ? 0.01 : 0.0))

            onStatusChanged: {
              if (status === Image.Ready) {
                panel.markPathReady(wallPath, true)
                if (isCurrent) {
                  gpuWarmDone = true
                }
              } else if (status === Image.Error) {
                panel.markPathReady(wallPath, false)
                if (isCurrent) {
                  panel.fadeProgress = 1.0
                  panel.previousPath = ""
                }
              }
            }

            Timer {
              interval: 40
              running: wallImg.status === Image.Ready && !wallImg.gpuWarmDone && !wallImg.isCurrent
              repeat: false
              onTriggered: wallImg.gpuWarmDone = true
            }
          }
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) {
            Quickshell.execDetached(["omarchy-theme-switcher"])
          } else {
            Quickshell.execDetached(["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""])
          }
          mouse.accepted = true
        }
      }
    }
  }
}
