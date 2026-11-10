#!/usr/bin/env python3
"""orb-voice-bridge: Protocol v1 stdio-to-voiced.sock bridge for Orb Desktop.

`orb-locald` speaks Protocol v1 over stdio to a child worker process and cancels
an in-flight transcription by killing that child (`voice_cancel`). By pointing
`ORB_VOICE_WORKER` at this tiny bridge:
1. Orb Desktop and Murmure share ONE resident Cohere Transcribe model inside
   `voiced` over `~/.local/share/md.thomas.voice/voiced.sock` instead of loading
   two 1.2 GiB models.
2. When `orb-locald` kills `orb-voice-bridge` on `voice_cancel`, ONLY this
   bridge exits and closes its Unix socket connection — `voiced` stays alive
   and keeps the model warm for Murmure and subsequent Orb requests!
3. When `ORB_VOICE_FAKE=1` or `ORB_VOICE_SOCKET=off`, transparently falls back
   to an in-process `worker.Worker` so offline unit tests work unchanged.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import time
from typing import Any, BinaryIO, Dict, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import voiced as vd  # noqa: E402
import worker as w  # noqa: E402


def resolve_socket_path() -> Optional[str]:
    raw = os.environ.get("ORB_VOICE_SOCKET") or os.environ.get("VOICED_SOCKET")
    if raw and raw.lower() in ("off", "none", "0", "false"):
        return None
    if os.environ.get("ORB_VOICE_FAKE") == "1" and not raw:
        return None
    return raw or vd.socket_path()


def connect_or_spawn_voiced(sock_path: str) -> Optional[socket.socket]:
    for attempt in range(2):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.settimeout(2.0)
            s.connect(sock_path)
            s.settimeout(None)
            return s
        except OSError:
            s.close()
            if attempt == 0:
                voiced_py = os.path.join(os.path.dirname(os.path.abspath(__file__)), "voiced.py")
                log_dir = os.path.join(vd.voice_home(), "logs")
                os.makedirs(log_dir, mode=0o700, exist_ok=True)
                log_path = os.path.join(log_dir, "voiced.log")
                try:
                    with open(log_path, "ab", buffering=0) as lf:
                        subprocess.Popen(
                            [sys.executable, voiced_py],
                            stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL,
                            stderr=lf,
                            start_new_session=True,
                        )
                except OSError:
                    return None
                deadline = time.monotonic() + 3.0
                while time.monotonic() < deadline:
                    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    try:
                        probe.settimeout(0.25)
                        probe.connect(sock_path)
                        probe.settimeout(None)
                        return probe
                    except OSError:
                        probe.close()
                        time.sleep(0.05)
    return None


def proxy_stdio_to_socket(stdin: BinaryIO, stdout: BinaryIO, sock_path: str) -> int:
    conn: Optional[socket.socket] = None
    rfile: Optional[BinaryIO] = None
    wfile: Optional[BinaryIO] = None

    def close_conn() -> None:
        nonlocal conn, rfile, wfile
        for f in (rfile, wfile):
            if f is not None:
                try:
                    f.close()
                except OSError:
                    pass
        if conn is not None:
            try:
                conn.close()
            except OSError:
                pass
        conn = None
        rfile = None
        wfile = None

    def ensure_conn() -> Tuple[BinaryIO, BinaryIO]:
        nonlocal conn, rfile, wfile
        if conn is not None and rfile is not None and wfile is not None:
            return rfile, wfile
        sock = connect_or_spawn_voiced(sock_path)
        if sock is None:
            raise w.WorkerError("daemon_missing", f"voiced is not reachable at {sock_path}")
        conn = sock
        rfile = sock.makefile("rb")
        wfile = sock.makefile("wb")
        return rfile, wfile

    try:
        while True:
            req_id: Any = None
            try:
                frame = w.read_request(stdin)
                if frame is None:
                    return 0
                req, payload = frame
                if not req:
                    continue
                req_id = req.get("id")
                op = req.get("op")
                if op == "shutdown":
                    w.write_response(stdout, {"id": req_id, "ok": True, "result": {"bye": True}})
                    return 0

                raw_line = (json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8")
                last_err: Optional[Exception] = None
                resp_obj: Optional[Dict[str, Any]] = None
                for _ in range(2):
                    try:
                        rf, wf = ensure_conn()
                        wf.write(raw_line)
                        if payload:
                            wf.write(payload)
                        wf.flush()
                        resp_line = rf.readline(w.MAX_HEADER_BYTES + 1)
                        if not resp_line:
                            raise ConnectionResetError("voiced closed connection")
                        resp_obj = json.loads(resp_line.decode("utf-8"))
                        break
                    except (BrokenPipeError, ConnectionResetError, OSError, ValueError) as e:
                        last_err = e
                        close_conn()
                if resp_obj is None:
                    raise w.WorkerError("internal", f"voiced socket call failed: {last_err}")
                w.write_response(stdout, resp_obj)
            except w.ProtocolError as e:
                rid = e.req_id if e.req_id is not None else req_id
                w.write_response(stdout, {"id": rid, "ok": False, "error": {"code": e.code, "message": e.message}})
                return 2
            except w.WorkerError as e:
                rid = e.req_id if e.req_id is not None else req_id
                w.write_response(stdout, {"id": rid, "ok": False, "error": {"code": e.code, "message": e.message}})
            except Exception as e:
                w.write_response(
                    stdout,
                    {"id": req_id, "ok": False, "error": {"code": "internal", "message": f"{type(e).__name__}: {e}"}},
                )
    finally:
        close_conn()


def main() -> int:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    except (AttributeError, ValueError):
        pass
    sock_path = resolve_socket_path()
    if not sock_path:
        return w.serve(sys.stdin.buffer, sys.stdout.buffer)
    return proxy_stdio_to_socket(sys.stdin.buffer, sys.stdout.buffer, sock_path)


if __name__ == "__main__":
    sys.exit(main())
