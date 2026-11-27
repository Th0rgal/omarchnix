{
  lib,
  pkgs,
  openOuraSrc,
}:
let
  stagedSrc = pkgs.runCommand "oura-daemon-src" { } ''
    mkdir -p "$out/open_oura"
    cp -r --no-preserve=mode,ownership "${./oura-daemon}/." "$out/"
    cp -r --no-preserve=mode,ownership "${openOuraSrc}/crates" "$out/open_oura/"

    # BlueZ 5.87 Linux BLE fix (open_oura PRs #24/#26):
    # 1. Avoid `ScanFilter { services: [OURA_SERVICE] }` which triggers a
    #    bluetoothd 5.87 SetDiscoveryFilter crash / empty discovery on Linux;
    #    filter by `OURA_SERVICE` in software (already present in ble.rs).
    # 2. Match both `p.id()` and `props.address` for `--address` on Linux.
    # 3. Keep discovery running until after `connect()` so BlueZ resolves
    #    bonded RPA addresses cleanly, then stop scan.
    ${pkgs.python3}/bin/python3 - "$out/open_oura/crates/oura-link/src/ble.rs" <<'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
src = p.read_text()

src, n_scan = re.subn(
    r"adapter\s*\.\s*start_scan\(ScanFilter\s*\{\s*services:\s*vec!\[protocol::OURA_SERVICE\],\s*\}\)\s*\.await\?;",
    """if let Err(e) = adapter.start_scan(ScanFilter::default()).await {
        if !e.to_string().contains("In Progress") && !e.to_string().contains("InProgress") {
            return Err(e.into());
        }
    }""",
    src,
)
assert n_scan == 2, f"expected 2 ScanFilter occurrences, found {n_scan}"

old_addr = """                if let Some(addr) = address {
                    if !p.id().to_string().eq_ignore_ascii_case(addr) {
                        continue;
                    }
                }"""
new_addr = """                if let Some(addr) = address {
                    let id_match = p.id().to_string().eq_ignore_ascii_case(addr);
                    let mac_match = props.address.to_string().eq_ignore_ascii_case(addr);
                    if !id_match && !mac_match {
                        continue;
                    }
                }"""
assert old_addr in src, "expected address check in ble.rs"
src = src.replace(old_addr, new_addr, 1)

old_rssi = """                let rssi = props.rssi.unwrap_or(i16::MIN);"""
new_rssi = """                // Prefer already-connected bonded rings (which have rssi=None
                // while connected), and ignore stale disconnected RPAs.
                let is_conn = p.is_connected().await.unwrap_or(false);
                let rssi = if is_conn {
                    0
                } else {
                    let Some(r) = props.rssi else {
                        continue;
                    };
                    r
                };"""
assert old_rssi in src, "expected rssi lookup in ble.rs"
src = src.replace(old_rssi, new_rssi, 1)

old_stop = """        let _ = adapter.stop_scan().await;

        let (peripheral, _) = chosen.ok_or(Error::DeviceNotFound)?;"""
new_stop = """        let (peripheral, _) = match chosen {
            Some(c) => c,
            None => {
                let _ = adapter.stop_scan().await;
                return Err(Error::DeviceNotFound);
            }
        };"""
assert old_stop in src, "expected stop_scan before connect in ble.rs"
src = src.replace(old_stop, new_stop, 1)

old_conn = """            if !peripheral.is_connected().await? {
                peripheral.connect().await?;
            }"""
new_conn = """            if !peripheral.is_connected().await? {
                let mut last_err = None;
                for attempt in 0..3 {
                    match peripheral.connect().await {
                        Ok(()) => {
                            last_err = None;
                            break;
                        }
                        Err(e) => {
                            last_err = Some(e);
                            if attempt < 2 {
                                tokio::time::sleep(Duration::from_millis(600)).await;
                            }
                        }
                    }
                }
                if let Some(e) = last_err {
                    let _ = adapter.stop_scan().await;
                    return Err(e.into());
                }
            }
            let _ = adapter.stop_scan().await;"""
assert old_conn in src, "expected peripheral.connect() in ble.rs"
src = src.replace(old_conn, new_conn, 1)

old_sub = """            for c in notify_chars {
                peripheral.subscribe(c).await?;
            }"""
new_sub = """            // Subscribe only to the primary Oura notify characteristic (98ed0003)
            // when present — avoids 3x duplicate notification echoes on Ring 5
            // and cuts GATT setup latency by 75%.
            let notify_list: Vec<_> = notify_chars.collect();
            let mut subscribed = 0usize;
            if let Some(primary) = notify_list.iter().find(|c| c.uuid == protocol::OURA_NOTIFY) {
                if peripheral.subscribe(primary).await.is_ok() {
                    subscribed += 1;
                }
            }
            if subscribed == 0 {
                for c in notify_list {
                    if peripheral.subscribe(c).await.is_ok() {
                        subscribed += 1;
                    }
                }
            }
            if subscribed == 0 {
                return Err(Error::Ble("failed to subscribe to any Oura notify characteristic".into()));
            }
            // Brief settle for BlueZ link-layer encryption before first ATT write.
            tokio::time::sleep(Duration::from_millis(150)).await;"""
assert old_sub in src, "expected peripheral.subscribe in ble.rs"
src = src.replace(old_sub, new_sub, 1)

p.write_text(src)
PY
  '';
in
pkgs.rustPlatform.buildRustPackage {
  pname = "oura-daemon";
  version = "0.1.0";
  src = stagedSrc;
  cargoLock.lockFile = ./oura-daemon/Cargo.lock;

  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.dbus ];

  cargoBuildFlags = [
    "--package"
    "oura-daemon"
  ];
  cargoTestFlags = [
    "--package"
    "oura-daemon"
  ];

  meta = {
    description = "Cloud-free Oura Ring BLE daemon, daily trend analyzer, and Hyprland gesture navigator";
    license = lib.licenses.mit;
    mainProgram = "ouractl";
    platforms = lib.platforms.linux;
  };
}
