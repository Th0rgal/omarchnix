import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null

  // Host contract for omarchy-shell toggle/summon/hide
  property bool opened: false
  property string filterText: ""
  property bool forceExpanded: false
  property int selectedIndex: 0

  property var iconIndex: ({})
  property var pendingIconIndex: ({})
  property var pendingIconScore: ({})
  property var usageMap: ({})

  readonly property string pluginId: (manifest && manifest.id) || "th0rgal.spotlight"
  readonly property string usagePath: Quickshell.env("HOME") + "/.local/state/omarchy/spotlight-usage.json"
  readonly property var hiddenIds: ({
    "footclient": true,
    "foot-server": true,
    "thunar-bulk-rename": true,
    "thunar-settings": true,
    "uuctl": true
  })

  // Match `Bar.qml`'s exact `glassBackground` (`Math.min(background.a, 0.35)`)
  // and `DockWindow.qml`'s `BorderSurface` hairline (`0.08` alpha over `bar.text`)
  // so Spotlight matches the top status bar and bottom dock in both Dark & Light modes.
  readonly property bool isLight: (Commons.Color.bar.background.r + Commons.Color.bar.background.g + Commons.Color.bar.background.b) > 1.5
  readonly property color cardSurface: Qt.rgba(
    Commons.Color.bar.background.r,
    Commons.Color.bar.background.g,
    Commons.Color.bar.background.b,
    Math.min(Commons.Color.bar.background.a, 0.35)
  )
  readonly property color barText: Commons.Color.bar.text
  readonly property color dividerColor: Qt.rgba(barText.r, barText.g, barText.b, 0.10)
  readonly property color rowSelectedBg: Qt.rgba(barText.r, barText.g, barText.b, isLight ? 0.09 : 0.14)
  readonly property color rowSelectedBorder: Qt.rgba(barText.r, barText.g, barText.b, isLight ? 0.08 : 0.12)
  readonly property color textPrimary: barText
  readonly property color textSelected: isLight ? "#000000" : "#ffffff"
  readonly property color textMuted: Qt.rgba(barText.r, barText.g, barText.b, 0.62)
  readonly property string uiFontFamily: Commons.Style.font.menuFamily || "IBM Plex Sans"
  readonly property color textPlaceholder: Qt.rgba(barText.r, barText.g, barText.b, 0.46)
  readonly property color caretColor: Commons.Color.accent

  readonly property bool showResults: filterText.trim().length > 0 || forceExpanded
  readonly property int maxVisibleRows: 6
  readonly property int pillWidth: 620
  readonly property int headerHeight: 62
  readonly property int rowHeight: 56
  readonly property int listPad: 8
  readonly property int visibleRowCount: Math.min(resultsModel.count, maxVisibleRows)
  readonly property int resultsAreaHeight: {
    if (!showResults) return 0
    if (resultsModel.count === 0) return 52
    return 1 + listPad * 2 + visibleRowCount * rowHeight
  }
  readonly property int cardHeight: headerHeight + resultsAreaHeight

  function open(payloadJson) {
    var expand = false
    try {
      var parsed = JSON.parse(String(payloadJson || "{}"))
      if (parsed && parsed.expand === true) expand = true
    } catch (e) {}
    root.forceExpanded = expand
    root.filterText = ""
    if (searchInput.text !== "") searchInput.text = ""
    root.selectedIndex = 0
    resultsModel.clear()
    if (expand) root.rebuildResults()
    if (!iconScanProc.running && Object.keys(root.iconIndex).length === 0) {
      iconScanProc.running = true
    }
    root.opened = true
    Qt.callLater(function() {
      searchInput.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
    root.forceExpanded = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
    else
      root.close()
  }

  function toggle(payloadJson) {
    if (root.opened) root.dismiss()
    else root.open(payloadJson || "{}")
  }

  // Quickshell's DesktopEntry.id already strips the outer `.desktop` file
  // suffix (e.g. `org.telegram.desktop.desktop` -> `org.telegram.desktop`).
  // Only strip `.desktop` if a caller passed a raw `.desktop` filename that
  // does not itself match a registered DesktopEntry.id.
  function normalizeId(rawId) {
    var s = String(rawId || "").trim()
    if (!s) return ""
    if (DesktopEntries.byId(s)) return s
    if (s.slice(-8) === ".desktop" && DesktopEntries.byId(s.slice(0, -8))) {
      return s.slice(0, -8)
    }
    return s
  }

  function shellQuote(value) {
    return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
  }

  function loadUsage(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      if (parsed && typeof parsed === "object") {
        root.usageMap = parsed
        return
      }
    } catch (e) {}
    root.usageMap = ({})
  }

  function recordUsage(desktopId) {
    var id = root.normalizeId(desktopId)
    if (!id) return
    var next = ({})
    for (var k in root.usageMap) next[k] = root.usageMap[k]
    var prev = next[id] || { count: 0, last: 0 }
    next[id] = {
      count: (Number(prev.count) || 0) + 1,
      last: Date.now()
    }
    root.usageMap = next
    usageFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function iconScanCommand() {
    return [
      'dirs="$HOME/.icons $HOME/.local/share/icons /run/current-system/sw/share/icons /etc/profiles/per-user/$USER/share/icons";',
      'pixmaps="/run/current-system/sw/share/pixmaps /etc/profiles/per-user/$USER/share/pixmaps /usr/share/pixmaps";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-}; do [ -n "$d" ] && dirs="$dirs $d/icons" && pixmaps="$pixmaps $d/pixmaps"; done; unset IFS;',
      'for base in $dirs; do',
      '  [ -d "$base" ] && find -L "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) ! -path "*/symbolic/*" \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null;',
      'done;',
      'for p in $pixmaps; do',
      '  [ -d "$p" ] && find -L "$p" -maxdepth 1 \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null;',
      'done'
    ].join(' ')
  }

  function scoreIconPath(path) {
    var p = String(path || "")
    if (/\.svg$/i.test(p) || p.indexOf("/scalable/") >= 0) return 10000
    var m = p.match(/\/(\d+)x\d+(@2)?\//)
    if (m) {
      var sz = parseInt(m[1], 10) * (m[2] ? 2 : 1)
      return sz
    }
    if (p.indexOf("/pixmaps/") >= 0) return 300
    return 64
  }

  function indexIconLine(line) {
    var p = String(line || "").trim()
    if (!p) return
    var slash = p.lastIndexOf("/")
    var file = slash >= 0 ? p.slice(slash + 1) : p
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (!name) return
    var sc = root.scoreIconPath(p)
    var prev = root.pendingIconScore[name] || 0
    if (sc > prev) {
      root.pendingIconScore[name] = sc
      root.pendingIconIndex[name] = p
    }
  }

  function resolveIcon(iconName) {
    var raw = String(iconName || "").trim()
    if (!raw) return Quickshell.iconPath("application-x-executable", true)
    if (raw.indexOf("file://") === 0 || raw.indexOf("image://") === 0) return raw
    if (raw.charAt(0) === "/") return "file://" + raw
    var indexed = root.iconIndex[raw]
    if (indexed) return "file://" + indexed
    var themed = Quickshell.iconPath(raw, true)
    if (themed && themed.length > 0) return themed
    return Quickshell.iconPath("application-x-executable", true)
  }

  function entryAcronym(text) {
    var parts = String(text || "")
      .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
      .toLowerCase()
      .split(/[^a-z0-9]+/)
    var out = ""
    for (var i = 0; i < parts.length; i++) {
      if (parts[i]) out += parts[i].charAt(0)
    }
    return out
  }

  function subsequenceBonus(name, query) {
    var qi = 0
    var gaps = 0
    var firstMatch = -1
    for (var ni = 0; ni < name.length && qi < query.length; ni++) {
      if (name.charAt(ni) === query.charAt(qi)) {
        if (firstMatch < 0) firstMatch = ni
        qi++
      } else if (firstMatch >= 0) {
        gaps++
      }
    }
    if (qi < query.length) return -1
    return Math.max(100, 3200 - firstMatch * 25 - gaps * 18)
  }

  function scoreEntry(entry, query) {
    var name = String(entry.name || entry.id || "").trim()
    if (!name) return -1
    var id = root.normalizeId(entry.id)
    var sub = String(entry.genericName || entry.comment || "").trim()
    var kw = ""
    try {
      if (entry.keywords && typeof entry.keywords.join === "function") kw = entry.keywords.join(" ")
    } catch (e) {}

    var usage = root.usageMap[id]
    var usageBoost = usage ? Math.min(600, (Number(usage.count) || 0) * 65) : 0

    var q = String(query || "").trim().toLowerCase()
    if (!q) {
      return 1000 + usageBoost
    }

    var nameLower = name.toLowerCase()
    var idLower = id.toLowerCase()
    var haystack = (name + " " + sub + " " + kw + " " + id).toLowerCase()

    // Multi-word queries: require every token to match either haystack or subsequence of name
    var terms = q.split(/\s+/)
    for (var t = 0; t < terms.length; t++) {
      var term = terms[t]
      if (!term) continue
      if (haystack.indexOf(term) < 0 && root.subsequenceBonus(nameLower, term) < 0) {
        return -1
      }
    }

    if (nameLower === q) return 12000 + usageBoost
    if (nameLower.indexOf(q) === 0) return 10000 - name.length * 4 + usageBoost
    if (idLower.indexOf(q) === 0) return 9400 - id.length * 4 + usageBoost

    // Word-boundary prefix inside name (e.g. "cal" -> "Notion Calendar")
    var wordBoundaryIdx = (" " + nameLower.replace(/[-_.:/]+/g, " ")).indexOf(" " + q)
    if (wordBoundaryIdx >= 0) return 8800 - wordBoundaryIdx * 8 + usageBoost

    var nameIdx = nameLower.indexOf(q)
    if (nameIdx > 0) return 7800 - nameIdx * 12 - name.length + usageBoost

    var idIdx = idLower.indexOf(q)
    if (idIdx > 0) return 7200 - idIdx * 12 + usageBoost

    var acr = root.entryAcronym(name + " " + id)
    if (acr.indexOf(q) === 0) return 6600 + usageBoost

    var hayIdx = haystack.indexOf(q)
    if (hayIdx >= 0) return 5800 - Math.min(400, hayIdx * 4) + usageBoost

    var subseq = root.subsequenceBonus(nameLower, q)
    if (subseq >= 0) return subseq + usageBoost

    return -1
  }

  function rebuildResults() {
    resultsModel.clear()
    if (!root.showResults) {
      root.selectedIndex = 0
      return
    }

    var values = DesktopEntries.applications.values || []
    var seenIds = ({})
    var seenNames = ({})
    var scored = []

    for (var i = 0; i < values.length; i++) {
      var rawEntry = values[i]
      if (!rawEntry) continue
      var id = root.normalizeId(rawEntry.id)
      if (!id || root.hiddenIds[id] === true || seenIds[id] === true) continue
      seenIds[id] = true

      var entry = DesktopEntries.byId(id) || rawEntry
      if (entry.noDisplay) continue

      var name = String(entry.name || id).trim()
      if (!name) continue

      var sc = root.scoreEntry(entry, root.filterText)
      if (sc < 0) continue

      var sub = String(entry.genericName || entry.comment || "").trim()
      if (sub.toLowerCase() === name.toLowerCase()) sub = ""

      scored.push({
        desktopId: id,
        name: name,
        subtitle: sub,
        icon: String(entry.icon || ""),
        runInTerminal: entry.runInTerminal === true,
        command: entry.command || [],
        score: sc,
        sortKey: name.toLowerCase()
      })
    }

    scored.sort(function(a, b) {
      if (a.score !== b.score) return b.score - a.score
      if (a.sortKey < b.sortKey) return -1
      if (a.sortKey > b.sortKey) return 1
      return 0
    })

    for (var j = 0; j < scored.length; j++) {
      var item = scored[j]
      var dedupKey = item.name.toLowerCase()
      if (seenNames[dedupKey]) continue
      seenNames[dedupKey] = true
      resultsModel.append({
        desktopId: item.desktopId,
        appName: item.name,
        subtitle: item.subtitle,
        iconName: item.icon,
        runInTerminal: item.runInTerminal,
        execWordsJson: JSON.stringify(item.command || [])
      })
    }

    root.selectedIndex = 0
    if (resultsList) resultsList.positionViewAtBeginning()
  }

  function moveSelection(delta) {
    if (!root.showResults) {
      if (delta > 0) {
        root.forceExpanded = true
        root.rebuildResults()
      }
      return
    }
    if (resultsModel.count === 0) return
    var next = root.selectedIndex + delta
    if (next < 0) next = 0
    if (next >= resultsModel.count) next = resultsModel.count - 1
    root.selectedIndex = next
    resultsList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function launchIndex(idx) {
    if (!root.showResults || idx < 0 || idx >= resultsModel.count) return
    var row = resultsModel.get(idx)
    if (!row || !row.desktopId) return

    var desktopId = String(row.desktopId)
    var runInTerm = row.runInTerminal === true
    var rawWords = []
    try { rawWords = JSON.parse(row.execWordsJson || "[]") } catch (e) { rawWords = [] }

    root.recordUsage(desktopId)
    root.dismiss()

    if (runInTerm) {
      var cleanWords = []
      for (var i = 0; i < rawWords.length; i++) {
        var w = String(rawWords[i] || "")
        if (w && !/^%[a-zA-Z]$/.test(w)) cleanWords.push(root.shellQuote(w))
      }
      if (cleanWords.length > 0) {
        Quickshell.execDetached(["bash", "-c", "if command -v ghostty >/dev/null 2>&1; then exec uwsm-app -- ghostty -e " + cleanWords.join(" ") + "; else exec uwsm-app -- foot -e " + cleanWords.join(" ") + "; fi"])
        return
      }
    }

    Quickshell.execDetached(["uwsm-app", "--", desktopId + ".desktop"])
  }

  ListModel {
    id: resultsModel
  }

  FileView {
    id: usageFile
    path: root.usagePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadUsage(text())
    onLoadFailed: root.loadUsage("{}")
  }

  Process {
    id: iconScanProc
    command: ["bash", "-c", root.iconScanCommand()]
    stdout: SplitParser {
      onRead: function(line) { root.indexIconLine(line) }
    }
    onStarted: {
      root.pendingIconIndex = ({})
      root.pendingIconScore = ({})
    }
    onExited: {
      root.iconIndex = root.pendingIconIndex
    }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      if (!iconScanProc.running) iconScanProc.running = true
      if (root.opened && root.showResults) root.rebuildResults()
    }
  }

  Component.onCompleted: {
    iconScanProc.running = true
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "omarchnix-spotlight"

    onContentRevealedChanged: {
      if (contentRevealed && root.opened) {
        searchInput.forceActiveFocus()
      } else if (!contentRevealed && !root.opened) {
        resultsModel.clear()
        root.filterText = ""
        if (searchInput.text !== "") searchInput.text = ""
      }
    }

    // Click anywhere outside the Spotlight card to dismiss
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.dismiss()
    }

    // Main frosted-glass Spotlight card (matches top status bar & bottom dock)
    BorderSurface {
      id: card
      width: Math.min(root.pillWidth, parent.width - 48)
      height: root.cardHeight
      x: Math.round((parent.width - width) / 2)
      y: Math.round(parent.height * 0.21)
      radius: 18
      color: root.cardSurface
      borderSpec: Border.flat(
        Qt.rgba(
          root.barText.r,
          root.barText.g,
          root.barText.b,
          0.08
        ),
        1
      )
      clip: true

      Behavior on height {
        NumberAnimation {
          duration: 120
          easing.type: Easing.OutCubic
        }
      }

      // Absorb clicks inside the card so they don't trigger outside dismiss
      MouseArea {
        anchors.fill: parent
        onClicked: searchInput.forceActiveFocus()
      }

      // Top Spotlight Search Header
      Item {
        id: searchBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.headerHeight

        // Crisp vector magnifying glass icon
        Canvas {
          id: searchGlyph
          width: 22
          height: 22
          anchors.left: parent.left
          anchors.leftMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          property color strokeColor: root.filterText.length > 0 ? root.textPrimary : root.textMuted
          onStrokeColorChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.strokeStyle = strokeColor
            ctx.lineWidth = 2.0
            ctx.lineCap = "round"
            ctx.beginPath()
            ctx.arc(9.5, 9.5, 6.5, 0, Math.PI * 2)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(14.5, 14.5)
            ctx.lineTo(19.5, 19.5)
            ctx.stroke()
          }
        }

        // Placeholder text
        Text {
          anchors.left: searchGlyph.right
          anchors.leftMargin: 14
          anchors.right: parent.right
          anchors.rightMargin: 24
          anchors.verticalCenter: parent.verticalCenter
          visible: searchInput.text.length === 0
          text: "Search"
          color: root.textPlaceholder
          font.family: root.uiFontFamily
          font.pixelSize: 22
          font.weight: Font.Normal
          elide: Text.ElideRight
        }

        // Live Search Input
        TextInput {
          id: searchInput
          anchors.left: searchGlyph.right
          anchors.leftMargin: 14
          anchors.right: enterHint.visible ? enterHint.left : parent.right
          anchors.rightMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          focus: true
          clip: true
          color: root.textPrimary
          selectionColor: "#4d8fb8de"
          selectedTextColor: root.textSelected
          font.family: root.uiFontFamily
          font.pixelSize: 22
          font.weight: Font.Normal

          cursorDelegate: Rectangle {
            id: caret
            width: 2
            height: 26
            radius: 1
            color: root.caretColor
            visible: searchInput.activeFocus

            SequentialAnimation on opacity {
              running: searchInput.activeFocus
              loops: Animation.Infinite
              NumberAnimation { from: 1.0; to: 1.0; duration: 520 }
              NumberAnimation { from: 1.0; to: 0.15; duration: 180 }
              NumberAnimation { from: 0.15; to: 0.15; duration: 320 }
              NumberAnimation { from: 0.15; to: 1.0; duration: 140 }
            }
          }

          onTextChanged: {
            root.filterText = text
            if (text.trim().length === 0) {
              root.forceExpanded = false
            }
            root.rebuildResults()
          }

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            var meta = (event.modifiers & Qt.MetaModifier) !== 0
            var ctrl = (event.modifiers & Qt.ControlModifier) !== 0

            if (event.key === Qt.Key_Escape) {
              root.dismiss()
              event.accepted = true
              return
            }

            if (meta) {
              if (event.key === Qt.Key_D && !root.showResults) {
                root.forceExpanded = true
                root.rebuildResults()
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_D || event.key === Qt.Key_Space || event.key === Qt.Key_W || event.key === Qt.Key_Q) {
                root.dismiss()
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_V) {
                searchInput.paste()
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_A) {
                searchInput.selectAll()
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_C) {
                searchInput.copy()
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_X) {
                searchInput.cut()
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_Backspace) {
                searchInput.text = ""
                event.accepted = true
                return
              }
            }

            if (ctrl && event.key === Qt.Key_U) {
              searchInput.text = ""
              event.accepted = true
              return
            }

            if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) {
              root.moveSelection(1)
              event.accepted = true
              return
            }

            if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) {
              root.moveSelection(-1)
              event.accepted = true
              return
            }

            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (root.showResults && resultsModel.count > 0) {
                root.launchIndex(root.selectedIndex)
              }
              event.accepted = true
              return
            }
          }
        }

        // Subtle top-hit quick-launch hint on right side of search bar
        Row {
          id: enterHint
          anchors.right: parent.right
          anchors.rightMargin: 18
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8
          visible: root.showResults && resultsModel.count > 0

          Rectangle {
            width: 26
            height: 22
            radius: 6
            color: root.rowSelectedBg
            border.width: 1
            border.color: root.rowSelectedBorder

            Text {
              anchors.centerIn: parent
              text: "↵"
              color: root.textMuted
              font.family: root.uiFontFamily
              font.pixelSize: 13
            }
          }
        }
      }

      // 1px Hairline Divider between Search Bar and Results
      Rectangle {
        id: divider
        anchors.top: searchBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        height: 1
        color: root.dividerColor
        visible: root.showResults
      }

      // Empty State when typing a non-matching query
      Item {
        anchors.top: divider.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 51
        visible: root.showResults && resultsModel.count === 0

        Text {
          anchors.centerIn: parent
          text: "No matching applications"
          color: root.textMuted
          font.family: root.uiFontFamily
          font.pixelSize: 14
        }
      }

      // Application Results List
      ListView {
        id: resultsList
        anchors.top: divider.bottom
        anchors.topMargin: root.listPad
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.listPad
        anchors.rightMargin: root.listPad
        height: root.visibleRowCount * root.rowHeight
        visible: root.showResults && resultsModel.count > 0
        model: resultsModel
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: resultsModel.count > root.maxVisibleRows

        delegate: Item {
          id: rowItem
          required property int index
          required property string desktopId
          required property string appName
          required property string subtitle
          required property string iconName

          readonly property bool isSelected: index === root.selectedIndex

          width: resultsList.width
          height: root.rowHeight

          Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 2
            anchors.rightMargin: 2
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            radius: 11
            color: rowItem.isSelected ? root.rowSelectedBg : "transparent"
            border.width: rowItem.isSelected ? 1 : 0
            border.color: root.rowSelectedBorder
          }

          Image {
            id: appIcon
            readonly property string resolvedSource: root.resolveIcon(rowItem.iconName)
            readonly property bool isSvgIcon: resolvedSource.slice(-4).toLowerCase() === ".svg"
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            width: 34
            height: 34
            sourceSize: isSvgIcon ? Qt.size(128, 128) : undefined
            source: resolvedSource
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            cache: false
            asynchronous: false
          }

          Column {
            anchors.left: appIcon.right
            anchors.leftMargin: 14
            anchors.right: openLabel.visible ? openLabel.left : parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
              width: parent.width
              text: rowItem.appName
              textFormat: Text.PlainText
              color: rowItem.isSelected ? root.textSelected : root.textPrimary
              font.family: root.uiFontFamily
              font.pixelSize: 16
              font.weight: Font.Medium
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              visible: rowItem.subtitle.length > 0
              text: rowItem.subtitle
              textFormat: Text.PlainText
              color: root.textMuted
              opacity: rowItem.isSelected ? 0.92 : 0.78
              font.family: root.uiFontFamily
              font.pixelSize: 13
              font.weight: Font.Normal
              elide: Text.ElideRight
            }
          }

          Text {
            id: openLabel
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            visible: rowItem.isSelected
            text: "Open"
            color: root.textMuted
            font.family: root.uiFontFamily
            font.pixelSize: 12
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: {
              if (root.selectedIndex !== rowItem.index) {
                root.selectedIndex = rowItem.index
              }
            }
            onClicked: root.launchIndex(rowItem.index)
          }
        }
      }
    }
  }
}
