#!/usr/bin/env python3
"""mac-meshd: Sovereign MacBook tether coordinator (`wg-macmesh0` / `10.88.200.1`),
Touch ID biometric approval gate, local Next.js preview TCP/WS bridge, and
screen-lock / lid-close instant SSH lease revoker.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
)

STATE_DIR = Path("/var/lib/mac-mesh")
RUN_DIR = Path("/run/mac-mesh")
PSKS_DIR = RUN_DIR / "psks"
LEASES_DIR = RUN_DIR / "leases"
AUTH_KEYS_FILE = RUN_DIR / "authorized_keys"
UI_SOCK_PATH = RUN_DIR / "ui.sock"

IFACE = "wg-macmesh0"
NFT_TABLE = "mac_mesh"
HUB_IP = "10.88.200.1"
LISTEN_PORT = @macTether_0@
DESKTOP_USER = @macTether_1@
DESKTOP_UID = @macTether_2@
DESKTOP_HOME = Path(@macTether_3@)
DISPATCH_WRAPPER = "/run/wrappers/bin/orb-tether-dispatch"
CONFIGURED_CORE_URL = @macTether_4@
TOKEN_FILE = Path(@macTether_5@)

HOSTED_FAILOVER_MAP = {
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

SAFE_ID_RE = re.compile(r"^[A-Za-z0-9-]{4,64}$")

def atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

def load_core_credentials() -> tuple[list[str], str] | None:
    token = ""
    api_url = CONFIGURED_CORE_URL.strip().rstrip("/")
    if TOKEN_FILE.is_file() and not TOKEN_FILE.is_symlink():
        try:
            token = TOKEN_FILE.read_text(encoding="utf-8").strip()
        except Exception:
            token = ""
    conn_path = DESKTOP_HOME / ".orb" / "connection.json"
    if conn_path.exists() and not conn_path.is_symlink():
        try:
            st = os.lstat(conn_path)
            if stat.S_ISREG(st.st_mode):
                obj = json.loads(conn_path.read_text(encoding="utf-8"))
                if not api_url:
                    api_url = str(obj.get("api_url") or obj.get("apiUrl") or "").strip().rstrip("/")
                if not token:
                    token = str(obj.get("token") or obj.get("jwt") or "").strip()
        except Exception:
            pass
    if not token:
        return None
    if not api_url:
        api_url = "https://orbcore.thomas.md"
    low = api_url.lower()
    if low in HOSTED_FAILOVER_MAP:
        origins = list(HOSTED_FAILOVER_MAP[low])
    elif low.startswith("http://10.88.0.1"):
        origins = [api_url, "https://orbcore.thomas.md", "https://agent-backend.thomas.md"]
    else:
        origins = [api_url]
    return origins, token

def core_http_json(
    method: str,
    rel_path: str,
    body: dict[str, Any] | None = None,
    timeout: float = 10.0,
) -> dict[str, Any]:
    creds = load_core_credentials()
    if not creds:
        raise RuntimeError("No Orb Core credentials found in ~/.orb/connection.json")
    origins, token = creds
    raw_body = json.dumps(body).encode("utf-8") if body is not None else None
    last_err: Exception | None = None
    for origin in origins:
        # Skip mesh HTTP origin quickly if wg-leanmesh0 is down
        eff_timeout = 2.0 if origin.startswith("http://10.88.0.1") and timeout <= 12.0 else timeout
        url = origin + rel_path
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": "omarchnix-mac-meshd/1.0",
        }
        if raw_body is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=raw_body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=eff_timeout) as resp:
                txt = resp.read().decode("utf-8", errors="replace")
                return json.loads(txt) if txt.strip() else {}
        except urllib.error.HTTPError as he:
            err_txt = he.read().decode("utf-8", errors="replace")
            if he.code in (400, 401, 403, 404, 409):
                raise RuntimeError(f"HTTP {he.code}: {err_txt[:240]}")
            last_err = he
        except Exception as exc:
            last_err = exc
    raise RuntimeError(f"Orb Core unreachable: {last_err}")

def detect_local_lan_ip() -> str:
    try:
        out = subprocess.run(
            ["ip", "-4", "-j", "route", "get", "1.1.1.1"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if out.returncode == 0:
            routes = json.loads(out.stdout)
            if routes and routes[0].get("prefsrc"):
                ip = str(routes[0]["prefsrc"])
                if not ip.startswith("10.88.") and not ip.startswith("127."):
                    return ip
    except Exception:
        pass
    return ""

def seal_tether_psk(request_id: str, recipient_kem_pub_b64: str, psk_b64: str) -> tuple[str, str]:
    eph_priv = X25519PrivateKey.generate()
    eph_pub_bytes = eph_priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    rec_pub = X25519PublicKey.from_public_bytes(base64.b64decode(recipient_kem_pub_b64))
    shared32 = eph_priv.exchange(rec_pub)
    key32 = hashlib.sha256(b"orb-mac-tether-psk-v1:" + shared32).digest()
    nonce12 = b"\x00" * 12
    psk32 = base64.b64decode(psk_b64)
    ct48 = ChaCha20Poly1305(key32).encrypt(nonce12, psk32, request_id.encode("utf-8"))
    return (
        base64.b64encode(eph_pub_bytes).decode("ascii"),
        base64.b64encode(ct48).decode("ascii"),
    )

def sign_manifest_file(manifest_unsigned: dict[str, Any], seed_file: Path, mf_path: Path) -> None:
    m = dict(manifest_unsigned)
    m["coordinator_pubkey_hex"] = "0" * 64
    m["signature_hex"] = "00"
    atomic_write(mf_path, (json.dumps(m, indent=2) + "\n").encode("utf-8"), 0o600)
    subprocess.run(
        [
            "lean-mesh", "sign-manifest",
            "--manifest", str(mf_path),
            "--signing-key-file", str(seed_file),
            "--output", str(mf_path),
        ],
        capture_output=True,
        text=True,
        check=True,
    )

def is_lid_closed() -> bool:
    hw_bin = "/run/current-system/sw/bin/omarchy-hw-laptop-closed"
    if os.path.exists(hw_bin):
        try:
            return subprocess.run([hw_bin], timeout=2).returncode == 0
        except Exception:
            pass
    for lid_state in Path("/proc/acpi/button/lid").glob("*/state"):
        try:
            if "closed" in lid_state.read_text().lower():
                return True
        except Exception:
            pass
    return False

def verify_operator_presence(summary: str) -> tuple[bool, str]:
    """Prompt Touch ID via `fprintd-verify` + Omarchy Touch ID HUD, or fall back
    to Polkit (`pkexec`) when docked in clamshell mode or when fingerprint hardware
    is absent (e.g. VM)."""
    fplist = shutil.which("fprintd-list") or "/run/current-system/sw/bin/fprintd-list"
    fpverify = shutil.which("fprintd-verify") or "/run/current-system/sw/bin/fprintd-verify"
    omarchy_shell = (
        f"/etc/profiles/per-user/{DESKTOP_USER}/bin/omarchy-shell"
        if os.path.exists(f"/etc/profiles/per-user/{DESKTOP_USER}/bin/omarchy-shell")
        else shutil.which("omarchy-shell")
    )
    enrolled = False
    if not is_lid_closed() and os.path.exists(fplist) and os.path.exists(fpverify):
        try:
            r = subprocess.run([fplist, DESKTOP_USER], capture_output=True, text=True, timeout=5)
            enrolled = r.returncode == 0 and (
                " - #" in r.stdout
                or ("Fingerprints for user" in r.stdout and "has no fingers" not in r.stdout)
            )
        except Exception:
            enrolled = False

    if enrolled:
        proc = subprocess.Popen(
            [fpverify, DESKTOP_USER],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if omarchy_shell and os.path.exists(omarchy_shell):
            try:
                ipc_payload = json.dumps({
                    "app": "Mac Tether",
                    "subtitle": summary,
                    "pid": proc.pid,
                })
                user_env = {
                    "HOME": str(DESKTOP_HOME),
                    "USER": DESKTOP_USER,
                    "XDG_RUNTIME_DIR": f"/run/user/{DESKTOP_UID}",
                    "PATH": f"/etc/profiles/per-user/{DESKTOP_USER}/bin:/run/current-system/sw/bin:/usr/bin:/bin",
                }
                subprocess.run(
                    [
                        "runuser", "-u", DESKTOP_USER, "--",
                        "env",
                        f"XDG_RUNTIME_DIR=/run/user/{DESKTOP_UID}",
                        omarchy_shell, "touchid", "begin", ipc_payload,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=1.0,
                    env=user_env,
                )
            except Exception:
                pass
        try:
            out_s, err_s = proc.communicate(timeout=35)
            combined = (out_s or "") + "\n" + (err_s or "")
            if proc.returncode == 0 and "verify-match" in combined:
                return True, "touchid"
            if "verify-no-match" in combined:
                return False, "Touch ID did not match"
            return False, "Touch ID cancelled"
        except subprocess.TimeoutExpired:
            proc.kill()
            return False, "Touch ID timed out"

    # Clamshell / VM Polkit fallback
    pkexec = "/run/wrappers/bin/pkexec"
    if os.path.exists(pkexec):
        try:
            r = subprocess.run(
                [
                    "runuser", "-u", DESKTOP_USER, "--",
                    "env", f"XDG_RUNTIME_DIR=/run/user/{DESKTOP_UID}",
                    pkexec, "/run/current-system/sw/bin/true",
                ],
                timeout=45,
            )
            if r.returncode == 0:
                return True, "polkit"
        except Exception as exc:
            return False, f"Polkit failed: {exc}"
    return False, "Biometric / Polkit verification unavailable"

def send_desktop_notification(title: str, body: str, urgency: str = "normal") -> None:
    notify_bin = shutil.which("notify-send") or "/run/current-system/sw/bin/notify-send"
    if not os.path.exists(notify_bin):
        return
    try:
        subprocess.Popen(
            [
                "runuser", "-u", DESKTOP_USER, "--",
                "env",
                f"XDG_RUNTIME_DIR=/run/user/{DESKTOP_UID}",
                f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{DESKTOP_UID}/bus",
                notify_bin, "-a", "Mac Tether", "-u", urgency, "-t", "10000", title, body,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass

class PreviewForwarder:
    """Async loopback TCP/WebSocket forwarder (`127.0.0.1:<port> -> 10.88.200.X:<port>`)."""
    def __init__(self, loop: asyncio.AbstractEventLoop, local_port: int, remote_ip: str, remote_port: int) -> None:
        self.loop = loop
        self.local_port = local_port
        self.remote_ip = remote_ip
        self.remote_port = remote_port
        self.server: asyncio.AbstractServer | None = None

    async def _pipe(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while True:
                chunk = await reader.read(65536)
                if not chunk:
                    break
                writer.write(chunk)
                await writer.drain()
        except Exception:
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def _handle_client(self, c_reader: asyncio.StreamReader, c_writer: asyncio.StreamWriter) -> None:
        try:
            r_reader, r_writer = await asyncio.wait_for(
                asyncio.open_connection(self.remote_ip, self.remote_port),
                timeout=5.0,
            )
        except Exception:
            c_writer.close()
            return
        await asyncio.gather(
            self._pipe(c_reader, r_writer),
            self._pipe(r_reader, c_writer),
        )

    async def start(self) -> bool:
        try:
            self.server = await asyncio.start_server(
                self._handle_client, host="127.0.0.1", port=self.local_port
            )
            return True
        except Exception:
            self.server = None
            return False

    def stop(self) -> None:
        if self.server is not None:
            self.server.close()
            self.server = None

class MacMeshDaemon:
    def __init__(self) -> None:
        self.loop = asyncio.new_event_loop()
        self.epoch = 1
        self.coord_seed = b""
        self.hub_sign_hex = ""
        self.wg_priv = ""
        self.wg_pub = ""
        self.requests: list[dict[str, Any]] = []
        self.active_leases: dict[str, dict[str, Any]] = {}
        self.forwarders: dict[str, list[PreviewForwarder]] = {}
        self.subscribers: set[asyncio.StreamWriter] = set()
        self.notified_ids: set[str] = set()
        self.core_online = False
        self.core_error = ""
        self.screen_locked = False

    def init_keys_and_interface(self) -> None:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(STATE_DIR, 0o700)
        for d in (RUN_DIR, PSKS_DIR, LEASES_DIR):
            d.mkdir(parents=True, exist_ok=True)
        os.chmod(RUN_DIR, 0o755)
        os.chmod(PSKS_DIR, 0o700)
        os.chmod(LEASES_DIR, 0o700)
        Path("/sys/fs/cgroup/orb-tether.slice").mkdir(parents=True, exist_ok=True)

        seed_file = STATE_DIR / "coordinator.seed"
        if not seed_file.is_file():
            atomic_write(seed_file, (os.urandom(32).hex() + "\n").encode("ascii"), 0o600)
        raw_seed = seed_file.read_bytes()
        try:
            seed_txt = raw_seed.decode("ascii").strip()
            if len(seed_txt) == 64:
                self.coord_seed = bytes.fromhex(seed_txt)
            else:
                raise ValueError("binary seed")
        except Exception:
            self.coord_seed = (raw_seed[:32] if len(raw_seed) >= 32 else os.urandom(32))
            atomic_write(seed_file, (self.coord_seed.hex() + "\n").encode("ascii"), 0o600)
        hub_sign = Ed25519PrivateKey.from_private_bytes(
            hashlib.sha256(b"mac-mesh-hub-sign:" + self.coord_seed).digest()
        )
        self.hub_sign_hex = hub_sign.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()

        wg_key_file = STATE_DIR / "wg.key"
        if not wg_key_file.is_file():
            gen = subprocess.run(["wg", "genkey"], capture_output=True, text=True, check=True)
            atomic_write(wg_key_file, (gen.stdout.strip() + "\n").encode("ascii"), 0o600)
        self.wg_priv = wg_key_file.read_text(encoding="ascii").strip()
        pub = subprocess.run(["wg", "pubkey"], input=self.wg_priv + "\n", capture_output=True, text=True, check=True)
        self.wg_pub = pub.stdout.strip()
        atomic_write(STATE_DIR / "wg.pub", (self.wg_pub + "\n").encode("ascii"), 0o644)

        epoch_file = STATE_DIR / "epoch"
        if epoch_file.is_file():
            try:
                self.epoch = max(1, int(epoch_file.read_text().strip()))
            except Exception:
                self.epoch = 1

        if not AUTH_KEYS_FILE.exists():
            atomic_write(AUTH_KEYS_FILE, b"", 0o644)

        self.reconcile_mac_mesh()

    def reconcile_mac_mesh(self) -> None:
        now = int(time.time())
        # Expire elapsed leases
        expired = [lid for lid, meta in self.active_leases.items() if int(meta["expires_at"]) <= now]
        for lid in expired:
            self._teardown_local_lease(lid)

        self.epoch += 1
        atomic_write(STATE_DIR / "epoch", f"{self.epoch}\n".encode("ascii"), 0o600)

        peers = [
            {
                "id": 1,
                "name": "m2air",
                "node_class": "reserved_prod",
                "overlay_ip": HUB_IP,
                "prefix_len": 32,
                "wg_pubkey": self.wg_pub,
                "sign_pubkey_hex": self.hub_sign_hex,
                "endpoint": f"0.0.0.0:{LISTEN_PORT}",
                "pinned_static": False,
                "revoked": False,
                "expires_at": now + 86400,
            }
        ]
        rules: list[dict[str, Any]] = []
        auth_lines: list[str] = []

        for lid, meta in sorted(self.active_leases.items()):
            peer_name = f"lease-{lid[:12]}"
            overlay_ip = meta["overlay_ip"]
            last_octet = int(overlay_ip.split(".")[-1])
            exp = int(meta["expires_at"])
            eff_scope = meta["effective_scope"]
            peers.append({
                "id": 100 + last_octet,
                "name": peer_name,
                "node_class": "mission_sandbox",
                "overlay_ip": overlay_ip,
                "prefix_len": 32,
                "wg_pubkey": meta["agent_wg_pubkey"],
                "sign_pubkey_hex": meta.get("agent_sign_pubkey_hex") or hashlib.sha256(
                    f"macmesh-peer:{lid}:{meta['agent_wg_pubkey']}".encode("utf-8")
                ).hexdigest(),
                "endpoint": meta.get("agent_endpoint") or None,
                "pinned_static": False,
                "revoked": False,
                "expires_at": exp,
            })
            psk_path = PSKS_DIR / (
                f"{peer_name}--m2air.psk" if peer_name < "m2air" else f"m2air--{peer_name}.psk"
            )
            atomic_write(psk_path, (meta["psk_b64"] + "\n").encode("ascii"), 0o600)

            for ap in meta.get("agent_ports", []):
                rules.append({
                    "src_peer": "m2air",
                    "dst_peer": peer_name,
                    "proto": "tcp",
                    "port_min": int(ap),
                    "port_max": int(ap),
                    "description": f"Local browser preview m2air -> {peer_name}:{ap}",
                })
            if eff_scope in ("sandbox_ssh", "host_ssh"):
                rules.append({
                    "src_peer": peer_name,
                    "dst_peer": "m2air",
                    "proto": "tcp",
                    "port_min": @macTether_6@,
                    "port_max": @macTether_7@,
                    "description": f"Touch ID JIT SSH tether {peer_name} -> m2air:@macTether_8@",
                })
                ssh_pub = (meta.get("agent_ssh_pubkey") or "").strip()
                if ssh_pub.startswith("ssh-ed25519 "):
                    opts = "restrict,pty"
                    if meta.get("mac_ports"):
                        permit_list = " ".join(
                            f"permitopen=\"127.0.0.1:{int(mp)}\"" for mp in meta["mac_ports"]
                        )
                        opts = f"restrict,port-forwarding,pty,{permit_list}"
                    auth_lines.append(
                        f'{opts},command="{DISPATCH_WRAPPER} {lid}" {ssh_pub}'
                    )

        manifest_unsigned = {
            "version": 1,
            "epoch": self.epoch,
            "panic_seq": 0,
            "is_emergency_panic": False,
            "issued_at": now,
            "expires_at": now + 86400,
            "max_ttl_secs": 86400,
            "peers": peers,
            "rules": rules,
        }
        mf_path = RUN_DIR / "manifest.json"
        sign_manifest_file(manifest_unsigned, STATE_DIR / "coordinator.seed", mf_path)
        atomic_write(
            AUTH_KEYS_FILE,
            ("\n".join(auth_lines) + ("\n" if auth_lines else "")).encode("utf-8"),
            0o644,
        )

        wg_out = subprocess.run(
            [
                "lean-mesh", "render-wg",
                "--manifest", str(mf_path),
                "--node", "m2air",
                "--private-key-file", str(STATE_DIR / "wg.key"),
                "--interface", IFACE,
                "--listen-port", str(LISTEN_PORT),
                "--psk-dir", str(PSKS_DIR),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        wg_conf_path = RUN_DIR / "wg.conf"
        atomic_write(wg_conf_path, wg_out.stdout.encode("utf-8"), 0o600)

        nft_out = subprocess.run(
            [
                "lean-mesh", "render-nft",
                "--manifest", str(mf_path),
                "--node", "m2air",
                "--interface", IFACE,
                "--nft-table", NFT_TABLE,
                "--jit-biometric",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        nft_conf_path = RUN_DIR / "nft.conf"
        atomic_write(nft_conf_path, nft_out.stdout.encode("utf-8"), 0o600)

        if subprocess.run(["ip", "link", "show", "dev", IFACE], capture_output=True).returncode != 0:
            subprocess.run(["ip", "link", "add", "dev", IFACE, "type", "wireguard"], check=True)
        subprocess.run(["ip", "-4", "addr", "replace", f"{HUB_IP}/32", "dev", IFACE], check=True)
        subprocess.run(["wg", "setconf", IFACE, str(wg_conf_path)], check=True)
        subprocess.run(["ip", "link", "set", "mtu", "1420", "up", "dev", IFACE], check=True)
        for meta in self.active_leases.values():
            subprocess.run(["ip", "-4", "route", "replace", f"{meta['overlay_ip']}/32", "dev", IFACE], check=False)

        subprocess.run(["nft", "delete", "table", "inet", NFT_TABLE], capture_output=True)
        subprocess.run(["nft", "-f", str(nft_conf_path)], check=True)

    def _kill_lease_cgroup(self, lease_id: str) -> None:
        cg_root = Path(f"/sys/fs/cgroup/orb-tether.slice/lease-{lease_id}")
        if not cg_root.exists():
            return
        for kill_file in [cg_root / "cgroup.kill", *cg_root.glob("*/cgroup.kill")]:
            try:
                kill_file.write_text("1\n")
            except Exception:
                pass
        for procs_file in [cg_root / "cgroup.procs", *cg_root.glob("*/cgroup.procs")]:
            try:
                for p in procs_file.read_text().splitlines():
                    if p.strip().isdigit():
                        os.kill(int(p.strip()), signal.SIGKILL)
            except Exception:
                pass

    def _teardown_local_lease(self, lease_id: str) -> None:
        self.active_leases.pop(lease_id, None)
        for fwd in self.forwarders.pop(lease_id, []):
            fwd.stop()
        env_file = LEASES_DIR / f"{lease_id}.env"
        try:
            env_file.unlink(missing_ok=True)
        except Exception:
            pass
        for psk_f in PSKS_DIR.glob(f"*lease-{lease_id[:12]}*.psk"):
            try:
                psk_f.unlink(missing_ok=True)
            except Exception:
                pass
        self._kill_lease_cgroup(lease_id)

    async def sync_preview_forwarders(self, lease_id: str) -> None:
        for fwd in self.forwarders.pop(lease_id, []):
            fwd.stop()
        meta = self.active_leases.get(lease_id)
        if not meta:
            return
        started: list[PreviewForwarder] = []
        active_ports: list[int] = []
        for port in meta.get("agent_ports", []):
            p = int(port)
            fwd = PreviewForwarder(self.loop, p, meta["overlay_ip"], p)
            if await fwd.start():
                started.append(fwd)
                active_ports.append(p)
        self.forwarders[lease_id] = started
        meta["bound_preview_ports"] = active_ports

    def mesh_plane_status(self, iface: str) -> dict[str, Any]:
        exists = subprocess.run(["ip", "link", "show", "dev", iface], capture_output=True).returncode == 0
        if not exists:
            return {"up": False, "peers": 0, "latest_handshake": 0, "roam": {}}
        dump = subprocess.run(["wg", "show", iface, "dump"], capture_output=True, text=True)
        peers = 0
        latest_hs = 0
        if dump.returncode == 0:
            for idx, ln in enumerate(dump.stdout.splitlines()):
                cols = ln.split("\t")
                if idx > 0 and len(cols) >= 8:
                    peers += 1
                    latest_hs = max(latest_hs, int(cols[4] or "0"))
        roam = {}
        roam_file = Path(f"/run/lean-mesh-{iface}/roam-status.json")
        if roam_file.is_file():
            try:
                roam = json.loads(roam_file.read_text(encoding="utf-8"))
            except Exception:
                roam = {}
        return {"up": True, "peers": peers, "latest_handshake": latest_hs, "roam": roam}

    def build_snapshot(self) -> dict[str, Any]:
        now = int(time.time())
        pending = [r for r in self.requests if r.get("state") == "pending"]
        active = []
        for r in self.requests:
            rid = str(r.get("id") or "")
            if r.get("state") == "approved" and int(r.get("expires_at") or 0) > now:
                item = dict(r)
                local_meta = self.active_leases.get(rid, {})
                item["local_active"] = rid in self.active_leases
                item["bound_preview_ports"] = local_meta.get("bound_preview_ports", r.get("agent_ports", []))
                item["remaining_secs"] = max(0, int(r.get("expires_at") or 0) - now)
                active.append(item)
        return {
            "version": 1,
            "now": now,
            "core_online": self.core_online,
            "core_error": self.core_error,
            "screen_locked": self.screen_locked,
            "lid_closed": is_lid_closed(),
            "planes": {
                "paloma": self.mesh_plane_status("wg-leanmesh0"),
                "personal": self.mesh_plane_status("wg-homemesh0"),
                "tether": self.mesh_plane_status(IFACE),
            },
            "pending": pending,
            "active": active,
        }

    def broadcast_snapshot(self) -> None:
        if not self.subscribers:
            return
        line = (json.dumps(self.build_snapshot(), separators=(",", ":")) + "\n").encode("utf-8")
        dead: list[asyncio.StreamWriter] = []
        for w in list(self.subscribers):
            try:
                w.write(line)
            except Exception:
                dead.append(w)
        for w in dead:
            self.subscribers.discard(w)

    def ingest_core_requests(self, items: list[dict[str, Any]]) -> None:
        now = int(time.time())
        self.requests = items
        live_approved_ids = set()
        for r in items:
            rid = str(r.get("id") or "")
            state = r.get("state")
            if state == "pending" and rid and rid not in self.notified_ids:
                self.notified_ids.add(rid)
                label = r.get("requester_label") or r.get("mission_id") or "Orb Mission"
                scope = r.get("requested_scope") or "sandbox_ssh"
                reason = r.get("reason") or ""
                send_desktop_notification(
                    f"Mac Tether Request · {label}",
                    f"[{scope}] {reason}",
                    urgency="critical",
                )
            if state == "approved" and int(r.get("expires_at") or 0) > now:
                live_approved_ids.add(rid)
        # Reap any local lease revoked/expired on Core (e.g. mission stopped!)
        reaped = False
        for lid in list(self.active_leases.keys()):
            if lid not in live_approved_ids:
                self._teardown_local_lease(lid)
                reaped = True
        if reaped:
            self.reconcile_mac_mesh()
        self.broadcast_snapshot()

    async def approve_request(
        self,
        req_id: str,
        target: str,
        ttl_minutes: int,
        session_scoped: bool,
    ) -> dict[str, Any]:
        if not SAFE_ID_RE.match(req_id):
            raise RuntimeError("Invalid request ID")
        req = next((r for r in self.requests if r.get("id") == req_id), None)
        if not req:
            # Refresh once from Core
            res = await asyncio.to_thread(core_http_json, "GET", "/api/mac-tether/requests")
            self.ingest_core_requests(res.get("requests", []))
            req = next((r for r in self.requests if r.get("id") == req_id), None)
        if not req:
            raise RuntimeError("Tether request not found")

        req_scope = str(req.get("requested_scope") or "sandbox_ssh")
        if req_scope == "preview":
            eff_scope = "preview"
            eff_target = "sandbox"
        else:
            eff_target = "thomas" if target == "thomas" else "sandbox"
            eff_scope = "host_ssh" if eff_target == "thomas" else "sandbox_ssh"

        label = str(req.get("requester_label") or req.get("mission_id") or "Mission")
        summary = f"{label} · {'Host (thomas)' if eff_target == 'thomas' else ('Preview' if eff_scope == 'preview' else 'Sandbox')} · {ttl_minutes}m"
        verified, auth_note = await asyncio.to_thread(verify_operator_presence, summary)
        if not verified:
            raise RuntimeError(auth_note)

        psk_b64 = base64.b64encode(os.urandom(32)).decode("ascii")
        agent_kem = str(req.get("agent_kem_pubkey") or "").strip()
        mac_kem_pub = ""
        sealed_psk = ""
        if agent_kem:
            mac_kem_pub, sealed_psk = seal_tether_psk(req_id, agent_kem, psk_b64)

        lan_ip = detect_local_lan_ip()
        direct_ep = f"{lan_ip}:{LISTEN_PORT}" if lan_ip else ""

        approve_body = {
            "biometric_verified": True,
            "effective_scope": eff_scope,
            "effective_target": eff_target,
            "ttl_minutes": int(ttl_minutes),
            "session_scoped": bool(session_scoped),
            "mac_wg_pubkey": self.wg_pub,
            "mac_kem_pubkey": mac_kem_pub,
            "sealed_psk_b64": sealed_psk,
            "mac_direct_endpoint": direct_ep,
        }
        resp = await asyncio.to_thread(
            core_http_json, "POST", f"/api/mac-tether/requests/{req_id}/approve", approve_body
        )
        tether = resp.get("tether") or {}
        overlay_ip = str(tether.get("overlay_ip") or "")
        expires_at = int(tether.get("expires_at") or (int(time.time()) + ttl_minutes * 60))
        relay_ep = str(tether.get("relay_endpoint") or "").strip()
        agent_direct = str(tether.get("agent_direct_endpoint") or "").strip()
        is_managed = bool(tether.get("is_managed_vm"))
        # Use agent direct endpoint on LAN/Paloma if present, otherwise blind UDP relay on orb-core
        agent_ep = agent_direct if (agent_direct and not is_managed) else (relay_ep or agent_direct)

        env_txt = (
            f"LEASE_ID={req_id}\n"
            f"TARGET={eff_target}\n"
            f"SCOPE={eff_scope}\n"
            f"OVERLAY_IP={overlay_ip}\n"
            f"EXPIRES_AT={expires_at}\n"
        )
        atomic_write(LEASES_DIR / f"{req_id}.env", env_txt.encode("ascii"), 0o600)

        self.active_leases[req_id] = {
            "lease_id": req_id,
            "effective_scope": eff_scope,
            "effective_target": eff_target,
            "overlay_ip": overlay_ip,
            "expires_at": expires_at,
            "psk_b64": psk_b64,
            "agent_wg_pubkey": str(tether.get("agent_wg_pubkey") or req.get("agent_wg_pubkey") or ""),
            "agent_ssh_pubkey": str(tether.get("agent_ssh_pubkey") or req.get("agent_ssh_pubkey") or ""),
            "agent_sign_pubkey_hex": str(tether.get("agent_sign_pubkey_hex") or ""),
            "agent_endpoint": agent_ep,
            "agent_ports": tether.get("agent_ports") or req.get("agent_ports") or [],
            "mac_ports": tether.get("mac_ports") or req.get("mac_ports") or [],
        }
        await asyncio.to_thread(self.reconcile_mac_mesh)
        await self.sync_preview_forwarders(req_id)

        # Kick a WireGuard handshake packet toward the relay so NAT mappings warm immediately
        if relay_ep and ":" in relay_ep:
            try:
                subprocess.Popen(
                    ["ping", "-c", "1", "-W", "1", overlay_ip],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception:
                pass

        refreshed = await asyncio.to_thread(core_http_json, "GET", "/api/mac-tether/requests")
        self.ingest_core_requests(refreshed.get("requests", []))
        return {"ok": True, "tether": tether}

    async def deny_request(self, req_id: str) -> dict[str, Any]:
        if not SAFE_ID_RE.match(req_id):
            raise RuntimeError("Invalid request ID")
        resp = await asyncio.to_thread(
            core_http_json, "POST", f"/api/mac-tether/requests/{req_id}/deny", {"reason": "Denied on MacBook"}
        )
        refreshed = await asyncio.to_thread(core_http_json, "GET", "/api/mac-tether/requests")
        self.ingest_core_requests(refreshed.get("requests", []))
        return {"ok": True, "tether": resp.get("tether")}

    async def revoke_request(self, req_id: str, reason: str = "Revoked from MacBook") -> dict[str, Any]:
        if not SAFE_ID_RE.match(req_id):
            raise RuntimeError("Invalid request ID")
        self._teardown_local_lease(req_id)
        await asyncio.to_thread(self.reconcile_mac_mesh)
        try:
            await asyncio.to_thread(
                core_http_json, "POST", f"/api/mac-tether/requests/{req_id}/revoke", {"reason": reason}
            )
            refreshed = await asyncio.to_thread(core_http_json, "GET", "/api/mac-tether/requests")
            self.ingest_core_requests(refreshed.get("requests", []))
        except Exception:
            self.broadcast_snapshot()
        return {"ok": True}

    async def revoke_ssh_leases_on_lock(self, trigger: str) -> int:
        ssh_ids = [
            lid
            for lid, meta in list(self.active_leases.items())
            if meta.get("effective_scope") in ("sandbox_ssh", "host_ssh")
        ]
        if not ssh_ids:
            return 0
        for lid in ssh_ids:
            self._teardown_local_lease(lid)
        await asyncio.to_thread(self.reconcile_mac_mesh)
        for lid in ssh_ids:
            try:
                await asyncio.to_thread(
                    core_http_json,
                    "POST",
                    f"/api/mac-tether/requests/{lid}/revoke",
                    {"reason": f"Auto-revoked on MacBook {trigger}"},
                )
            except Exception:
                pass
        try:
            refreshed = await asyncio.to_thread(core_http_json, "GET", "/api/mac-tether/requests")
            self.ingest_core_requests(refreshed.get("requests", []))
        except Exception:
            self.broadcast_snapshot()
        return len(ssh_ids)

    async def revoke_all(self) -> dict[str, Any]:
        all_ids = list(self.active_leases.keys()) + [
            str(r["id"]) for r in self.requests if r.get("state") == "approved"
        ]
        seen = set()
        for lid in all_ids:
            if lid and lid not in seen:
                seen.add(lid)
                await self.revoke_request(lid, "Revoked all tethers from MacBook")
        return {"ok": True, "revoked": len(seen)}

    async def handle_ui_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        sock = writer.get_extra_info("socket")
        if sock is not None:
            creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
            _, peer_uid, _ = struct.unpack("3i", creds)
            if peer_uid not in (0, DESKTOP_UID):
                writer.close()
                return
        try:
            raw = await asyncio.wait_for(reader.readline(), timeout=10.0)
            if not raw:
                writer.close()
                return
            cmd = json.loads(raw.decode("utf-8"))
            op = cmd.get("op")
            if op == "status":
                writer.write((json.dumps(self.build_snapshot()) + "\n").encode("utf-8"))
                await writer.drain()
                writer.close()
                return
            if op == "watch":
                self.subscribers.add(writer)
                writer.write((json.dumps(self.build_snapshot()) + "\n").encode("utf-8"))
                await writer.drain()
                try:
                    while not reader.at_eof():
                        chunk = await reader.read(256)
                        if not chunk:
                            break
                finally:
                    self.subscribers.discard(writer)
                    writer.close()
                return
            if op == "approve":
                res = await self.approve_request(
                    str(cmd.get("id") or ""),
                    str(cmd.get("target") or "sandbox"),
                    int(cmd.get("ttl_minutes") or 60),
                    bool(cmd.get("session_scoped", True)),
                )
            elif op == "deny":
                res = await self.deny_request(str(cmd.get("id") or ""))
            elif op == "revoke":
                res = await self.revoke_request(str(cmd.get("id") or ""))
            elif op == "revoke_all":
                res = await self.revoke_all()
            elif op == "lock_event":
                self.screen_locked = True
                n = await self.revoke_ssh_leases_on_lock(str(cmd.get("trigger") or "screen lock"))
                res = {"ok": True, "revoked_ssh_leases": n}
            elif op == "unlock_event":
                self.screen_locked = False
                self.broadcast_snapshot()
                res = {"ok": True}
            else:
                res = {"ok": False, "error": f"Unknown op: {op}"}
            writer.write((json.dumps(res) + "\n").encode("utf-8"))
            await writer.drain()
        except Exception as exc:
            try:
                writer.write((json.dumps({"ok": False, "error": str(exc)}) + "\n").encode("utf-8"))
                await writer.drain()
            except Exception:
                pass
        finally:
            if writer not in self.subscribers:
                try:
                    writer.close()
                except Exception:
                    pass

    async def core_poll_loop(self) -> None:
        since_gen = 0
        while True:
            try:
                ev = await asyncio.to_thread(
                    core_http_json,
                    "GET",
                    f"/api/mac-tether/events?since_gen={since_gen}&wait_secs=25",
                    None,
                    32.0,
                )
                self.core_online = True
                self.core_error = ""
                since_gen = int(ev.get("generation") or since_gen)
                if "requests" in ev and isinstance(ev["requests"], list):
                    self.ingest_core_requests(ev["requests"])
            except Exception as exc:
                self.core_online = False
                self.core_error = str(exc)[:180]
                self.broadcast_snapshot()
                await asyncio.sleep(5.0)

    async def watchdog_loop(self) -> None:
        last_lid = False
        last_locked = False
        while True:
            await asyncio.sleep(2.0)
            now = int(time.time())
            expired = [lid for lid, m in self.active_leases.items() if int(m["expires_at"]) <= now]
            if expired:
                await asyncio.to_thread(self.reconcile_mac_mesh)
                self.broadcast_snapshot()

            lid_now = is_lid_closed()
            if lid_now and not last_lid:
                await self.revoke_ssh_leases_on_lock("lid close")
            last_lid = lid_now

            # Check systemd-logind LockedHint + hyprlock process
            locked_now = False
            try:
                if subprocess.run(["pgrep", "-x", "hyprlock"], capture_output=True).returncode == 0:
                    locked_now = True
                else:
                    lg = subprocess.run(
                        ["loginctl", "list-sessions", "--no-legend"],
                        capture_output=True,
                        text=True,
                        timeout=2,
                    )
                    for ln in lg.stdout.splitlines():
                        parts = ln.split()
                        if len(parts) >= 3 and parts[2] == DESKTOP_USER:
                            pr = subprocess.run(
                                ["loginctl", "show-session", parts[0], "-p", "LockedHint", "--value"],
                                capture_output=True,
                                text=True,
                                timeout=2,
                            )
                            if pr.stdout.strip() == "yes":
                                locked_now = True
            except Exception:
                pass

            self.screen_locked = locked_now
            if locked_now and not last_locked:
                await self.revoke_ssh_leases_on_lock("screen lock")
            last_locked = locked_now
            self.broadcast_snapshot()

    async def run(self) -> None:
        self.init_keys_and_interface()
        if UI_SOCK_PATH.exists():
            UI_SOCK_PATH.unlink()
        server = await asyncio.start_unix_server(self.handle_ui_client, path=str(UI_SOCK_PATH))
        os.chmod(UI_SOCK_PATH, 0o666)  # Peer UID strictly enforced via SO_PEERCRED
        await asyncio.gather(
            server.serve_forever(),
            self.core_poll_loop(),
            self.watchdog_loop(),
        )

def main() -> None:
    daemon = MacMeshDaemon()
    asyncio.run(daemon.run())

if __name__ == "__main__":
    main()
