#!/usr/bin/env python3
"""
lean-mesh-p2p-punch.py — Zero-open-port WireGuard UDP hole-punching reconciler
for non-NixOS peers (e.g. dgx-spark / umbrel on Ubuntu).

Uses the existing `orb-core:51890` blind relay purely for in-band `RNDZ`
endpoint discovery (authenticated by WireGuard RFC 7693 `mac1`), then points
kernel WireGuard directly at the peer's observed NAT ip:port. Automatically
falls back to `relay` if symmetric NAT blocks direct handshakes.
"""
import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import time


def wg_mac1(pub32: bytes, prefix: bytes) -> bytes:
    key = hashlib.blake2s(b"mac1----" + pub32, digest_size=32).digest()
    return hashlib.blake2s(prefix, key=key, digest_size=16).digest()


def query_rndz(relay_ep: str, self_pub32: bytes, peer_pub32: bytes, timeout: float = 1.0):
    host, port_s = relay_ep.rsplit(":", 1)
    prefix = b"RNDZ" + self_pub32 + peer_pub32
    req = prefix + wg_mac1(peer_pub32, prefix)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(req, (host, int(port_s)))
        resp, _ = sock.recvfrom(64)
        if len(resp) == 16 and resp[:4] == b"RNDR":
            ip_u32, peer_port, flags, age_s = struct.unpack("!IHHI", resp[4:16])
            if flags in (1, 2) and ip_u32 != 0 and peer_port != 0 and age_s <= 120:
                ip_str = socket.inet_ntoa(struct.pack("!I", ip_u32))
                if not ip_str.startswith("127."):
                    return f"{ip_str}:{peer_port}"
    except Exception:
        return None
    finally:
        sock.close()
    return None


def wg_dump(iface: str):
    out = subprocess.run(["wg", "show", iface, "dump"], capture_output=True, text=True)
    if out.returncode != 0:
        return {}
    state = {}
    for idx, line in enumerate(out.stdout.splitlines()):
        cols = line.split("\t")
        if idx > 0 and len(cols) >= 8:
            state[cols[0]] = {
                "endpoint": cols[2] if cols[2] != "(none)" else "",
                "handshake": int(cols[4] or "0"),
                "keepalive": cols[7],
            }
    return state


def reconcile_once(iface: str, self_pub_b64: str, peer_pub_b64: str, relay_ep: str, state_file: str, max_stale: int):
    now = int(time.time())
    self_pub32 = base64.b64decode(self_pub_b64)
    peer_pub32 = base64.b64decode(peer_pub_b64)
    cur = wg_dump(iface).get(peer_pub_b64, {"endpoint": "", "handshake": 0, "keepalive": "off"})

    try:
        prev = json.load(open(state_file, "r", encoding="utf-8"))
    except Exception:
        prev = {}

    p2p_ep = query_rndz(relay_ep, self_pub32, peer_pub32)
    if not p2p_ep and prev.get("p2p_ep"):
        if cur["endpoint"] == prev["p2p_ep"] and cur["handshake"] > 0 and (now - cur["handshake"]) <= max_stale:
            p2p_ep = prev["p2p_ep"]

    probe_at = int(prev.get("probe_at") or 0)
    backoff_until = int(prev.get("backoff_until") or 0)
    last_direct_hs = int(prev.get("last_direct_hs") or 0)
    if p2p_ep != prev.get("p2p_ep"):
        probe_at = backoff_until = last_direct_hs = 0

    use_p2p = False
    if p2p_ep:
        if cur["endpoint"] == p2p_ep:
            fresh_boot = probe_at == 0
            if fresh_boot:
                probe_at = now
            if cur["handshake"] >= probe_at or (fresh_boot and last_direct_hs == 0 and cur["handshake"] > 0 and (now - cur["handshake"]) <= max_stale):
                last_direct_hs = max(last_direct_hs, cur["handshake"])
                backoff_until = 0
            if last_direct_hs > 0 and (now - last_direct_hs) <= max_stale:
                use_p2p = True
            elif last_direct_hs == 0 and (now - probe_at) <= 30:
                use_p2p = True
            else:
                backoff_until = now + 120
        elif now >= backoff_until:
            probe_at = now
            last_direct_hs = 0
            use_p2p = True

    target_ep = p2p_ep if use_p2p else relay_ep
    if target_ep != cur["endpoint"]:
        subprocess.run(["wg", "set", iface, "peer", peer_pub_b64, "persistent-keepalive", "0"], check=False)
        subprocess.run(["wg", "set", iface, "peer", peer_pub_b64, "endpoint", target_ep, "persistent-keepalive", "25"], check=False)

    os.makedirs(os.path.dirname(state_file), exist_ok=True)
    tmp = f"{state_file}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "path_kind": "direct_p2p" if use_p2p else "control_plane_relay",
                "endpoint": target_ep,
                "p2p_ep": p2p_ep,
                "probe_at": probe_at,
                "backoff_until": backoff_until,
                "last_direct_hs": last_direct_hs,
                "updated_at": now,
            },
            fh,
        )
    os.chmod(tmp, 0o644)
    os.replace(tmp, state_file)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", default="wg-homemesh0")
    ap.add_argument("--self-pub", required=True)
    ap.add_argument("--peer-pub", required=True)
    ap.add_argument("--relay", default="65.109.98.246:51890")
    ap.add_argument("--state-file", default="/run/lean-mesh-wg-homemesh0/p2p-punch.json")
    ap.add_argument("--max-stale", type=int, default=210)
    args = ap.parse_args()
    reconcile_once(args.iface, args.self_pub, args.peer_pub, args.relay, args.state_file, args.max_stale)


if __name__ == "__main__":
    main()
