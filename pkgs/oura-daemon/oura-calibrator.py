#!/usr/bin/env python3
"""Interactive real-time Oura Ring Gesture Calibrator & Recorder.

Tails `~/.local/state/oura/motion-trace.jsonl` (written at ~50 Hz by `ourad`
when Gesture Mode is active) and serves a self-contained Web UI on
`http://127.0.0.1:7879` that guides you through recording labeled examples of:
  1. Rest / Typing (negative baseline)
  2. Open Mission Control (palm-up + lift up)
  3. Close Mission Control (palm-down + push down)
  4. Move Right (R->L)
  5. Move Left (L->R)

Saves labeled 50 Hz traces to `~/.local/state/oura/labeled-gestures.json` for
exact template/matched-filter calibration.
"""

import json
import math
import os
import subprocess
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "oura"
TRACE_PATH = STATE_DIR / "motion-trace.jsonl"
OUT_PATH = STATE_DIR / "labeled-gestures.json"
TPL_PATH = STATE_DIR / "gesture-templates.json"
PORT = 7879

RING_BUF = deque(maxlen=400)  # ~8s of live samples
RING_LOCK = threading.Lock()
LAST_SAMPLE_MONO = 0.0
RECORDING = {"active": False, "label": None, "samples": [], "started_ms": 0}
DATASET = {"created_unix": int(time.time()), "gestures": {}}


def compile_templates(dataset: dict) -> dict | None:
    gest = dataset.get("gestures", {})
    classes = ("open_mc", "close_mc", "swipe_right", "swipe_left")
    if any(not gest.get(c) for c in classes):
        return None
    w_len, tail = 24, 4

    def resample_20ms(rep):
        ts0, ts_end = rep[0]["ts_ms"], rep[-1]["ts_ms"]
        out, j, t = [], 0, ts0
        while t <= ts_end:
            while j + 1 < len(rep) and rep[j + 1]["ts_ms"] < t:
                j += 1
            if j + 1 < len(rep):
                t0, t1 = rep[j]["ts_ms"], rep[j + 1]["ts_ms"]
                a = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
                x = (rep[j]["x"] * (1 - a) + rep[j + 1]["x"] * a) / 1000.0
                y = (rep[j]["y"] * (1 - a) + rep[j + 1]["y"] * a) / 1000.0
                z = (rep[j]["z"] * (1 - a) + rep[j + 1]["z"] * a) / 1000.0
                lg = rep[j].get("lin_g", 0.0) * (1 - a) + rep[j + 1].get("lin_g", 0.0) * a
            else:
                x, y, z = rep[j]["x"] / 1000.0, rep[j]["y"] / 1000.0, rep[j]["z"] / 1000.0
                lg = rep[j].get("lin_g", 0.0)
            out.append((x, y, z, lg))
            t += 20
        return out

    def znorm(v):
        n = math.sqrt(sum(a * a for a in v)) or 1.0
        return [a / n for a in v]

    def window_vec(seq, end_idx):
        v = []
        for k in range(end_idx - w_len + 1, end_idx + 1):
            idx = max(0, min(len(seq) - 1, k))
            x, y, z, _ = seq[idx]
            v.extend((x, y, z))
        return v

    tpls = {}
    for c in classes:
        wins = []
        for rep in gest[c]:
            if len(rep) < 5:
                continue
            seq = resample_20ms(rep)
            pk = max(range(len(seq)), key=lambda i: seq[i][3])
            wins.append(znorm(window_vec(seq, min(len(seq) - 1, pk + tail))))
        if not wins:
            return None
        mean = [sum(w[i] for w in wins) / len(wins) for i in range(len(wins[0]))]
        tpls[c] = [round(x, 6) for x in znorm(mean)]

    return {
        "window_len": w_len,
        "sample_dt_ms": 20,
        "min_lin_g": 0.85,
        "peak_confirm_samples": 5,
        "cooldown_ms": 500,
        "thresholds": {
            "open_mc": 0.74,
            "close_mc": 0.74,
            "swipe_right": 0.76,
            "swipe_left": 0.75,
        },
        "templates": tpls,
    }


def save_dataset() -> Path:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(DATASET, indent=2))
    tpl = compile_templates(DATASET)
    if tpl is not None:
        TPL_PATH.write_text(json.dumps(tpl, indent=2))
    return OUT_PATH


def tail_trace():
    global LAST_SAMPLE_MONO
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    TRACE_PATH.touch(exist_ok=True)
    with TRACE_PATH.open("r") as f:
        f.seek(0, os.SEEK_END)
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.015)
                continue
            line = line.strip()
            if not line:
                continue
            try:
                sample = json.loads(line)
            except Exception:
                continue
            now_mono = time.monotonic()
            with RING_LOCK:
                LAST_SAMPLE_MONO = now_mono
                RING_BUF.append(sample)
                if RECORDING["active"]:
                    RECORDING["samples"].append(sample)


HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Oura Gesture Calibrator</title>
<style>
  :root {
    --bg: #141414;
    --surface: #181818;
    --surface-hover: #1E1E1E;
    --canvas-bg: #111112;
    --border: #262626;
    --fg-strong: #F4F4F5;
    --fg-muted: #8E8E93;
    --fg-subtle: #636366;
    --cta-bg: #F4F4F5;
    --cta-fg: #141414;
    --cta-hover: #E4E4E7;
    --green: #199E70;
    --blue: #86AEE4;
    --amber: #C98500;
    --red: #E05D5D;
    --grid-line: rgba(255, 255, 255, 0.06);
  }

  @media (prefers-color-scheme: light) {
    :root {
      --bg: #F5F6F8;
      --surface: #FFFFFF;
      --surface-hover: #ECEEF2;
      --canvas-bg: #FAFBFD;
      --border: #DCE0E6;
      --fg-strong: #111318;
      --fg-muted: #5A6070;
      --fg-subtle: #8890A0;
      --cta-bg: #111318;
      --cta-fg: #F4F4F5;
      --cta-hover: #242833;
      --green: #10855B;
      --blue: #2D6FD1;
      --amber: #B37400;
      --red: #CC3B3B;
      --grid-line: rgba(17, 19, 24, 0.08);
    }
  }

  * { box-sizing: border-box; }

  body {
    margin: 0;
    padding: 36px 20px 48px;
    background: var(--bg);
    color: var(--fg-strong);
    font: 14px/1.5 "IBM Plex Sans", "Inter", -apple-system, system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
  }

  .wrap {
    max-width: 640px;
    margin: 0 auto;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }

  .title {
    margin: 0;
    font-size: 18px;
    font-weight: 600;
    letter-spacing: -0.01em;
    color: var(--fg-strong);
  }

  .section-label {
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--fg-subtle);
  }

  .mono {
    font-family: "Lilex Nerd Font", "Lilex", "IBM Plex Mono", ui-monospace, monospace;
    font-variant-numeric: tabular-nums;
  }

  /* Fixed-width status pill so state transitions never cause reflow */
  .status-pill {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 7px;
    width: 108px;
    height: 28px;
    border-radius: 999px;
    border: 1px solid var(--border);
    background: var(--surface);
    font-size: 12px;
    font-weight: 500;
    color: var(--fg-muted);
    white-space: nowrap;
    flex-shrink: 0;
  }

  .status-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--fg-subtle);
    flex-shrink: 0;
  }

  .status-pill[data-state="live"] { color: var(--fg-strong); }
  .status-pill[data-state="live"] .status-dot { background: var(--green); }
  .status-pill[data-state="rec"] { color: var(--red); border-color: var(--red); }
  .status-pill[data-state="rec"] .status-dot { background: var(--red); }

  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px;
  }

  .step-meta {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 10px;
  }

  .step-title {
    margin: 0 0 6px;
    font-size: 20px;
    font-weight: 600;
    letter-spacing: -0.015em;
    color: var(--fg-strong);
  }

  .step-desc {
    margin: 0 0 20px;
    font-size: 14px;
    color: var(--fg-muted);
    min-height: 42px;
  }

  .cta {
    width: 100%;
    height: 48px;
    border: 1px solid transparent;
    border-radius: 12px;
    background: var(--cta-bg);
    color: var(--cta-fg);
    font: 600 14px/1 "IBM Plex Sans", "Inter", -apple-system, system-ui, sans-serif;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 10px;
    transition: background 120ms ease, opacity 120ms ease;
  }

  .cta:hover:not(:disabled) { background: var(--cta-hover); }
  .cta:disabled { opacity: 0.72; cursor: default; }
  .cta[data-recording="true"] {
    background: var(--red);
    color: #FFFFFF;
  }

  .kbd {
    font-size: 11px;
    font-weight: 500;
    padding: 2px 6px;
    border-radius: 5px;
    border: 1px solid currentColor;
    opacity: 0.55;
  }

  .actions {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-top: 12px;
  }

  .btn-secondary {
    height: 34px;
    padding: 0 12px;
    border-radius: 8px;
    border: 1px solid var(--border);
    background: transparent;
    color: var(--fg-muted);
    font: 500 12px/1 "IBM Plex Sans", "Inter", -apple-system, system-ui, sans-serif;
    cursor: pointer;
    transition: background 120ms ease, color 120ms ease;
  }

  .btn-secondary:hover:not(:disabled) {
    background: var(--surface-hover);
    color: var(--fg-strong);
  }

  .btn-secondary:disabled { opacity: 0.45; cursor: default; }

  .status-line {
    margin: 14px 0 0;
    min-height: 20px;
    font-size: 12px;
    color: var(--fg-muted);
  }

  .steps {
    display: grid;
    grid-template-columns: repeat(5, 1fr);
    gap: 8px;
  }

  .step-pill {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 4px;
    padding: 10px 10px;
    border-radius: 10px;
    border: 1px solid var(--border);
    background: var(--surface);
    color: var(--fg-muted);
    cursor: pointer;
    text-align: left;
    transition: background 120ms ease, border-color 120ms ease;
  }

  .step-pill:hover { background: var(--surface-hover); }
  .step-pill[data-active="true"] {
    border-color: var(--fg-strong);
    color: var(--fg-strong);
  }

  .step-pill-name {
    font-size: 12px;
    font-weight: 500;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    width: 100%;
  }

  .step-pill-count {
    font-size: 11px;
    color: var(--fg-subtle);
  }

  .step-pill[data-done="true"] .step-pill-count {
    color: var(--green);
  }

  .sensor-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 10px;
  }

  .legend {
    display: flex;
    align-items: center;
    gap: 14px;
    font-size: 11px;
    color: var(--fg-muted);
  }

  .legend-item {
    display: inline-flex;
    align-items: center;
    gap: 5px;
  }

  .swatch {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    display: inline-block;
  }

  canvas {
    width: 100%;
    height: 112px;
    display: block;
    border-radius: 8px;
    background: var(--canvas-bg);
    border: 1px solid var(--border);
  }

  @media (max-width: 560px) {
    .steps { grid-template-columns: repeat(2, 1fr); }
  }
</style>
</head>
<body>
  <main class="wrap">
    <header class="header">
      <h1 class="title">Oura Gesture Calibrator</h1>
      <div id="streamPill" class="status-pill" data-state="idle">
        <span class="status-dot"></span>
        <span id="streamText">Idle</span>
      </div>
    </header>

    <section class="card">
      <div class="step-meta">
        <span id="stepIndex" class="section-label mono">STEP 1 OF 5</span>
        <span id="stepReps" class="section-label mono">0 / 1 REPS</span>
      </div>
      <h2 id="stepTitle" class="step-title"></h2>
      <p id="stepDesc" class="step-desc"></p>

      <button id="recBtn" class="cta" type="button" data-recording="false">
        <span id="recBtnText">Record rep</span>
        <span id="recBtnKbd" class="kbd mono">Space</span>
      </button>

      <div class="actions">
        <button id="clearBtn" class="btn-secondary" type="button">Reset step</button>
        <button id="saveBtn" class="btn-secondary" type="button">Save dataset</button>
      </div>

      <p id="statusLine" class="status-line"></p>
    </section>

    <nav class="steps" id="stepPills" aria-label="Calibration steps"></nav>

    <section class="card">
      <div class="sensor-header">
        <span class="section-label">Accelerometer</span>
        <div class="legend mono">
          <span class="legend-item"><i class="swatch" style="background:var(--blue)"></i>X</span>
          <span class="legend-item"><i class="swatch" style="background:var(--green)"></i>Y</span>
          <span class="legend-item"><i class="swatch" style="background:var(--amber)"></i>Z</span>
          <span id="hzLabel" style="min-width:44px;text-align:right">0 Hz</span>
        </div>
      </div>
      <canvas id="wave" width="600" height="112"></canvas>
    </section>
  </main>

<script>
const STEPS = [
  { id: "rest_typing", short: "Typing", name: "Rest / Normal Typing", reps: 1, dur: 4.0,
    desc: "Keep your hand palm-down and type or move normally for 4 seconds." },
  { id: "open_mc", short: "Open MC", name: "Open Mission Control", reps: 3, dur: 1.8,
    desc: "Flip palm-up and perform one upward lift to open Mission Control." },
  { id: "close_mc", short: "Close MC", name: "Close Mission Control", reps: 3, dur: 1.8,
    desc: "Flip palm-down and perform one downward push to close Mission Control." },
  { id: "swipe_right", short: "Right (R→L)", name: "Move Right (R → L)", reps: 3, dur: 1.5,
    desc: "Perform one Right-to-Left motion to switch to the Space on the right." },
  { id: "swipe_left", short: "Left (L→R)", name: "Move Left (L → R)", reps: 3, dur: 1.5,
    desc: "Perform one Left-to-Right motion to switch to the Space on the left." },
];

let curStep = 0;
let counts = Object.fromEntries(STEPS.map(s => [s.id, 0]));
let recording = false;
let lastBadgeState = "";
let lastHzText = "";

const el = (id) => document.getElementById(id);

function buildStepPills() {
  const nav = el("stepPills");
  nav.innerHTML = "";
  STEPS.forEach((st, i) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "step-pill";
    btn.id = `pill-${i}`;
    btn.innerHTML = `<span class="step-pill-name">${i + 1}. ${st.short}</span><span class="step-pill-count mono" id="pill-count-${i}">0/${st.reps}</span>`;
    btn.onclick = () => {
      if (!recording) {
        curStep = i;
        updateStepUI();
      }
    };
    nav.appendChild(btn);
  });
}

function updateStepUI() {
  const s = STEPS[curStep];
  el("stepIndex").textContent = `STEP ${curStep + 1} OF ${STEPS.length}`;
  el("stepReps").textContent = `${counts[s.id]} / ${s.reps} REPS`;
  el("stepTitle").textContent = s.name;
  el("stepDesc").textContent = s.desc;
  STEPS.forEach((st, i) => {
    const pill = el(`pill-${i}`);
    pill.dataset.active = String(i === curStep);
    pill.dataset.done = String(counts[st.id] >= st.reps);
    el(`pill-count-${i}`).textContent = `${counts[st.id]}/${st.reps}`;
  });
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function recordRep() {
  if (recording) return;
  recording = true;
  const s = STEPS[curStep];
  const btn = el("recBtn");
  const btnText = el("recBtnText");
  const btnKbd = el("recBtnKbd");
  btn.disabled = true;
  btnKbd.style.display = "none";

  btnText.textContent = "Get ready…";
  await sleep(450);

  btn.dataset.recording = "true";
  await fetch("/record/start", { method: "POST", body: JSON.stringify({ label: s.id }) });

  const t0 = performance.now();
  const durMs = s.dur * 1000;
  while (performance.now() - t0 < durMs) {
    const rem = Math.max(0, (durMs - (performance.now() - t0)) / 1000);
    btnText.textContent = `Recording · ${rem.toFixed(1)}s`;
    await sleep(60);
  }

  btn.dataset.recording = "false";
  btnText.textContent = "Saving…";
  const resp = await (await fetch("/record/stop", { method: "POST" })).json();

  if (resp.count < 5) {
    el("statusLine").textContent = "No samples received — ensure Space Gestures is active and try again.";
  } else {
    counts[s.id] = resp.total_for_label;
    const allDone = STEPS.every(st => counts[st.id] >= st.reps);
    el("statusLine").textContent = allDone
      ? `All steps complete and saved (${resp.count} samples).`
      : `Saved rep ${counts[s.id]}/${s.reps} (${resp.count} samples).`;
    if (counts[s.id] >= s.reps && curStep < STEPS.length - 1) {
      curStep++;
    }
  }

  btnText.textContent = "Record rep";
  btnKbd.style.display = "";
  btn.disabled = false;
  recording = false;
  updateStepUI();
}

el("recBtn").onclick = recordRep;

window.addEventListener("keydown", (e) => {
  if (e.code === "Space" && !e.repeat && document.activeElement?.tagName !== "BUTTON") {
    e.preventDefault();
    recordRep();
  }
});

el("clearBtn").onclick = async () => {
  if (recording) return;
  const s = STEPS[curStep];
  await fetch("/record/clear", { method: "POST", body: JSON.stringify({ label: s.id }) });
  counts[s.id] = 0;
  el("statusLine").textContent = `Cleared ${s.name}.`;
  updateStepUI();
};

el("saveBtn").onclick = async () => {
  const r = await (await fetch("/save", { method: "POST" })).json();
  el("statusLine").textContent = `Dataset written to ${r.path}`;
};

// Live waveform poller — zero DOM reflows on steady state
const cv = el("wave");
const ctx = cv.getContext("2d");

function getColors() {
  const cs = getComputedStyle(document.documentElement);
  return {
    grid: cs.getPropertyValue("--grid-line").trim(),
    x: cs.getPropertyValue("--blue").trim(),
    y: cs.getPropertyValue("--green").trim(),
    z: cs.getPropertyValue("--amber").trim(),
  };
}

async function poll() {
  try {
    const r = await (await fetch("/live")).json();
    const state = r.recording ? "rec" : (r.live ? "live" : "idle");
    if (state !== lastBadgeState) {
      lastBadgeState = state;
      el("streamPill").dataset.state = state;
      el("streamText").textContent = state === "rec" ? "Recording" : (state === "live" ? "Live" : "Idle");
    }

    const hzText = `${r.hz} Hz`;
    if (hzText !== lastHzText) {
      lastHzText = hzText;
      el("hzLabel").textContent = hzText;
    }

    const pts = r.samples;
    const col = getColors();
    ctx.clearRect(0, 0, cv.width, cv.height);
    ctx.strokeStyle = col.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, cv.height / 2);
    ctx.lineTo(cv.width, cv.height / 2);
    ctx.stroke();

    if (pts.length > 1) {
      const draw = (key, stroke) => {
        ctx.strokeStyle = stroke;
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        for (let i = 0; i < pts.length; i++) {
          const x = (i / (pts.length - 1)) * cv.width;
          const y = cv.height / 2 - (pts[i][key] / 2500.0) * (cv.height * 0.44);
          if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        }
        ctx.stroke();
      };
      draw("x", col.x);
      draw("y", col.y);
      draw("z", col.z);
    }
  } catch (_) {}
  setTimeout(poll, 100);
}

buildStepPills();
updateStepUI();
poll();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/live":
            now_ms = int(time.time() * 1000)
            now_mono = time.monotonic()
            with RING_LOCK:
                samples = list(RING_BUF)[-180:]
                # 2.5s window prevents dips across ourad's 1.0s BufWriter flush
                live = (now_mono - LAST_SAMPLE_MONO) < 2.8
                recent_count = sum(1 for s in samples if now_ms - s.get("ts_ms", 0) <= 2500)
                hz = round(recent_count / 2.5) if live else 0
                rec = RECORDING["active"]
            self._send_json({"samples": samples, "hz": hz, "live": live, "recording": rec})
        else:
            body = HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n) if n > 0 else b"{}"
        data = json.loads(raw.decode() or "{}")

        if self.path == "/record/start":
            with RING_LOCK:
                live = (time.monotonic() - LAST_SAMPLE_MONO) < 2.8
            if not live:
                subprocess.run(["ouractl", "gestures", "on"], capture_output=True)
                time.sleep(0.35)
            with RING_LOCK:
                RECORDING["active"] = True
                RECORDING["label"] = data.get("label", "unknown")
                RECORDING["samples"] = []
                RECORDING["started_ms"] = int(time.time() * 1000)
            self._send_json({"ok": True})
        elif self.path == "/record/stop":
            # Wait briefly for ourad's 1s trace flush so tail samples arrive
            time.sleep(1.05)
            with RING_LOCK:
                RECORDING["active"] = False
                label = RECORDING["label"]
                samples = list(RECORDING["samples"])
                RECORDING["samples"] = []
            if len(samples) >= 5:
                DATASET["gestures"].setdefault(label, []).append(samples)
                save_dataset()
            total = len(DATASET["gestures"].get(label, []))
            self._send_json({"ok": True, "count": len(samples), "total_for_label": total})
        elif self.path == "/record/clear":
            label = data.get("label", "")
            DATASET["gestures"][label] = []
            save_dataset()
            self._send_json({"ok": True})
        elif self.path == "/save":
            path = save_dataset()
            self._send_json({"ok": True, "path": str(path)})
        else:
            self._send_json({"ok": False}, 404)


if __name__ == "__main__":
    t = threading.Thread(target=tail_trace, daemon=True)
    t.start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Oura Gesture Calibrator running at http://127.0.0.1:{PORT}", flush=True)
    srv.serve_forever()
