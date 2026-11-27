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

        # BlueZ 5.87 Linux BLE fixes (open_oura PRs #24/#26 + D-Bus robustness):
        # 1. Reuse a single process-global `Manager` (D-Bus BluetoothSession) and
        #    abort `_pump` on Drop so reconnects never leak D-Bus clients or stack
        #    BlueZ `StartNotify` refcounts (which caused 3x duplicate PropertiesChanged
        #    broadcasts / 150 Hz ACM echoes that broke 50 Hz gesture templates).
        # 2. Avoid `ScanFilter { services: [OURA_SERVICE] }` which triggers a
        #    bluetoothd 5.87 SetDiscoveryFilter crash / empty discovery on Linux;
        #    filter by `OURA_SERVICE` in software (already present in ble.rs).
        # 3. Skip peripherals whose D-Bus object vanished between `peripherals()`
        #    and `p.properties()` (prevents `Method "GetAll" ... doesn't exist`
        #    on first toggle / stale RPA teardown).
        # 4. Match both `p.id()` and `props.address` for `--address` on Linux.
        # 5. Keep discovery running until after `connect()` so BlueZ resolves
        #    bonded RPA addresses cleanly, then stop scan.
        # 6. Deduplicate identical BLE notifications arriving within 8 ms in `_pump`
        #    as defense-in-depth against multi-client BlueZ broadcast echoes.
        ${pkgs.python3}/bin/python3 - "$out/open_oura/crates/oura-link/src/ble.rs" <<'PY'
    import re
    import sys
    from pathlib import Path

    p = Path(sys.argv[1])
    src = p.read_text()

    old_mgr = """async fn first_adapter() -> Result<btleplug::platform::Adapter> {
        let manager = Manager::new().await?;"""
    new_mgr = """static BLE_MANAGER: tokio::sync::OnceCell<Manager> = tokio::sync::OnceCell::const_new();

    impl Drop for BleTransport {
        fn drop(&mut self) {
            self._pump.abort();
        }
    }

    async fn first_adapter() -> Result<btleplug::platform::Adapter> {
        let manager = BLE_MANAGER
            .get_or_try_init(|| async { Manager::new().await })
            .await?;"""
    assert old_mgr in src, "expected first_adapter() in ble.rs"
    src = src.replace(old_mgr, new_mgr, 1)

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

    old_props = "let Some(props) = p.properties().await? else {"
    new_props = "let Ok(Some(props)) = p.properties().await else {"
    assert src.count(old_props) == 2, f"expected 2 p.properties() calls, found {src.count(old_props)}"
    src = src.replace(old_props, new_props)

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
    new_conn = """            if !peripheral.is_connected().await.unwrap_or(false) {
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
                // when present — avoids duplicate notification echoes on Ring 5
                // and cuts GATT setup latency by 75%.
                let notify_list: Vec<_> = notify_chars.collect();
                let mut subscribed = 0usize;
                if let Some(primary) = notify_list.iter().find(|c| c.uuid == protocol::OURA_NOTIFY) {
                    match peripheral.subscribe(primary).await {
                        Ok(()) => subscribed += 1,
                        Err(e) if e.to_string().contains("Already") || e.to_string().contains("InProgress") => {
                            subscribed += 1;
                        }
                        Err(_) => {}
                    }
                }
                if subscribed == 0 {
                    for c in notify_list {
                        match peripheral.subscribe(c).await {
                            Ok(()) => subscribed += 1,
                            Err(e) if e.to_string().contains("Already") || e.to_string().contains("InProgress") => {
                                subscribed += 1;
                            }
                            Err(_) => {}
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

    old_pump = """        let pump = tokio::spawn(async move {
                if let Ok(mut stream) = pump_peripheral.notifications().await {
                    while let Some(n) = stream.next().await {
                        // Best-effort fan-out; ignore if there are no live receivers.
                        let _ = pump_tx.send(n.value);
                    }
                }
            });"""
    new_pump = """        let pump = tokio::spawn(async move {
                if let Ok(mut stream) = pump_peripheral.notifications().await {
                    let mut last_val: Option<Vec<u8>> = None;
                    let mut last_at = Instant::now();
                    while let Some(n) = stream.next().await {
                        if last_val.as_deref() == Some(n.value.as_slice())
                            && last_at.elapsed() < Duration::from_millis(8)
                        {
                            continue;
                        }
                        last_val = Some(n.value.clone());
                        last_at = Instant::now();
                        // Best-effort fan-out; ignore if there are no live receivers.
                        let _ = pump_tx.send(n.value);
                    }
                }
            });"""
    assert old_pump in src, "expected notification pump in ble.rs"
    src = src.replace(old_pump, new_pump, 1)

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
