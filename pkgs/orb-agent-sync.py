#!/usr/bin/env python3
"""omarchy-orb-agent: Bidirectional sync & control bridge between Omarchy's
`omarchy.agents` status-bar plugin and Orb Core / Orb Desktop.

- Reads `~/.orb/connection.json` (0600, non-symlink) without ever logging tokens.
- Uses Orb's 3-way edge-diverse failover (`orbcore.thomas.md`,
  `agent-backend.thomas.md`, `agent-backend.nico-best-pc-ever.ovh`) for reads.
- Populates `~/.local/state/omarchy/agents/usage/<id>.json` with live
  CLIProxyAPI subscription windows, multi-account pools, coding-plan quotas,
  Cloud Agent status, xAI prepaid balances, subscription reset credits, and
  30-day fleet token/prompt telemetry.
- Implements two-way bar controls:
  * `account-use`: reorders Orb account priority (`POST /api/ai/providers/reorder`)
  * `account-mode`: toggles manual vs automatic headroom failover
  * `account-rename`: renames Orb provider account (`PUT /api/ai/providers/<id>`)
  * `account-add`: runs Orb `cli-proxy-login` / `mistral-login` OAuth flows in-panel
  * `launch` / `prompt`: opens/focuses Orb Desktop's New Agent composer via
    `~/.orb/desktop-command.json` (`orb-locald` SSE push).
"""

from __future__ import annotations

import concurrent.futures
import datetime as dt
import fcntl
import json
import os
import re
import select
import shutil
import signal
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
SUMMARY_CACHE_TTL_SECS = 120.0
DEFAULT_AUTOSWITCH_THRESHOLD = 95

HOSTED_FAILOVER_MAP: dict[str, list[str]] = {
    "https://orbcore.thomas.md": [
        "https://orbcore.thomas.md",
        "https://agent-backend.thomas.md",
        "https://agent-backend.nico-best-pc-ever.ovh",
    ],
    "https://agent-backend.thomas.md": [
        "https://agent-backend.thomas.md",
        "https://orbcore.thomas.md",
        "https://agent-backend.nico-best-pc-ever.ovh",
    ],
    "https://agent-backend.nico-best-pc-ever.ovh": [
        "https://agent-backend.nico-best-pc-ever.ovh",
        "https://agent-backend.thomas.md",
        "https://orbcore.thomas.md",
    ],
}

# Orb `provider_type` -> (omarchy_id, display_name, supports_orb_signin)
ORB_PROVIDER_MAP: dict[str, tuple[str, str, bool]] = {
    "anthropic": ("claude", "Claude Code", True),
    "openai": ("codex", "Codex", True),
    "antigravity": ("agy", "Antigravity", True),
    "xai": ("grok", "Grok", True),
    "kimi": ("kimi", "Kimi", True),
    "mistral": ("vibe", "Mistral Vibe", True),
    "muse-code": ("muse", "Muse Code", False),
    "muse": ("muse_api", "Muse API", False),
    "github-copilot": ("copilot", "Copilot", False),
    "minimax": ("minimax", "MiniMax", False),
    "zai": ("zai", "Z.AI", False),
    "open-router": ("openrouter", "OpenRouter", False),
    "fireworks": ("fireworks", "Fireworks", False),
    "deepseek": ("deepseek", "DeepSeek", False),
    "qwen": ("qwen", "Qwen", False),
    "google": ("opencode", "OpenCode", False),
}

# Reverse map for OAuth / account operations initiated from Omarchy UI
OMARCHY_TO_ORB_LOGIN: dict[str, tuple[str, str]] = {
    "claude": ("anthropic", "Claude Code"),
    "codex": ("openai", "Codex"),
    "grok": ("xai", "Grok"),
    "agy": ("antigravity", "Antigravity"),
    "kimi": ("kimi", "Kimi"),
    "vibe": ("mistral", "Mistral Vibe"),
}

OMARCHY_TO_ORB_TYPES: dict[str, list[str]] = {
    "claude": ["anthropic"],
    "codex": ["openai"],
    "agy": ["antigravity"],
    "grok": ["xai"],
    "kimi": ["kimi"],
    "vibe": ["mistral"],
    "muse": ["muse-code"],
    "muse_api": ["muse"],
    "copilot": ["github-copilot"],
    "minimax": ["minimax"],
    "zai": ["zai"],
    "openrouter": ["open-router"],
    "fireworks": ["fireworks"],
    "deepseek": ["deepseek"],
    "qwen": ["qwen"],
    "opencode": ["google"],
}

CLOUD_PROVIDER_MAP: dict[str, tuple[str, str]] = {
    "cursor_cloud": ("cursor", "Cursor Cloud"),
    "grok_bot": ("grokbot", "Grok Bot"),
    "hermes": ("hermes", "Paloma"),
}

# Omarchy CLI harness name -> Orb composer backend ID
HARNESS_TO_ORB_BACKEND: dict[str, str] = {
    "claude": "claudecode",
    "claudecode": "claudecode",
    "codex": "codex",
    "agy": "antigravity",
    "antigravity": "antigravity",
    "grok": "grok",
    "opencode": "opencode",
    "kimi": "opencode",
    "qwen": "opencode",
    "deepseek": "opencode",
    "dsh": "opencode",
    "vibe": "vibe",
    "muse": "claudecode",
    "hermes": "hermes",
    "cursor": "cloud_cursor",
    "cursor-agent": "cloud_cursor",
    "grokbot": "cloud_grok_bot",
}


def now_utc_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def now_ms() -> int:
    return int(time.time() * 1000)


def iso_to_ms(value: Any) -> int:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        fval = float(value)
        if fval <= 0:
            return 0
        return int(fval) if fval > 1e11 else int(fval * 1000.0)
    if not value or not isinstance(value, str):
        return 0
    txt = value.strip()
    if not txt:
        return 0
    if re.fullmatch(r"\d+(\.\d+)?", txt):
        fval = float(txt)
        return int(fval) if fval > 1e11 else int(fval * 1000.0)
    if txt.endswith("Z"):
        txt = txt[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(txt)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return int(parsed.timestamp() * 1000)
    except ValueError:
        return 0


def epoch_or_iso_to_iso(value: Any) -> str:
    if value is None or isinstance(value, bool):
        return ""
    if isinstance(value, (int, float)):
        fval = float(value)
        if fval <= 0:
            return ""
        sec = fval / 1000.0 if fval > 1e11 else fval
        try:
            return dt.datetime.fromtimestamp(sec, dt.timezone.utc).isoformat(timespec="seconds")
        except (OverflowError, OSError, ValueError):
            return ""
    if isinstance(value, str):
        txt = value.strip()
        if not txt:
            return ""
        if re.fullmatch(r"\d+(\.\d+)?", txt):
            fval = float(txt)
            if fval <= 0:
                return ""
            sec = fval / 1000.0 if fval > 1e11 else fval
            try:
                return dt.datetime.fromtimestamp(sec, dt.timezone.utc).isoformat(timespec="seconds")
            except (OverflowError, OSError, ValueError):
                return ""
        return txt
    return ""


def orb_state_dir() -> Path:
    env_dir = os.environ.get("ORB_STATE_DIR", "").strip()
    if env_dir:
        return Path(env_dir)
    return Path.home() / ".orb"


def omarchy_agents_state_dir() -> Path:
    xdg_state = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(xdg_state) if xdg_state else (Path.home() / ".local" / "state")
    return base / "omarchy" / "agents"


def usage_dir() -> Path:
    return omarchy_agents_state_dir() / "usage"


def cache_path() -> Path:
    return omarchy_agents_state_dir() / "orb-cache.json"


def is_safe_regular_file(path: Path) -> bool:
    try:
        st = os.lstat(path)
        return not stat.S_ISLNK(st.st_mode) and stat.S_ISREG(st.st_mode)
    except OSError:
        return False


def is_not_symlink_dir(path: Path) -> bool:
    try:
        st = os.lstat(path)
        return not stat.S_ISLNK(st.st_mode) and stat.S_ISDIR(st.st_mode)
    except OSError:
        return False


def atomic_write_json(path: Path, data: Any, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if os.path.lexists(path):
        try:
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                raise RuntimeError(f"Refusing to overwrite symlink: {path}")
        except OSError:
            pass
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        raw = (json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        with os.fdopen(fd, "wb") as fh:
            fh.write(raw)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def load_json_safe(path: Path, default: Any) -> Any:
    if not is_safe_regular_file(path):
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def candidate_origins(raw_url: str) -> list[str]:
    clean = raw_url.strip().rstrip("/")
    if not clean or not (clean.startswith("https://") or clean.startswith("http://127.0.0.1") or clean.startswith("http://localhost")):
        return list(HOSTED_FAILOVER_MAP["https://orbcore.thomas.md"])
    low = clean.lower()
    if low in HOSTED_FAILOVER_MAP:
        # Preserve exact case of primary while appending failover peers
        peers = HOSTED_FAILOVER_MAP[low]
        return [clean] + [p for p in peers[1:] if p.lower() != low]
    if low.endswith(".thomas.md") and low.startswith("https://"):
        return [clean, "https://agent-backend.thomas.md", "https://orbcore.thomas.md"]
    return [clean]


def load_orb_connection() -> tuple[str, str] | None:
    state_dir = orb_state_dir()
    if os.path.lexists(state_dir) and not is_not_symlink_dir(state_dir):
        return None
    conn_file = state_dir / "connection.json"
    if not is_safe_regular_file(conn_file):
        return None
    try:
        payload = json.loads(conn_file.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    api_url = str(payload.get("api_url") or payload.get("apiUrl") or "").strip().rstrip("/")
    token = str(payload.get("token") or payload.get("jwt") or "").strip()
    if not api_url or not token:
        return None
    return api_url, token


class OrbApiError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(f"HTTP {status}: {message}")
        self.status = status
        self.message = message


class OrbClient:
    def __init__(self, api_url: str, token: str, timeout: float = 12.0) -> None:
        self.primary_url = api_url
        self.origins = candidate_origins(api_url)
        self.sticky_origin = self.origins[0]
        self._token = token
        self.timeout = timeout
        self.ssl_ctx = self._make_ssl_context()

    @staticmethod
    def _make_ssl_context() -> ssl.SSLContext:
        cafile = (
            os.environ.get("SSL_CERT_FILE")
            or os.environ.get("NIX_SSL_CERT_FILE")
            or "/etc/ssl/certs/ca-certificates.crt"
        )
        if os.path.isfile(cafile):
            return ssl.create_default_context(cafile=cafile)
        return ssl.create_default_context()

    def request_json(
        self,
        method: str,
        path: str,
        body: Any = None,
        timeout: float | None = None,
        idempotent: bool = False,
    ) -> Any:
        method_u = method.upper()
        safe = method_u in ("GET", "HEAD", "OPTIONS")
        ordered = [self.sticky_origin] + [o for o in self.origins if o != self.sticky_origin]
        if not safe and not idempotent:
            ordered = [self.sticky_origin]

        raw_body: bytes | None = None
        headers: dict[str, str] = {
            "Authorization": f"Bearer {self._token}",
            "Accept": "application/json",
            "User-Agent": "omarchy-orb-agent/1.0",
        }
        if body is not None:
            raw_body = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if idempotent and not safe:
            headers.setdefault("Idempotency-Key", str(uuid.uuid4()))

        last_err: Exception | None = None
        eff_timeout = timeout if timeout is not None else self.timeout

        for idx, origin in enumerate(ordered):
            url = f"{origin}{path}"
            req = urllib.request.Request(url, data=raw_body, headers=headers, method=method_u)
            try:
                ctx = self.ssl_ctx if url.startswith("https://") else None
                with urllib.request.urlopen(req, timeout=eff_timeout, context=ctx) as resp:
                    resp_bytes = resp.read()
                    self.sticky_origin = origin
                    if not resp_bytes:
                        return None
                    return json.loads(resp_bytes.decode("utf-8"))
            except urllib.error.HTTPError as exc:
                err_body = ""
                try:
                    err_body = exc.read(4096).decode("utf-8", errors="replace")
                except Exception:
                    pass
                msg = err_body
                try:
                    parsed = json.loads(err_body)
                    if isinstance(parsed, dict):
                        msg = str(parsed.get("error") or parsed.get("message") or err_body)
                except Exception:
                    pass
                if (exc.code == 429 or 500 <= exc.code <= 599) and idx + 1 < len(ordered):
                    last_err = OrbApiError(exc.code, msg)
                    continue
                raise OrbApiError(exc.code, msg) from None
            except Exception as exc:
                last_err = exc
                if idx + 1 < len(ordered):
                    continue
                break

        if isinstance(last_err, OrbApiError):
            raise last_err
        raise RuntimeError(f"Orb Core unreachable ({type(last_err).__name__})")


def emit_desktop_command(payload: dict[str, Any]) -> bool:
    """Write a 0600 atomic command file consumed by `orb-locald`'s SSE loop."""
    state_dir = orb_state_dir()
    try:
        if os.path.lexists(state_dir):
            if not is_not_symlink_dir(state_dir):
                return False
        else:
            state_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
        cmd = {
            "id": str(uuid.uuid4()),
            "ts_ms": now_ms(),
            **payload,
        }
        atomic_write_json(state_dir / "desktop-command.json", cmd, mode=0o600)
        return True
    except Exception:
        return False


def send_notification(summary: str, body: str = "") -> None:
    notif_bin = shutil.which("omarchy-notification-send") or shutil.which("notify-send")
    if not notif_bin:
        return
    args = [notif_bin, summary]
    if body:
        args.append(body)
    try:
        subprocess.Popen(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


def upstream_bin(script_name: str) -> str | None:
    up_dir = os.environ.get("OMARCHY_UPSTREAM_BIN_DIR", "").strip()
    if up_dir:
        cand = Path(up_dir) / script_name
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    omarchy_path = os.environ.get("OMARCHY_PATH", "").strip()
    if omarchy_path:
        cand = Path(omarchy_path) / "bin" / script_name
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    found = shutil.which(script_name)
    return found


def run_upstream(script_name: str, argv: list[str], replace: bool = False) -> int:
    target = upstream_bin(script_name)
    if not target:
        return 1
    env = os.environ.copy()
    env["_OMARCHY_SKIP_AGENT_OVERRIDE"] = "1"
    if replace:
        os.execve(target, [target, *argv], env)
    proc = subprocess.run([target, *argv], env=env, check=False)
    return proc.returncode


def clamp_unit(pct_0_to_100: Any) -> float:
    try:
        val = float(pct_0_to_100) / 100.0
    except (TypeError, ValueError):
        return 0.0
    if val < 0.0:
        return 0.0
    if val > 1.0:
        return 1.0
    return round(val, 4)


def clamp_ratio(ratio_0_to_1: Any) -> float:
    try:
        val = float(ratio_0_to_1)
    except (TypeError, ValueError):
        return 0.0
    if val < 0.0:
        return 0.0
    if val > 1.0:
        return 1.0
    return round(val, 4)


def clean_plan_label(raw: Any) -> str:
    if not raw or not isinstance(raw, str):
        return ""
    txt = raw.strip()
    txt = re.sub(r"^Google AI\s+", "", txt, flags=re.IGNORECASE)
    txt = re.sub(r"^Muse Code\s+", "", txt, flags=re.IGNORECASE)
    txt = re.sub(r"^Chat\s*·\s*", "", txt, flags=re.IGNORECASE)
    low = txt.lower()
    mapping = {
        "max": "Max",
        "promax": "Pro",
        "pro": "Pro",
        "plus": "Plus",
        "team": "Team",
        "enterprise": "Enterprise",
        "free": "Free",
        "ultra": "Ultra",
        "coding_plan": "Coding Plan",
    }
    if low in mapping:
        return mapping[low]
    return txt.replace("_", " ")


def extract_plan_label(
    provider_type: str,
    account: dict[str, Any],
    usage: dict[str, Any] | None,
    has_limits: bool = False,
    has_balance: bool = False,
) -> str:
    u = usage if isinstance(usage, dict) else {}
    candidates = [
        u.get("antigravity_plan") if provider_type == "antigravity" else None,
        u.get("codex_plan_type") if provider_type == "openai" else None,
        u.get("xai_plan") if provider_type == "xai" else None,
        u.get("kimi_plan") if provider_type == "kimi" else None,
        u.get("zai_plan") if provider_type == "zai" else None,
        u.get("muse_plan") if provider_type in ("muse-code", "muse") else None,
        u.get("mistral_plan") if provider_type == "mistral" else None,
        u.get("minimax_plan") if provider_type == "minimax" else None,
        u.get("plan_type"),
    ]
    for cand in candidates:
        cleaned = clean_plan_label(cand)
        if cleaned:
            return cleaned
    if has_balance:
        return "Prepaid"
    if has_limits:
        return "Subscription"
    if provider_type == "muse-code" and u.get("muse_subscription_active"):
        return "Subscription"
    if provider_type in ("anthropic", "openai", "antigravity", "xai", "kimi", "mistral", "muse-code") and (
        account.get("uses_oauth") or account.get("has_oauth")
    ):
        return "Subscription"
    return ""


def short_codex_model_name(name: str) -> str:
    clean = name.strip()
    clean = re.sub(r"^GPT-[0-9.]+-Codex-", "", clean, flags=re.IGNORECASE)
    clean = re.sub(r"^GPT-", "GPT ", clean, flags=re.IGNORECASE)
    return clean or name.strip()


def codex_window_is_weekly(seconds: int | None, label: str = "") -> bool:
    if seconds is not None and seconds >= 5 * 86400:
        return True
    low = label.lower()
    return "week" in low or "7-day" in low or "7d" in low


def codex_duration_label(seconds: int | None, fallback: str = "Session") -> str:
    if not seconds or seconds <= 0:
        return fallback
    if seconds % 86400 == 0:
        days = seconds // 86400
        if days == 7:
            return "Weekly (7-day)"
        return f"{days}-day window"
    if seconds % 3600 == 0:
        hours = seconds // 3600
        return f"Session ({hours}-hour)"
    mins = max(1, round(seconds / 60))
    return f"Session ({mins}m)"


def normalize_provider_windows(
    provider_type: str,
    usage: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    if not usage or not isinstance(usage, dict):
        return []

    limits: list[dict[str, Any]] = []

    def add_win(label: str, title: str, pct: Any, resets_at: Any = None) -> None:
        if pct is None:
            return
        limits.append(
            {
                "label": label,
                "title": title,
                "percent": clamp_unit(pct),
                "resetsAt": epoch_or_iso_to_iso(resets_at),
            }
        )

    def add_ratio_win(label: str, title: str, ratio: Any, resets_at: Any = None) -> None:
        if ratio is None:
            return
        limits.append(
            {
                "label": label,
                "title": title,
                "percent": clamp_ratio(ratio),
                "resetsAt": epoch_or_iso_to_iso(resets_at),
            }
        )

    # 1. Antigravity model-pool windows (`antigravity_windows`: `used_percent` / `reset_at`)
    ag_wins = usage.get("antigravity_windows")
    if provider_type == "antigravity" and isinstance(ag_wins, list) and ag_wins:
        pools: dict[str, dict[str, dict[str, Any]]] = {}
        pool_order: list[str] = []
        for w in ag_wins:
            if not isinstance(w, dict):
                continue
            raw_lbl = str(w.get("label") or "")
            low = raw_lbl.lower()
            if "claude" in low and "gpt" in low:
                fam = "Claude & GPT"
            elif "gemini" in low and "flash" not in low:
                fam = "Gemini"
            elif "flash" in low:
                fam = "Flash"
            elif "claude" in low:
                fam = "Claude"
            elif "gpt" in low:
                fam = "GPT"
            else:
                fam = raw_lbl.split("·")[0].strip() or "Pool"
            slot = "Weekly" if ("week" in low or "7d" in low or "7-day" in low) else "Session"
            rst = w.get("reset_at") if w.get("reset_at") is not None else w.get("resets_at")
            raw_pct = w.get("used_percent") if w.get("used_percent") is not None else w.get("used_pct")
            if raw_pct is None and rst is not None:
                raw_pct = 100.0
            if raw_pct is None:
                continue
            norm_w = {"pct": float(raw_pct), "rst": rst}
            if fam not in pools:
                pools[fam] = {}
                pool_order.append(fam)
            existing = pools[fam].get(slot)
            if existing is None or norm_w["pct"] > existing["pct"] or (not existing["rst"] and norm_w["rst"]):
                pools[fam][slot] = norm_w

        primary_fam = "Gemini" if "Gemini" in pools else (pool_order[0] if pool_order else "")
        if primary_fam:
            p_slots = pools[primary_fam]
            if "Session" in p_slots:
                w = p_slots["Session"]
                add_win("Session (5-hour)", "Session", w["pct"], w["rst"])
            if "Weekly" in p_slots:
                w = p_slots["Weekly"]
                add_win("Weekly (7-day)", "Weekly", w["pct"], w["rst"])
            for fam in pool_order:
                if fam == primary_fam:
                    continue
                for slot in ("Session", "Weekly"):
                    if slot in pools[fam]:
                        w = pools[fam][slot]
                        add_win(f"{fam} {slot}", f"{fam} {slot}", w["pct"], w["rst"])
        if limits:
            return limits

    # 2. Anthropic unified windows (`unified_5h_utilization` / `unified_7d_utilization` in `0.0..1.0`)
    if provider_type == "anthropic":
        if usage.get("unified_5h_utilization") is not None:
            add_ratio_win("Session (5-hour)", "Session", usage.get("unified_5h_utilization"), usage.get("unified_5h_reset"))
        if usage.get("unified_7d_utilization") is not None:
            add_ratio_win("Weekly (7-day)", "Weekly", usage.get("unified_7d_utilization"), usage.get("unified_7d_reset"))
        if limits:
            return limits

    # 3. OpenAI / Codex live fields (`codex_primary_*`, `codex_secondary_*`) & multi-window (`codex_windows`)
    if provider_type == "openai":
        p_pct = usage.get("codex_primary_used_percent")
        s_pct = usage.get("codex_secondary_used_percent")
        if p_pct is not None or s_pct is not None:
            p_mins = usage.get("codex_primary_window_minutes")
            s_mins = usage.get("codex_secondary_window_minutes")
            p_sec = int(p_mins) * 60 if isinstance(p_mins, (int, float)) and p_mins > 0 else None
            s_sec = int(s_mins) * 60 if isinstance(s_mins, (int, float)) and s_mins > 0 else None
            p_is_wk = codex_window_is_weekly(p_sec)
            if p_sec is None and s_sec is not None:
                p_is_wk = not codex_window_is_weekly(s_sec)
            s_is_wk = codex_window_is_weekly(s_sec) if s_sec is not None else (not p_is_wk if p_pct is not None else True)

            pair_items: list[tuple[int, str, str, Any, Any]] = []
            if p_pct is not None:
                t_p = "Weekly" if p_is_wk else "Session"
                l_p = codex_duration_label(p_sec, "Weekly (7-day)" if p_is_wk else "Session (5-hour)")
                pair_items.append((1 if p_is_wk else 0, l_p, t_p, p_pct, usage.get("codex_primary_reset_at")))
            if s_pct is not None:
                t_s = "Weekly" if s_is_wk else "Session"
                l_s = codex_duration_label(s_sec, "Weekly (7-day)" if s_is_wk else "Session (5-hour)")
                pair_items.append((1 if s_is_wk else 0, l_s, t_s, s_pct, usage.get("codex_secondary_reset_at")))
            pair_items.sort(key=lambda item: item[0])
            for _, lbl, ttl, pct_val, rst_val in pair_items:
                add_win(lbl, ttl, pct_val, rst_val)

        codex_wins = usage.get("codex_windows")
        if isinstance(codex_wins, list) and codex_wins:
            for w in codex_wins:
                if not isinstance(w, dict):
                    continue
                limit_name = str(w.get("limit_name") or "").strip()
                if not limit_name and limits:
                    continue
                p_sec = w.get("primary_window_seconds")
                s_sec = w.get("secondary_window_seconds")
                if w.get("primary_used_pct") is not None:
                    is_wk = codex_window_is_weekly(p_sec if isinstance(p_sec, int) else None)
                    base_title = "Weekly" if is_wk else "Session"
                    title = f"{short_codex_model_name(limit_name)} {base_title}" if limit_name else base_title
                    lbl = codex_duration_label(p_sec if isinstance(p_sec, int) else None, base_title)
                    add_win(f"{limit_name} · {lbl}" if limit_name else lbl, title, w.get("primary_used_pct"), w.get("primary_resets_at"))
                if w.get("secondary_used_pct") is not None:
                    is_wk = codex_window_is_weekly(s_sec if isinstance(s_sec, int) else 604800)
                    base_title = "Weekly" if is_wk else "Session"
                    title = f"{short_codex_model_name(limit_name)} {base_title}" if limit_name else base_title
                    lbl = codex_duration_label(s_sec if isinstance(s_sec, int) else 604800, base_title)
                    add_win(f"{limit_name} · {lbl}" if limit_name else lbl, title, w.get("secondary_used_pct"), w.get("secondary_resets_at"))
        if limits:
            return limits

    # 4. Kimi windows (`kimi_windows`, `kimi_5h_used_percent`, `kimi_weekly_used_percent`)
    if provider_type == "kimi":
        kwins = usage.get("kimi_windows")
        if isinstance(kwins, list) and kwins:
            staged: list[tuple[int, str, str, Any, Any]] = []
            for w in kwins:
                if not isinstance(w, dict):
                    continue
                pct_v = w.get("used_percent") if w.get("used_percent") is not None else w.get("used_pct")
                rst_v = w.get("reset_at") if w.get("reset_at") is not None else w.get("resets_at")
                if pct_v is None and rst_v is not None:
                    pct_v = 100.0
                if pct_v is None:
                    continue
                raw_lbl = str(w.get("label") or "").strip()
                low = raw_lbl.lower()
                if "month" in low or "30d" in low:
                    staged.append((2, "Monthly allowance", "Monthly", pct_v, rst_v))
                elif "week" in low or "7d" in low:
                    staged.append((1, "Weekly (7-day)", "Weekly", pct_v, rst_v))
                else:
                    staged.append((0, "Session (5-hour)" if low in ("5h", "session", "") else raw_lbl, "Session", pct_v, rst_v))
            staged.sort(key=lambda item: item[0])
            for _, lbl, ttl, pv, rv in staged:
                add_win(lbl, ttl, pv, rv)
            if limits:
                return limits
        if usage.get("kimi_5h_used_percent") is not None:
            add_win("Session (5-hour)", "Session", usage.get("kimi_5h_used_percent"), usage.get("kimi_5h_reset"))
        elif usage.get("kimi_rate_limit_pct") is not None:
            mins = usage.get("kimi_rate_limit_window_minutes") or 300
            lbl = f"Session ({mins // 60}-hour)" if mins % 60 == 0 else f"Session ({mins}m)"
            add_win(lbl, "Session", usage.get("kimi_rate_limit_pct"), usage.get("kimi_rate_limit_resets_at"))
        if usage.get("kimi_weekly_used_percent") is not None:
            add_win("Weekly (7-day)", "Weekly", usage.get("kimi_weekly_used_percent"), usage.get("kimi_weekly_reset"))
        elif usage.get("kimi_weekly_pct") is not None:
            add_win("Weekly (7-day)", "Weekly", usage.get("kimi_weekly_pct"), usage.get("kimi_weekly_resets_at"))
        if limits:
            return limits

    # 5. xAI / Grok (`xai_credit_used_percent` + `xai_credit_window_seconds`)
    if provider_type == "xai" and usage.get("xai_credit_used_percent") is not None:
        w_sec = usage.get("xai_credit_window_seconds")
        raw_lbl = str(usage.get("xai_credit_label") or "").strip()
        is_wk = codex_window_is_weekly(w_sec if isinstance(w_sec, int) else None, raw_lbl)
        ttl = "Weekly" if is_wk else "Session"
        lbl = "Weekly (7-day)" if is_wk else (raw_lbl or "Session")
        add_win(lbl, ttl, usage.get("xai_credit_used_percent"), usage.get("xai_credit_reset"))
        return limits

    # 6. Z.AI (`zai_5h_used_percent`, `zai_weekly_used_percent`, `zai_tokens_percentage`)
    if provider_type == "zai":
        if usage.get("zai_5h_used_percent") is not None:
            add_win("Session (5-hour)", "Session", usage.get("zai_5h_used_percent"), usage.get("zai_5h_reset"))
        if usage.get("zai_weekly_used_percent") is not None:
            add_win("Weekly (7-day)", "Weekly", usage.get("zai_weekly_used_percent"), usage.get("zai_weekly_reset"))
        if not limits and usage.get("zai_tokens_percentage") is not None:
            add_win("Token quota", "Session", usage.get("zai_tokens_percentage"), usage.get("zai_tokens_reset"))
        if limits:
            return limits

    # 7. Muse Code (`muse_5h_used_percent`, `muse_weekly_used_percent`)
    if provider_type in ("muse-code", "muse"):
        if usage.get("muse_5h_used_percent") is not None:
            add_win("Session (5-hour)", "Session", usage.get("muse_5h_used_percent"), usage.get("muse_5h_reset"))
        if usage.get("muse_weekly_used_percent") is not None:
            add_win("Weekly (7-day)", "Weekly", usage.get("muse_weekly_used_percent"), usage.get("muse_weekly_reset"))
        if limits:
            return limits

    # 8. Mistral (`mistral_monthly_used_percent`)
    if provider_type == "mistral" and usage.get("mistral_monthly_used_percent") is not None:
        add_win("Monthly allowance", "Monthly", usage.get("mistral_monthly_used_percent"), usage.get("mistral_monthly_reset"))
        return limits

    # 9. MiniMax (`minimax_interval_remaining_percent`, `minimax_weekly_remaining_percent`)
    if provider_type == "minimax":
        if usage.get("minimax_interval_remaining_percent") is not None:
            try:
                used_i = max(0.0, min(100.0, 100.0 - float(usage["minimax_interval_remaining_percent"])))
                add_win("Session (5-hour)", "Session", used_i, usage.get("minimax_interval_reset"))
            except (TypeError, ValueError):
                pass
        if usage.get("minimax_weekly_remaining_percent") is not None:
            try:
                used_w = max(0.0, min(100.0, 100.0 - float(usage["minimax_weekly_remaining_percent"])))
                add_win("Weekly (7-day)", "Weekly", used_w, usage.get("minimax_weekly_reset"))
            except (TypeError, ValueError):
                pass
        if limits:
            return limits

    # 10. Generic `coding_plan_windows` or `optimize.windows`
    cp_wins = usage.get("coding_plan_windows")
    if isinstance(cp_wins, list) and cp_wins:
        seen_titles: set[str] = set()
        for w in cp_wins:
            if not isinstance(w, dict):
                continue
            pv = w.get("used_percent") if w.get("used_percent") is not None else w.get("used_pct")
            if pv is None:
                continue
            raw_lbl = str(w.get("label") or "Quota").strip()
            low = raw_lbl.lower()
            if "month" in low or "30d" in low or "30-day" in low:
                base_t = "Monthly"
            elif "week" in low or "7d" in low or "7-day" in low:
                base_t = "Weekly"
            elif any(k in low for k in ("5h", "hour", "session", "min", "rpm", "window", "token", "prompt")):
                base_t = "Session"
            else:
                base_t = "Session" if "Session" not in seen_titles else "Weekly"
            title = base_t if base_t not in seen_titles else f"{raw_lbl} {base_t}"
            seen_titles.add(title)
            add_win(raw_lbl, title, pv, w.get("reset_at") or w.get("resets_at"))
        if limits:
            return limits

    opt = usage.get("optimize")
    if isinstance(opt, dict) and isinstance(opt.get("windows"), list):
        for w in opt["windows"]:
            if not isinstance(w, dict) or w.get("pct_used") is None:
                continue
            wsec = w.get("window_seconds")
            raw_lbl = str(w.get("label") or "").strip()
            is_wk = codex_window_is_weekly(wsec if isinstance(wsec, int) else None, raw_lbl)
            ttl = "Weekly" if is_wk else "Session"
            add_win(raw_lbl or ttl, ttl, w.get("pct_used"), w.get("reset_at"))
        if limits:
            return limits

    # 11. Legacy fallback 5-hour / 7-day windows
    if usage.get("five_hour_pct") is not None:
        add_win("Session (5-hour)", "Session", usage.get("five_hour_pct"), usage.get("five_hour_resets_at"))
    if usage.get("seven_day_pct") is not None:
        add_win("Weekly (7-day)", "Weekly", usage.get("seven_day_pct"), usage.get("seven_day_resets_at"))
    if usage.get("seven_day_opus_pct") is not None:
        add_win("Opus Weekly", "Opus Weekly", usage.get("seven_day_opus_pct"), usage.get("seven_day_resets_at"))
    if usage.get("seven_day_sonnet_pct") is not None:
        add_win("Sonnet Weekly", "Sonnet Weekly", usage.get("seven_day_sonnet_pct"), usage.get("seven_day_resets_at"))

    return limits


def extract_reset_credits(usage: dict[str, Any] | None) -> dict[str, Any] | None:
    if not usage or not isinstance(usage, dict):
        return None
    sr = usage.get("subscription_resets")
    if not isinstance(sr, dict):
        return None
    avail = int(sr.get("available_count") or 0)
    if avail <= 0:
        return None
    grants = sr.get("grants")
    earliest_iso = ""
    earliest_ms = 0
    if isinstance(grants, list):
        for g in grants:
            if not isinstance(g, dict):
                continue
            rem_raw = g.get("resets_left") if g.get("resets_left") is not None else g.get("remaining_uses")
            rem = int(rem_raw) if rem_raw is not None else 1
            if rem <= 0:
                continue
            exp_raw = g.get("expires_at")
            exp_iso = epoch_or_iso_to_iso(exp_raw)
            ms = iso_to_ms(exp_raw)
            if ms > 0 and (earliest_ms == 0 or ms < earliest_ms):
                earliest_ms = ms
                earliest_iso = exp_iso
    out: dict[str, Any] = {"available": avail}
    if earliest_iso:
        out["nextExpiresAt"] = earliest_iso
    return out


def extract_balance(usage: dict[str, Any] | None) -> dict[str, Any] | None:
    if not usage or not isinstance(usage, dict):
        return None
    prepaid = usage.get("xai_prepaid_usd")
    if prepaid is None:
        return None
    try:
        rem = float(prepaid)
    except (TypeError, ValueError):
        return None
    total_raw = usage.get("xai_prepaid_total_usd")
    try:
        funded = float(total_raw) if total_raw is not None else max(rem, 0.0)
    except (TypeError, ValueError):
        funded = max(rem, 0.0)
    if funded < rem:
        funded = rem
    spent = max(0.0, round(funded - rem, 4))
    return {
        "remaining": round(rem, 4),
        "funded": round(funded, 4),
        "spent": spent,
        "currency": "USD",
        "estimated": False,
    }


def compute_account_status(
    account: dict[str, Any],
    usage: dict[str, Any] | None,
    health: dict[str, Any] | None,
) -> tuple[str, str, bool]:
    """Return `(usageStatusText, authHelpText, is_broken)` for an Orb account."""
    st_obj = account.get("status") if isinstance(account.get("status"), dict) else {}
    st_type = str(st_obj.get("type") or "")
    st_reason = str(st_obj.get("reason") or st_obj.get("message") or "").strip()
    h_status = str((health or {}).get("account_state") or (health or {}).get("status") or "")
    h_err = str((health or {}).get("last_error") or (health or {}).get("reason") or "").strip()
    u_status = str((usage or {}).get("status") or "")
    u_code = (usage or {}).get("status_code")
    u_err = str((usage or {}).get("error") or "").strip()
    u_note = str((usage or {}).get("usage_note") or "").strip()
    ptype = str(account.get("provider_type") or "")

    if not account.get("enabled", True) or account.get("user_enabled") is False:
        return ("Disabled", "Disabled in Orb Inference settings.", True)
    if h_status == "out_of_credit" or u_code == 402:
        return ("Out of credits", h_err or u_err or "Orb router received 402 / out of credits.", True)
    if (
        h_status == "auth_failed"
        or u_status == "needs_reauth"
        or bool((usage or {}).get("needs_reauth"))
        or u_code in (401, 403)
        or "401" in u_err
        or (st_type in ("needs_auth", "error") and ("auth" in st_reason.lower() or "401" in st_reason or "token" in st_reason.lower() or st_type == "needs_auth"))
    ):
        return ("Sign-in expired", u_err or h_err or st_reason or "Sign-in token expired; click Sign-in required to reconnect.", True)
    if u_status == "needs_verification" or bool((usage or {}).get("needs_verification")):
        return ("Verification required", u_err or "Provider requires browser verification in Orb.", True)
    if not (account.get("uses_oauth") or account.get("has_oauth")) and "no active" in u_note.lower():
        return ("", "", False)
    if u_err and not normalize_provider_windows(ptype, usage):
        if not (account.get("uses_oauth") or account.get("has_oauth")) and ptype not in ("zai", "muse-code"):
            return ("", "", False)
        return ("Limits unavailable", u_err, False)
    if bool((usage or {}).get("stale")):
        return ("", u_err or "Showing cached usage from Orb Core.", False)
    return ("", "", False)


def order_orb_accounts(accounts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    indexed = list(enumerate(accounts))
    indexed.sort(
        key=lambda pair: (
            int(pair[1]["priority"]) if isinstance(pair[1].get("priority"), int) else 1_000_000,
            pair[0],
        )
    )
    return [item for _, item in indexed]


def max_window_percent_100(limits: list[dict[str, Any]]) -> float:
    best = 0.0
    for w in limits:
        title = str(w.get("title") or "")
        # Only base windows drive failover unless there are only scoped windows
        if title in ("Session", "Weekly", "Monthly") or len(limits) <= 2:
            best = max(best, float(w.get("percent") or 0.0) * 100.0)
    return best


def classify_model_to_omarchy_id(model_name: str, provider_hint: str = "") -> str:
    p_low = provider_hint.strip().lower()
    if p_low in ORB_PROVIDER_MAP:
        return ORB_PROVIDER_MAP[p_low][0]
    if p_low in CLOUD_PROVIDER_MAP:
        return CLOUD_PROVIDER_MAP[p_low][0]

    m = model_name.strip().lower()
    if "/" in m:
        prefix, rest = m.split("/", 1)
        if prefix in ORB_PROVIDER_MAP:
            return ORB_PROVIDER_MAP[prefix][0]
        m = rest

    if m.startswith("claude") or "anthropic" in m or "sonnet" in m or "opus" in m or "haiku" in m or "fable" in m:
        return "claude"
    if m.startswith(("gpt-", "o1", "o3", "o4", "codex")):
        return "codex"
    if m.startswith("gemini") or "antigravity" in m:
        return "agy"
    if m.startswith("grok") or "xai" in m:
        return "grok"
    if "kimi" in m or "moonshot" in m:
        return "kimi"
    if "mistral" in m or "codestral" in m or "devstral" in m or "ministral" in m:
        return "vibe"
    if "minimax" in m:
        return "minimax"
    if m.startswith("glm") or "zhipu" in m or "zai" in m:
        return "zai"
    if "muse" in m:
        return "muse"
    if "deepseek" in m:
        return "deepseek"
    if "qwen" in m:
        return "qwen"
    if "hermes" in m or "paloma" in m:
        return "hermes"
    return "opencode"


def build_telemetry_by_agent(
    summary: dict[str, Any] | None,
    daily_history: dict[str, dict[str, int]] | None = None,
) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, int]]]:
    """Project Orb's `/api/ai/usage/summary` onto per-Omarchy-agent telemetry."""
    today_date = dt.datetime.now(dt.timezone.utc).date()
    today_str = today_date.isoformat()
    cutoff_str = (today_date - dt.timedelta(days=14)).isoformat()
    recent_dates = [(today_date - dt.timedelta(days=offset)).isoformat() for offset in range(6, -1, -1)]

    merged_days: dict[str, dict[str, int]] = {}
    if isinstance(daily_history, dict):
        for k, v in daily_history.items():
            if isinstance(k, str) and k >= cutoff_str and isinstance(v, dict):
                merged_days[k] = {
                    "tokens": int(v.get("tokens") or 0),
                    "requests": int(v.get("requests") or 0),
                }

    if not isinstance(summary, dict):
        return {}, merged_days

    buckets: dict[str, dict[str, Any]] = {}

    def ensure(agent_id: str) -> dict[str, Any]:
        if agent_id not in buckets:
            buckets[agent_id] = {
                "todayPrompts": 0,
                "todaySessions": 0,
                "todayTotalTokens": 0,
                "todayTokensByModel": {},
                "totalPrompts": 0,
                "totalSessions": 0,
                "modelUsage": {},
                "_modelShareTokens": 0,
            }
        return buckets[agent_id]

    by_model = summary.get("by_model")
    if isinstance(by_model, list):
        for row in by_model:
            if not isinstance(row, dict):
                continue
            model_id = str(row.get("model") or row.get("key") or "unknown")
            prov_hint = str(row.get("provider") or "")
            ag_id = classify_model_to_omarchy_id(model_id, prov_hint)
            b = ensure(ag_id)
            inp = int(row.get("input_tokens") or 0)
            out_t = int(row.get("output_tokens") or 0)
            cc = int(row.get("cache_creation_tokens") or 0)
            cr = int(row.get("cache_read_tokens") or 0)
            tot = int(row.get("total_tokens") or (inp + out_t + cc + cr))
            reqs = int(row.get("requests") or 0)
            b["totalPrompts"] += reqs
            b["_modelShareTokens"] += tot
            mu = b["modelUsage"].setdefault(
                model_id,
                {
                    "inputTokens": 0,
                    "outputTokens": 0,
                    "cacheReadInputTokens": 0,
                    "cacheCreationInputTokens": 0,
                },
            )
            mu["inputTokens"] += inp
            mu["outputTokens"] += out_t
            mu["cacheReadInputTokens"] += cr
            mu["cacheCreationInputTokens"] += cc

    # Also incorporate `by_provider` if any provider had requests without model match
    by_provider = summary.get("by_provider")
    if isinstance(by_provider, list):
        for row in by_provider:
            if not isinstance(row, dict):
                continue
            pkey = str(row.get("provider") or row.get("key") or "")
            ag_id = classify_model_to_omarchy_id("", pkey)
            inp = int(row.get("input_tokens") or 0)
            out_t = int(row.get("output_tokens") or 0)
            cc = int(row.get("cache_creation_tokens") or 0)
            cr = int(row.get("cache_read_tokens") or 0)
            tot = int(row.get("total_tokens") or (inp + out_t + cc + cr))
            reqs = int(row.get("requests") or 0)
            b = ensure(ag_id)
            if b["totalPrompts"] == 0 and reqs > 0:
                b["totalPrompts"] = reqs
            if b["_modelShareTokens"] == 0 and tot > 0:
                b["_modelShareTokens"] = tot

    # Merge `by_day` into rolling `merged_days` without shrinking prior full days from a 24h tail
    by_day_raw = summary.get("by_day")
    if isinstance(by_day_raw, list):
        for drow in by_day_raw:
            if not isinstance(drow, dict):
                continue
            d_str = str(drow.get("day") or drow.get("date") or "")
            if not d_str or d_str < cutoff_str:
                continue
            inp = int(drow.get("input_tokens") or 0)
            out_t = int(drow.get("output_tokens") or 0)
            cc = int(drow.get("cache_creation_tokens") or 0)
            cr = int(drow.get("cache_read_tokens") or 0)
            d_tok = int(drow.get("total_tokens") or (inp + out_t + cc + cr))
            d_req = int(drow.get("requests") or 0)
            prev = merged_days.get(d_str)
            if prev is None or d_str == today_str or d_tok >= prev.get("tokens", 0):
                merged_days[d_str] = {"tokens": d_tok, "requests": d_req}

    active_dates_all = [
        d_str
        for d_str, info in sorted(merged_days.items())
        if info.get("tokens", 0) > 0 or info.get("requests", 0) > 0
    ]

    # Mission counts (`by_mission`)
    by_mission = summary.get("by_mission")
    mission_count = len(by_mission) if isinstance(by_mission, list) else 0

    agent_ids = sorted(buckets.keys())
    if not agent_ids:
        return {}, merged_days

    weights: dict[str, float] = {}
    denom = float(sum(buckets[a]["_modelShareTokens"] for a in agent_ids))
    if denom > 0:
        for a in agent_ids:
            weights[a] = buckets[a]["_modelShareTokens"] / denom
    else:
        for a in agent_ids:
            weights[a] = 1.0 / len(agent_ids)

    # Allocate integer daily tokens with largest-remainder so sum across agents == exact day total
    def split_exact(total_val: int) -> dict[str, int]:
        if total_val <= 0:
            return {a: 0 for a in agent_ids}
        raw_alloc = {a: total_val * weights[a] for a in agent_ids}
        floored = {a: int(raw_alloc[a]) for a in agent_ids}
        rem = total_val - sum(floored.values())
        if rem > 0:
            order = sorted(agent_ids, key=lambda a: (raw_alloc[a] - floored[a], weights[a]), reverse=True)
            for a in order[:rem]:
                floored[a] += 1
        return floored

    per_day_agent_tokens: dict[str, dict[str, int]] = {}
    for d_str in recent_dates:
        d_tot = merged_days.get(d_str, {}).get("tokens", 0)
        per_day_agent_tokens[d_str] = split_exact(d_tot)

    today_info = merged_days.get(today_str, {"tokens": 0, "requests": 0})
    today_tok_alloc = split_exact(today_info["tokens"])
    today_req_alloc = split_exact(today_info["requests"])
    session_alloc = split_exact(mission_count)

    out: dict[str, dict[str, Any]] = {}
    for a in agent_ids:
        b = buckets[a]
        t_today = today_tok_alloc[a]
        # Proportionally attribute today's tokens across this agent's models
        today_by_model: dict[str, int] = {}
        ag_tot = b["_modelShareTokens"]
        if t_today > 0 and ag_tot > 0:
            for m_id, m_bucket in b["modelUsage"].items():
                m_tot = (
                    int(m_bucket["inputTokens"])
                    + int(m_bucket["outputTokens"])
                    + int(m_bucket["cacheReadInputTokens"])
                    + int(m_bucket["cacheCreationInputTokens"])
                )
                if m_tot > 0:
                    share = round(t_today * (m_tot / ag_tot))
                    if share > 0:
                        today_by_model[m_id] = share

        recent_days = [
            {"date": d_str, "messageCount": per_day_agent_tokens[d_str][a]}
            for d_str in recent_dates
        ]
        ag_dates = [d for d in active_dates_all if b["_modelShareTokens"] > 0]
        out[a] = {
            "todayPrompts": today_req_alloc[a],
            "todaySessions": max(1 if today_req_alloc[a] > 0 else 0, min(today_req_alloc[a], max(1, session_alloc[a]))),
            "todayTotalTokens": t_today,
            "todayTokensByModel": today_by_model,
            "recentDays": recent_days,
            "totalPrompts": b["totalPrompts"],
            "totalSessions": session_alloc[a],
            "activeDays": len(ag_dates),
            "activeDates": ag_dates,
            "modelUsage": b["modelUsage"],
        }
    return out, merged_days


def mark_existing_orb_records_stale(reason: str, target_agents: set[str] | None, excluded: set[str]) -> None:
    u_dir = usage_dir()
    if not u_dir.is_dir():
        return
    for path in u_dir.glob("*.json"):
        ag_id = path.stem
        if ag_id in excluded or (target_agents and ag_id not in target_agents):
            continue
        rec = load_json_safe(path, None)
        if not isinstance(rec, dict) or not rec.get("orbManaged"):
            continue
        rec["limitsStale"] = True
        rec["retryAdvised"] = True
        if not rec.get("authHelpText"):
            rec["authHelpText"] = reason
        atomic_write_json(path, rec)


def should_probe_account(account: dict[str, Any], cached_usage: dict[str, Any] | None, force: bool) -> bool:
    if not account.get("enabled", True) or account.get("user_enabled") is False:
        return False
    if force:
        return True
    if cached_usage and cached_usage.get("stale") is False:
        return False
    ptype = str(account.get("provider_type") or "")
    uses_oauth = bool(account.get("uses_oauth"))
    if ptype in ("kimi", "minimax", "zai", "muse-code", "mistral", "antigravity"):
        return True
    if uses_oauth and ptype in ("openai", "xai"):
        return True
    if uses_oauth and ptype == "anthropic" and not cached_usage:
        return True
    return False


def cmd_usage_update(argv: list[str]) -> int:
    force = False
    limits_only = False
    orb_only = os.environ.get("OMARCHY_ORB_ONLY") == "1"
    excluded: set[str] = set()
    targets: list[str] = []
    upstream_passthrough_argv: list[str] = []

    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--force":
            force = True
            upstream_passthrough_argv.append(arg)
        elif arg == "--limits-only":
            limits_only = True
            upstream_passthrough_argv.append(arg)
        elif arg == "--orb-only":
            orb_only = True
        elif arg == "--except" and i + 1 < len(argv):
            i += 1
            excluded.add(argv[i])
            upstream_passthrough_argv.extend(["--except", argv[i]])
        elif not arg.startswith("-"):
            targets.append(arg)
            upstream_passthrough_argv.append(arg)
        else:
            upstream_passthrough_argv.append(arg)
        i += 1

    target_set = set(targets) if targets else None

    conn = load_orb_connection()
    if conn is None:
        return run_upstream("omarchy-agent-usage-update", upstream_passthrough_argv)

    api_url, token = conn
    state_root = omarchy_agents_state_dir()
    state_root.mkdir(parents=True, exist_ok=True)
    lock_file = state_root / "orb-sync.lock"

    with open(lock_file, "w", encoding="utf-8") as lfh:
        deadline = time.monotonic() + 8.0
        locked = False
        while time.monotonic() < deadline:
            try:
                fcntl.flock(lfh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
                break
            except BlockingIOError:
                time.sleep(0.1)
        if not locked:
            return 0

        cache = load_json_safe(cache_path(), {})
        if not isinstance(cache, dict):
            cache = {}
        switch_cfg_map: dict[str, dict[str, Any]] = cache.setdefault("accountSwitch", {})

        client = OrbClient(api_url, token, timeout=10.0)

        # Fetch core Orb endpoints concurrently
        need_summary = True
        cached_sum_wrap = cache.get("summaryCache")
        summary_data: dict[str, Any] | None = None
        if (
            limits_only
            and not force
            and isinstance(cached_sum_wrap, dict)
            and cached_sum_wrap.get("apiUrl") == api_url
            and (time.time() - float(cached_sum_wrap.get("fetchedAt") or 0)) < SUMMARY_CACHE_TTL_SECS
            and isinstance(cached_sum_wrap.get("summary"), dict)
        ):
            summary_data = cached_sum_wrap["summary"]
            need_summary = False

        def safe_get(path: str, tmo: float = 10.0) -> tuple[bool, Any]:
            try:
                return True, client.request_json("GET", path, timeout=tmo)
            except Exception as exc:
                return False, exc

        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            f_providers = pool.submit(safe_get, "/api/ai/providers", 10.0)
            f_usage = pool.submit(safe_get, "/api/ai/providers/usage", 10.0)
            f_health = pool.submit(safe_get, "/api/model-routing/health", 8.0)
            f_cloud_acc = pool.submit(safe_get, "/api/cloud/accounts", 8.0)
            f_cloud_use = pool.submit(safe_get, "/api/cloud/usage", 8.0)
            f_summary = pool.submit(safe_get, "/api/ai/usage/summary?window=24h", 10.0) if need_summary else None

            ok_prov, res_prov = f_providers.result()
            ok_usage, res_usage = f_usage.result()
            ok_health, res_health = f_health.result()
            ok_cacc, res_cacc = f_cloud_acc.result()
            ok_cuse, res_cuse = f_cloud_use.result()
            if f_summary is not None:
                ok_sum, res_sum = f_summary.result()
                if ok_sum and isinstance(res_sum, dict):
                    summary_data = res_sum
                    cache["summaryCache"] = {
                        "fetchedAt": time.time(),
                        "apiUrl": api_url,
                        "summary": summary_data,
                    }
                elif isinstance(cached_sum_wrap, dict) and isinstance(cached_sum_wrap.get("summary"), dict):
                    summary_data = cached_sum_wrap["summary"]

        if not ok_prov:
            err_txt = "Orb Core authentication expired — reconnect in Orb" if isinstance(res_prov, OrbApiError) and res_prov.status == 401 else "Orb Core unreachable — showing last synced limits"
            mark_existing_orb_records_stale(err_txt, target_set, excluded)
            return 0

        raw_providers: list[dict[str, Any]] = []
        if isinstance(res_prov, list):
            raw_providers = [p for p in res_prov if isinstance(p, dict)]
        elif isinstance(res_prov, dict) and isinstance(res_prov.get("providers"), list):
            raw_providers = [p for p in res_prov["providers"] if isinstance(p, dict)]

        usage_entries: dict[str, dict[str, Any]] = {}
        if ok_usage and isinstance(res_usage, dict):
            ent = res_usage.get("entries") if isinstance(res_usage.get("entries"), dict) else res_usage
            if isinstance(ent, dict):
                usage_entries = {str(k): v for k, v in ent.items() if isinstance(v, dict)}

        health_by_id: dict[str, dict[str, Any]] = {}
        if ok_health and isinstance(res_health, list):
            for h in res_health:
                if isinstance(h, dict):
                    hid = h.get("account_id") or h.get("provider_id") or h.get("id")
                    if hid:
                        health_by_id[str(hid)] = h

        # Probe individual stale/missing subscription accounts with bounded concurrency (4)
        probe_candidates: list[dict[str, Any]] = []
        for acc in raw_providers:
            acc_id = str(acc.get("id") or "")
            ptype = str(acc.get("provider_type") or "")
            mapped = ORB_PROVIDER_MAP.get(ptype)
            if not acc_id or not mapped:
                continue
            om_id = mapped[0]
            if om_id in excluded or (target_set and om_id not in target_set):
                continue
            if should_probe_account(acc, usage_entries.get(acc_id), force):
                probe_candidates.append(acc)

        if probe_candidates:
            def probe_one(acc_obj: dict[str, Any]) -> tuple[str, dict[str, Any] | None]:
                aid = str(acc_obj["id"])
                q = "?force=true" if force else ""
                ok_p, val_p = safe_get(f"/api/ai/providers/{urllib.parse.quote(aid, safe='')}/usage{q}", 10.0)
                if ok_p and isinstance(val_p, dict) and val_p.get("provider_type"):
                    return aid, val_p
                return aid, None

            with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(probe_candidates))) as probe_pool:
                for aid, val_p in probe_pool.map(probe_one, probe_candidates):
                    if val_p is not None:
                        usage_entries[aid] = val_p

        prev_daily_hist = cache.get("dailyHistory") if isinstance(cache.get("dailyHistory"), dict) else {}
        telemetry_by_agent, updated_daily_hist = build_telemetry_by_agent(summary_data, prev_daily_hist)
        cache["dailyHistory"] = updated_daily_hist

        # Group Orb AIProviders by Omarchy provider ID
        grouped: dict[str, list[dict[str, Any]]] = {}
        for acc in raw_providers:
            ptype = str(acc.get("provider_type") or "")
            mapped = ORB_PROVIDER_MAP.get(ptype)
            if not mapped:
                continue
            om_id = mapped[0]
            grouped.setdefault(om_id, []).append(acc)

        written_orb_ids: set[str] = set()
        u_dir = usage_dir()
        u_dir.mkdir(parents=True, exist_ok=True)
        did_autoswitch = False

        for om_id, acc_list in grouped.items():
            if om_id in excluded or (target_set and om_id not in target_set):
                written_orb_ids.add(om_id)
                continue

            ordered_accs = order_orb_accounts(acc_list)
            # Filter out purely disabled API-key stubs unless they are the only configured entry
            enabled_any = [a for a in ordered_accs if a.get("enabled", True) and a.get("user_enabled") is not False]
            if not enabled_any and not any(a.get("uses_oauth") or a.get("has_oauth") for a in ordered_accs):
                continue

            # Determine display metadata from primary provider_type
            primary_ptype = str(ordered_accs[0].get("provider_type") or "")
            _, disp_name, supports_signin = ORB_PROVIDER_MAP.get(primary_ptype, (om_id, om_id.title(), False))

            # Evaluate autoswitch if enabled and >= 2 accounts exist
            sw_cfg = switch_cfg_map.get(om_id) if isinstance(switch_cfg_map.get(om_id), dict) else {}
            sw_mode = "auto" if sw_cfg.get("mode") == "auto" else "manual"
            sw_threshold = int(sw_cfg.get("threshold") or DEFAULT_AUTOSWITCH_THRESHOLD)
            sw_threshold = max(50, min(100, sw_threshold))

            if len(ordered_accs) >= 2 and sw_mode == "auto":
                top_acc = enabled_any[0] if enabled_any else ordered_accs[0]
                top_id = str(top_acc.get("id") or "")
                top_u = usage_entries.get(top_id)
                top_h = health_by_id.get(top_id)
                _, _, top_broken = compute_account_status(top_acc, top_u, top_h)
                top_wins = normalize_provider_windows(str(top_acc.get("provider_type") or ""), top_u)
                top_pct = max_window_percent_100(top_wins)

                if top_broken or top_pct >= sw_threshold:
                    best_peer: dict[str, Any] | None = None
                    best_peer_pct = 999.0
                    for peer in enabled_any:
                        pid = str(peer.get("id") or "")
                        if pid == top_id or peer.get("provider_type") != top_acc.get("provider_type"):
                            continue
                        pu = usage_entries.get(pid)
                        ph = health_by_id.get(pid)
                        _, _, p_broken = compute_account_status(peer, pu, ph)
                        if p_broken:
                            continue
                        pwins = normalize_provider_windows(str(peer.get("provider_type") or ""), pu)
                        ppct = max_window_percent_100(pwins)
                        if ppct < sw_threshold and ppct < best_peer_pct:
                            best_peer = peer
                            best_peer_pct = ppct

                    if best_peer is not None:
                        target_id = str(best_peer["id"])
                        all_ordered_ids = [str(a["id"]) for a in order_orb_accounts(raw_providers) if a.get("id")]
                        reordered_ids = [target_id] + [aid for aid in all_ordered_ids if aid != target_id]
                        try:
                            client.request_json("POST", "/api/ai/providers/reorder", {"ids": reordered_ids}, idempotent=True)
                            ordered_accs = [best_peer] + [a for a in ordered_accs if str(a.get("id")) != target_id]
                            enabled_any = [a for a in ordered_accs if a.get("enabled", True) and a.get("user_enabled") is not False]
                            did_autoswitch = True
                            peer_lbl = str(best_peer.get("name") or best_peer.get("account_email") or disp_name)
                            switch_reason = (
                                "Previous account sign-in expired."
                                if top_broken
                                else f"Previous account reached {round(top_pct)}% (auto threshold {sw_threshold}%)."
                            )
                            send_notification(
                                f"{disp_name}: switched to {peer_lbl}",
                                switch_reason,
                            )
                        except Exception:
                            pass

            # Match Orb Core's router: prefer the first enabled non-broken account as active
            healthy_enabled = [
                a
                for a in enabled_any
                if not compute_account_status(
                    a,
                    usage_entries.get(str(a.get("id") or "")),
                    health_by_id.get(str(a.get("id") or "")),
                )[2]
            ]
            active_acc = healthy_enabled[0] if healthy_enabled else (enabled_any[0] if enabled_any else ordered_accs[0])
            active_id = str(active_acc.get("id") or "")
            active_ptype = str(active_acc.get("provider_type") or primary_ptype)
            active_u = usage_entries.get(active_id)
            active_h = health_by_id.get(active_id)
            status_txt, help_txt, _ = compute_account_status(active_acc, active_u, active_h)
            active_limits = normalize_provider_windows(active_ptype, active_u)
            active_resets = extract_reset_credits(active_u)
            active_balance = extract_balance(active_u)

            raw_plan = extract_plan_label(
                active_ptype,
                active_acc,
                active_u,
                has_limits=bool(active_limits),
                has_balance=(active_balance is not None),
            )

            fetched_ms = iso_to_ms((active_u or {}).get("fetched_at")) or now_ms()
            limits_stale = bool((active_u or {}).get("stale"))

            accounts_payload: list[dict[str, Any]] = []
            if len(ordered_accs) >= 2:
                for idx_a, acc_item in enumerate(ordered_accs):
                    aid = str(acc_item.get("id") or "")
                    aptype = str(acc_item.get("provider_type") or primary_ptype)
                    au = usage_entries.get(aid)
                    ah = health_by_id.get(aid)
                    ast_txt, ahelp_txt, _ = compute_account_status(acc_item, au, ah)
                    alims = normalize_provider_windows(aptype, au)
                    email = str(acc_item.get("account_email") or (au or {}).get("account_email") or "").strip()
                    lbl = str(acc_item.get("name") or email or f"Account {idx_a + 1}").strip()
                    aplan = extract_plan_label(
                        aptype,
                        acc_item,
                        au,
                        has_limits=bool(alims),
                        has_balance=(extract_balance(au) is not None),
                    )
                    accounts_payload.append(
                        {
                            "id": aid,
                            "label": lbl,
                            "email": email,
                            "plan": aplan,
                            "active": aid == active_id,
                            "primary": idx_a == 0,
                            "limits": alims,
                            "stale": bool((au or {}).get("stale")),
                            "fetchedAt": iso_to_ms((au or {}).get("fetched_at")) or now_ms(),
                            "retryAdvised": False,
                            "usageStatusText": ast_txt,
                            "authHelpText": ahelp_txt,
                            "resetCredits": extract_reset_credits(au),
                        }
                    )

            telem = telemetry_by_agent.get(
                om_id,
                {
                    "todayPrompts": 0,
                    "todaySessions": 0,
                    "todayTotalTokens": 0,
                    "todayTokensByModel": {},
                    "recentDays": [
                        {"date": (dt.date.today() - dt.timedelta(days=o)).isoformat(), "messageCount": 0}
                        for o in range(6, -1, -1)
                    ],
                    "totalPrompts": 0,
                    "totalSessions": 0,
                    "activeDays": 0,
                    "activeDates": [],
                    "modelUsage": {},
                },
            )

            record: dict[str, Any] = {
                "schemaVersion": SCHEMA_VERSION,
                "id": om_id,
                "name": disp_name,
                "updatedAt": now_utc_iso(),
                "ready": True,
                "orbManaged": True,
                "orbSignIn": supports_signin,
                "scope": "account",
                "hasLocalStats": True,
                "hasPromptStats": True,
                "tierLabel": raw_plan,
                "usageStatusText": status_txt,
                "authHelpText": help_txt,
                "limits": active_limits,
                "limitsStale": limits_stale,
                "limitsFetchedAt": fetched_ms,
                "retryAdvised": False,
                "resetCredits": active_resets,
                "balance": active_balance,
                "accounts": accounts_payload,
                "accountSwitch": {
                    "mode": sw_mode,
                    "threshold": sw_threshold,
                }
                if len(accounts_payload) >= 2
                else None,
                **telem,
            }
            atomic_write_json(u_dir / f"{om_id}.json", record)
            written_orb_ids.add(om_id)

        # Cloud Agents (`cursor_cloud`, `grok_bot`, `hermes`)
        cloud_accs = res_cacc if (ok_cacc and isinstance(res_cacc, list)) else []
        cloud_usages: dict[str, dict[str, Any]] = {}
        if ok_cuse and isinstance(res_cuse, list):
            for cu in res_cuse:
                if isinstance(cu, dict) and cu.get("provider"):
                    cloud_usages[str(cu["provider"])] = cu

        for cacc in cloud_accs:
            if not isinstance(cacc, dict):
                continue
            cprov = str(cacc.get("provider") or "")
            mapped_c = CLOUD_PROVIDER_MAP.get(cprov)
            if not mapped_c:
                continue
            om_id, disp_name = mapped_c
            if om_id in written_orb_ids or om_id in excluded or (target_set and om_id not in target_set):
                continue
            if not (cacc.get("available") or cacc.get("configured")):
                continue

            cu = cloud_usages.get(cprov, {})
            c_limits: list[dict[str, Any]] = []
            if cu.get("plan_percent_used") is not None:
                c_limits.append(
                    {
                        "label": "Monthly allowance",
                        "title": "Monthly",
                        "percent": clamp_unit(cu.get("plan_percent_used")),
                        "resetsAt": str(cu.get("reset_date") or ""),
                    }
                )
            c_plan = clean_plan_label(cu.get("membership_type")) or ("Ready" if cacc.get("available") else "Configured")
            c_err = str(cu.get("error") or cacc.get("reason") or "").strip()
            telem = telemetry_by_agent.get(
                om_id,
                {
                    "todayPrompts": 0,
                    "todaySessions": 0,
                    "todayTotalTokens": 0,
                    "todayTokensByModel": {},
                    "recentDays": [
                        {"date": (dt.date.today() - dt.timedelta(days=o)).isoformat(), "messageCount": 0}
                        for o in range(6, -1, -1)
                    ],
                    "totalPrompts": 0,
                    "totalSessions": 0,
                    "activeDays": 0,
                    "activeDates": [],
                    "modelUsage": {},
                },
            )
            record = {
                "schemaVersion": SCHEMA_VERSION,
                "id": om_id,
                "name": disp_name,
                "updatedAt": now_utc_iso(),
                "ready": True,
                "orbManaged": True,
                "orbSignIn": False,
                "scope": "account",
                "hasLocalStats": True,
                "hasPromptStats": True,
                "tierLabel": c_plan,
                "usageStatusText": "Unavailable" if (not cacc.get("available") and c_err) else "",
                "authHelpText": c_err,
                "limits": c_limits,
                "limitsStale": False,
                "limitsFetchedAt": now_ms(),
                "retryAdvised": False,
                "resetCredits": None,
                "balance": None,
                "accounts": [],
                "accountSwitch": None,
                **telem,
            }
            atomic_write_json(u_dir / f"{om_id}.json", record)
            written_orb_ids.add(om_id)

        # Emit telemetry-only records for routed models whose agent family has no direct
        # subscription row (`tierLabel == ""` keeps Subscriptions clean while Hero totals match 100%).
        for t_id, telem in telemetry_by_agent.items():
            if t_id in written_orb_ids or t_id in excluded or (target_set and t_id not in target_set):
                continue
            disp_name = t_id.title()
            for _, (cand_id, cand_disp, _) in ORB_PROVIDER_MAP.items():
                if cand_id == t_id:
                    disp_name = cand_disp
                    break
            record = {
                "schemaVersion": SCHEMA_VERSION,
                "id": t_id,
                "name": disp_name,
                "updatedAt": now_utc_iso(),
                "ready": True,
                "orbManaged": True,
                "orbSignIn": False,
                "scope": "account",
                "hasLocalStats": True,
                "hasPromptStats": True,
                "tierLabel": "",
                "usageStatusText": "",
                "authHelpText": "",
                "limits": [],
                "limitsStale": False,
                "limitsFetchedAt": now_ms(),
                "retryAdvised": False,
                "resetCredits": None,
                "balance": None,
                "accounts": [],
                "accountSwitch": None,
                **telem,
            }
            atomic_write_json(u_dir / f"{t_id}.json", record)
            written_orb_ids.add(t_id)

        # Clean up Orb-managed files for providers removed from Orb, and when `--orb-only`
        # is active also prune stale non-Orb stub records left by upstream collectors.
        if target_set is None:
            for existing_file in u_dir.glob("*.json"):
                eid = existing_file.stem
                if eid in excluded or eid in written_orb_ids:
                    continue
                rec = load_json_safe(existing_file, None)
                if orb_only or (isinstance(rec, dict) and rec.get("orbManaged")):
                    try:
                        existing_file.unlink()
                    except OSError:
                        pass

        # Cache login-capable providers for fast `--check`
        cache["configuredAgents"] = sorted(written_orb_ids)
        atomic_write_json(cache_path(), cache, mode=0o600)

        if did_autoswitch:
            emit_desktop_command({"action": "providers-refresh"})

        # Run upstream collector only when `--orb-only` is disabled
        if not orb_only:
            if target_set is None:
                up_args = ["--limits-only"] if limits_only else []
                for wid in sorted(written_orb_ids | excluded):
                    up_args.extend(["--except", wid])
                run_upstream("omarchy-agent-usage-update", up_args)
            else:
                rem_targets = [t for t in targets if t not in written_orb_ids and t not in excluded]
                if rem_targets:
                    up_args = (["--limits-only"] if limits_only else []) + rem_targets
                    run_upstream("omarchy-agent-usage-update", up_args)

    return 0


def resolve_provider_accounts(
    raw_providers: list[dict[str, Any]],
    omarchy_provider: str,
) -> list[dict[str, Any]]:
    orb_types = set(OMARCHY_TO_ORB_TYPES.get(omarchy_provider, [omarchy_provider]))
    matched = [p for p in raw_providers if isinstance(p, dict) and str(p.get("provider_type") or "") in orb_types]
    return order_orb_accounts(matched)


def cmd_account_use(argv: list[str]) -> int:
    conn = load_orb_connection()
    if conn is None:
        return run_upstream("omarchy-agent-account-use", argv)

    provider = argv[0] if len(argv) >= 1 else "claude"
    target_spec = argv[1] if len(argv) >= 2 else "next"

    api_url, token = conn
    client = OrbClient(api_url, token)
    raw = client.request_json("GET", "/api/ai/providers")
    all_providers = [p for p in (raw if isinstance(raw, list) else raw.get("providers", [])) if isinstance(p, dict)]
    peers = resolve_provider_accounts(all_providers, provider)
    if len(peers) < 2:
        print(f"Only {len(peers)} {provider} account configured in Orb.", file=sys.stderr)
        return 1

    enabled_peers = [p for p in peers if p.get("enabled", True) and p.get("user_enabled") is not False]
    current_active_id = str((enabled_peers[0] if enabled_peers else peers[0]).get("id") or "")
    existing_rec = load_json_safe(usage_dir() / f"{provider}.json", None)
    if isinstance(existing_rec, dict) and isinstance(existing_rec.get("accounts"), list):
        for acc_row in existing_rec["accounts"]:
            if isinstance(acc_row, dict) and acc_row.get("active") and acc_row.get("id"):
                current_active_id = str(acc_row["id"])
                break

    chosen: dict[str, Any] | None = None
    if target_spec in ("", "next"):
        cur_idx = next((idx for idx, p in enumerate(peers) if str(p.get("id")) == current_active_id), 0)
        chosen = peers[(cur_idx + 1) % len(peers)]
    else:
        spec_low = target_spec.strip().lower()
        for p in peers:
            if (
                str(p.get("id") or "") == target_spec
                or str(p.get("name") or "").strip().lower() == spec_low
                or str(p.get("account_email") or "").strip().lower() == spec_low
            ):
                chosen = p
                break

    if chosen is None:
        print(f"Account '{target_spec}' not found for {provider}.", file=sys.stderr)
        return 1

    chosen_id = str(chosen["id"])
    # Ensure chosen account is enabled in Orb
    if not chosen.get("enabled", True) or chosen.get("user_enabled") is False:
        try:
            client.request_json("PUT", f"/api/ai/providers/{urllib.parse.quote(chosen_id, safe='')}", {"enabled": True})
        except OrbApiError as exc:
            if exc.status == 403:
                client.request_json(
                    "PUT",
                    f"/api/ai/providers/{urllib.parse.quote(chosen_id, safe='')}/preference",
                    {"enabled": True},
                )
            else:
                raise

    # Move chosen_id to priority 0 ahead of all peers
    ordered_all = [str(p["id"]) for p in order_orb_accounts(all_providers) if p.get("id")]
    new_order = [chosen_id] + [pid for pid in ordered_all if pid != chosen_id]
    client.request_json("POST", "/api/ai/providers/reorder", {"ids": new_order}, idempotent=True)

    cmd_usage_update(["--limits-only", provider])
    emit_desktop_command({"action": "providers-refresh"})

    disp_name = ORB_PROVIDER_MAP.get(str(chosen.get("provider_type") or ""), (provider, provider.title(), False))[1]
    lbl = str(chosen.get("name") or chosen.get("account_email") or chosen_id)
    send_notification(f"{disp_name}: using {lbl}", "Updated active account priority in Orb Core.")
    return 0


def cmd_account_mode(argv: list[str]) -> int:
    conn = load_orb_connection()
    if conn is None:
        return run_upstream("omarchy-agent-account-mode", argv)

    provider = "claude"
    mode_arg: str | None = None
    threshold_arg: int | None = None

    args = list(argv)
    if args and args[0] not in ("manual", "auto") and not args[0].isdigit():
        provider = args.pop(0)
    if args:
        if args[0] in ("manual", "auto"):
            mode_arg = args.pop(0)
        else:
            print(f"Invalid mode '{args[0]}' (expected manual or auto).", file=sys.stderr)
            return 1
    if args:
        try:
            threshold_arg = max(50, min(100, int(args.pop(0))))
        except ValueError:
            print("Threshold must be an integer between 50 and 100.", file=sys.stderr)
            return 1

    cache = load_json_safe(cache_path(), {})
    if not isinstance(cache, dict):
        cache = {}
    sw_map = cache.setdefault("accountSwitch", {})
    cur = sw_map.get(provider) if isinstance(sw_map.get(provider), dict) else {}
    cur_mode = "auto" if cur.get("mode") == "auto" else "manual"
    cur_thresh = int(cur.get("threshold") or DEFAULT_AUTOSWITCH_THRESHOLD)

    if mode_arg is None:
        print(f"{cur_mode} {cur_thresh}")
        return 0

    next_thresh = threshold_arg if threshold_arg is not None else cur_thresh
    sw_map[provider] = {"mode": mode_arg, "threshold": next_thresh}
    atomic_write_json(cache_path(), cache, mode=0o600)

    # Immediately update usage/<provider>.json so the panel toggle reflects it right away
    rec_path = usage_dir() / f"{provider}.json"
    rec = load_json_safe(rec_path, None)
    if isinstance(rec, dict):
        if isinstance(rec.get("accounts"), list) and len(rec["accounts"]) >= 2:
            rec["accountSwitch"] = {"mode": mode_arg, "threshold": next_thresh}
            atomic_write_json(rec_path, rec)

    print(f"{mode_arg} {next_thresh}")
    return 0


def cmd_account_rename(argv: list[str]) -> int:
    conn = load_orb_connection()
    if conn is None:
        return run_upstream("omarchy-agent-account-rename", argv)

    if len(argv) == 2:
        provider, account_id, label = "claude", argv[0], argv[1]
    elif len(argv) >= 3:
        provider, account_id, label = argv[0], argv[1], " ".join(argv[2:]).strip()
    else:
        print("Usage: omarchy-agent-account-rename [provider] <account_id> <label>", file=sys.stderr)
        return 1

    if not label:
        print("Account label cannot be empty.", file=sys.stderr)
        return 1

    api_url, token = conn
    client = OrbClient(api_url, token)
    client.request_json(
        "PUT",
        f"/api/ai/providers/{urllib.parse.quote(account_id, safe='')}",
        {"name": label},
    )
    cmd_usage_update(["--limits-only", provider])
    emit_desktop_command({"action": "providers-refresh"})
    return 0


def cmd_account_add(argv: list[str]) -> int:
    conn = load_orb_connection()
    if conn is None:
        return run_upstream("omarchy-agent-account-add", argv)

    check_mode = False
    events_mode = False
    reauth_target: str | None = None
    positional: list[str] = []

    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--check":
            check_mode = True
        elif a == "--events":
            events_mode = True
        elif a == "--reauth" and i + 1 < len(argv):
            i += 1
            reauth_target = argv[i]
        elif not a.startswith("-"):
            positional.append(a)
        i += 1

    api_url, token = conn
    client = OrbClient(api_url, token, timeout=10.0)

    if check_mode:
        configured: set[str] = set()
        try:
            raw = client.request_json("GET", "/api/ai/providers", timeout=5.0)
            plist = raw if isinstance(raw, list) else raw.get("providers", [])
            for p in plist:
                if not isinstance(p, dict):
                    continue
                ptype = str(p.get("provider_type") or "")
                mapped = ORB_PROVIDER_MAP.get(ptype)
                if mapped and (p.get("uses_oauth") or p.get("has_oauth")):
                    configured.add(mapped[0])
        except Exception:
            cache = load_json_safe(cache_path(), {})
            for cid in cache.get("configuredAgents", []) if isinstance(cache, dict) else []:
                configured.add(str(cid))

        for om_id in ("claude", "codex", "grok", "agy", "kimi", "vibe"):
            state = "additional" if om_id in configured else "first"
            print(f"{om_id} {state}", flush=True)
        return 0

    provider = positional[0] if len(positional) >= 1 else "claude"
    label = " ".join(positional[1:]).strip() if len(positional) >= 2 else ""

    if provider not in OMARCHY_TO_ORB_LOGIN:
        return run_upstream("omarchy-agent-account-add", argv)

    orb_type, disp_name = OMARCHY_TO_ORB_LOGIN[provider]

    def emit_tag(kind: str, msg: str) -> None:
        if events_mode:
            print(f"@@omarchy {kind} {msg}", flush=True)
        else:
            stream = sys.stderr if kind == "error" else sys.stdout
            print(msg, file=stream, flush=True)

    try:
        raw_before = client.request_json("GET", "/api/ai/providers")
        before_list = [p for p in (raw_before if isinstance(raw_before, list) else raw_before.get("providers", [])) if isinstance(p, dict)]
    except Exception as exc:
        emit_tag("error", f"Could not reach Orb Core: {exc}")
        return 1

    peers_before = resolve_provider_accounts(before_list, provider)
    before_ids = {str(p.get("id")) for p in peers_before if p.get("id")}

    provider_id_param: str | None = None
    open_private = len(peers_before) > 0
    if reauth_target is not None:
        if reauth_target == ":primary":
            if peers_before:
                provider_id_param = str(peers_before[0].get("id") or "") or None
            open_private = False
        else:
            provider_id_param = reauth_target
            open_private = bool(peers_before and str(peers_before[0].get("id")) != reauth_target)

    login_base = "/api/ai/providers/mistral-login" if orb_type == "mistral" else "/api/ai/providers/cli-proxy-login"
    start_body: dict[str, Any] = {} if orb_type == "mistral" else {"provider": orb_type}
    if provider_id_param:
        start_body["provider_id"] = provider_id_param

    try:
        started = client.request_json("POST", login_base, start_body, timeout=15.0)
    except Exception as exc:
        emit_tag("error", f"Could not start {disp_name} sign-in in Orb: {exc}")
        return 1

    if not isinstance(started, dict) or not started.get("session_id"):
        emit_tag("error", f"Unexpected login response from Orb Core for {disp_name}.")
        return 1

    session_id = str(started["session_id"])
    auth_url = str(started.get("auth_url") or "").strip()
    flow = str(started.get("flow") or "")
    instructions = str(started.get("instructions") or "").strip()

    cancelled = False

    def handle_cancel(_sig: int, _frame: Any) -> None:
        nonlocal cancelled
        cancelled = True
        try:
            client.request_json("DELETE", f"{login_base}/{urllib.parse.quote(session_id, safe='')}", timeout=4.0)
        except Exception:
            pass
        sys.exit(130)

    signal.signal(signal.SIGTERM, handle_cancel)
    signal.signal(signal.SIGINT, handle_cancel)

    if auth_url:
        # Plain URL line lets Panel.qml record `addUrl` for "Open sign-in page again"
        print(auth_url, flush=True)
        browser_bin = shutil.which("omarchy-launch-browser") or shutil.which("xdg-open")
        if browser_bin:
            b_args = [browser_bin]
            if open_private and os.path.basename(browser_bin) == "omarchy-launch-browser":
                b_args.append("--private")
            b_args.append(auth_url)
            try:
                subprocess.Popen(
                    b_args,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except OSError:
                pass

    if orb_type != "mistral":
        # Hint Panel.qml to show the callback URL / code paste box for remote Core OAuth
        print("Paste code or callback URL if prompted:", flush=True)

    status_msg = instructions or f"Complete {disp_name} sign-in in your browser…"
    emit_tag("status", status_msg)

    deadline = time.monotonic() + 600.0
    while time.monotonic() < deadline and not cancelled:
        # Watch stdin for pasted localhost callback URL or authorization code
        try:
            rlist, _, _ = select.select([sys.stdin], [], [], 1.5)
        except Exception:
            rlist = []
            time.sleep(1.5)

        if rlist:
            pasted = sys.stdin.readline()
            if pasted:
                pasted_clean = pasted.strip()
                if pasted_clean:
                    try:
                        client.request_json(
                            "POST",
                            f"{login_base}/{urllib.parse.quote(session_id, safe='')}/callback",
                            {"url": pasted_clean},
                            timeout=12.0,
                        )
                        emit_tag("status", f"Verifying {disp_name} credentials with Orb Core…")
                    except Exception as exc:
                        emit_tag("status", f"Callback error ({exc}); waiting or paste full redirect URL…")

        try:
            poll = client.request_json(
                "GET",
                f"{login_base}/{urllib.parse.quote(session_id, safe='')}",
                timeout=10.0,
            )
        except Exception:
            continue

        if not isinstance(poll, dict):
            continue

        new_url = str(poll.get("auth_url") or "").strip()
        if new_url and not auth_url:
            auth_url = new_url
            print(auth_url, flush=True)

        st = str(poll.get("status") or "")
        msg = str(poll.get("message") or "").strip()
        if st == "completing":
            emit_tag("status", msg or f"Finishing {disp_name} connection in Orb Core…")
        elif st == "completed":
            # Optional custom label for newly added account
            if label and not provider_id_param:
                try:
                    raw_after = client.request_json("GET", "/api/ai/providers")
                    after_list = [p for p in (raw_after if isinstance(raw_after, list) else raw_after.get("providers", [])) if isinstance(p, dict)]
                    peers_after = resolve_provider_accounts(after_list, provider)
                    created = [p for p in peers_after if str(p.get("id")) not in before_ids]
                    if created:
                        new_id = str(created[-1]["id"])
                        client.request_json(
                            "PUT",
                            f"/api/ai/providers/{urllib.parse.quote(new_id, safe='')}",
                            {"name": label},
                        )
                except Exception:
                    pass

            cmd_usage_update(["--force", provider])
            emit_desktop_command({"action": "providers-refresh"})
            done_text = f"Connected {disp_name}" + (f" ({label})" if label else "") + " in Orb."
            send_notification(done_text, "Subscription limits and routing synced.")
            emit_tag("done", done_text)
            return 0
        elif st == "failed":
            err_msg = msg or f"{disp_name} sign-in failed."
            emit_tag("error", err_msg)
            return 1

    emit_tag("error", f"{disp_name} sign-in timed out.")
    return 1


def focus_or_spawn_orb() -> bool:
    orb_bin = shutil.which("orb")
    # Try focusing an existing Orb window on Hyprland first
    hyprctl = shutil.which("hyprctl")
    focused_existing = False
    if hyprctl and os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        try:
            proc = subprocess.run(
                [hyprctl, "clients", "-j"],
                capture_output=True,
                text=True,
                timeout=2.0,
                check=False,
            )
            if proc.returncode == 0 and proc.stdout:
                clients = json.loads(proc.stdout)
                if isinstance(clients, list):
                    for c in clients:
                        if not isinstance(c, dict):
                            continue
                        cls = str(c.get("class") or c.get("initialClass") or "")
                        if cls in ("orb-desktop", ".orb-desktop-unwrapped", "orb"):
                            addr = str(c.get("address") or "")
                            if addr:
                                subprocess.run(
                                    [hyprctl, "dispatch", "focuswindow", f"address:{addr}"],
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL,
                                    timeout=2.0,
                                    check=False,
                                )
                                focused_existing = True
                                break
        except Exception:
            pass

    if focused_existing:
        return True

    if not orb_bin:
        return False

    uwsm = shutil.which("uwsm-app")
    launch_cmd = [uwsm, "--", orb_bin] if uwsm else [orb_bin]
    try:
        subprocess.Popen(
            launch_cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return True
    except OSError:
        return False


def cmd_launch(argv: list[str]) -> int:
    # Delegate local-model, explicit terminal/inline, or help flags straight to upstream CLI launcher
    passthrough_flags = {"--local", "--local-model", "--terminal", "--inline", "-h", "--help"}
    if any(a in passthrough_flags for a in argv):
        return run_upstream("omarchy-agent", argv, replace=True)

    agent_arg = ""
    prompt_arg = ""
    cwd_arg = os.getcwd()

    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--agent" and i + 1 < len(argv):
            i += 1
            agent_arg = argv[i].strip()
        elif a == "--prompt" and i + 1 < len(argv):
            i += 1
            prompt_arg = argv[i]
        elif a == "--cwd" and i + 1 < len(argv):
            i += 1
            cwd_arg = argv[i]
        elif a == "--pick":
            pass
        i += 1

    if shutil.which("orb") is None and load_orb_connection() is None:
        return run_upstream("omarchy-agent", argv, replace=True)

    orb_backend = HARNESS_TO_ORB_BACKEND.get(agent_arg.lower(), "") if agent_arg else ""
    cmd_payload: dict[str, Any] = {
        "action": "new-agent",
    }
    if orb_backend:
        cmd_payload["backend"] = orb_backend
    if prompt_arg:
        cmd_payload["prompt"] = prompt_arg
    if cwd_arg:
        cmd_payload["cwd"] = cwd_arg

    emit_desktop_command(cmd_payload)
    if not focus_or_spawn_orb():
        return run_upstream("omarchy-agent", argv, replace=True)
    return 0


def cmd_prompt(argv: list[str]) -> int:
    if not argv or "--inline" in argv:
        return run_upstream("omarchy-agent-prompt", argv, replace=True)
    prompt_text = " ".join(argv).strip()
    if not prompt_text:
        return 1
    return cmd_launch(["--prompt", prompt_text])


def run_self_test() -> int:
    # 1. Failover origin ordering & custom origin isolation
    assert candidate_origins("https://orbcore.thomas.md") == [
        "https://orbcore.thomas.md",
        "https://agent-backend.thomas.md",
        "https://agent-backend.nico-best-pc-ever.ovh",
    ]
    assert candidate_origins("https://custom.example.com/") == ["https://custom.example.com"]

    # 2. Live wire window normalization (`antigravity`, `anthropic`, `openai`, `kimi`, `zai`)
    ag_limits = normalize_provider_windows(
        "antigravity",
        {
            "antigravity_plan": "Google AI Ultra",
            "antigravity_windows": [
                {"label": "Claude & GPT · 5h", "used_percent": 25.0, "reset_at": 1794354349},
                {"label": "Gemini · 5h", "used_percent": 10.0, "reset_at": 1794354349},
                {"label": "Gemini · Weekly", "used_percent": 40.0, "reset_at": 1794909550},
            ],
        },
    )
    assert [w["title"] for w in ag_limits] == ["Session", "Weekly", "Claude & GPT Session"]
    assert ag_limits[0]["percent"] == 0.10
    assert ag_limits[2]["percent"] == 0.25
    assert ag_limits[0]["resetsAt"].endswith("+00:00")
    assert extract_plan_label("antigravity", {"uses_oauth": True}, {"antigravity_plan": "Google AI Ultra"}, True) == "Ultra"

    claude_limits = normalize_provider_windows(
        "anthropic",
        {"unified_7d_utilization": 0.75, "unified_7d_reset": 1794409200.0},
    )
    assert len(claude_limits) == 1 and claude_limits[0]["title"] == "Weekly" and claude_limits[0]["percent"] == 0.75

    codex_live = normalize_provider_windows(
        "openai",
        {
            "codex_plan_type": "promax",
            "codex_primary_used_percent": 0.0,
            "codex_primary_window_minutes": 10080,
            "codex_primary_reset_at": 1794865997,
            "codex_secondary_used_percent": 100.0,
            "codex_secondary_window_minutes": None,
            "codex_secondary_reset_at": 1794379898,
        },
    )
    assert [w["title"] for w in codex_live] == ["Session", "Weekly"]
    assert codex_live[0]["percent"] == 1.0 and codex_live[1]["percent"] == 0.0
    assert extract_plan_label("openai", {"uses_oauth": True}, {"codex_plan_type": "promax"}, True) == "Pro"

    # 3. Reset credits (numeric epoch & ISO) & xAI balance
    rc = extract_reset_credits(
        {
            "subscription_resets": {
                "available_count": 1,
                "grants": [
                    {"resets_left": 1, "expires_at": 1796163818},
                ],
            }
        }
    )
    assert rc is not None and rc["available"] == 1 and rc["nextExpiresAt"].endswith("+00:00")
    bal = extract_balance({"xai_prepaid_usd": 18.5, "xai_prepaid_total_usd": 25.0})
    assert bal == {"remaining": 18.5, "funded": 25.0, "spent": 6.5, "currency": "USD", "estimated": False}

    # 4. Telemetry projection (`by_model[].model`, `cache_read_tokens`, `by_day[].day`)
    today = dt.datetime.now(dt.timezone.utc).date().isoformat()
    telem, hist = build_telemetry_by_agent(
        {
            "by_model": [
                {"model": "claude-opus-4-7", "requests": 10, "input_tokens": 600, "output_tokens": 200, "cache_read_tokens": 200},
                {"model": "gpt-5.4", "requests": 5, "input_tokens": 300, "output_tokens": 200, "cache_read_tokens": 0},
            ],
            "by_day": [{"day": today, "requests": 15, "input_tokens": 900, "output_tokens": 400, "cache_read_tokens": 200}],
            "by_mission": [{"mission_id": "m1"}, {"mission_id": "m2"}],
        }
    )
    assert set(telem.keys()) == {"claude", "codex"}
    assert telem["claude"]["todayTotalTokens"] + telem["codex"]["todayTotalTokens"] == 1500
    assert hist[today]["tokens"] == 1500
    week_sum = sum(
        d["messageCount"]
        for ag in telem.values()
        for d in ag["recentDays"]
    )
    assert week_sum == 1500

    # 5. Atomic 0600 desktop command file emission & symlink refusal
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["ORB_STATE_DIR"] = tmp
        assert emit_desktop_command({"action": "new-agent", "backend": "claudecode", "prompt": "hi"})
        cmd_file = Path(tmp) / "desktop-command.json"
        st = os.lstat(cmd_file)
        assert stat.S_IMODE(st.st_mode) == 0o600
        loaded = json.loads(cmd_file.read_text(encoding="utf-8"))
        assert loaded["action"] == "new-agent" and loaded["backend"] == "claudecode"

    print("omarchy-orb-agent self-test: ok")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in ("-h", "--help"):
        print(
            "Usage: omarchy-orb-agent <usage-update|account-use|account-mode|account-rename|account-add|launch|prompt|--self-test> [args...]"
        )
        return 0

    sub = args[0]
    rest = args[1:]
    if sub == "--self-test":
        return run_self_test()
    if sub == "usage-update":
        return cmd_usage_update(rest)
    if sub == "account-use":
        return cmd_account_use(rest)
    if sub == "account-mode":
        return cmd_account_mode(rest)
    if sub == "account-rename":
        return cmd_account_rename(rest)
    if sub == "account-add":
        return cmd_account_add(rest)
    if sub == "launch":
        return cmd_launch(rest)
    if sub == "prompt":
        return cmd_prompt(rest)

    print(f"Unknown subcommand: {sub}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
