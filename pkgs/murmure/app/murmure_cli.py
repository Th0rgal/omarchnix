#!/usr/bin/env python3
"""murmure: CLI & controller for Murmure on NixOS / Linux."""

from __future__ import annotations

import ctypes
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from typing import Any, Dict, Optional

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
VOICED_DIR = os.path.abspath(os.path.join(THIS_DIR, "..", "voiced"))
for p in (THIS_DIR, VOICED_DIR):
    if p not in sys.path:
        sys.path.insert(0, p)

import murmured as md  # noqa: E402
import pipeline as vp  # noqa: E402
import worker as w  # noqa: E402

GGUF_URL = (
    f"https://huggingface.co/{w.MODEL_REPO}/resolve/{w.MODEL_REVISION}/cohere-transcribe-q4_k.gguf"
)


def connect_daemon(autostart: bool = True) -> Optional[socket.socket]:
    sock_path = md.control_socket_path()
    for attempt in range(2):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.settimeout(2.0)
            s.connect(sock_path)
            s.settimeout(None)
            return s
        except OSError:
            s.close()
            if not autostart or attempt > 0:
                return None
            # Try systemd user service first, else background spawn
            subprocess.run(
                ["systemctl", "--user", "start", "murmure.service"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            deadline = time.monotonic() + 1.2
            while time.monotonic() < deadline:
                probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    probe.settimeout(0.2)
                    probe.connect(sock_path)
                    probe.settimeout(None)
                    return probe
                except OSError:
                    probe.close()
                    time.sleep(0.05)
            log_dir = os.path.join(vp.voice_home(), "logs")
            os.makedirs(log_dir, mode=0o700, exist_ok=True)
            with open(os.path.join(log_dir, "murmured.log"), "ab", buffering=0) as lf:
                subprocess.Popen(
                    [sys.executable, os.path.join(THIS_DIR, "murmured.py")],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=lf,
                    start_new_session=True,
                )
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline:
                probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    probe.settimeout(0.2)
                    probe.connect(sock_path)
                    probe.settimeout(None)
                    return probe
                except OSError:
                    probe.close()
                    time.sleep(0.05)
    return None


def rpc(req: Dict[str, Any], autostart: bool = True) -> Dict[str, Any]:
    s = connect_daemon(autostart=autostart)
    if s is None:
        return {"ok": False, "error": "murmured is not running"}
    try:
        s.sendall((json.dumps(req) + "\n").encode("utf-8"))
        rfile = s.makefile("rb")
        line = rfile.readline(65536)
        return json.loads(line.decode("utf-8")) if line else {"ok": False, "error": "empty reply"}
    finally:
        try:
            s.close()
        except OSError:
            pass


def _bind_parent_death_signal() -> bool:
    """Ensure `murmure watch` exits automatically when Quickshell terminates."""
    if sys.platform != "linux":
        return True
    try:
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        libc.prctl(1, signal.SIGTERM, 0, 0, 0)  # PR_SET_PDEATHSIG = 1
    except Exception:
        pass
    return os.getppid() != 1


def watch_loop() -> int:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if not _bind_parent_death_signal():
        return 0
    while True:
        s = connect_daemon(autostart=True)
        if s is None:
            print(json.dumps({"event": "state", "state": "idle", "phase": "idle", "visible": False}), flush=True)
            time.sleep(2.0)
            continue
        try:
            s.sendall(b'{"op":"watch"}\n')
            rfile = s.makefile("rb")
            while True:
                line = rfile.readline(65536)
                if not line:
                    break
                sys.stdout.write(line.decode("utf-8", errors="replace"))
                sys.stdout.flush()
        except (OSError, KeyboardInterrupt):
            return 0
        finally:
            try:
                s.close()
            except OSError:
                pass
        time.sleep(1.0)


def download_model() -> int:
    hub = os.environ.get("HF_HUB_CACHE") or os.path.join(
        os.environ.get("HF_HOME") or os.path.expanduser("~/.cache/huggingface"),
        "hub",
    )
    repo_dir = os.path.join(hub, "models--" + w.MODEL_REPO.replace("/", "--"))
    snap_dir = os.path.join(repo_dir, "snapshots", w.MODEL_REVISION)
    refs_dir = os.path.join(repo_dir, "refs")
    os.makedirs(snap_dir, exist_ok=True)
    os.makedirs(refs_dir, exist_ok=True)
    with open(os.path.join(refs_dir, "main"), "w", encoding="utf-8") as rf:
        rf.write(w.MODEL_REVISION)
    dest = os.path.join(snap_dir, "cohere-transcribe-q4_k.gguf")
    if os.path.isfile(dest) and os.path.getsize(dest) > 1_000_000_000:
        print(f"Model already present at {dest} ({os.path.getsize(dest) / (1024**3):.2f} GiB)")
        return 0
    tmp = f"{dest}.part"
    print(f"Downloading {GGUF_URL} -> {dest} ...")
    req = urllib.request.Request(GGUF_URL, headers={"User-Agent": "murmure-nixos/1.0"})
    with urllib.request.urlopen(req) as resp, open(tmp, "wb") as out:
        total = int(resp.headers.get("Content-Length") or 0)
        done = 0
        last_pct = -1
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
            done += len(chunk)
            if total > 0:
                pct = int(done * 100 / total)
                if pct >= last_pct + 5:
                    last_pct = pct
                    print(f"  {pct}% ({done / (1024**2):.0f} / {total / (1024**2):.0f} MiB)", flush=True)
    os.replace(tmp, dest)
    print(f"Ready: {dest}")
    return 0


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "toggle"
    if cmd in ("toggle", "start", "commit", "cancel", "status"):
        res = rpc({"op": cmd})
        if cmd == "status":
            print(json.dumps(res, indent=2, ensure_ascii=False))
        return 0 if res.get("ok") else 1
    if cmd == "stop":
        res = rpc({"op": "commit"})
        return 0 if res.get("ok") else 1
    if cmd == "watch":
        return watch_loop()
    if cmd == "language":
        if len(sys.argv) < 3:
            st = md.SettingsStore().get()
            print(st["language"])
            return 0
        code = sys.argv[2].strip().lower()
        if code not in vp.LANGUAGE_BY_CODE:
            sys.stderr.write(f"Unsupported language {code!r}. Supported: {', '.join(vp.LANGUAGE_BY_CODE)}\n")
            return 1
        res = rpc({"op": "set_language", "language": code})
        if not res.get("ok"):
            md.SettingsStore().update({"language": code})
        return 0
    if cmd == "settings":
        settings_bin = os.environ.get("MURMURE_SETTINGS_BIN") or os.path.join(THIS_DIR, "murmure_settings.py")
        os.execvp(settings_bin if os.access(settings_bin, os.X_OK) else sys.executable,
                  [settings_bin] if os.access(settings_bin, os.X_OK) else [sys.executable, settings_bin])
    if cmd == "download-model":
        return download_model()
    if cmd == "learn":
        learn_py = os.path.join(VOICED_DIR, "learn.py")
        os.execvp(sys.executable, [sys.executable, learn_py, *sys.argv[2:]])
    if cmd == "daemon":
        return md.main()

    sys.stderr.write(
        "Usage: murmure [toggle|start|commit|cancel|status|watch|language <code>|settings|download-model|learn|daemon]\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
