// State, window cycling, and high-DPI icon scoring for the macOS-style dock.

var POSITIONS = ["top", "bottom", "left", "right"]

function normalizePosition(value) {
  var position = String(value || "").trim().toLowerCase()
  return POSITIONS.indexOf(position) >= 0 ? position : "bottom"
}

function isVertical(position) {
  var normalized = normalizePosition(position)
  return normalized === "left" || normalized === "right"
}

function normalizeId(value) {
  var id = String(value || "").trim()
  if (id.slice(-16) === ".desktop.desktop") return id.slice(0, -8)
  return id
}

function pinnedIds(dockConfig) {
  var source = dockConfig && Array.isArray(dockConfig.pinned) ? dockConfig.pinned : []
  var ids = []
  for (var i = 0; i < source.length; i++) {
    var id = normalizeId(source[i])
    if (id && ids.indexOf(id) === -1) ids.push(id)
  }
  return ids
}

function isDockWindow(window) {
  if (!window || !window.key) return false
  if (window.minimized === true) return true
  if (window.noDisplay === true) return false
  return window.workspaceId >= 1
}

var MINIMIZED_WORKSPACE = "special:minimized"

function isMinimizedWorkspace(name) {
  return String(name || "") === MINIMIZED_WORKSPACE
}

function claimingEntryId(appId, entries) {
  var id = String(appId || "")
  if (!id) return ""
  var list = entries || []
  var flag = "--app-id=" + id
  for (var i = 0; i < list.length; i++) {
    var words = String(list[i].execString || "").split(/\s+/)
    if (words.indexOf(flag) >= 0) return list[i].id
  }
  if (id.indexOf("org.omarchy.") !== 0) return ""
  var command = id.slice("org.omarchy.".length)
  for (var j = 0; j < list.length; j++) {
    var program = String((list[j].command || [])[0] || "")
    if (list[j].runInTerminal && program.slice(program.lastIndexOf("/") + 1) === command) return list[j].id
  }
  return ""
}

// Rank candidate icon files so high-DPI PNGs (256x256 / 512x512) and scalable
// full-color SVGs always beat tiny 16x16 / 32x32 / 48x48 icons or symbolic SVGs.
function scoreIconPath(filePath, homeDir) {
  var path = String(filePath || "")
  if (!path) return -1
  var lower = path.toLowerCase()
  var isSvg = lower.slice(-4) === ".svg"
  var isSymbolic = lower.indexOf("-symbolic.") >= 0 || lower.indexOf("/symbolic/") >= 0
  if (isSymbolic) return 1

  var bonus = 0
  if (homeDir && path.indexOf(homeDir + "/") === 0) bonus += 200
  if (path.indexOf("/hicolor/") >= 0) bonus += 100

  if (isSvg) return 10000 + bonus

  var sizeMatch = path.match(/\/(\d+)x(\d+)(?:@(\d+))?\//)
  if (sizeMatch) {
    var basePx = Math.max(parseInt(sizeMatch[1], 10) || 0, parseInt(sizeMatch[2], 10) || 0)
    var scale = parseInt(sizeMatch[3], 10) || 1
    var effectivePx = basePx * scale
    if (effectivePx >= 256 && effectivePx <= 512) return 9000 + effectivePx + bonus
    if (effectivePx > 512) return 8900 + Math.min(500, Math.round(effectivePx / 4)) + bonus
    return effectivePx + bonus
  }

  if (path.indexOf("/pixmaps/") >= 0) return 400 + bonus
  return 200 + bonus
}

function humanizeAppId(appId) {
  var raw = String(appId || "").trim()
  if (!raw) return "App"
  if (raw.slice(-8) === ".desktop") raw = raw.slice(0, -8)
  var parts = raw.split(".")
  var tail = parts[parts.length - 1] || raw
  if (tail.toLowerCase() === "desktop" && parts.length >= 2)
    tail = parts[parts.length - 2]
  tail = tail.replace(/[-_]+/g, " ").trim()
  if (!tail) return raw
  return tail.split(/\s+/).map(function(word) {
    return word.charAt(0).toUpperCase() + word.slice(1)
  }).join(" ")
}

function workspaceSummary(windows) {
  var list = windows || []
  if (list.length === 0) return ""
  var ids = []
  var hasMinimized = false
  for (var i = 0; i < list.length; i++) {
    var w = list[i]
    if (w.minimized) {
      hasMinimized = true
    } else if (w.workspaceId >= 1 && ids.indexOf(w.workspaceId) === -1) {
      ids.push(w.workspaceId)
    }
  }
  ids.sort(function(a, b) { return a - b })
  if (ids.length === 0) return hasMinimized ? "Minimized" : ""
  if (ids.length === 1) return "Space " + ids[0]
  return "Spaces " + ids.join(", ")
}

function buildItems(pinned, windows) {
  var items = []
  var byKey = {}

  function itemFor(key, isPinned) {
    if (!byKey[key]) {
      byKey[key] = { key: key, pinned: isPinned, windows: [] }
      items.push(byKey[key])
    }
    return byKey[key]
  }

  for (var i = 0; i < (pinned || []).length; i++) {
    if (pinned[i]) itemFor(pinned[i], true)
  }

  for (var j = 0; j < (windows || []).length; j++) {
    var window = windows[j]
    if (isDockWindow(window)) itemFor(window.key, false).windows.push(window)
  }

  return items
}

function orderItems(items, order) {
  var byKey = {}
  for (var i = 0; i < (items || []).length; i++) byKey[items[i].key] = items[i]
  var result = []
  var placed = {}
  for (var j = 0; j < (order || []).length; j++) {
    var key = order[j]
    if (byKey[key] && !placed[key]) {
      result.push(byKey[key])
      placed[key] = true
    }
  }
  for (var k = 0; k < (items || []).length; k++) {
    if (!placed[items[k].key]) result.push(items[k])
  }
  return result
}

function orderWithKeyAt(order, key, index) {
  var keys = (order || []).filter(function(other) { return other !== key })
  keys.splice(Math.max(0, Math.min(keys.length, index)), 0, key)
  return keys
}

function dropIndex(fromIndex, offset, slotSize, count) {
  if (count <= 0 || !(slotSize > 0)) return fromIndex
  var target = fromIndex + Math.round(offset / slotSize)
  return Math.max(0, Math.min(count - 1, target))
}

function pinsInOrder(order, pinned, allPinned) {
  var result = (order || []).filter(function(key) { return pinned[key] === true })
  for (var i = 0; i < (allPinned || []).length; i++) {
    if (result.indexOf(allPinned[i]) === -1 && (order || []).indexOf(allPinned[i]) === -1) result.push(allPinned[i])
  }
  return result
}

function pickWindow(windows, workspaceId) {
  var list = windows || []
  if (list.length === 0) return -1

  var cycleOrder = list.map(function(_, index) { return index })
  cycleOrder.sort(function(a, b) {
    var minDiff = (list[a].minimized ? 1 : 0) - (list[b].minimized ? 1 : 0)
    if (minDiff !== 0) return minDiff
    var wsA = list[a].workspaceId >= 1 ? list[a].workspaceId : 999999
    var wsB = list[b].workspaceId >= 1 ? list[b].workspaceId : 999999
    if (wsA !== wsB) return wsA - wsB
    return a - b
  })

  for (var i = 0; i < cycleOrder.length; i++) {
    if (list[cycleOrder[i]].activated) return cycleOrder[(i + 1) % cycleOrder.length]
  }

  for (var j = 0; j < cycleOrder.length; j++) {
    var idx = cycleOrder[j]
    if (!list[idx].minimized && list[idx].workspaceId === workspaceId) return idx
  }

  return cycleOrder[0]
}
