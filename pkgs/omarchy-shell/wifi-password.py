#!/usr/bin/env python3
"""Show or copy the personal Wi-Fi key for one network selected in the panel."""

import subprocess
import sys


def nmcli(*args, secret=False):
    command = ["nmcli", "--escape", "no"]
    if secret:
        command.append("--show-secrets")
    result = subprocess.run(command + list(args), capture_output=True, check=True)
    return result.stdout.decode().removesuffix("\n")


def field(uuid, name, secret=False):
    return nmcli("-g", name, "connection", "show", "uuid", uuid, secret=secret)


def profile_for(ssid, iface):
    active = nmcli("-g", "GENERAL.CON-UUID", "device", "show", iface)
    wifi_ssid = "802-11-wireless.ssid"
    if active and active != "--" and field(active, wifi_ssid) == ssid:
        return active

    matches = []
    for line in nmcli("-t", "-f", "UUID,TYPE", "connection", "show").splitlines():
        uuid, kind = line.split(":", 1)
        if kind == "802-11-wireless" and field(uuid, wifi_ssid) == ssid:
            matches.append(uuid)
    if len(matches) == 1:
        return matches[0]
    if matches:
        raise ValueError("Several profiles use this network name. Connect the desired profile first.")
    raise ValueError("This network has no accessible saved profile.")


def password_for(uuid):
    prefix = "802-11-wireless-security."
    security = field(uuid, prefix + "key-mgmt")
    if security in ("wpa-psk", "sae", "wpa-none"):
        key = "psk"
    elif security == "none":
        key = "wep-key" + field(uuid, prefix + "wep-tx-keyidx")
    else:
        raise ValueError("This network has no shareable personal Wi-Fi password.")
    value = field(uuid, prefix + key, secret=True)
    if not value:
        raise ValueError("NetworkManager could not provide a saved password for this profile.")
    return value.encode()


def main(action, ssid, iface):
    try:
        value = password_for(profile_for(ssid, iface))
        if action == "copy":
            subprocess.run(["wl-copy", "--sensitive"], input=value, check=True)
        elif action == "show":
            subprocess.run(
                ["zenity", "--text-info", "--title", f"Wi-Fi password · {ssid}",
                 "--width=420", "--height=180"], input=value, check=False
            )
    except (ValueError, subprocess.CalledProcessError) as exc:
        message = str(exc) if isinstance(exc, ValueError) else "Could not access the saved password or clipboard."
        subprocess.run(["zenity", "--error", "--text", message], check=False)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
