function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

// Preserved for upstream callers/tests that inspect OsdModel.
var widestIcon = ""

function classifyIcon(name, percent) {
  var raw = String(name || "").trim()
  var n = raw.toLowerCase()

  if (n === "headphones-muted" || n === "headset-muted" || raw === "󰟎") {
    return { kind: "headphones", muted: true }
  }
  if (n === "headphones" || n === "headset" || raw === "󰋋") {
    return { kind: "headphones", muted: false }
  }

  if (n === "volume-muted" || n === "volume-mute" || n === "muted" || n === "mute") {
    return { kind: "speaker", muted: true }
  }
  if (raw === "") {
    // `omarchy.audio` passes "" for both muted (>0%) and unmuted 0% scroll.
    return { kind: "speaker", muted: percent > 0 }
  }
  if (
    n === "volume-zero"
    || n === "volume-low"
    || n === "volume-medium"
    || n === "volume-high"
    || n === "volume"
    || raw === ""
    || raw === ""
    || raw === ""
    || n === ""
  ) {
    return { kind: "speaker", muted: false }
  }

  if (
    n === "microphone-muted"
    || n === "microphone-off"
    || n === "mic-muted"
    || n === "mic-off"
    || raw === "󰍭"
  ) {
    return { kind: "mic", muted: true }
  }
  if (n === "microphone" || n === "mic" || raw === "󰍬") {
    return { kind: "mic", muted: false }
  }

  if (n === "brightness" || n === "display" || raw === "󰍹") {
    return { kind: "brightness", muted: false }
  }
  if (n === "keyboard" || raw === "󰌌") {
    return { kind: "keyboard", muted: false }
  }

  if (n === "media-play" || n === "player-play" || raw === "󰐊") {
    return { kind: "media-play", muted: false }
  }
  if (n === "media-pause" || n === "player-pause" || raw === "󰏤") {
    return { kind: "media-pause", muted: false }
  }
  if (n === "media-next" || n === "player-next" || raw === "󰒭") {
    return { kind: "media-next", muted: false }
  }
  if (n === "media-previous" || n === "player-previous" || raw === "󰒮") {
    return { kind: "media-previous", muted: false }
  }
  if (
    n === "media"
    || n === "player"
    || n === "media-source"
    || n === "player-source"
    || raw === "󰝚"
  ) {
    return { kind: "media-note", muted: false }
  }

  return { kind: "glyph", muted: false }
}

function iconFor(name, percent) {
  var raw = String(name || "").trim()
  var n = raw.toLowerCase()
  if (n === "headphones-muted" || n === "headset-muted") return "󰟎"
  if (n === "headphones" || n === "headset") return "󰋋"
  if (n === "volume-muted" || n === "volume-mute" || n === "muted" || n === "mute") return ""
  if (n === "volume-zero") return ""
  if (n === "volume-low") return ""
  if (n === "volume-medium") return ""
  if (n === "volume-high") return ""
  if (n === "volume") {
    if (percent <= 0) return ""
    if (percent <= 33) return ""
    if (percent <= 66) return ""
    return ""
  }
  if (n === "microphone-muted" || n === "microphone-off" || n === "mic-muted" || n === "mic-off") return "󰍭"
  if (n === "microphone" || n === "mic") return "󰍬"
  if (n === "keyboard") return "󰌌"
  if (n === "brightness" || n === "display") return "󰍹"
  if (n === "touchpad") return "󰟸"
  if (n === "touch" || n === "touchscreen") return "󰝁"
  if (n === "reboot" || n === "restart") return "󰜉"
  if (n === "shutdown" || n === "power" || n === "poweroff") return "󰐥"
  if (n === "logout" || n === "sign-out" || n === "leave") return "󰍃"
  if (n === "media" || n === "player") return "󰝚"
  if (n === "media-source" || n === "player-source") return "󰝚"
  if (n === "media-play" || n === "player-play") return "󰐊"
  if (n === "media-pause" || n === "player-pause") return "󰏤"
  if (n === "media-next" || n === "player-next") return "󰒭"
  if (n === "media-previous" || n === "player-previous") return "󰒮"
  if (raw.length > 0) return raw
  if (percent <= 0) return ""
  if (percent <= 33) return ""
  if (percent <= 66) return ""
  return ""
}

function stateForShow(iconName, rawMessage, rawValue, rawMax, rawProgressText, rawDuration, fmt) {
  var number = typeof fmt === "function" ? fmt : function(v) { return String(v) }
  var maxValue = Math.max(1, parseInt(rawMax || "100", 10))
  var parsedValue = parseInt(rawValue || "0", 10)
  var hasProgress = rawValue !== "" && !isNaN(parsedValue) && rawMessage === ""
  var value = hasProgress ? clamp(parsedValue, 0, maxValue) : 0
  var percent = hasProgress ? Math.round(value * 100 / maxValue) : -1
  var parsedDuration = parseInt(rawDuration || "1350", 10)
  var classified = classifyIcon(iconName, percent)

  var readout = String(rawMessage || "")
  if (!readout && hasProgress) {
    readout = classified.muted ? "Muted" : (rawProgressText || (number(percent) + "%"))
  }

  return {
    iconKey: String(iconName || "").toLowerCase(),
    iconKind: classified.kind,
    isMuted: classified.muted,
    maxValue: maxValue,
    hasProgress: hasProgress,
    value: value,
    percent: percent,
    message: readout,
    icon: iconFor(iconName, percent),
    duration: isNaN(parsedDuration) ? 1350 : Math.max(0, parsedDuration)
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    widestIcon: widestIcon,
    classifyIcon: classifyIcon,
    iconFor: iconFor,
    stateForShow: stateForShow
  }
}
