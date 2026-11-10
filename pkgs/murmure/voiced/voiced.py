#!/usr/bin/env python3
"""voiced: one Cohere Transcribe model per machine, shared by every client.

Serves Protocol v1 over a Unix domain socket (`~/.local/share/md.thomas.voice/voiced.sock`
on Linux, `~/Library/Application Support/md.thomas.voice/voiced.sock` on macOS) so
Murmure, Orb Desktop, and CLI tools share one resident model:

    Murmure ─┐
    Orb ─────┼── ~/.local/share/md.thomas.voice/voiced.sock ──▶ voiced
    CLI ─────┘                  (0600, owner only)             one resident model

Supports:
- systemd socket activation (`LISTEN_FDS` / `LISTEN_PID` on fd 3) on Linux
- launchd socket activation (`launch_activate_socket`) on macOS
- standalone socket binding when started manually or by `orb-voice-bridge`
"""

from __future__ import annotations

import ctypes
import os
import queue
import signal
import socket
import sys
import threading
import time
from typing import Any, Dict, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pipeline as vp  # noqa: E402
import worker as w  # noqa: E402


def env_secs(name: str, default: float) -> float:
    try:
        v = float(os.environ.get(name, default))
        return v if v > 0 else default
    except ValueError:
        return default


def voice_home() -> str:
    return vp.voice_home()


def socket_path() -> str:
    return os.environ.get("VOICED_SOCKET") or os.path.join(voice_home(), "voiced.sock")


def log(msg: str) -> None:
    sys.stderr.write(f"[voiced] {time.strftime('%H:%M:%S')} {msg}\n")
    sys.stderr.flush()


class Job:
    __slots__ = ("req", "payload", "done", "response")

    def __init__(self, req: Dict[str, Any], payload: bytes) -> None:
        self.req = req
        self.payload = payload
        self.done = threading.Event()
        self.response: Dict[str, Any] = {}


class Engine:
    """Owns the single backend; runs every op on one dedicated inference thread."""

    def __init__(self, backend=None, unload_after: float = 600.0) -> None:
        self.worker = w.Worker(backend)
        self.jobs: "queue.Queue[Optional[Job]]" = queue.Queue()
        self.unload_after = unload_after
        self.last_used = time.monotonic()
        self.clients = 0
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self._run, name="voiced-inference", daemon=True)
        self.thread.start()

    def submit(self, req: Dict[str, Any], payload: bytes) -> Dict[str, Any]:
        job = Job(req, payload)
        self.jobs.put(job)
        job.done.wait()
        return job.response

    def stop(self) -> None:
        self.jobs.put(None)
        self.thread.join(timeout=3.0)

    def idle_for(self) -> float:
        return time.monotonic() - self.last_used

    def _run(self) -> None:
        while True:
            try:
                job = self.jobs.get(timeout=2.0)
            except queue.Empty:
                if self.worker.backend.loaded and self.idle_for() >= self.unload_after:
                    log(f"idle {self.idle_for():.0f}s: unloading model")
                    self.worker.backend.unload()
                continue
            if job is None:
                try:
                    self.worker.backend.unload()
                except Exception:
                    pass
                return
            self.last_used = time.monotonic()
            job.response = self._handle(job.req, job.payload)
            self.last_used = time.monotonic()
            job.done.set()

    def _handle(self, req: Dict[str, Any], payload: bytes) -> Dict[str, Any]:
        rid = req.get("id")
        op = req.get("op")
        try:
            if op == "shutdown":
                result: Dict[str, Any] = {"bye": True}
            elif op == "unload":
                result = {"loaded": self.worker.backend.loaded, "shared": True}
            else:
                result = self.worker.handle(req, payload)
                if op == "hello":
                    with self.lock:
                        result.update(
                            {
                                "shared": True,
                                "daemon": "voiced",
                                "clients": self.clients,
                                "pid": os.getpid(),
                                "loaded": self.worker.backend.loaded,
                            }
                        )
            return {"id": rid, "ok": True, "result": result}
        except w.WorkerError as e:
            return {"id": rid, "ok": False, "error": {"code": e.code, "message": e.message}}
        except MemoryError:
            self.worker.backend.unload()
            return {"id": rid, "ok": False, "error": {"code": "internal", "message": "out of memory"}}
        except Exception as e:
            log(f"unhandled error: {type(e).__name__}: {e}")
            return {"id": rid, "ok": False, "error": {"code": "internal", "message": f"{type(e).__name__}: {e}"}}


def serve_connection(engine: Engine, conn: socket.socket) -> None:
    with engine.lock:
        engine.clients += 1
    rfile = conn.makefile("rb")
    wfile = conn.makefile("wb")
    try:
        while True:
            try:
                frame = w.read_request(rfile)
            except w.ProtocolError as e:
                w.write_response(wfile, {"id": e.req_id, "ok": False, "error": {"code": e.code, "message": e.message}})
                return
            except w.WorkerError as e:
                w.write_response(wfile, {"id": e.req_id, "ok": False, "error": {"code": e.code, "message": e.message}})
                continue
            if frame is None:
                return
            req, payload = frame
            if not req:
                continue
            response = engine.submit(req, payload)
            try:
                w.write_response(wfile, response)
            except (BrokenPipeError, ConnectionResetError):
                return
            if req.get("op") == "shutdown":
                return
    except (BrokenPipeError, ConnectionResetError, OSError):
        return
    finally:
        with engine.lock:
            engine.clients -= 1
        for f in (rfile, wfile):
            try:
                f.close()
            except OSError:
                pass
        conn.close()


def systemd_socket() -> Optional[socket.socket]:
    """The listener systemd created for us (`voiced.socket`), when socket-activated."""
    if os.environ.get("VOICED_NO_SYSTEMD") == "1":
        return None
    try:
        listen_pid = int(os.environ.get("LISTEN_PID", "0"))
        listen_fds = int(os.environ.get("LISTEN_FDS", "0"))
    except ValueError:
        return None
    if listen_pid != os.getpid() or listen_fds < 1:
        return None
    os.environ.pop("LISTEN_PID", None)
    os.environ.pop("LISTEN_FDS", None)
    os.environ.pop("LISTEN_FDNAMES", None)
    return socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, fileno=3)


def launchd_socket() -> Optional[socket.socket]:
    if os.environ.get("VOICED_NO_LAUNCHD") == "1" or sys.platform != "darwin":
        return None
    try:
        libc = ctypes.CDLL(None)
        fn = libc.launch_activate_socket
    except (OSError, AttributeError):
        return None
    fn.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.POINTER(ctypes.c_int)), ctypes.POINTER(ctypes.c_size_t)]
    fn.restype = ctypes.c_int
    fds = ctypes.POINTER(ctypes.c_int)()
    count = ctypes.c_size_t(0)
    if fn(b"Listener", ctypes.byref(fds), ctypes.byref(count)) != 0 or count.value == 0:
        return None
    fd = fds[0]
    libc.free(fds)
    return socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, fileno=fd)


def bind_socket(path: str) -> socket.socket:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.connect(path)
        probe.close()
        raise SystemExit(f"voiced already running on {path}")
    except (FileNotFoundError, ConnectionRefusedError, OSError):
        probe.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    old = os.umask(0o177)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(path)
    finally:
        os.umask(old)
    s.listen(16)
    return s


def serve(listener: socket.socket, engine: Engine, exit_after: float, owned_path: Optional[str]) -> int:
    listener.settimeout(1.0)
    log(f"ready pid={os.getpid()} backend={engine.worker.backend.name} python={sys.executable}")
    try:
        while True:
            try:
                conn, _ = listener.accept()
            except socket.timeout:
                with engine.lock:
                    clients = engine.clients
                if clients == 0 and engine.idle_for() >= exit_after:
                    log(f"idle {engine.idle_for():.0f}s with no client: exiting")
                    return 0
                continue
            except OSError:
                return 0
            conn.settimeout(None)
            threading.Thread(target=serve_connection, args=(engine, conn), name="voiced-conn", daemon=True).start()
    except (KeyboardInterrupt, SystemExit):
        return 0
    finally:
        try:
            listener.close()
        except OSError:
            pass
        if owned_path:
            try:
                os.unlink(owned_path)
            except FileNotFoundError:
                pass
        engine.stop()


def main() -> int:
    def _on_term(*_args: Any) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)
    os.makedirs(voice_home(), mode=0o700, exist_ok=True)
    engine = Engine(unload_after=env_secs("VOICED_UNLOAD_SECS", 600.0))
    listener = systemd_socket() or launchd_socket()
    owned = None
    if listener is None:
        owned = socket_path()
        listener = bind_socket(owned)
        log(f"bound {owned}")
    else:
        log("socket-activated")
    if os.environ.get("VOICED_PRELOAD") == "1":
        engine.submit({"op": "load"}, b"")
    return serve(listener, engine, env_secs("VOICED_EXIT_SECS", 1800.0), owned)


if __name__ == "__main__":
    rc = main()
    try:
        sys.stdout.flush()
        sys.stderr.flush()
    except Exception:
        pass
    os._exit(rc)
