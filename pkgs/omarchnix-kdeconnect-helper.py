#!/usr/bin/env python3
"""omarchnix-kdeconnect-helper — Event-driven KDE Connect D-Bus helper for omarchnix.sharing.

Supports LAN discovery and WireGuard / lean-mesh (10.88.0.0/16) direct IP pairing
without any Tailscale dependency, legacy SNI tray icon, or polling churn.
"""

import ipaddress
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
from typing import Any

import gi
from gi.repository import Gio, GLib

KDECONNECT_CLI = "@KDECONNECT_CLI@"
IP_BIN = "@IP_BIN@"
SSHFS_BIN = "@SSHFS_BIN@"
FUSERMOUNT3_BIN = "@FUSERMOUNT3_BIN@"
GIO_BIN = "@GIO_BIN@"
XDG_OPEN_BIN = "@XDG_OPEN_BIN@"

BUS_NAME = "org.kde.kdeconnect"
DAEMON_PATH = "/modules/kdeconnect"
DAEMON_IFACE = "org.kde.kdeconnect.daemon"
DEVICE_IFACE = "org.kde.kdeconnect.device"
BATTERY_IFACE = "org.kde.kdeconnect.device.battery"
SHARE_IFACE = "org.kde.kdeconnect.device.share"
SFTP_IFACE = "org.kde.kdeconnect.device.sftp"
FINDMYPHONE_IFACE = "org.kde.kdeconnect.device.findmyphone"
PROPS_IFACE = "org.freedesktop.DBus.Properties"

SAFE_ID_RE = re.compile(r"^[A-Za-z0-9_]{1,128}$")
LEAN_MESH_NET = ipaddress.ip_network("10.88.0.0/16")

IGNORED_LAN_PREFIXES = (
    "lo",
    "awdl",
    "ve-",
    "veth",
    "docker",
    "podman",
    "br-",
    "virbr",
    "tun",
    "tap",
    "wg",
    "leanmesh",
)


def resolve_bin(configured: str, fallback_name: str) -> str:
    if configured and not configured.startswith("@") and os.path.exists(configured):
        return configured
    return shutil.which(fallback_name) or fallback_name


def is_safe_device_id(value: str) -> bool:
    return bool(SAFE_ID_RE.match(value or ""))


def normalize_ip(raw: str) -> str:
    text = (raw or "").strip()
    if text.startswith("[") and text.endswith("]"):
        text = text[1:-1].strip()
    if "%" in text:
        addr_part, zone = text.split("%", 1)
        if not zone or "%" in zone:
            raise ValueError("Invalid IPv6 zone")
        parsed = ipaddress.ip_address(addr_part)
        return f"{parsed.compressed}%{zone}"
    parsed = ipaddress.ip_address(text)
    return parsed.compressed


def seed_addresses_from_env() -> list[str]:
    raw = os.environ.get("OMARCHNIX_KDECONNECT_SEED_ADDRESSES", "").strip()
    if not raw:
        return []
    try:
        items = json.loads(raw)
    except Exception:
        return []
    if not isinstance(items, list):
        return []
    out: list[str] = []
    for item in items:
        try:
            norm = normalize_ip(str(item))
            if norm not in out:
                out.append(norm)
        except ValueError:
            continue
    return out


def discover_local_addresses() -> dict[str, str]:
    ip_bin = resolve_bin(IP_BIN, "ip")
    mesh_ip = ""
    mesh_if = ""
    lan_ip = ""
    lan_if = ""
    try:
        res = subprocess.run(
            [ip_bin, "-j", "-4", "addr", "show", "up"],
            capture_output=True,
            text=True,
            timeout=2.0,
            check=False,
        )
        if res.returncode == 0 and res.stdout.strip():
            ifaces = json.loads(res.stdout)
            for iface in ifaces if isinstance(ifaces, list) else []:
                ifname = str(iface.get("ifname") or "")
                if not ifname or ifname == "lo":
                    continue
                for info in iface.get("addr_info") or []:
                    if info.get("family") != "inet":
                        continue
                    local = str(info.get("local") or "")
                    if not local:
                        continue
                    try:
                        addr = ipaddress.ip_address(local)
                    except ValueError:
                        continue
                    if addr.is_loopback or addr.is_link_local:
                        continue
                    is_mesh_iface = (
                        ifname.startswith("wg-leanmesh")
                        or ifname.startswith("leanmesh")
                        or addr in LEAN_MESH_NET
                    )
                    if is_mesh_iface and not mesh_ip:
                        mesh_ip = local
                        mesh_if = ifname
                        continue
                    if not lan_ip and not any(ifname.startswith(p) for p in IGNORED_LAN_PREFIXES):
                        lan_ip = local
                        lan_if = ifname
    except Exception:
        pass
    return {
        "mesh": mesh_ip,
        "meshInterface": mesh_if,
        "lan": lan_ip,
        "lanInterface": lan_if,
    }


def dbus_call(
    conn: Gio.DBusConnection,
    object_path: str,
    interface: str,
    method: str,
    params: GLib.Variant | None = None,
    reply_type: str | None = None,
    timeout_ms: int = 3000,
) -> Any:
    vtype = GLib.VariantType.new(reply_type) if reply_type else None
    res = conn.call_sync(
        BUS_NAME,
        object_path,
        interface,
        method,
        params,
        vtype,
        Gio.DBusCallFlags.NONE,
        timeout_ms,
        None,
    )
    return res.unpack() if res is not None else None


def ensure_daemon(conn: Gio.DBusConnection) -> bool:
    try:
        has_owner = conn.call_sync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            GLib.Variant("(s)", (BUS_NAME,)),
            GLib.VariantType.new("(b)"),
            Gio.DBusCallFlags.NONE,
            1500,
            None,
        ).unpack()[0]
        if has_owner:
            return True
        conn.call_sync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "StartServiceByName",
            GLib.Variant("(su)", (BUS_NAME, 0)),
            GLib.VariantType.new("(u)"),
            Gio.DBusCallFlags.NONE,
            4000,
            None,
        )
        return True
    except Exception:
        return False


def get_custom_devices(conn: Gio.DBusConnection) -> list[str]:
    try:
        val = dbus_call(
            conn,
            DAEMON_PATH,
            PROPS_IFACE,
            "Get",
            GLib.Variant("(ss)", (DAEMON_IFACE, "customDevices")),
            "(v)",
        )
        raw = val[0] if val else []
        out: list[str] = []
        for item in raw if isinstance(raw, list) else []:
            try:
                norm = normalize_ip(str(item))
                if norm not in out:
                    out.append(norm)
            except ValueError:
                continue
        return out
    except Exception:
        return []


def set_custom_devices(conn: Gio.DBusConnection, addresses: list[str]) -> None:
    dbus_call(
        conn,
        DAEMON_PATH,
        PROPS_IFACE,
        "Set",
        GLib.Variant("(ssv)", (DAEMON_IFACE, "customDevices", GLib.Variant("as", addresses))),
        None,
    )


def ensure_seed_addresses(conn: Gio.DBusConnection) -> list[str]:
    current = get_custom_devices(conn)
    seeds = seed_addresses_from_env()
    if not seeds:
        return current
    merged = list(current)
    changed = False
    for s in seeds:
        if s not in merged:
            merged.append(s)
            changed = True
    if changed:
        try:
            set_custom_devices(conn, merged)
            dbus_call(conn, DAEMON_PATH, DAEMON_IFACE, "forceOnNetworkChange")
            return merged
        except Exception:
            return current
    return current


def device_sort_key(dev: dict[str, Any]) -> tuple[int, str, str]:
    if dev.get("pairRequestedByPeer") or dev.get("pairRequested"):
        rank = 0
    elif dev.get("connected"):
        rank = 1
    elif dev.get("pairable"):
        rank = 2
    elif dev.get("paired"):
        rank = 3
    else:
        rank = 4
    return (rank, str(dev.get("name") or "").lower(), str(dev.get("id") or ""))


def build_snapshot(conn: Gio.DBusConnection, seed_once: bool = False) -> dict[str, Any]:
    local_addrs = discover_local_addresses()
    if not ensure_daemon(conn):
        return {
            "version": 1,
            "daemonRunning": False,
            "localAddresses": local_addrs,
            "customAddresses": [],
            "devices": [],
        }

    custom_addrs = ensure_seed_addresses(conn) if seed_once else get_custom_devices(conn)

    try:
        dev_res = dbus_call(
            conn,
            DAEMON_PATH,
            DAEMON_IFACE,
            "devices",
            GLib.Variant("(bb)", (False, False)),
            "(as)",
        )
        device_ids = [d for d in (dev_res[0] if dev_res else []) if is_safe_device_id(str(d))]
    except Exception:
        return {
            "version": 1,
            "daemonRunning": False,
            "localAddresses": local_addrs,
            "customAddresses": custom_addrs,
            "devices": [],
        }

    devices: list[dict[str, Any]] = []
    for dev_id in device_ids:
        dev_path = f"{DAEMON_PATH}/devices/{dev_id}"
        try:
            props_res = dbus_call(
                conn,
                dev_path,
                PROPS_IFACE,
                "GetAll",
                GLib.Variant("(s)", (DEVICE_IFACE,)),
                "(a{sv})",
            )
            props = props_res[0] if props_res else {}
        except Exception:
            continue

        reachable = bool(props.get("isReachable", False))
        paired = bool(props.get("isPaired", False))
        pair_req = bool(props.get("isPairRequested", False))
        pair_req_peer = bool(props.get("isPairRequestedByPeer", False))

        loaded: list[str] = []
        if reachable and paired:
            try:
                lp_res = dbus_call(conn, dev_path, DEVICE_IFACE, "loadedPlugins", None, "(as)")
                loaded = [str(x) for x in (lp_res[0] if lp_res else [])]
            except Exception:
                loaded = []

        battery_pct = -1
        charging = False
        if "kdeconnect_battery" in loaded:
            try:
                bat_res = dbus_call(
                    conn,
                    f"{dev_path}/battery",
                    PROPS_IFACE,
                    "GetAll",
                    GLib.Variant("(s)", (BATTERY_IFACE,)),
                    "(a{sv})",
                )
                bat_props = bat_res[0] if bat_res else {}
                charge = int(bat_props.get("charge", -1))
                if 0 <= charge <= 100:
                    battery_pct = charge
                    charging = bool(bat_props.get("isCharging", False))
            except Exception:
                pass

        # Hide stale unreachable unpaired ghosts that have no pending pair state
        if not paired and not reachable and not pair_req and not pair_req_peer:
            continue

        devices.append(
            {
                "id": dev_id,
                "name": str(props.get("name") or dev_id),
                "type": str(props.get("type") or "smartphone"),
                "reachable": reachable,
                "paired": paired,
                "connected": reachable and paired,
                "pairable": reachable and not paired,
                "pairRequested": pair_req,
                "pairRequestedByPeer": pair_req_peer,
                "verificationKey": str(props.get("verificationKey") or ""),
                "battery": battery_pct,
                "charging": charging,
                "caps": {
                    "clipboard": "kdeconnect_clipboard" in loaded,
                    "share": "kdeconnect_share" in loaded,
                    "ring": "kdeconnect_findmyphone" in loaded,
                    "sftp": "kdeconnect_sftp" in loaded,
                },
            }
        )

    devices.sort(key=device_sort_key)
    return {
        "version": 1,
        "daemonRunning": True,
        "localAddresses": local_addrs,
        "customAddresses": custom_addrs,
        "devices": devices,
    }


def emit_json(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def cmd_watch(conn: Gio.DBusConnection) -> int:
    emit_json(build_snapshot(conn, seed_once=True))

    loop = GLib.MainLoop()
    pending = {"timer": 0}

    def flush_snapshot() -> bool:
        pending["timer"] = 0
        try:
            emit_json(build_snapshot(conn, seed_once=False))
        except BrokenPipeError:
            loop.quit()
        except Exception:
            pass
        return False

    def schedule_refresh(*_args: Any) -> None:
        if pending["timer"] != 0:
            GLib.source_remove(pending["timer"])
        pending["timer"] = GLib.timeout_add(180, flush_snapshot)

    def on_name_owner_changed(
        _c: Gio.DBusConnection,
        _sender: str,
        _path: str,
        _iface: str,
        _sig: str,
        params: GLib.Variant,
    ) -> None:
        name, _old, _new = params.unpack()
        if name == BUS_NAME:
            schedule_refresh()

    conn.signal_subscribe(
        BUS_NAME,
        None,
        None,
        None,
        None,
        Gio.DBusSignalFlags.NONE,
        schedule_refresh,
    )
    conn.signal_subscribe(
        "org.freedesktop.DBus",
        "org.freedesktop.DBus",
        "NameOwnerChanged",
        "/org/freedesktop/DBus",
        BUS_NAME,
        Gio.DBusSignalFlags.NONE,
        on_name_owner_changed,
    )

    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    return 0


def run_kdeconnect_cli(args: list[str], timeout_sec: float = 10.0) -> subprocess.CompletedProcess[str]:
    cli = resolve_bin(KDECONNECT_CLI, "kdeconnect-cli")
    env = dict(os.environ)
    env.setdefault("QT_QPA_PLATFORM", "wayland;xcb")
    return subprocess.run(
        [cli, *args],
        capture_output=True,
        text=True,
        timeout=timeout_sec,
        env=env,
        check=False,
    )


def unmount_stale_sshfs(mount_point: str) -> None:
    if not mount_point:
        return
    try:
        mounts = pathlib.Path("/proc/mounts").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    if f"{mount_point} fuse.sshfs " not in mounts:
        return
    for candidate in (
        FUSERMOUNT3_BIN,
        "/run/wrappers/bin/fusermount3",
        shutil.which("fusermount3") or "",
        shutil.which("fusermount") or "",
    ):
        if not candidate or candidate.startswith("@") or not os.path.exists(candidate):
            continue
        res = subprocess.run([candidate, "-uz", mount_point], capture_output=True, check=False)
        if res.returncode == 0:
            return
        subprocess.run([candidate, "-u", mount_point], capture_output=True, check=False)
        return


def cmd_browse_files(conn: Gio.DBusConnection, dev_id: str) -> int:
    sshfs_bin = resolve_bin(SSHFS_BIN, "sshfs")
    if not shutil.which(sshfs_bin) and not os.path.exists(sshfs_bin):
        sys.stderr.write("sshfs is not installed\n")
        return 1

    sftp_path = f"{DAEMON_PATH}/devices/{dev_id}/sftp"
    mount_point = ""
    is_mounted = False
    try:
        mp = dbus_call(conn, sftp_path, SFTP_IFACE, "mountPoint", None, "(s)")
        mount_point = str(mp[0]) if mp else ""
        im = dbus_call(conn, sftp_path, SFTP_IFACE, "isMounted", None, "(b)")
        is_mounted = bool(im[0]) if im else False
    except Exception:
        pass

    if mount_point and not is_mounted:
        unmount_stale_sshfs(mount_point)

    try:
        mounted_res = dbus_call(
            conn, sftp_path, SFTP_IFACE, "mountAndWait", None, "(b)", timeout_ms=20000
        )
        mounted = bool(mounted_res[0]) if mounted_res else False
    except Exception as exc:
        sys.stderr.write(f"Could not mount phone storage: {exc}\n")
        return 1

    if not mounted:
        reason = ""
        try:
            err_res = dbus_call(conn, sftp_path, SFTP_IFACE, "getMountError", None, "(s)")
            reason = str(err_res[0]) if err_res else ""
        except Exception:
            pass
        sys.stderr.write((reason or "Phone denied or disabled filesystem exposure") + "\n")
        return 1

    target = mount_point
    try:
        dirs_res = dbus_call(conn, sftp_path, SFTP_IFACE, "getDirectories", None, "(a{sv})")
        dirs_map = dirs_res[0] if dirs_res else {}
        if isinstance(dirs_map, dict) and dirs_map:
            target = next(iter(dirs_map.keys()))
    except Exception:
        pass

    if not target:
        sys.stderr.write("Phone storage mount point unavailable\n")
        return 1

    opener = resolve_bin(XDG_OPEN_BIN, "xdg-open")
    gio_bin = resolve_bin(GIO_BIN, "gio")
    if os.path.exists(gio_bin) or shutil.which(gio_bin):
        subprocess.Popen(
            [gio_bin, "open", target],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    else:
        subprocess.Popen(
            [opener, target],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    return 0


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "snapshot"
    conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    if cmd == "snapshot":
        emit_json(build_snapshot(conn, seed_once=True))
        return 0

    if cmd == "watch":
        return cmd_watch(conn)

    if not ensure_daemon(conn):
        sys.stderr.write("KDE Connect daemon is not running\n")
        return 1

    if cmd == "refresh":
        try:
            dbus_call(conn, DAEMON_PATH, DAEMON_IFACE, "forceOnNetworkChange")
        except Exception:
            run_kdeconnect_cli(["--refresh"])
        return 0

    if cmd in ("add-address", "remove-address"):
        if len(argv) < 3:
            sys.stderr.write("IP address required\n")
            return 1
        try:
            norm = normalize_ip(argv[2])
        except ValueError:
            sys.stderr.write("Enter a valid IPv4 or IPv6 address (without port)\n")
            return 1
        addrs = get_custom_devices(conn)
        if cmd == "add-address":
            if norm not in addrs:
                addrs.append(norm)
                set_custom_devices(conn, addrs)
            dbus_call(conn, DAEMON_PATH, DAEMON_IFACE, "forceOnNetworkChange")
        else:
            next_addrs = [a for a in addrs if a != norm]
            if len(next_addrs) != len(addrs):
                set_custom_devices(conn, next_addrs)
        return 0

    if cmd == "send-clipboard":
        target = argv[2] if len(argv) > 2 else "--all"
        if target == "--all":
            snap = build_snapshot(conn)
            targets = [
                d["id"]
                for d in snap.get("devices", [])
                if d.get("connected") and d.get("caps", {}).get("clipboard")
            ]
            if not targets:
                sys.stderr.write("No connected phone with clipboard sync enabled\n")
                return 1
            rc = 0
            for dev_id in targets:
                res = run_kdeconnect_cli(["--device", dev_id, "--send-clipboard"])
                if res.returncode != 0:
                    rc = res.returncode
            return rc
        if not is_safe_device_id(target):
            sys.stderr.write("Invalid device ID\n")
            return 1
        res = run_kdeconnect_cli(["--device", target, "--send-clipboard"])
        if res.returncode != 0:
            sys.stderr.write((res.stderr or "Clipboard send failed").strip() + "\n")
        return res.returncode

    if len(argv) < 3 or not is_safe_device_id(argv[2]):
        sys.stderr.write("Valid device ID required\n")
        return 1
    dev_id = argv[2]
    dev_path = f"{DAEMON_PATH}/devices/{dev_id}"

    if cmd == "pair":
        dbus_call(conn, dev_path, DEVICE_IFACE, "requestPairing")
        return 0
    if cmd == "accept":
        dbus_call(conn, dev_path, DEVICE_IFACE, "acceptPairing")
        return 0
    if cmd == "reject":
        dbus_call(conn, dev_path, DEVICE_IFACE, "cancelPairing")
        return 0
    if cmd == "unpair":
        dbus_call(conn, dev_path, DEVICE_IFACE, "unpair")
        return 0
    if cmd == "ring":
        try:
            dbus_call(conn, f"{dev_path}/findmyphone", FINDMYPHONE_IFACE, "ring")
            return 0
        except Exception:
            res = run_kdeconnect_cli(["--device", dev_id, "--ring"])
            return res.returncode
    if cmd == "browse-files":
        return cmd_browse_files(conn, dev_id)
    if cmd == "send-files":
        raw_stdin = sys.stdin.read().strip()
        files: list[str] = []
        if raw_stdin:
            parsed = json.loads(raw_stdin)
            if isinstance(parsed, list):
                files = [str(p).strip() for p in parsed if str(p).strip()]
        else:
            files = [p.strip() for p in argv[3:] if p.strip()]
        if not files:
            sys.stderr.write("No files selected\n")
            return 1
        uris = [pathlib.Path(f).expanduser().resolve().as_uri() for f in files]
        try:
            dbus_call(
                conn,
                f"{dev_path}/share",
                SHARE_IFACE,
                "shareUrls",
                GLib.Variant("(as)", (uris,)),
                None,
                timeout_ms=10000,
            )
            return 0
        except Exception:
            rc = 0
            for f in files:
                res = run_kdeconnect_cli(["--device", dev_id, "--share", f])
                if res.returncode != 0:
                    rc = res.returncode
            return rc

    sys.stderr.write(f"Unknown subcommand: {cmd}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
