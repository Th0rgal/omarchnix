#!/usr/bin/env python3
"""murmured: Native Wayland / Hyprland on-device dictation daemon for Murmure.

Features:
- Hardware-level evdev global shortcut monitor (`Fn + Right ⇧` default, distinct
  left/right modifiers, tap-to-toggle & hold push-to-talk with 250 ms release tail,
  live shortcut recorder for Settings).
- Hyprland `murmure-recording` submap integration so `Esc` (cancel) and `Return`
  (commit) are cleanly swallowed during active dictation without leaking into apps.
- PipeWire 16 kHz mono keep-warm recorder with rolling pre-buffer (`RingBuffer`),
  perceptual 30-bar waveform envelope meter (25 Hz), and adaptive VAD `Chunker`
  tuned for Apple M2 Vulkan's 64-frame workgroup tile.
- Shared `voiced` Unix-socket client (`~/.local/share/md.thomas.voice/voiced.sock`)
  so Murmure and Orb Desktop share one resident Cohere Transcribe model.
- Full `TextPipeline` (`vocabulary.txt`, `corrections.json`, disfluency stripping,
  voice commands, spoken numbers, smart cross-chunk casing joiner).
- Universal Wayland + Hyprland paste (`wl-copy` + terminal-aware `Ctrl+Shift+V` vs
  `Ctrl+V` via `hyprctl eval` + 650 ms clipboard restore).
"""

from __future__ import annotations

import atexit
import collections
import glob
import io
import json
import locale
import math
import os
import select
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import wave
from typing import Any, Callable, Deque, Dict, List, Optional, Set, Tuple

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
VOICED_DIR = os.path.abspath(os.path.join(THIS_DIR, "..", "voiced"))
if VOICED_DIR not in sys.path:
    sys.path.insert(0, VOICED_DIR)

import orb_voice_bridge as bridge  # noqa: E402
import pipeline as vp  # noqa: E402
import voiced as vd  # noqa: E402
import worker as w  # noqa: E402

SAMPLE_RATE = 16000
BARS = 30

# Linux input-event-codes.h
EV_KEY = 0x01
KEY_ESC = 1
KEY_ENTER = 28
KEY_KPENTER = 96

MODIFIER_ORDER = (
    "fn",
    "leftControl",
    "rightControl",
    "leftOption",
    "rightOption",
    "leftShift",
    "rightShift",
    "leftCommand",
    "rightCommand",
)

MODIFIER_KEYCODES: Dict[str, int] = {
    "fn": 464,
    "leftControl": 29,
    "rightControl": 97,
    "leftOption": 56,
    "rightOption": 100,
    "leftShift": 42,
    "rightShift": 54,
    "leftCommand": 125,
    "rightCommand": 126,
}
KEYCODE_TO_MODIFIER: Dict[int, str] = {v: k for k, v in MODIFIER_KEYCODES.items()}

MODIFIER_LABELS: Dict[str, str] = {
    "fn": "Fn",
    "leftControl": "Left ⌃",
    "rightControl": "Right ⌃",
    "leftOption": "Left ⌥",
    "rightOption": "Right ⌥",
    "leftShift": "Left ⇧",
    "rightShift": "Right ⇧",
    "leftCommand": "Left ⌘",
    "rightCommand": "Right ⌘",
}

FUNCTION_KEYCODES: Set[int] = set(range(59, 69)) | {87, 88} | set(range(183, 195))
ARROW_KEYCODES: Set[int] = {103, 105, 106, 108}

EVDEV_KEY_LABELS: Dict[int, str] = {
    14: "⌫", 15: "Tab", 28: "Return", 57: "Space", 96: "Return", 111: "⌦",
    103: "↑", 105: "←", 106: "→", 108: "↓",
    2: "1", 3: "2", 4: "3", 5: "4", 6: "5", 7: "6", 8: "7", 9: "8", 10: "9", 11: "0",
    12: "-", 13: "=", 16: "Q", 17: "W", 18: "E", 19: "R", 20: "T", 21: "Y", 22: "U",
    23: "I", 24: "O", 25: "P", 26: "[", 27: "]", 30: "A", 31: "S", 32: "D", 33: "F",
    34: "G", 35: "H", 36: "J", 37: "K", 38: "L", 39: ";", 40: "'", 41: "`", 43: "\\",
    44: "Z", 45: "X", 46: "C", 47: "V", 48: "B", 49: "N", 50: "M", 51: ",", 52: ".", 53: "/",
    59: "F1", 60: "F2", 61: "F3", 62: "F4", 63: "F5", 64: "F6", 65: "F7", 66: "F8",
    67: "F9", 68: "F10", 87: "F11", 88: "F12", 183: "F13", 184: "F14", 185: "F15",
    186: "F16", 187: "F17", 188: "F18", 189: "F19", 190: "F20",
}

INPUT_EVENT_STRUCT = struct.Struct("llHHi")


def log(msg: str) -> None:
    sys.stderr.write(f"[murmure] {time.strftime('%H:%M:%S')} {msg}\n")
    sys.stderr.flush()


def config_dir() -> str:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "murmure")


def settings_path() -> str:
    return os.path.join(config_dir(), "settings.json")


def control_socket_path() -> str:
    if os.environ.get("MURMURE_SOCKET"):
        return os.environ["MURMURE_SOCKET"]
    rt = os.environ.get("XDG_RUNTIME_DIR")
    if rt and os.path.isdir(rt):
        return os.path.join(rt, "murmure.sock")
    return os.path.join(vp.voice_home(), "murmure.sock")


def detect_default_language() -> str:
    for env_key in ("LC_ALL", "LC_MESSAGES", "LANG"):
        val = os.environ.get(env_key, "")
        if val:
            code = val.split(".", 1)[0].split("_", 1)[0].split("-", 1)[0].lower()
            if code in vp.LANGUAGE_BY_CODE:
                return code
    try:
        loc = locale.getlocale()[0] or ""
        code = loc.split("_", 1)[0].lower()
        if code in vp.LANGUAGE_BY_CODE:
            return code
    except Exception:
        pass
    return "en"


DEFAULT_SHORTCUT: Dict[str, Any] = {
    "modifiers": ["fn", "rightShift"],
    "keyCode": None,
    "keyLabel": None,
}


def format_shortcut_label(sc: Dict[str, Any]) -> str:
    mods = set(sc.get("modifiers") or [])
    ordered = [MODIFIER_LABELS[m] for m in MODIFIER_ORDER if m in mods]
    kl = sc.get("keyLabel")
    if kl:
        ordered.append(str(kl))
    return " + ".join(ordered) if ordered else "Fn + Right ⇧"


def is_valid_shortcut(sc: Dict[str, Any]) -> bool:
    mods = [m for m in (sc.get("modifiers") or []) if m in MODIFIER_KEYCODES]
    kc = sc.get("keyCode")
    if kc is not None:
        return bool(mods) or (int(kc) in FUNCTION_KEYCODES)
    return bool(mods)


class SettingsStore:
    def __init__(self, path: Optional[str] = None) -> None:
        self.path = path or settings_path()
        self.lock = threading.Lock()
        self._mtime: float = -1.0
        self.data: Dict[str, Any] = self._defaults()
        self.reload(force=True)

    def _defaults(self) -> Dict[str, Any]:
        return {
            "language": detect_default_language(),
            "shortcut": dict(DEFAULT_SHORTCUT),
            "liveChunks": True,
            "restoreClipboard": True,
            "releaseTailMs": 250.0,
            "prebufferSecs": 0.45,
            "keepWarmMinutes": 5.0,
            "autoStopSilenceSecs": 5.0,
            "autoStopNoSpeechSecs": 20.0,
            "removeDisfluencies": True,
            "voiceCommands": False,
            "convertNumbers": False,
            "streamInline": False,
            "openAtLogin": True,
        }

    def reload(self, force: bool = False) -> bool:
        with self.lock:
            try:
                st = os.stat(self.path)
                if not force and st.st_mtime == self._mtime:
                    return False
                with open(self.path, "r", encoding="utf-8") as f:
                    raw = json.load(f)
                self._mtime = st.st_mtime
            except (OSError, ValueError):
                if force:
                    self.data = self._defaults()
                return False

            merged = self._defaults()
            if isinstance(raw, dict):
                for k in merged:
                    if k in raw:
                        merged[k] = raw[k]
            if merged["language"] not in vp.LANGUAGE_BY_CODE:
                merged["language"] = detect_default_language()
            if not isinstance(merged["shortcut"], dict) or not is_valid_shortcut(merged["shortcut"]):
                merged["shortcut"] = dict(DEFAULT_SHORTCUT)
            self.data = merged
            return True

    def get(self) -> Dict[str, Any]:
        self.reload(force=False)
        with self.lock:
            out = dict(self.data)
            out["shortcut"] = dict(self.data["shortcut"])
            out["shortcutLabel"] = format_shortcut_label(out["shortcut"])
            return out

    def update(self, patch: Dict[str, Any]) -> Dict[str, Any]:
        with self.lock:
            cur = dict(self.data)
            for k, v in patch.items():
                if k == "language" and isinstance(v, str) and v in vp.LANGUAGE_BY_CODE:
                    cur["language"] = v
                elif k == "shortcut" and isinstance(v, dict) and is_valid_shortcut(v):
                    cur["shortcut"] = {
                        "modifiers": [m for m in MODIFIER_ORDER if m in (v.get("modifiers") or [])],
                        "keyCode": int(v["keyCode"]) if v.get("keyCode") is not None else None,
                        "keyLabel": str(v["keyLabel"]) if v.get("keyLabel") else None,
                    }
                elif k in (
                    "liveChunks",
                    "restoreClipboard",
                    "removeDisfluencies",
                    "voiceCommands",
                    "convertNumbers",
                    "streamInline",
                    "openAtLogin",
                ):
                    cur[k] = bool(v)
                elif k in (
                    "releaseTailMs",
                    "prebufferSecs",
                    "keepWarmMinutes",
                    "autoStopSilenceSecs",
                    "autoStopNoSpeechSecs",
                ):
                    try:
                        cur[k] = max(0.0, float(v))
                    except (TypeError, ValueError):
                        pass
            self.data = cur
            os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
            tmp = f"{self.path}.tmp.{os.getpid()}"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(cur, f, ensure_ascii=False, indent=2)
                f.write("\n")
            os.replace(tmp, self.path)
            try:
                self._mtime = os.stat(self.path).st_mtime
            except OSError:
                pass
            out = dict(cur)
            out["shortcut"] = dict(cur["shortcut"])
            out["shortcutLabel"] = format_shortcut_label(out["shortcut"])
            return out


# --------------------------------------------------------------------------
# Core DSP / State Machines (1:1 port of MurmureCore)


class HotkeyState:
    """Tap (< hold_threshold) toggles start/commit; hold (>= hold_threshold) is push-to-talk."""

    def __init__(self, hold_threshold: float = 0.35) -> None:
        self.hold_threshold = hold_threshold
        self.recording = False
        self._down = False
        self._started_at: Optional[float] = None

    def update(self, pressed: bool, at: float) -> Optional[str]:
        was_down = self._down
        self._down = pressed
        if pressed and not was_down:
            if self.recording:
                self.recording = False
                self._started_at = None
                return "commit"
            self.recording = True
            self._started_at = at
            return "start"
        if (not pressed) and was_down and self.recording and self._started_at is not None:
            started = self._started_at
            self._started_at = None
            if (at - started) >= self.hold_threshold:
                self.recording = False
                return "releaseCommit"
        return None

    def reset(self) -> None:
        self.recording = False
        self._started_at = None


class RingBuffer:
    """Fixed-capacity rolling Float32 ring buffer for pre-buffering audio."""

    def __init__(self, capacity: int) -> None:
        self.capacity = max(1, capacity)
        self._buf: Deque[float] = collections.deque(maxlen=self.capacity)

    def append_many(self, samples: List[float]) -> None:
        if len(samples) >= self.capacity:
            self._buf.clear()
            self._buf.extend(samples[-self.capacity :])
        else:
            self._buf.extend(samples)

    def drain(self) -> List[float]:
        out = list(self._buf)
        self._buf.clear()
        return out

    def clear(self) -> None:
        self._buf.clear()


class Chunker:
    """Adaptive energy VAD chunker tuned for Apple M2 Vulkan's 64-frame (5.12s) encoder tiles."""

    def __init__(
        self,
        sample_rate: int = SAMPLE_RATE,
        min_chunk: float = 4.6,
        max_chunk: float = 14.8,
        min_pause: float = 0.42,
    ) -> None:
        self.sample_rate = sample_rate
        self.min_chunk = min_chunk
        self.max_chunk = max_chunk
        self.min_pause = min_pause
        self.frame = sample_rate * 30 // 1000  # 480 samples = 30 ms
        self.frame_rms: List[float] = []
        self.cut_frame = 0
        self._carry: List[float] = []
        self.speech_frames = 0
        self.trailing_silent_frames = 0

    @property
    def has_spoken(self) -> bool:
        return self.speech_frames >= 5

    @property
    def fps(self) -> float:
        return self.sample_rate / float(self.frame)

    @property
    def trailing_silent_secs(self) -> float:
        return self.trailing_silent_frames / self.fps

    @property
    def total_secs(self) -> float:
        return len(self.frame_rms) / self.fps

    def should_auto_stop(self, no_speech_secs: float = 20.0, silence_after_speech_secs: float = 5.0) -> bool:
        if self.has_spoken:
            return silence_after_speech_secs > 0 and self.trailing_silent_secs >= silence_after_speech_secs
        return no_speech_secs > 0 and self.total_secs >= no_speech_secs

    def _silence_threshold(self) -> float:
        window = int(10 * self.fps)
        recent = sorted(self.frame_rms[-window:])
        if not recent:
            return 0.006
        floor = recent[len(recent) // 10]
        speech = recent[(len(recent) * 9) // 10]
        return max(0.006, min(floor * 3.0, speech * 0.3))

    def feed(self, samples: List[float]) -> Optional[int]:
        self._carry.extend(samples)
        used = 0
        fsize = self.frame
        while len(self._carry) - used >= fsize:
            seg = self._carry[used : used + fsize]
            energy = math.sumprod(seg, seg) if hasattr(math, "sumprod") else sum(x * x for x in seg)
            rms = math.sqrt(energy / fsize)
            self.frame_rms.append(rms)
            thresh = self._silence_threshold()
            if rms < thresh:
                self.trailing_silent_frames += 1
            else:
                self.speech_frames += 1
                self.trailing_silent_frames = 0
            used += fsize
        if used:
            del self._carry[:used]

        pending = len(self.frame_rms) - self.cut_frame
        if pending < self.min_chunk * self.fps:
            return None

        thresh = self._silence_threshold()
        needed = int(self.min_pause * self.fps)
        run = 0
        lowest = self.cut_frame + int(self.min_chunk * self.fps / 2)
        for i in range(len(self.frame_rms) - 1, lowest - 1, -1):
            if self.frame_rms[i] < thresh:
                run += 1
            elif run >= needed:
                cut_f = i + 1 + run // 2
                self.cut_frame = cut_f
                return cut_f * fsize
            else:
                run = 0

        if pending >= self.max_chunk * self.fps:
            start_f = max(self.cut_frame + 1, len(self.frame_rms) - int(3 * self.fps))
            q = min(range(start_f, len(self.frame_rms)), key=lambda idx: self.frame_rms[idx])
            self.cut_frame = q
            return q * fsize
        return None


def encode_wav_16k(samples: List[float]) -> bytes:
    ints = [max(-32768, min(32767, int(round(s * (32768.0 if s < 0 else 32767.0))))) for s in samples]
    raw = struct.pack(f"<{len(ints)}h", *ints) if ints else b""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(raw)
    return buf.getvalue()


# --------------------------------------------------------------------------
# PipeWire Keep-Warm Audio Recorder


class PipeWireRecorder:
    """Streams 16 kHz mono s16le PCM from PipeWire (`pw-cat` / `pw-record`) with keep-warm prebuffer."""

    def __init__(self, on_samples: Callable[[], None]) -> None:
        self.on_samples = on_samples
        self.lock = threading.Lock()
        self.samples: List[float] = []
        self.prebuffer = RingBuffer(int(0.45 * SAMPLE_RATE))
        self.active_recording = False
        self.envelope = 0.0
        self.levels: List[float] = []
        self._proc: Optional[subprocess.Popen] = None
        self._reader_thread: Optional[threading.Thread] = None
        self._warm_timer: Optional[threading.Timer] = None
        self._zero_run: int = 0
        self._last_heal_at: float = -30.0

    def _spawn_stream(self) -> None:
        if self._proc is not None and self._proc.poll() is None:
            return
        cmds = [
            [
                "pw-cat",
                "--record",
                "--raw",
                "-",
                "--format",
                "s16",
                "--rate",
                str(SAMPLE_RATE),
                "--channels",
                "1",
                "--latency",
                "10ms",
            ],
            [
                "pw-record",
                "--raw",
                "--format",
                "s16",
                "--rate",
                str(SAMPLE_RATE),
                "--channels",
                "1",
                "--latency",
                "10ms",
                "-",
            ],
        ]
        last_err: Optional[Exception] = None
        for cmd in cmds:
            try:
                proc = subprocess.Popen(
                    cmd,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    bufsize=0,
                )
                self._proc = proc
                t = threading.Thread(target=self._read_loop, args=(proc,), name="murmure-pw-read", daemon=True)
                self._reader_thread = t
                t.start()
                return
            except OSError as e:
                last_err = e
        raise RuntimeError(f"Could not start PipeWire microphone capture: {last_err}")

    def _heal_zero_stream_async(self, proc: subprocess.Popen) -> None:
        def _heal() -> None:
            log("detected all-zero PipeWire capture; restarting WirePlumber & audio stream")
            try:
                subprocess.run(
                    ["systemctl", "--user", "restart", "wireplumber.service"],
                    env=_user_systemd_env(),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=4.0,
                    check=False,
                )
            except Exception:
                pass
            time.sleep(0.35)
            with self.lock:
                should_respawn = self.active_recording
            if self._proc is proc:
                self._proc = None
            if proc.poll() is None:
                try:
                    proc.terminate()
                except Exception:
                    pass
            if should_respawn:
                try:
                    self._spawn_stream()
                except Exception as e:
                    log(f"stream respawn after heal failed: {e}")

        threading.Thread(target=_heal, name="murmure-pw-heal", daemon=True).start()

    def _read_loop(self, proc: subprocess.Popen) -> None:
        out = proc.stdout
        if out is None:
            return
        try:
            # Skip optional container header if pw-cat/pw-record ever emits WAV ("RIFF") or Sun .au ("dns.")
            first = out.read(44)
            if not first:
                return
            pending = bytearray()
            if len(first) >= 12 and first[:4] == b"RIFF" and first[8:12] == b"WAVE":
                # Raw PCM starts right after the 44-byte standard PCM WAV header
                pass
            elif len(first) >= 24 and first[:4] == b"dns.":
                # PipeWire sndfile Sun/DEC .au header (little-endian data offset at bytes 4..8, typically 24)
                hdr_off = struct.unpack("<I", first[4:8])[0]
                if 24 <= hdr_off <= len(first):
                    pending.extend(first[hdr_off:])
                elif hdr_off > len(first):
                    rem = hdr_off - len(first)
                    if rem <= 4096:
                        out.read(rem)
            else:
                pending.extend(first)

            chunk_bytes = 320  # 160 int16 samples = 10 ms @ 16 kHz
            while proc.poll() is None:
                raw = out.read(chunk_bytes)
                if not raw:
                    break
                pending.extend(raw)
                n_shorts = len(pending) // 2
                if n_shorts <= 0:
                    continue
                usable = bytes(pending[: n_shorts * 2])
                del pending[: n_shorts * 2]
                ints = struct.unpack(f"<{n_shorts}h", usable)
                all_zero = not any(ints)
                floats = [x / 32768.0 for x in ints]

                notify = False
                need_heal = False
                with self.lock:
                    if self.active_recording:
                        if all_zero:
                            self._zero_run += n_shorts
                            now = time.monotonic()
                            if self._zero_run >= int(0.8 * SAMPLE_RATE) and (now - self._last_heal_at) >= 15.0:
                                self._zero_run = 0
                                self._last_heal_at = now
                                need_heal = True
                        else:
                            self._zero_run = 0
                        self.samples.extend(floats)
                        self._meter_locked(floats)
                        notify = True
                    else:
                        self._zero_run = 0
                        self.prebuffer.append_many(floats)
                if need_heal:
                    self._heal_zero_stream_async(proc)
                    return
                if notify:
                    try:
                        self.on_samples()
                    except Exception:
                        pass
        finally:
            if self._proc is proc:
                self._proc = None
            with self.lock:
                should_respawn = self.active_recording
            if should_respawn:
                time.sleep(0.15)
                with self.lock:
                    still_rec = self.active_recording
                if still_rec:
                    try:
                        self._spawn_stream()
                    except Exception as e:
                        log(f"stream auto-respawn failed: {e}")

    def _meter_locked(self, chunk: List[float]) -> None:
        block = 160  # 10 ms @ 16 kHz
        i = 0
        n = len(chunk)
        while i + block <= n:
            seg = chunk[i : i + block]
            e = math.sumprod(seg, seg) if hasattr(math, "sumprod") else sum(x * x for x in seg)
            rms = max(math.sqrt(e / block), 1e-6)
            db = 20.0 * math.log10(rms)
            target = max(0.0, min(1.0, (db + 62.0) / 40.0))
            tau = 45.0 if target > self.envelope else 180.0
            self.envelope += (target - self.envelope) * (1.0 - math.exp(-10.0 / tau))
            self.levels.append(self.envelope)
            i += block
        if len(self.levels) > 200:
            del self.levels[: len(self.levels) - 200]

    def start(self, prebuffer_secs: float) -> None:
        if self._warm_timer is not None:
            self._warm_timer.cancel()
            self._warm_timer = None
        cap = max(1600, int(prebuffer_secs * SAMPLE_RATE))
        already_warm = self._proc is not None and self._proc.poll() is None
        with self.lock:
            warm_samples = self.prebuffer.drain() if already_warm else []
            self.prebuffer = RingBuffer(cap)
            self.samples = warm_samples[-cap:] if warm_samples else []
            self.levels = []
            self.envelope = 0.0
            self._zero_run = 0
            self.active_recording = True
        self._spawn_stream()

    def drain_levels(self) -> List[float]:
        with self.lock:
            out = list(self.levels)
            self.levels.clear()
            return out

    @property
    def count(self) -> int:
        with self.lock:
            return len(self.samples)

    def slice(self, start: int, end: int) -> List[float]:
        with self.lock:
            s = max(0, min(start, len(self.samples)))
            e = max(s, min(end, len(self.samples)))
            return self.samples[s:e]

    def stop(self, keep_warm_minutes: float) -> List[float]:
        with self.lock:
            self.active_recording = False
            self.prebuffer.clear()
            captured = list(self.samples)
            self.samples = []
        if self._warm_timer is not None:
            self._warm_timer.cancel()
            self._warm_timer = None
        warm_secs = max(0.0, keep_warm_minutes * 60.0)
        if warm_secs > 0:
            t = threading.Timer(warm_secs, self.shutdown)
            t.daemon = True
            self._warm_timer = t
            t.start()
        else:
            self.shutdown()
        return captured

    def shutdown(self) -> None:
        if self._warm_timer is not None:
            self._warm_timer.cancel()
            self._warm_timer = None
        proc = self._proc
        self._proc = None
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=1.0)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        with self.lock:
            self.active_recording = False
            self.prebuffer.clear()


# --------------------------------------------------------------------------
# Shared voiced Client


class VoiceSocketClient:
    def __init__(self) -> None:
        self._req_id = 0

    def _call(self, op: str, extra: Optional[Dict[str, Any]] = None, payload: bytes = b"") -> Dict[str, Any]:
        self._req_id += 1
        req: Dict[str, Any] = {"id": self._req_id, "op": op}
        if extra:
            req.update(extra)
        if payload:
            req["audio_bytes"] = len(payload)
        sock_path = vd.socket_path()
        sock = bridge.connect_or_spawn_voiced(sock_path)
        if sock is None:
            raise w.WorkerError("daemon_missing", f"voiced is not reachable at {sock_path}")
        try:
            rfile = sock.makefile("rb")
            wfile = sock.makefile("wb")
            wfile.write((json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8"))
            if payload:
                wfile.write(payload)
            wfile.flush()
            resp_line = rfile.readline(w.MAX_HEADER_BYTES + 1)
            if not resp_line:
                raise w.WorkerError("internal", "voiced closed connection unexpectedly")
            resp = json.loads(resp_line.decode("utf-8"))
            if not resp.get("ok"):
                err = resp.get("error") or {}
                raise w.WorkerError(str(err.get("code") or "error"), str(err.get("message") or "voiced error"))
            return resp.get("result") or {}
        finally:
            try:
                sock.close()
            except OSError:
                pass

    def load(self) -> Dict[str, Any]:
        return self._call("load")

    def hello(self) -> Dict[str, Any]:
        return self._call("hello")

    def transcribe(
        self,
        wav_bytes: bytes,
        language: str,
        context: Optional[str] = None,
        vocabulary: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        extra: Dict[str, Any] = {"language": language, "punctuation": True}
        if context:
            extra["context"] = context
        if vocabulary is not None:
            extra["vocabulary"] = vocabulary
        return self._call("transcribe", extra=extra, payload=wav_bytes)


# --------------------------------------------------------------------------
# Wayland Clipboard + Hyprland Universal Paste


def _user_systemd_env() -> Dict[str, str]:
    env = dict(os.environ)
    rt = env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    env["XDG_RUNTIME_DIR"] = rt
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={rt}/bus")
    return env


def _hyprctl_env() -> Optional[Dict[str, str]]:
    env = dict(os.environ)
    rt = env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    env["XDG_RUNTIME_DIR"] = rt
    hypr_dir = os.path.join(rt, "hypr")
    if not env.get("HYPRLAND_INSTANCE_SIGNATURE") and os.path.isdir(hypr_dir):
        try:
            res = subprocess.run(
                ["hyprctl", "instances", "-j"],
                env=env,
                capture_output=True,
                text=True,
                timeout=1.5,
            )
            if res.returncode == 0:
                arr = json.loads(res.stdout)
                if arr and isinstance(arr, list) and arr[0].get("instance"):
                    env["HYPRLAND_INSTANCE_SIGNATURE"] = str(arr[0]["instance"])
        except Exception:
            entries = sorted(os.listdir(hypr_dir))
            if entries:
                env["HYPRLAND_INSTANCE_SIGNATURE"] = entries[-1]
    return env if env.get("HYPRLAND_INSTANCE_SIGNATURE") else None


PASTE_LUA = r"""
do
  local w = hl.get_active_window()
  local is_term = false
  if w then
    for _, tag in ipairs(w.tags or {}) do
      if tag:gsub("%*$", "") == "terminal" then
        is_term = true
        break
      end
    end
    if not is_term then
      local cls = (w.class or w.initial_class or ""):lower()
      if cls:match("^(foot|foot%-scratchpad|alacritty|kitty|wezterm|.*ghostty.*|org%.omarchy%..*|tui%..*)$") then
        is_term = true
      end
    end
  end
  local mods = is_term and "CTRL SHIFT" or "CTRL"
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = "V", state = "down" }))
  hl.timer(function()
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = "V", state = "up" }))
  end, { timeout = 45, type = "oneshot" })
end
""".strip()


def ensure_hyprland_submap(murmure_bin: str) -> None:
    env = _hyprctl_env()
    if not env:
        return
    lua = f"""
do
  if not rawget(_G, "__murmure_submap_defined") then
    rawset(_G, "__murmure_submap_defined", true)
    hl.define_submap("murmure-recording", function()
      hl.bind("Escape", hl.dsp.exec_cmd({json.dumps(f"{murmure_bin} cancel")}))
      hl.bind("Return", hl.dsp.exec_cmd({json.dumps(f"{murmure_bin} commit")}))
      hl.bind("KP_Enter", hl.dsp.exec_cmd({json.dumps(f"{murmure_bin} commit")}))
    end)
  end
end
""".strip()
    try:
        subprocess.run(["hyprctl", "-q", "eval", lua], env=env, timeout=1.5, check=False)
    except Exception:
        pass


def set_hyprland_recording_submap(active: bool, murmure_bin: str) -> None:
    env = _hyprctl_env()
    if not env:
        return
    if active:
        ensure_hyprland_submap(murmure_bin)
        cmd = ["hyprctl", "-q", "dispatch", "submap", "murmure-recording"]
    else:
        cmd = ["hyprctl", "-q", "dispatch", "submap", "reset"]
    try:
        subprocess.run(cmd, env=env, timeout=1.5, check=False)
    except Exception:
        pass


def paste_text_wayland(text: str, restore_clipboard: bool = True) -> bool:
    if not text:
        return True
    saved_mime: Optional[str] = None
    saved_bytes: Optional[bytes] = None

    if restore_clipboard:
        try:
            types_res = subprocess.run(["wl-paste", "--list-types"], capture_output=True, text=True, timeout=1.0)
            if types_res.returncode == 0:
                mimes = [m.strip() for m in types_res.stdout.splitlines() if m.strip()]
                preferred = None
                for cand in ("text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "image/png"):
                    if cand in mimes:
                        preferred = cand
                        break
                if preferred is None and mimes:
                    preferred = mimes[0]
                if preferred:
                    raw_res = subprocess.run(
                        ["wl-paste", "--no-newline", "--type", preferred],
                        capture_output=True,
                        timeout=1.0,
                    )
                    if raw_res.returncode == 0 and len(raw_res.stdout) <= 16 * 1024 * 1024:
                        saved_mime = preferred
                        saved_bytes = raw_res.stdout
        except Exception:
            pass

    try:
        subprocess.run(
            ["wl-copy", "--type", "text/plain;charset=utf-8"],
            input=text.encode("utf-8"),
            timeout=1.5,
            check=True,
        )
    except Exception as e:
        log(f"wl-copy failed: {e}")
        return False

    env = _hyprctl_env()
    pasted = False
    if env:
        try:
            res = subprocess.run(["hyprctl", "-q", "eval", PASTE_LUA], env=env, timeout=1.5)
            pasted = res.returncode == 0
        except Exception as e:
            log(f"hyprctl paste failed: {e}")

    if restore_clipboard and pasted:
        def _restore() -> None:
            time.sleep(0.65)
            try:
                cur = subprocess.run(
                    ["wl-paste", "--no-newline", "--type", "text/plain;charset=utf-8"],
                    capture_output=True,
                    timeout=1.0,
                )
                if cur.returncode == 0 and cur.stdout.decode("utf-8", errors="replace") != text:
                    return  # User copied something else in the meantime
                if saved_bytes is not None and saved_mime:
                    subprocess.run(
                        ["wl-copy", "--type", saved_mime],
                        input=saved_bytes,
                        timeout=1.5,
                        check=False,
                    )
                else:
                    subprocess.run(["wl-copy", "--clear"], timeout=1.0, check=False)
            except Exception:
                pass

        threading.Thread(target=_restore, name="murmure-clip-restore", daemon=True).start()

    return pasted


# --------------------------------------------------------------------------
# Evdev Hardware Global Hotkey Monitor


def is_keyboard_sysfs(event_name: str) -> bool:
    cap_path = f"/sys/class/input/{event_name}/device/capabilities/key"
    try:
        with open(cap_path, "r", encoding="utf-8") as f:
            words = [int(w, 16) for w in f.read().strip().split() if w]
    except (OSError, ValueError):
        return False
    if not words:
        return False
    # LSB word is last in sysfs capabilities/key; check standard typing keys (KEY_Q=16..KEY_P=25, KEY_LEFTSHIFT=42, KEY_RIGHTSHIFT=54)
    lsb = words[-1]
    has_alpha = bool(lsb & ((1 << 16) | (1 << 30) | (1 << 42) | (1 << 54)))
    return has_alpha


class EvdevHotkeyMonitor:
    def __init__(
        self,
        settings: SettingsStore,
        on_action: Callable[[str], None],
        on_capture_event: Callable[[Dict[str, Any]], None],
    ) -> None:
        self.settings = settings
        self.on_action = on_action
        self.on_capture_event = on_capture_event
        self.hotkey = HotkeyState(hold_threshold=0.35)
        self.lock = threading.Lock()
        self.capturing = False
        self._capture_peak: Set[str] = set()
        self._key_held = False
        self._held_mods_by_fd: Dict[int, Set[str]] = {}
        self._fds: Dict[int, str] = {}
        self._stop = threading.Event()
        self.accessible_devices = 0
        self.permission_ok = False
        self._thread = threading.Thread(target=self._loop, name="murmure-evdev", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def reset_chord(self) -> None:
        with self.lock:
            self.hotkey.reset()
            self._key_held = False

    def set_capturing(self, enabled: bool) -> None:
        with self.lock:
            self.capturing = enabled
            self._capture_peak.clear()
            self.hotkey.reset()
            self._key_held = False

    def _scan_devices(self, poller: select.poll) -> None:
        existing_paths = set(self._fds.values())
        any_kbd_seen = False
        for sys_path in sorted(glob.glob("/sys/class/input/event*")):
            ev_name = os.path.basename(sys_path)
            if not is_keyboard_sysfs(ev_name):
                continue
            any_kbd_seen = True
            dev_path = f"/dev/input/{ev_name}"
            if dev_path in existing_paths:
                continue
            try:
                fd = os.open(dev_path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
            except OSError:
                continue
            self._fds[fd] = dev_path
            self._held_mods_by_fd[fd] = set()
            poller.register(fd, select.POLLIN | select.POLLERR | select.POLLHUP)
            log(f"monitoring keyboard {dev_path}")
        self.accessible_devices = len(self._fds)
        self.permission_ok = (self.accessible_devices > 0) or (not any_kbd_seen)

    def _held_modifiers(self) -> Set[str]:
        out: Set[str] = set()
        for s in self._held_mods_by_fd.values():
            out |= s
        return out

    def _loop(self) -> None:
        poller = select.poll()
        last_scan = 0.0
        ev_size = INPUT_EVENT_STRUCT.size

        while not self._stop.is_set():
            now = time.monotonic()
            if now - last_scan >= 3.0:
                self._scan_devices(poller)
                last_scan = now

            events = poller.poll(300)
            for fd, mask in events:
                if mask & (select.POLLERR | select.POLLHUP | select.POLLNVAL):
                    poller.unregister(fd)
                    self._fds.pop(fd, None)
                    self._held_mods_by_fd.pop(fd, None)
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    self.accessible_devices = len(self._fds)
                    continue
                try:
                    raw = os.read(fd, ev_size * 32)
                except OSError:
                    continue
                for off in range(0, (len(raw) // ev_size) * ev_size, ev_size):
                    _sec, _usec, ev_type, code, value = INPUT_EVENT_STRUCT.unpack_from(raw, off)
                    if ev_type != EV_KEY:
                        continue
                    self._handle_key_event(fd, code, value)

        for fd in list(self._fds):
            try:
                os.close(fd)
            except OSError:
                pass

    def _handle_key_event(self, fd: int, code: int, value: int) -> None:
        # value: 0 = release, 1 = press, 2 = repeat
        mod_name = KEYCODE_TO_MODIFIER.get(code)
        if mod_name is not None:
            fd_mods = self._held_mods_by_fd.setdefault(fd, set())
            if value == 0:
                fd_mods.discard(mod_name)
            else:
                fd_mods.add(mod_name)

        held = self._held_modifiers()
        with self.lock:
            capturing = self.capturing

        if capturing:
            self._handle_capture(code, value, mod_name, held)
            return

        sc = self.settings.get()["shortcut"]
        sc_mods = set(sc.get("modifiers") or [])
        sc_key = sc.get("keyCode")

        action: Optional[str] = None
        with self.lock:
            if sc_key is None:
                if mod_name is not None and value in (0, 1):
                    action = self.hotkey.update(held == sc_mods, time.monotonic())
            else:
                if value == 1:
                    eff_held = set(held)
                    if "fn" not in sc_mods:
                        eff_held.discard("fn")
                    if code == sc_key and eff_held == sc_mods and not self._key_held:
                        self._key_held = True
                        action = self.hotkey.update(True, time.monotonic())
                elif value == 0 and self._key_held and code == sc_key:
                    self._key_held = False
                    action = self.hotkey.update(False, time.monotonic())

        if action:
            self.on_action(action)

    def _handle_capture(self, code: int, value: int, mod_name: Optional[str], held: Set[str]) -> None:
        if mod_name is not None:
            with self.lock:
                self._capture_peak |= held
                peak = set(self._capture_peak)
                done = len(held) == 0 and len(peak) > 0
                if done:
                    self._capture_peak.clear()
                    self.capturing = False
            preview_sc = {
                "modifiers": [m for m in MODIFIER_ORDER if m in (peak | held)],
                "keyCode": None,
                "keyLabel": None,
            }
            if done:
                saved = self.settings.update({"shortcut": preview_sc})
                self.on_capture_event({"event": "shortcut_captured", "shortcut": saved["shortcut"], "label": saved["shortcutLabel"]})
            else:
                self.on_capture_event({"event": "shortcut_preview", "label": format_shortcut_label(preview_sc)})
            return

        if value != 1:
            return
        if code == KEY_ESC and not held:
            with self.lock:
                self._capture_peak.clear()
                self.capturing = False
            self.on_capture_event({"event": "shortcut_cancelled"})
            return

        eff_mods = set(held)
        if code in FUNCTION_KEYCODES or code in ARROW_KEYCODES:
            eff_mods.discard("fn")
        label = EVDEV_KEY_LABELS.get(code, f"Key{code}")
        cand = {
            "modifiers": [m for m in MODIFIER_ORDER if m in eff_mods],
            "keyCode": code,
            "keyLabel": label,
        }
        if is_valid_shortcut(cand):
            with self.lock:
                self._capture_peak.clear()
                self.capturing = False
            saved = self.settings.update({"shortcut": cand})
            self.on_capture_event({"event": "shortcut_captured", "shortcut": saved["shortcut"], "label": saved["shortcutLabel"]})


# --------------------------------------------------------------------------
# Dictation Session Controller + Pub/Sub IPC Server


class DictationDaemon:
    MAX_SESSION_SECS = 15 * 60.0

    def __init__(self, murmure_bin: str) -> None:
        self.murmure_bin = murmure_bin
        self.settings = SettingsStore()
        self.client = VoiceSocketClient()
        self.recorder = PipeWireRecorder(on_samples=self._on_samples)
        self.evdev = EvdevHotkeyMonitor(
            settings=self.settings,
            on_action=self._on_hotkey_action,
            on_capture_event=self._broadcast,
        )

        self.lock = threading.RLock()
        self.state = "idle"  # idle | recording | transcribing
        self.phase = "idle"  # idle | recording | transcribing | message
        self.message = ""
        self.levels: List[float] = [0.0] * BARS
        self._last_meter = 0.0
        self.live_preview = ""
        self.session_id = 0
        self.language = self.settings.get()["language"]
        self.chunker = Chunker()
        self.chunk_start = 0
        self.fed_up_to = 0
        self.chunk_texts: Dict[int, str] = {}
        self.chunk_count = 0
        self.streamed_up_to = 0
        self.chunk_error: Optional[w.WorkerError] = None
        self.started_at = 0.0
        self._release_timer: Optional[threading.Timer] = None
        self._flash_timer: Optional[threading.Timer] = None

        self._voice_queue: "collections.deque[Callable[[], None]]" = collections.deque()
        self._voice_cv = threading.Condition()
        self._subscribers_lock = threading.Lock()
        self._subscribers: Set[socket.socket] = set()
        self._stop = threading.Event()

        threading.Thread(target=self._voice_worker_loop, name="murmure-voice-q", daemon=True).start()
        threading.Thread(target=self._meter_tick_loop, name="murmure-meter", daemon=True).start()

    def _enqueue_voice(self, fn: Callable[[], None]) -> None:
        with self._voice_cv:
            self._voice_queue.append(fn)
            self._voice_cv.notify()

    def _voice_worker_loop(self) -> None:
        while not self._stop.is_set():
            with self._voice_cv:
                while not self._voice_queue and not self._stop.is_set():
                    self._voice_cv.wait(timeout=1.0)
                if not self._voice_queue:
                    continue
                fn = self._voice_queue.popleft()
            try:
                fn()
            except Exception as e:
                log(f"voice task error: {e}")

    def snapshot(self) -> Dict[str, Any]:
        cfg = self.settings.get()
        with self.lock:
            return {
                "event": "state",
                "state": self.state,
                "phase": self.phase,
                "message": self.message,
                "visible": self.phase != "idle",
                "language": self.language if self.state != "idle" else cfg["language"],
                "livePreview": self.live_preview,
                "levels": [round(x, 3) for x in self.levels],
                "shortcutLabel": cfg["shortcutLabel"],
                "shortcut": cfg["shortcut"],
                "evdevReady": self.evdev.permission_ok,
                "evdevDevices": self.evdev.accessible_devices,
                "modelReady": w.model_present(w.resolve_model_dir()),
                "modelDir": w.resolve_model_dir(),
                "vocabularyPath": os.path.join(vp.voice_home(), "vocabulary.txt"),
                "languages": vp.LANGUAGES,
                "settings": cfg,
            }

    def _broadcast(self, payload: Dict[str, Any]) -> None:
        raw = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
        dead: List[socket.socket] = []
        with self._subscribers_lock:
            subs = list(self._subscribers)
        for s in subs:
            try:
                s.sendall(raw)
            except OSError:
                dead.append(s)
        if dead:
            with self._subscribers_lock:
                for s in dead:
                    self._subscribers.discard(s)
                    try:
                        s.close()
                    except OSError:
                        pass

    def _broadcast_state(self) -> None:
        self._broadcast(self.snapshot())

    def _meter_tick_loop(self) -> None:
        while not self._stop.is_set():
            time.sleep(0.04)
            with self.lock:
                if self.state != "recording":
                    continue
                env = self.recorder.drain_levels()
                if env:
                    self._last_meter = max(env)
                else:
                    self._last_meter *= 0.8
                val = math.pow(max(0.0, min(1.0, self._last_meter)), 0.8)
                self.levels.pop(0)
                self.levels.append(val)
                msg = {
                    "event": "levels",
                    "levels": [round(x, 3) for x in self.levels],
                    "livePreview": self.live_preview,
                }
            self._broadcast(msg)

    def _on_hotkey_action(self, action: str) -> None:
        if action == "start":
            self.start_session()
        elif action == "commit":
            self.commit_session()
        elif action == "releaseCommit":
            self.commit_after_release_tail()

    def start_session(self) -> None:
        with self.lock:
            if self._release_timer is not None:
                self._release_timer.cancel()
                self._release_timer = None
                return
            if self.state != "idle":
                return
            if self._flash_timer is not None:
                self._flash_timer.cancel()
                self._flash_timer = None

            cfg = self.settings.get()
            self.session_id += 1
            self.language = cfg["language"]
            self.chunker = Chunker()
            self.chunk_start = 0
            self.fed_up_to = 0
            self.chunk_texts = {}
            self.chunk_count = 0
            self.streamed_up_to = 0
            self.chunk_error = None
            self.started_at = time.monotonic()
            self.levels = [0.0] * BARS
            self._last_meter = 0.0
            self.live_preview = ""

            try:
                self.recorder.start(cfg["prebufferSecs"])
            except Exception as e:
                self.evdev.reset_chord()
                self._flash_locked(str(e))
                return

            self.state = "recording"
            self.phase = "recording"
            self.message = ""

        set_hyprland_recording_submap(True, self.murmure_bin)
        self._broadcast_state()
        self._enqueue_voice(lambda: self._safe_prewarm())

    def _safe_prewarm(self) -> None:
        try:
            self.client.load()
        except Exception as e:
            log(f"prewarm failed: {e}")

    def toggle_session(self) -> None:
        with self.lock:
            st = self.state
        if st == "idle":
            self.start_session()
        elif st == "recording":
            self.evdev.reset_chord()
            self.commit_session()

    def cancel_session(self) -> None:
        with self.lock:
            if self._release_timer is not None:
                self._release_timer.cancel()
                self._release_timer = None
            if self.state == "idle" and self.phase == "idle":
                return
            was_rec = self.state == "recording"
            cfg = self.settings.get()
            self.session_id += 1
            self.live_preview = ""
            self.state = "idle"
            self.phase = "idle"
            self.message = ""
        self.evdev.reset_chord()
        if was_rec:
            self.recorder.stop(cfg["keepWarmMinutes"])
        set_hyprland_recording_submap(False, self.murmure_bin)
        self._broadcast_state()

    def commit_after_release_tail(self) -> None:
        with self.lock:
            if self.state != "recording":
                return
            if self._release_timer is not None:
                self._release_timer.cancel()
                self._release_timer = None
            tail_secs = max(0.0, self.settings.get()["releaseTailMs"] / 1000.0)
            if tail_secs <= 0:
                do_now = True
            else:
                do_now = False
                sid = self.session_id

                def _fire() -> None:
                    with self.lock:
                        if self.session_id != sid or self.state != "recording":
                            return
                        self._release_timer = None
                    self.commit_session()

                t = threading.Timer(tail_secs, _fire)
                t.daemon = True
                self._release_timer = t
                t.start()
        if do_now:
            self.commit_session()

    def commit_session(self) -> None:
        with self.lock:
            if self._release_timer is not None:
                self._release_timer.cancel()
                self._release_timer = None
            if self.state != "recording":
                return
            cfg = self.settings.get()
            self.state = "transcribing"
            self.phase = "transcribing"
            chunk_start = self.chunk_start
        self.evdev.reset_chord()
        set_hyprland_recording_submap(False, self.murmure_bin)
        all_samples = self.recorder.stop(cfg["keepWarmMinutes"])
        tail = all_samples[min(chunk_start, len(all_samples)) :]
        self._broadcast_state()
        self._submit_chunk(tail, final=True)

    def set_language(self, lang: str) -> Dict[str, Any]:
        saved = self.settings.update({"language": lang})
        with self.lock:
            if self.state != "idle":
                self.language = saved["language"]
        self._broadcast_state()
        return saved

    def _on_samples(self) -> None:
        to_submit: Optional[List[float]] = None
        auto_action: Optional[str] = None

        with self.lock:
            if self.state != "recording":
                return
            if (time.monotonic() - self.started_at) > self.MAX_SESSION_SECS:
                auto_action = "commit"
            else:
                end = self.recorder.count
                fresh = self.recorder.slice(self.fed_up_to, end)
                self.fed_up_to = end
                cut = self.chunker.feed(fresh)
                cfg = self.settings.get()
                if self._release_timer is None and self.chunker.should_auto_stop(
                    no_speech_secs=cfg["autoStopNoSpeechSecs"],
                    silence_after_speech_secs=cfg["autoStopSilenceSecs"],
                ):
                    auto_action = "commit" if self.chunker.has_spoken else "cancel"
                elif cfg["liveChunks"] and cut is not None and cut > self.chunk_start:
                    to_submit = self.recorder.slice(self.chunk_start, cut)
                    self.chunk_start = cut

        if auto_action == "commit":
            self.commit_session()
        elif auto_action == "cancel":
            self.cancel_session()
        elif to_submit is not None:
            self._submit_chunk(to_submit, final=False)

    def _submit_chunk(self, samples: List[float], final: bool) -> None:
        with self.lock:
            idx = self.chunk_count
            self.chunk_count += 1
            sid = self.session_id
            lang = self.language
            prev_ctx = self.chunk_texts.get(idx - 1) if idx > 0 else None
        vocab = vp.load_vocabulary()

        def _job() -> None:
            text = ""
            failure: Optional[w.WorkerError] = None
            if len(samples) >= SAMPLE_RATE // 5:
                try:
                    res = self.client.transcribe(
                        wav_bytes=encode_wav_16k(samples),
                        language=lang,
                        context=prev_ctx,
                        vocabulary=vocab,
                    )
                    text = str(res.get("text") or "")
                    log(f"chunk {idx} {res.get('duration_secs', 0):.2f}s infer={res.get('infer_secs', 0):.2f}s")
                except w.WorkerError as e:
                    failure = e
                except Exception as e:
                    failure = w.WorkerError("internal", str(e))

            to_paste_inline: List[str] = []
            cfg = self.settings.get()
            with self.lock:
                if self.session_id != sid:
                    return
                self.chunk_texts[idx] = text
                if failure is not None:
                    self.chunk_error = failure
                completed = [self.chunk_texts[i] for i in range(self.chunk_count) if i in self.chunk_texts]
                self.live_preview = vp.join_and_process(
                    completed,
                    language=self.language,
                    vocabulary=vocab,
                    remove_disfluencies=cfg["removeDisfluencies"],
                    voice_commands=cfg["voiceCommands"],
                    convert_numbers=cfg["convertNumbers"],
                )
                if cfg["streamInline"] and self.state == "recording":
                    joiner = vp.language_joiner(self.language)
                    while self.streamed_up_to in self.chunk_texts:
                        raw_c = self.chunk_texts[self.streamed_up_to]
                        proc_c = vp.postprocess_transcript(
                            raw_c,
                            language=self.language,
                            vocabulary=vocab,
                            remove_disfluencies=cfg["removeDisfluencies"],
                            voice_commands=cfg["voiceCommands"],
                            convert_numbers=cfg["convertNumbers"],
                        )
                        if proc_c:
                            prefix = joiner if self.streamed_up_to > 0 else ""
                            to_paste_inline.append(prefix + proc_c)
                        self.streamed_up_to += 1
                should_finish = final or self.state == "transcribing"

            self._broadcast_state()
            for piece in to_paste_inline:
                paste_text_wayland(piece, restore_clipboard=cfg["restoreClipboard"])
            if should_finish:
                self._finish_if_done()

        self._enqueue_voice(_job)

    def _finish_if_done(self) -> None:
        cfg = self.settings.get()
        vocab = vp.load_vocabulary()
        final_text = ""
        err: Optional[w.WorkerError] = None
        with self.lock:
            if self.state != "transcribing" or len(self.chunk_texts) < self.chunk_count:
                return
            rem_indices = (
                range(self.streamed_up_to, self.chunk_count)
                if cfg["streamInline"]
                else range(0, self.chunk_count)
            )
            raw_chunks = [self.chunk_texts[i] for i in rem_indices if i in self.chunk_texts]
            final_text = vp.join_and_process(
                raw_chunks,
                language=self.language,
                vocabulary=vocab,
                remove_disfluencies=cfg["removeDisfluencies"],
                voice_commands=cfg["voiceCommands"],
                convert_numbers=cfg["convertNumbers"],
            )
            self.session_id += 1
            self.live_preview = ""
            err = self.chunk_error
            streamed = self.streamed_up_to
            lang = self.language
            if err is not None and not final_text and streamed == 0:
                self.state = "idle"
                msg = "voiced not reachable" if err.code == "daemon_missing" else err.message
                self._flash_locked(msg)
                return
            self.state = "idle"
            self.phase = "idle"
            self.message = ""

        self._broadcast_state()
        if final_text:
            prefix = vp.language_joiner(lang) if (cfg["streamInline"] and streamed > 0) else ""
            ok = paste_text_wayland(prefix + final_text, restore_clipboard=cfg["restoreClipboard"])
            if not ok:
                with self.lock:
                    self._flash_locked("Copied to clipboard")

    def _flash_locked(self, message: str) -> None:
        log(f"status message: {message}")
        self.phase = "message"
        self.message = message
        sid = self.session_id
        if self._flash_timer is not None:
            self._flash_timer.cancel()

        def _clear() -> None:
            with self.lock:
                if self.state == "idle" and self.session_id == sid:
                    self.phase = "idle"
                    self.message = ""
            self._broadcast_state()

        t = threading.Timer(2.6, _clear)
        t.daemon = True
        self._flash_timer = t
        t.start()
        threading.Thread(target=self._broadcast_state, daemon=True).start()

    # ------------------------------------------------------------------
    # Control Socket Server

    def _handle_client(self, conn: socket.socket) -> None:
        rfile = conn.makefile("rb")
        keep_open = False
        try:
            while True:
                line = rfile.readline(65536)
                if not line:
                    break
                try:
                    req = json.loads(line.decode("utf-8"))
                except ValueError:
                    continue
                op = req.get("op")
                if op == "watch":
                    keep_open = True
                    with self._subscribers_lock:
                        self._subscribers.add(conn)
                    conn.sendall((json.dumps(self.snapshot(), ensure_ascii=False) + "\n").encode("utf-8"))
                    # Block until peer disconnects
                    while not self._stop.is_set():
                        if not conn.recv(1024):
                            break
                    break
                if op == "toggle":
                    self.toggle_session()
                    resp = {"ok": True, **self.snapshot()}
                elif op == "start":
                    self.start_session()
                    resp = {"ok": True, **self.snapshot()}
                elif op == "commit":
                    self.commit_session()
                    resp = {"ok": True, **self.snapshot()}
                elif op == "cancel":
                    self.cancel_session()
                    resp = {"ok": True, **self.snapshot()}
                elif op == "status":
                    resp = {"ok": True, **self.snapshot()}
                elif op == "set_language":
                    saved = self.set_language(str(req.get("language") or "en"))
                    resp = {"ok": True, "settings": saved}
                elif op == "update_settings":
                    saved = self.settings.update(req.get("settings") or {})
                    self._broadcast_state()
                    resp = {"ok": True, "settings": saved}
                elif op == "capture_shortcut":
                    self.evdev.set_capturing(bool(req.get("enable", True)))
                    resp = {"ok": True}
                else:
                    resp = {"ok": False, "error": f"unknown op {op!r}"}
                conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
        except OSError:
            pass
        finally:
            if keep_open:
                with self._subscribers_lock:
                    self._subscribers.discard(conn)
            try:
                rfile.close()
            except OSError:
                pass
            try:
                conn.close()
            except OSError:
                pass

    def serve(self) -> int:
        sock_path = control_socket_path()
        os.makedirs(os.path.dirname(sock_path), mode=0o700, exist_ok=True)
        os.makedirs(vp.voice_home(), mode=0o700, exist_ok=True)
        vocab_file = os.path.join(vp.voice_home(), "vocabulary.txt")
        if not os.path.exists(vocab_file):
            try:
                with open(vocab_file, "w", encoding="utf-8") as vf:
                    vf.write("# One proper noun or technical term per line (e.g. Murmure, Omarchnix, PostgreSQL)\n")
            except OSError:
                pass

        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(sock_path)
            probe.close()
            log(f"murmured already running at {sock_path}")
            return 0
        except OSError:
            probe.close()
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass

        old_umask = os.umask(0o177)
        try:
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(sock_path)
        finally:
            os.umask(old_umask)
        srv.listen(16)
        srv.settimeout(1.0)

        ensure_hyprland_submap(self.murmure_bin)
        atexit.register(lambda: set_hyprland_recording_submap(False, self.murmure_bin))
        self.evdev.start()
        log(f"ready sock={sock_path} shortcut={self.settings.get()['shortcutLabel']!r}")

        try:
            while not self._stop.is_set():
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                threading.Thread(target=self._handle_client, args=(conn,), name="murmure-ipc", daemon=True).start()
        finally:
            self._stop.set()
            self.evdev.stop()
            self.recorder.shutdown()
            set_hyprland_recording_submap(False, self.murmure_bin)
            try:
                srv.close()
            except OSError:
                pass
            try:
                os.unlink(sock_path)
            except FileNotFoundError:
                pass
        return 0


def main() -> int:
    murmure_bin = os.environ.get("MURMURE_CLI_BIN") or "murmure"
    daemon = DictationDaemon(murmure_bin=murmure_bin)
    signal.signal(signal.SIGTERM, lambda *_: daemon._stop.set())
    signal.signal(signal.SIGINT, lambda *_: daemon._stop.set())
    return daemon.serve()


if __name__ == "__main__":
    sys.exit(main())
