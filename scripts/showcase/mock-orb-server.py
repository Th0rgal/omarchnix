#!/usr/bin/env python3
"""Deterministic local mock Core + static UI server for the Omarchnix Orb showcase.

Run inside a desktop session (or showcase VM):
  python3 scripts/showcase/mock-orb-server.py --port 1430 &
  ORB_DEV_URL=http://127.0.0.1:1430 orb
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import pathlib
import shutil
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MISSION_ID = "omarchnix-showcase"
MISSION_2_ID = "omarchnix-spaces"
NOW = "2026-11-11T14:27:00Z"

USER_PROMPT = (
    "Review the Omarchnix desktop polish and verify the three-Space workflow. "
    "Keep the configuration declarative and the interface quiet."
)

ASSISTANT_MD = """The desktop configuration is ready for review. All three Spaces share the same centered window geometry and native frosted surfaces.

| Component | Status | Result |
| :--- | :--- | :--- |
| Spaces & navigation | ✓ Verified | Three contiguous Spaces |
| Native Orb surface | ✓ Verified | GTK4 + WebKitGTK, 78% sidebar |
| Biometric approval | ✓ Verified | Explicit scanning and success states |

The workspace invariant stays small and explicit:

```lean
def validSpace (n : Nat) : Prop := 1 ≤ n ∧ n ≤ 3

theorem first_space_valid : validSpace 1 := by
  constructor <;> omega
```

The Nix profile keeps the same behavior across machines. **Ready for the next iteration.**"""

EVENTS = [
    {
        "id": 1,
        "event_id": "ev-1",
        "sequence": 1,
        "event_type": "user_message",
        "timestamp": "2026-11-11T14:26:10Z",
        "content": USER_PROMPT,
        "metadata": {},
    },
    {
        "id": 2,
        "event_id": "ev-2",
        "sequence": 2,
        "event_type": "tool_call",
        "timestamp": "2026-11-11T14:26:18Z",
        "tool_call_id": "call-1",
        "tool_name": "bash",
        "content": json.dumps({"command": "nix flake check --no-build"}),
        "metadata": {},
    },
    {
        "id": 3,
        "event_id": "ev-3",
        "sequence": 3,
        "event_type": "tool_result",
        "timestamp": "2026-11-11T14:26:24Z",
        "tool_call_id": "call-1",
        "tool_name": "bash",
        "content": json.dumps({"exit_code": 0, "stdout": "all checks evaluated cleanly"}),
        "metadata": {},
    },
    {
        "id": 4,
        "event_id": "ev-4",
        "sequence": 4,
        "event_type": "tool_call",
        "timestamp": "2026-11-11T14:26:28Z",
        "tool_call_id": "call-2",
        "tool_name": "bash",
        "content": json.dumps({"command": "omarchnix status --json"}),
        "metadata": {},
    },
    {
        "id": 5,
        "event_id": "ev-5",
        "sequence": 5,
        "event_type": "tool_result",
        "timestamp": "2026-11-11T14:26:30Z",
        "tool_call_id": "call-2",
        "tool_name": "bash",
        "content": json.dumps({"exit_code": 0, "stdout": "{\"shell\":\"omarchy-shell\",\"spaces\":3}"}),
        "metadata": {},
    },
    {
        "id": 6,
        "event_id": "ev-6",
        "sequence": 6,
        "event_type": "assistant_message",
        "timestamp": NOW,
        "content": ASSISTANT_MD,
        "metadata": {"success": True},
    },
]

MISSIONS = [
    {
        "id": MISSION_ID,
        "title": "Polish the Linux desktop experience",
        "status": "completed",
        "project": "omarchnix",
        "backend": "codex",
        "model_override": "gpt-6.1-terra",
        "model_effort": "medium",
        "remote_node_id": "m2air",
        "created_at": "2026-11-11T14:26:00Z",
        "updated_at": NOW,
        "first_viewed_at": NOW,
        "history": [
            {"role": "user", "content": USER_PROMPT},
            {"role": "assistant", "content": ASSISTANT_MD},
        ],
    },
    {
        "id": MISSION_2_ID,
        "title": "Unify Spaces and window margins",
        "status": "working",
        "project": "omarchnix",
        "backend": "codex",
        "model_override": "gpt-6.1-terra",
        "model_effort": "medium",
        "remote_node_id": "spark",
        "created_at": "2026-11-11T14:20:00Z",
        "updated_at": "2026-11-11T14:25:00Z",
        "first_viewed_at": "2026-11-11T14:25:00Z",
        "history": [],
    },
]

PROJECTS = [
    {"slug": "omarchnix", "title": "Omarchnix", "mission_count": 2, "updated_at": NOW},
    {"slug": "verity", "title": "Verity", "mission_count": 4, "updated_at": "2026-11-11T13:50:00Z"},
    {"slug": "turbo-lean", "title": "Turbo Lean", "mission_count": 3, "updated_at": "2026-11-11T12:15:00Z"},
    {"slug": "nixos-fleet", "title": "NixOS Fleet", "mission_count": 2, "updated_at": "2026-11-11T11:00:00Z"},
]


def discover_ui_root(explicit: str | None) -> pathlib.Path:
    if explicit:
        return pathlib.Path(explicit).resolve()
    env_root = os.environ.get("ORB_UI_ROOT")
    if env_root and pathlib.Path(env_root, "index.html").is_file():
        return pathlib.Path(env_root).resolve()
    orb_bin = shutil.which("orb")
    if orb_bin:
        txt = pathlib.Path(orb_bin).read_text(errors="ignore")
        for tok in txt.split("'"):
            if tok.endswith("/share/orb") and pathlib.Path(tok, "index.html").is_file():
                return pathlib.Path(tok).resolve()
    raise SystemExit("Could not locate ORB_UI_ROOT; pass --ui-root /nix/store/...-orb-desktop-.../share/orb")


def make_handler(ui_root: pathlib.Path):
    stats = {"events_served": 0, "projects_served": 0}
    boot_snippet = (
        "<script>"
        "(function(){"
        "try{"
        'localStorage.setItem("orb.apiUrl",window.location.origin);'
        'localStorage.setItem("orb.jwt","showcase-token");'
        f'localStorage.setItem("orb.selectedConversation","m:{MISSION_ID}");'
        "const wrap=(orig)=>{if(!orig||orig.__showcaseWrapped)return orig;"
        "const fn=async(cmd,args,opts)=>{"
        'if(cmd==="transport_bridge_configure")return{proxy_base_url:null,stream_proxy_base_urls:[]};'
        'if(cmd==="desktop_connection_load")return{api_url:window.location.origin,token:"showcase-token"};'
        'if(cmd==="desktop_connection_save"||cmd==="desktop_prefs_patch")return{ok:true};'
        'if(cmd==="desktop_prefs_load")return{prefs:{}};'
        "return orig(cmd,args,opts);};"
        "fn.__showcaseWrapped=true;return fn;};"
        "for(const r of[window.__ORB_DESKTOP__,window.__TAURI__]){"
        'if(r&&r.core&&typeof r.core.invoke==="function")r.core.invoke=wrap(r.core.invoke.bind(r.core));'
        "}"
        'if(window.__TAURI_INTERNALS__&&typeof window.__TAURI_INTERNALS__.invoke==="function"){'
        "window.__TAURI_INTERNALS__.invoke=wrap(window.__TAURI_INTERNALS__.invoke.bind(window.__TAURI_INTERNALS__));"
        "}"
        "}catch{}"
        "})();"
        "</script>"
    )

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args) -> None:
            return

        def send_json(
            self,
            payload: object,
            code: int = 200,
            extra_headers: dict[str, str] | None = None,
        ) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "*")
            self.send_header("Access-Control-Expose-Headers", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
            for k, v in (extra_headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def do_OPTIONS(self) -> None:
            self.send_json({"ok": True})

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length") or "0")
            if length > 0:
                _ = self.rfile.read(length)
            self.send_json({"ok": True})

        def do_PATCH(self) -> None:
            self.do_POST()

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            path = parsed.path
            qs = parse_qs(parsed.query)

            if path == "/api/control/stream":
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                try:
                    self.wfile.write(b": connected\n\n")
                    self.wfile.flush()
                    while True:
                        time.sleep(15)
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    pass
                return

            if path == "/__showcase_ready":
                ready = stats["events_served"] >= 1 and stats["projects_served"] >= 1
                return self.send_json({"ready": ready, **stats}, 200 if ready else 503)
            if path == "/api/health":
                return self.send_json({"status": "ok", "version": "0.13.0"})
            if path == "/api/auth/me":
                return self.send_json({"id": "thomas", "username": "thomas", "role": "admin"})
            if path == "/api/auth/status":
                return self.send_json({"authenticated": True, "auth_required": True, "role": "admin"})
            if path == "/api/projects":
                stats["projects_served"] += 1
                return self.send_json({"projects": PROJECTS})
            if path == "/api/backends":
                return self.send_json(
                    [
                        {"id": "codex", "name": "codex", "available": True},
                        {"id": "opencode", "name": "opencode", "available": True},
                        {"id": "claudecode", "name": "claudecode", "available": True},
                    ]
                )
            if path == "/api/providers/backend-models":
                return self.send_json(
                    {
                        "backends": {
                            "codex": [{"id": "gpt-6.1-terra", "label": "Default"}],
                        }
                    }
                )
            if path == "/api/model-routing/chains":
                return self.send_json([{"id": "default", "name": "Default", "is_default": True}])
            if path == "/api/remote-nodes":
                return self.send_json(
                    {
                        "nodes": [
                            {"id": "m2air", "name": "m2air", "online": True, "slots_available": 4, "slots_total": 4},
                            {"id": "spark", "name": "spark", "online": True, "slots_available": 8, "slots_total": 8},
                        ]
                    }
                )
            if path == "/api/ai/providers":
                return self.send_json({"providers": []})
            if path == "/api/ai/providers/usage":
                return self.send_json({"entries": {}})
            if path == "/api/settings":
                return self.send_json({"inbox_enabled": True})
            if path == "/api/library/skill":
                return self.send_json([])
            if path.startswith("/api/control/inbox-state"):
                return self.send_json({"unread_count": 7, "items": [f"inb-{i}" for i in range(7)]})
            if path == "/api/control/codex-speed":
                return self.send_json({"tiers": [{"id": "standard", "label": "Standard"}]})
            if path == "/api/control/queue":
                return self.send_json({"items": [], "revision": 0})
            if path == "/api/control/cyber-capabilities":
                return self.send_json({"route_supported": False})
            if path == "/api/control/missions":
                status_filter = (qs.get("status") or [None])[0]
                proj_filter = (qs.get("project") or [None])[0]
                rows = list(MISSIONS)
                if status_filter == "acknowledged":
                    rows = []
                elif status_filter:
                    rows = [m for m in rows if m["status"] == status_filter]
                if proj_filter:
                    rows = [m for m in rows if m.get("project") == proj_filter]
                return self.send_json(rows)
            if path == f"/api/control/missions/{MISSION_ID}":
                return self.send_json(MISSIONS[0])
            if path == f"/api/control/missions/{MISSION_2_ID}":
                return self.send_json(MISSIONS[1])
            if path == f"/api/control/missions/{MISSION_ID}/events":
                max_seq = EVENTS[-1]["sequence"]
                since = int(qs["since_seq"][0]) if qs.get("since_seq") else None
                before = int(qs["before_seq"][0]) if qs.get("before_seq") else None
                rows = [
                    e
                    for e in EVENTS
                    if (since is None or e["sequence"] > since)
                    and (before is None or e["sequence"] < before)
                ]
                ev_headers = {
                    "X-Orb-Events-Protocol": "1",
                    "X-Has-More": "false",
                    "X-Max-Sequence": str(max_seq),
                }
                if rows:
                    ev_headers["X-Next-Cursor"] = str(
                        rows[-1]["sequence"] if since is not None else rows[0]["sequence"]
                    )
                    ev_headers["X-Page-Max-Sequence"] = str(rows[-1]["sequence"])
                    stats["events_served"] += 1
                return self.send_json(rows, extra_headers=ev_headers)
            if path == f"/api/control/missions/{MISSION_2_ID}/events":
                return self.send_json(
                    [],
                    extra_headers={
                        "X-Orb-Events-Protocol": "1",
                        "X-Has-More": "false",
                        "X-Max-Sequence": "0",
                    },
                )
            if path.startswith("/api/control/missions/") and (
                path.endswith("/automations")
                or path.endswith("/shares")
                or path.endswith("/checkpoints")
                or "/tool-calls/" in path
            ):
                return self.send_json([])
            if path.startswith("/api/"):
                return self.send_json({})

            rel = path.lstrip("/") or "index.html"
            candidate = (ui_root / rel).resolve()
            if not str(candidate).startswith(str(ui_root)) or not candidate.is_file():
                candidate = ui_root / "index.html"
            data = candidate.read_bytes()
            mime, _ = mimetypes.guess_type(str(candidate))
            mime = mime or "application/octet-stream"
            if candidate.name == "index.html":
                html = data.decode("utf-8", errors="replace").replace("<head>", f"<head>{boot_snippet}", 1)
                data = html.encode("utf-8")
                mime = "text/html; charset=utf-8"
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(data)

    return Handler


class ShowcaseHTTPServer(ThreadingHTTPServer):
    daemon_threads = True


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ui-root", help="Path to share/orb directory")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=1430)
    args = ap.parse_args()

    ui_root = discover_ui_root(args.ui_root)
    srv = ShowcaseHTTPServer((args.host, args.port), make_handler(ui_root))
    print(f"Serving Orb showcase UI ({ui_root}) + mock Core on http://{args.host}:{args.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
