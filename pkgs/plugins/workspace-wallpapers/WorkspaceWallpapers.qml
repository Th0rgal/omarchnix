import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons as Commons

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/workspace-wallpapers.json"
  readonly property string backgroundLink: home + "/.local/state/omarchy/current/background"
  readonly property bool isLight:
    (0.2126 * Commons.Color.background.r + 0.7152 * Commons.Color.background.g + 0.0722 * Commons.Color.background.b) > 0.5

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
  property var variants: ({})

  function sanitizeBucket(obj) {
    if (!obj || typeof obj !== "object") return null
    var def = (typeof obj.default === "string" && obj.default.trim() !== "") ? obj.default.trim() : ""
    var ws = {}
    var hasWs = false
    if (obj.workspaces && typeof obj.workspaces === "object") {
      for (var k in obj.workspaces) {
        var v = String(obj.workspaces[k] || "").trim()
        if (v) {
          ws[String(k)] = v
          hasWs = true
        }
      }
    }
    if (!def && !hasWs) return null
    return { "default": def, "workspaces": ws }
  }

  function addBucketPaths(bucket, seen, list) {
    if (!bucket) return
    function add(p) {
      var s = String(p || "").trim()
      if (s && !seen[s]) {
        seen[s] = true
        list.push(s)
      }
    }
    var map = bucket.workspaces || {}
    for (var k in map) add(map[k])
    add(bucket.default)
  }

  function bucketsFor(isLightMode, isPortrait) {
    var mode = isLightMode ? "light" : "dark"
    var v = root.variants || {}
    var list = []
    if (isPortrait && v.portrait && typeof v.portrait === "object") {
      if (v.portrait[mode]) list.push(v.portrait[mode])
      if (v.portrait.default || v.portrait.workspaces) list.push(v.portrait)
    }
    if (v[mode]) list.push(v[mode])
    list.push({ "default": root.defaultWallpaper, "workspaces": root.workspaceMap || {} })
    return list
  }

  function primaryBucketFor(isLightMode, isPortrait) {
    var buckets = root.bucketsFor(isLightMode, isPortrait)
    return buckets.length > 0 ? buckets[0] : null
  }

  function pathsForOrientation(isPortrait) {
    var seen = {}
    var list = []
    addBucketPaths(root.primaryBucketFor(false, isPortrait), seen, list)
    addBucketPaths(root.primaryBucketFor(true, isPortrait), seen, list)
    return list
  }

  readonly property var allPaths: {
    var seen = {}
    var list = []
    var land = root.pathsForOrientation(false)
    var port = root.pathsForOrientation(true)
    for (var i = 0; i < land.length; i++) {
      if (!seen[land[i]]) {
        seen[land[i]] = true
        list.push(land[i])
      }
    }
    for (var j = 0; j < port.length; j++) {
      if (!seen[port[j]]) {
        seen[port[j]] = true
        list.push(port[j])
      }
    }
    return list
  }

  function pathForWorkspace(wsId, isPortrait) {
    var num = parseInt(String(wsId || ""), 10)
    var exact = (!isNaN(num) && num > 0) ? String(num) : ""
    var slot = (!isNaN(num) && num > 0) ? String(((num - 1) % 10) + 1) : ""
    var key = (!exact) ? String(wsId || "") : ""
    var buckets = root.bucketsFor(root.isLight, Boolean(isPortrait))
    for (var i = 0; i < buckets.length; i++) {
      var b = buckets[i]
      if (!b) continue
      var map = b.workspaces || {}
      if (exact && map[exact]) return String(map[exact])
      if (slot && map[slot]) return String(map[slot])
      if (key && map[key]) return String(map[key])
      if (b.default) return String(b.default)
    }
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
        var nextVariants = {}
        if (obj.variants && typeof obj.variants === "object") {
          var vDark = sanitizeBucket(obj.variants.dark)
          var vLight = sanitizeBucket(obj.variants.light)
          if (vDark) nextVariants.dark = vDark
          if (vLight) nextVariants.light = vLight
          if (obj.variants.portrait && typeof obj.variants.portrait === "object") {
            var pObj = obj.variants.portrait
            var pNext = {}
            var pDark = sanitizeBucket(pObj.dark)
            var pLight = sanitizeBucket(pObj.light)
            var pFlat = sanitizeBucket(pObj)
            if (pDark) pNext.dark = pDark
            if (pLight) pNext.light = pLight
            if (pFlat) {
              pNext.default = pFlat.default
              pNext.workspaces = pFlat.workspaces
            }
            if (Object.keys(pNext).length > 0) nextVariants.portrait = pNext
          }
        }
        root.variants = nextVariants
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

  // Hyprland v0.57.x skips `CLayerSurface::animateIn()` when mapping a
  // `WlrLayer.Background` surface while a covering fullscreen window is active
  // on that monitor (`LayerSurface.cpp:241`), and `setFullscreenFadeAnimation`
  // (`WorkspaceAnimationController.cpp:186`) only restores `WlrLayer.Top` when
  // exiting fullscreen — stranding the wallpaper layer at `alpha = 0` (gray
  // `misc.background_color`). Verify layer alpha after map and self-heal any
  // zero-alpha monitor once fullscreen clears, with zero steady-state polling.
  property bool needsAlphaVerify: true
  property var zeroAlphaMonitors: ({})
  property int unmappedRetries: 0

  function scheduleAlphaVerify(delayMs) {
    root.needsAlphaVerify = true
    alphaVerifyTimer.interval = (delayMs !== undefined && delayMs > 0) ? delayMs : 120
    alphaVerifyTimer.restart()
  }

  function resetHealBudgetsAndVerify(delayMs) {
    var instances = wallpaperPanels.instances || []
    for (var i = 0; i < instances.length; i++) {
      var p = instances[i]
      if (p) p.healAttempts = 0
    }
    root.scheduleAlphaVerify(delayMs)
  }

  function handleLayersJson(raw) {
    var text = String(raw || "").trim()
    if (!text) return
    var obj = null
    try {
      obj = JSON.parse(text)
    } catch (e) {
      return
    }
    if (!obj || typeof obj !== "object") return

    var instances = wallpaperPanels.instances || []
    if (instances.length === 0) return

    var allMapped = true
    var nextZero = {}
    var scheduledFollowUp = false

    for (var i = 0; i < instances.length; i++) {
      var p = instances[i]
      if (!p) continue
      var monName = (p.monitor && p.monitor.name)
        ? String(p.monitor.name)
        : ((p.screen && p.screen.name) ? String(p.screen.name) : "")
      if (!monName || !obj[monName] || !obj[monName].levels) {
        allMapped = false
        continue
      }

      var levels = obj[monName].levels
      var matched = 0
      var maxAlpha = 0.0
      var checkLevels = ["0", "1"]
      for (var li = 0; li < checkLevels.length; li++) {
        var arr = levels[checkLevels[li]]
        if (!Array.isArray(arr)) continue
        for (var j = 0; j < arr.length; j++) {
          var entry = arr[j]
          if (entry && entry.namespace === "omarchnix-workspace-wallpaper") {
            matched += 1
            var a = Number(entry.alpha)
            if (!isNaN(a) && a > maxAlpha) maxAlpha = a
          }
        }
      }

      if (matched === 0) {
        allMapped = false
        continue
      }

      if (maxAlpha >= 0.99) {
        p.healAttempts = 0
      } else {
        nextZero[monName] = true
        if (p.healAttempts < 1) {
          p.healAttempts += 1
          p.healByRemap()
          scheduledFollowUp = true
        }
      }
    }

    root.zeroAlphaMonitors = nextZero

    if (scheduledFollowUp) {
      root.unmappedRetries = 0
      root.scheduleAlphaVerify(120)
    } else if (!allMapped && root.unmappedRetries < 10) {
      root.unmappedRetries += 1
      root.scheduleAlphaVerify(150)
    } else if (Object.keys(nextZero).length === 0) {
      root.unmappedRetries = 0
      root.needsAlphaVerify = false
    }
  }

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
    scheduleAlphaVerify(180)
  }

  Timer {
    id: alphaVerifyTimer
    interval: 120
    repeat: false
    onTriggered: {
      if (!alphaVerifyProc.running) alphaVerifyProc.running = true
    }
  }

  Process {
    id: alphaVerifyProc
    command: ["hyprctl", "-j", "layers"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleLayersJson(text)
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event) return
      var name = String(event.name || "")
      var data = String(event.data || "")
      if (name === "openlayer" && data === "omarchnix-workspace-wallpaper") {
        root.unmappedRetries = 0
        root.scheduleAlphaVerify(100)
      } else if (root.needsAlphaVerify || Object.keys(root.zeroAlphaMonitors).length > 0) {
        if (
          name === "fullscreen"
          || name === "workspacev2"
          || name === "focusedmonv2"
          || name === "activespecialv2"
          || name === "closewindow"
          || name === "movewindowv2"
        ) {
          root.resetHealBudgetsAndVerify(20)
        }
      }
    }
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
        var focusedMon = Hyprland.focusedMonitor
        var focusedPortrait = Boolean(focusedMon && focusedMon.height > focusedMon.width)
        var activeTarget = root.pathForWorkspace(
          (focusedMon && focusedMon.activeWorkspace && focusedMon.activeWorkspace.id > 0)
            ? focusedMon.activeWorkspace.id
            : 1,
          focusedPortrait
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
    id: wallpaperPanels
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      property bool remapping: false
      property int healAttempts: 0

      screen: modelData
      visible: !remapping
      color: "#0b0e14"
      updatesEnabled: true
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore

      WlrLayershell.namespace: "omarchnix-workspace-wallpaper"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      readonly property HyprlandMonitor monitor: Hyprland.monitorFor(screen)
      readonly property bool monitorHasFullscreen: Boolean(monitor && monitor.activeWorkspace && monitor.activeWorkspace.hasFullscreen)
      property int fastWsId: 0

      function healByRemap() {
        remapping = true
        remapRestoreTimer.restart()
      }

      Timer {
        id: remapRestoreTimer
        interval: 16
        repeat: false
        onTriggered: panel.remapping = false
      }

      onMonitorChanged: {
        if (monitor && monitor.name) root.scheduleAlphaVerify(120)
      }

      onMonitorHasFullscreenChanged: {
        if (!monitorHasFullscreen && monitor && monitor.name && root.zeroAlphaMonitors[monitor.name]) {
          panel.healAttempts = 0
          root.scheduleAlphaVerify(20)
        }
      }

      readonly property int monitorWsId: (monitor && monitor.activeWorkspace && monitor.activeWorkspace.id > 0 && monitor.activeWorkspace.id < 9000)
        ? monitor.activeWorkspace.id
        : 1

      readonly property int activeWsId: fastWsId > 0 ? fastWsId : monitorWsId
      readonly property bool isPortrait: (height > 0 && width > 0)
        ? (height > width)
        : Boolean(screen && screen.height > screen.width)
      readonly property string targetPath: root.pathForWorkspace(activeWsId, isPortrait)
      readonly property var panelPreloadedPaths: root.pathsForOrientation(isPortrait)

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
      readonly property bool currentReady: Boolean(currentPath !== "" && readyMap[currentPath])

      onMonitorWsIdChanged: {
        if (monitorWsId > 0 && fastWsId !== monitorWsId) {
          fastWsId = monitorWsId
        }
      }

      onIsPortraitChanged: {
        readyMap = ({})
        previousPath = ""
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
          } else if (name === "moveworkspacev2" || name === "changeworkspaceid") {
            Hyprland.refreshMonitors()
            Hyprland.refreshWorkspaces()
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
        root.scheduleAlphaVerify(120)
      }

      onTargetPathChanged: {
        if (!targetPath || targetPath === currentPath) return
        fadeAnim.stop()
        var hasPreviousInPool = currentPath !== "" && panelPreloadedPaths.indexOf(currentPath) >= 0
        if (!hasPreviousInPool || readyMap[targetPath]) {
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
          model: panel.panelPreloadedPaths

          Image {
            id: wallImg
            required property var modelData
            readonly property string wallPath: String(modelData || "")
            readonly property bool isCurrent: wallPath !== "" && wallPath === panel.currentPath
            readonly property bool isPrevious: wallPath !== "" && wallPath === panel.previousPath && panel.fadeProgress < 1.0
            readonly property bool shouldLoad: isCurrent || isPrevious || panel.currentReady
            property bool gpuWarmDone: false

            anchors.fill: parent
            source: (shouldLoad && panel.decodeWidth > 0 && panel.decodeHeight > 0 && wallPath !== "") ? ("file://" + wallPath) : ""
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
