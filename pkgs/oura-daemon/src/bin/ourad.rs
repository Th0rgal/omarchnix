//! `ourad` — long-lived cloud-free Oura Ring BLE daemon for Omarchnix.
//!
//! Owns the single BLE GATT link to the ring, maintains local SQLite history +
//! daily trends (`oura.db`), runs the Ring Runner–derived gesture engine on the
//! live ~50 Hz ACM stream when Gesture Mode is enabled, and serves real-time
//! snapshots + control commands over `$XDG_RUNTIME_DIR/ourad.sock`.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc, watch};

use oura_daemon::gesture::{GestureConfig, GestureDetector, GestureTemplates};
use oura_daemon::hyprland;
use oura_daemon::ipc::{default_socket_path, DaemonSnapshot, GestureToggleMode, Request, Response};
use oura_daemon::summary::{compute_daily_trends, load_cached_device};
use oura_link::ble::BleTransport;
use oura_link::client::AcmSample;
use oura_link::transport::Transport;
use oura_link::OuraClient;
use oura_protocol::protocol::{self, feature};
use oura_store::storage::Store;

#[derive(Parser, Debug)]
#[command(name = "ourad", version, about = "Omarchnix Oura Ring BLE daemon")]
struct Args {
    /// Device name substring filter when scanning.
    #[arg(long, default_value = "Oura")]
    name: String,

    /// Optional exact BLE address / identifier to target.
    #[arg(long)]
    address: Option<String>,

    /// Path to the 16-byte hex auth key file (e.g. sops-nix `/run/secrets/oura_auth_key`).
    #[arg(long)]
    key_file: Option<PathBuf>,

    /// Path to SQLite history database.
    #[arg(long)]
    db: Option<PathBuf>,

    /// Path to persisted gesture config & calibration JSON.
    #[arg(long)]
    config_file: Option<PathBuf>,

    /// Unix socket path.
    #[arg(long)]
    socket: Option<PathBuf>,

    /// BLE scan timeout in seconds.
    #[arg(long, default_value_t = 25)]
    scan_timeout: u64,

    /// Periodic background sync interval in minutes (0 disables periodic sync).
    #[arg(long, default_value_t = 15)]
    sync_interval_minutes: u64,
}

enum DaemonCmd {
    Sync,
    LiveHr { seconds: u64 },
    Gestures { mode: GestureToggleMode },
    ZeroNeutral,
    Calibrate,
    UpdateConfig {
        invert_h: Option<bool>,
        require_lift_to_arm: Option<bool>,
        swipe_accel_g: Option<f64>,
        lift_accel_g: Option<f64>,
        auto_off_minutes: Option<u32>,
    },
    Shutdown,
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn default_db_path() -> PathBuf {
    let data = std::env::var("XDG_DATA_HOME").unwrap_or_else(|_| {
        format!(
            "{}/.local/share",
            std::env::var("HOME").unwrap_or_else(|_| "/tmp".into())
        )
    });
    PathBuf::from(data).join("oura").join("oura.db")
}

fn default_config_path() -> PathBuf {
    let state = std::env::var("XDG_STATE_HOME").unwrap_or_else(|_| {
        format!(
            "{}/.local/state",
            std::env::var("HOME").unwrap_or_else(|_| "/tmp".into())
        )
    });
    PathBuf::from(state).join("oura").join("gesture-config.json")
}

fn default_key_path() -> PathBuf {
    let cfg = std::env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| {
        format!(
            "{}/.config",
            std::env::var("HOME").unwrap_or_else(|_| "/tmp".into())
        )
    });
    PathBuf::from(cfg).join("oura").join("key.hex")
}

fn load_key(path: &Path) -> Result<Option<[u8; 16]>> {
    if !path.exists() {
        return Ok(None);
    }
    let raw = std::fs::read_to_string(path)
        .with_context(|| format!("reading key file {}", path.display()))?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    let bytes = hex::decode(trimmed)
        .with_context(|| format!("decoding hex key in {}", path.display()))?;
    if bytes.len() != 16 {
        return Err(anyhow!(
            "key file {} must contain 16 bytes (32 hex chars), got {}",
            path.display(),
            bytes.len()
        ));
    }
    let mut key = [0u8; 16];
    key.copy_from_slice(&bytes);
    Ok(Some(key))
}

async fn connect_and_auth(
    args: &Args,
    key_path: &Path,
) -> Result<(OuraClient<BleTransport>, bool)> {
    let key = load_key(key_path)?;
    let transport = BleTransport::connect(
        &args.name,
        args.address.as_deref(),
        Duration::from_secs(args.scan_timeout),
    )
    .await
    .context("connecting to Oura ring over BLE")?;
    let client = OuraClient::new(transport);
    let authed = if let Some(k) = key {
        client
            .authenticate(&k)
            .await
            .context("authenticating with ring")?;
        true
    } else {
        false
    };
    Ok((client, authed))
}

fn ensure_parent(path: &Path) {
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
}

async fn ensure_warm_client<'a>(
    warm: &'a mut Option<(OuraClient<BleTransport>, bool)>,
    args: &Args,
    key_path: &Path,
) -> Result<&'a (OuraClient<BleTransport>, bool)> {
    if warm.is_none() {
        let pair = connect_and_auth(args, key_path).await?;
        *warm = Some(pair);
    }
    Ok(warm.as_ref().unwrap())
}

async fn run_sync(
    warm: &mut Option<(OuraClient<BleTransport>, bool)>,
    args: &Args,
    key_path: &Path,
    db_path: &Path,
    cmd_rx: &mut mpsc::Receiver<DaemonCmd>,
    state_tx: &watch::Sender<DaemonSnapshot>,
) -> Option<DaemonCmd> {
    state_tx.send_modify(|s| {
        s.state = "syncing".into();
        s.last_error = None;
    });

    let mut preempted: Option<DaemonCmd> = None;
    let work = async {
        let (client, authed) = ensure_warm_client(warm, args, key_path).await?;
        let authed = *authed;
        state_tx.send_modify(|s| {
            s.connected = true;
            s.state = "syncing".into();
        });

        let fw = client.firmware().await.ok();
        let serial = client.serial().await.ok();
        let hw = client.hardware_id().await.ok();
        let battery = if authed {
            client.battery().await.ok()
        } else {
            None
        };
        let latest_hr = if authed {
            client
                .feature_latest(feature::DAYTIME_HR)
                .await
                .ok()
                .and_then(|v| v.bpm)
        } else {
            None
        };
        let latest_spo2 = if authed {
            client.feature_latest(feature::SPO2).await.ok()
        } else {
            None
        };

        ensure_parent(db_path);
        let store = Store::open(db_path).context("opening SQLite store")?;
        let serial_key = serial.clone().unwrap_or_else(|| "unknown".into());

        if let Some(ref info) = fw {
            let _ = store.upsert_device(&serial_key, hw.as_deref(), Some(info));
        }
        if let Some(ref b) = battery {
            let _ = store.insert_battery(&serial_key, b);
        }
        if let Some(bpm) = latest_hr {
            let _ = store.insert_reading(&serial_key, "latest_hr", bpm as f64, "bpm");
        }

        if authed {
            let _ = client.setup_app_stream().await;
            let _ = client.sync_time().await;
            let cursor = store.cursor(&serial_key).unwrap_or(0);
            let pending_batch = std::cell::RefCell::new(Vec::new());
            let _ = tokio::time::timeout(
                Duration::from_secs(45),
                client.drain_events(
                    cursor,
                    |ev| {
                        pending_batch.borrow_mut().push(ev.clone());
                        true
                    },
                    |progress| {
                        let mut batch = pending_batch.borrow_mut();
                        let ok = store
                            .commit_batch(&serial_key, &batch, progress.next_cursor)
                            .is_ok();
                        batch.clear();
                        ok
                    },
                ),
            )
            .await;
        }

        let trends = compute_daily_trends(db_path);
        state_tx.send_modify(|s| {
            s.connected = true;
            s.state = "idle".into();
            if serial.is_some() {
                s.serial = serial;
            }
            if hw.is_some() {
                s.hardware_id = hw.clone();
                if s.ring_name.is_none() {
                    s.ring_name = hw;
                }
            }
            if let Some(ref info) = fw {
                s.firmware = Some(info.firmware_version.clone());
            }
            if let Some(ref b) = battery {
                s.battery_percent = Some(b.percent);
                s.charging = Some(b.charging_progress > 0);
            }
            if let Some(bpm) = latest_hr.or(trends.latest_hr) {
                s.latest_hr = Some(bpm);
            }
            if let Some(sp) = latest_spo2.and_then(|v| v.spo2_percent) {
                s.spo2_percent = Some(sp);
            }
            s.last_sync_unix = Some(now_unix());
            s.trends = trends;
            s.last_error = None;
        });

        Ok::<(), anyhow::Error>(())
    };

    let outcome = tokio::select! {
        res = tokio::time::timeout(Duration::from_secs(75), work) => {
            match res {
                Ok(inner) => inner,
                Err(_) => Err(anyhow!("sync timed out after 75s")),
            }
        }
        Some(cmd) = cmd_rx.recv() => {
            tracing::info!("preempting background sync for incoming user command");
            preempted = Some(cmd);
            state_tx.send_modify(|s| {
                s.state = "idle".into();
            });
            Ok(())
        }
    };

    if let Err(e) = outcome {
        tracing::warn!("sync failed: {e:#}");
        if let Some((c, _)) = warm.take() {
            let _ = c.transport().disconnect().await;
        }
        state_tx.send_modify(|s| {
            s.connected = false;
            s.state = "idle".into();
            s.last_error = Some(format!("{e}"));
        });
    }

    preempted
}

async fn run_live_hr(
    warm: &mut Option<(OuraClient<BleTransport>, bool)>,
    args: &Args,
    key_path: &Path,
    db_path: &Path,
    seconds: u64,
    state_tx: &watch::Sender<DaemonSnapshot>,
) {
    state_tx.send_modify(|s| {
        s.state = "live_hr".into();
        s.live_hr_active = true;
        s.last_error = None;
    });

    let res: Result<()> = async {
        let (client, authed) = ensure_warm_client(warm, args, key_path).await?;
        if !*authed {
            return Err(anyhow!("auth key required for live HR"));
        }
        state_tx.send_modify(|s| {
            s.connected = true;
        });

        let serial = state_tx
            .borrow()
            .serial
            .clone()
            .unwrap_or_else(|| "unknown".into());
        ensure_parent(db_path);
        let store = Store::open(db_path).ok();

        let dur = Duration::from_secs(seconds.clamp(5, 120));
        client
            .live_heart_rate(dur, false, |sample| {
                if let Some(ref st) = store {
                    let _ = st.insert_reading(&serial, "live_hr", sample.bpm as f64, "bpm");
                }
                state_tx.send_modify(|s| {
                    s.live_hr = Some(sample.bpm);
                    s.latest_hr = Some(sample.bpm);
                });
            })
            .await?;

        let trends = compute_daily_trends(db_path);
        state_tx.send_modify(|s| {
            s.connected = true;
            s.state = "idle".into();
            s.live_hr_active = false;
            s.trends = trends;
        });
        Ok(())
    }
    .await;

    if let Err(e) = res {
        tracing::warn!("live-hr failed: {e:#}");
        if let Some((c, _)) = warm.take() {
            let _ = c.transport().disconnect().await;
        }
        state_tx.send_modify(|s| {
            s.connected = false;
            s.state = "idle".into();
            s.live_hr_active = false;
            s.last_error = Some(format!("{e}"));
        });
    }
}

async fn run_gesture_session(
    warm: &mut Option<(OuraClient<BleTransport>, bool)>,
    args: &Args,
    key_path: &Path,
    config_path: &Path,
    detector: &mut GestureDetector,
    cmd_rx: &mut mpsc::Receiver<DaemonCmd>,
    state_tx: &watch::Sender<DaemonSnapshot>,
) -> Option<DaemonCmd> {
    let auto_off_secs = (detector.config().auto_off_minutes.max(1)) * 60;
    let was_warm = warm.is_some();
    state_tx.send_modify(|s| {
        s.state = if was_warm { "gestures" } else { "connecting_gestures" }.into();
        s.gestures_enabled = true;
        s.gestures_remaining_sec = auto_off_secs;
        s.last_error = None;
    });

    // Fast path: if warm link is already open, arm ACM immediately (< 80 ms!).
    // If the warm write fails (link dropped), transparently drop & reconnect once.
    let mut armed = false;
    if let Some((ref client, authed)) = warm {
        if *authed {
            if client
                .transport()
                .write(&protocol::req_set_realtime(protocol::realtime::ACM, 5, 0))
                .await
                .is_ok()
            {
                armed = true;
                tracing::info!("armed 50 Hz ACM on warm BLE link (instant)");
            } else {
                tracing::info!("warm BLE link stale — reconnecting");
                if let Some((c, _)) = warm.take() {
                    let _ = c.transport().disconnect().await;
                }
            }
        }
    }

    if !armed {
        state_tx.send_modify(|s| {
            s.connected = false;
            s.state = "connecting_gestures".into();
        });
        let connect_started = Instant::now();
        let connect_fut = connect_and_auth(args, key_path);
        tokio::pin!(connect_fut);

        let connect_result = loop {
            tokio::select! {
                res = &mut connect_fut => break Some(res),
                cmd = cmd_rx.recv() => {
                    match cmd {
                        Some(DaemonCmd::Shutdown) => {
                            state_tx.send_modify(|s| {
                                s.connected = false;
                                s.state = "idle".into();
                                s.gestures_enabled = false;
                                s.gestures_remaining_sec = 0;
                                s.last_error = None;
                            });
                            return Some(DaemonCmd::Shutdown);
                        }
                        Some(DaemonCmd::Gestures { mode: GestureToggleMode::Off }) => {
                            tracing::info!("gesture connect cancelled by explicit off");
                            state_tx.send_modify(|s| {
                                s.connected = false;
                                s.state = "idle".into();
                                s.gestures_enabled = false;
                                s.gestures_remaining_sec = 0;
                                s.last_error = None;
                            });
                            return None;
                        }
                        Some(DaemonCmd::Gestures { mode: GestureToggleMode::Toggle })
                            if connect_started.elapsed() >= Duration::from_millis(500) =>
                        {
                            tracing::info!("gesture connect cancelled by user toggle");
                            state_tx.send_modify(|s| {
                                s.connected = false;
                                s.state = "idle".into();
                                s.gestures_enabled = false;
                                s.gestures_remaining_sec = 0;
                                s.last_error = None;
                            });
                            return None;
                        }
                        // Ignore bounce toggles (<500ms), duplicate `On`, or config updates while connecting.
                        Some(_) => continue,
                        None => break None,
                    }
                }
            }
        };

        let (client, authed) = match connect_result {
            Some(Ok(pair)) => pair,
            Some(Err(e)) => {
                tracing::warn!("gesture BLE connect failed: {e:#}");
                state_tx.send_modify(|s| {
                    s.connected = false;
                    s.state = "idle".into();
                    s.gestures_enabled = false;
                    s.gestures_remaining_sec = 0;
                    s.last_error = Some(format!("{e:#}"));
                });
                return None;
            }
            None => return None,
        };

        if !authed {
            let _ = client.transport().disconnect().await;
            state_tx.send_modify(|s| {
                s.connected = false;
                s.state = "idle".into();
                s.gestures_enabled = false;
                s.gestures_remaining_sec = 0;
                s.last_error = Some("auth key required for ACM gestures".into());
            });
            return None;
        }

        if let Err(e) = client
            .transport()
            .write(&protocol::req_set_realtime(protocol::realtime::ACM, 5, 0))
            .await
        {
            tracing::warn!("failed to arm ACM realtime stream: {e:#}");
            let _ = client.transport().disconnect().await;
            state_tx.send_modify(|s| {
                s.connected = false;
                s.state = "idle".into();
                s.gestures_enabled = false;
                s.gestures_remaining_sec = 0;
                s.last_error = Some(format!("ACM start failed: {e}"));
            });
            return None;
        }

        *warm = Some((client, authed));
        tracing::info!("gesture session active — armed 50 Hz ACM stream");
    }

    state_tx.send_modify(|s| {
        s.connected = true;
        s.state = "gestures".into();
    });

    let client = &warm.as_ref().unwrap().0;
    let mut raw_rx = client.transport().subscribe();
    while raw_rx.try_recv().is_ok() {}

    let mut expires_at = Instant::now() + Duration::from_secs(auto_off_secs as u64);
    let mut renew_tick = tokio::time::interval(Duration::from_secs(240));
    renew_tick.tick().await;
    let mut sec_tick = tokio::time::interval(Duration::from_secs(1));
    let mut last_attitude_push = Instant::now();
    let mut last_sample_at = Instant::now();
    let mut samples_this_sec: u16 = 0;
    let mut current_hz: u16 = 0;
    let mut logged_first_sample = false;
    let mut logged_other_frames: u8 = 0;
    let mut deferred_cmd: Option<DaemonCmd> = None;

    // Rolling JSONL motion trace (`~/.local/state/oura/motion-trace.jsonl`, capped at 10 MB)
    // so every gesture session records raw x/y/z + computed accelerations & fired events
    // for offline gesture accuracy tuning.
    let trace_path = config_path
        .parent()
        .unwrap_or_else(|| Path::new("/tmp"))
        .join("motion-trace.jsonl");
    let tpl_path = config_path
        .parent()
        .unwrap_or_else(|| Path::new("/tmp"))
        .join("gesture-templates.json");
    if let Some(tpls) = GestureTemplates::load(&tpl_path) {
        tracing::info!(
            path = %tpl_path.display(),
            window_len = tpls.window_len,
            "loaded calibrated 3D matched-filter gesture templates"
        );
        detector.set_templates(Some(tpls));
    }
    if std::fs::metadata(&trace_path)
        .map(|m| m.len() > 10 * 1024 * 1024)
        .unwrap_or(false)
    {
        let _ = std::fs::rename(&trace_path, trace_path.with_extension("jsonl.prev"));
    }
    let mut trace_writer = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&trace_path)
        .ok()
        .map(std::io::BufWriter::new);

    loop {
        tokio::select! {
            _ = renew_tick.tick() => {
                if let Err(e) = client
                    .transport()
                    .write(&protocol::req_set_realtime(protocol::realtime::ACM, 5, 0))
                    .await
                {
                    tracing::warn!("ACM window renew failed: {e:#}");
                    break;
                }
            }
            _ = sec_tick.tick() => {
                current_hz = samples_this_sec;
                samples_this_sec = 0;
                let rem = expires_at.saturating_duration_since(Instant::now()).as_secs() as u32;
                state_tx.send_modify(|s| {
                    s.gestures_remaining_sec = rem;
                    s.attitude.acm_hz = current_hz;
                });
                if rem == 0 {
                    tracing::info!("gesture mode auto-off timer reached");
                    break;
                }
                if let Some(ref mut w) = trace_writer {
                    use std::io::Write;
                    let _ = w.flush();
                }
                detector.sync_mission_control_open(hyprland::is_mission_control_open().await);
                if hyprland::is_session_locked().await {
                    tracing::info!("session locked — stopping ACM gesture stream to save ring battery");
                    break;
                }
            }
            frame = raw_rx.recv() => {
                match frame {
                    Ok(bytes) => {
                        let parsed = AcmSample::parse_frame(&bytes);
                        if parsed.is_empty() && logged_other_frames < 5 {
                            logged_other_frames += 1;
                            tracing::info!(
                                tag = bytes.first().copied().unwrap_or(0),
                                len = bytes.len(),
                                hex = %hex::encode(&bytes),
                                "non-ACM notification during gesture session"
                            );
                        }
                        for sample in parsed {
                            samples_this_sec = samples_this_sec.saturating_add(1);
                            if !logged_first_sample {
                                logged_first_sample = true;
                                tracing::info!(x = sample.x, y = sample.y, z = sample.z, "first live ACM sample received");
                            }
                            let now_inst = Instant::now();
                            let dt_ms = now_inst
                                .saturating_duration_since(last_sample_at)
                                .as_millis()
                                .clamp(5, 100) as u32;
                            last_sample_at = now_inst;
                            let (action, cal_done) = detector.feed(sample, dt_ms);
                            if let Some(ref mut w) = trace_writer {
                                use std::io::Write;
                                let att = detector.attitude();
                                let ts_ms = SystemTime::now()
                                    .duration_since(UNIX_EPOCH)
                                    .map(|d| d.as_millis())
                                    .unwrap_or(0);
                                let ev = action.map(|a| a.as_str()).unwrap_or("");
                                let _ = writeln!(
                                    w,
                                    "{{\"ts_ms\":{ts_ms},\"x\":{},\"y\":{},\"z\":{},\"lin_g\":{:.3},\"ah_g\":{:.3},\"aup_g\":{:.3},\"inv\":{},\"armed\":{},\"ev\":\"{ev}\"}}",
                                    sample.x, sample.y, sample.z, att.lin_g, att.accel_h_g, att.accel_up_g, att.palm_inverted, att.nav_armed
                                );
                            }
                            if cal_done {
                                let _ = detector.config().save(config_path);
                                let cfg_clone = detector.config().clone();
                                state_tx.send_modify(|s| {
                                    s.gesture_config = cfg_clone;
                                    let mut att = detector.attitude();
                                    att.acm_hz = current_hz;
                                    s.attitude = att;
                                });
                            }
                            if let Some(act) = action {
                                // Reset inactivity timeout on real gesture use.
                                let secs = (detector.config().auto_off_minutes.max(1)) * 60;
                                expires_at = Instant::now() + Duration::from_secs(secs as u64);
                                tracing::info!("gesture detected: {:?}", act);
                                tokio::spawn(hyprland::dispatch_gesture(act));
                                state_tx.send_modify(|s| {
                                    s.last_gesture = Some(act.as_str().into());
                                    s.last_gesture_unix = Some(now_unix());
                                    s.gestures_remaining_sec = secs;
                                });
                            }
                        }
                        if last_attitude_push.elapsed() >= Duration::from_millis(50) {
                            last_attitude_push = Instant::now();
                            let mut att = detector.attitude();
                            att.acm_hz = current_hz;
                            state_tx.send_modify(|s| {
                                s.attitude = att;
                            });
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => {
                        tracing::warn!("BLE notification stream closed");
                        break;
                    }
                }
            }
            cmd = cmd_rx.recv() => {
                match cmd {
                    Some(DaemonCmd::Gestures { mode: GestureToggleMode::Off | GestureToggleMode::Toggle }) => {
                        break;
                    }
                    Some(DaemonCmd::Gestures { mode: GestureToggleMode::On }) => {
                        let secs = (detector.config().auto_off_minutes.max(1)) * 60;
                        expires_at = Instant::now() + Duration::from_secs(secs as u64);
                    }
                    Some(DaemonCmd::ZeroNeutral) => {
                        if detector.zero_now().is_some() {
                            let _ = detector.config().save(config_path);
                            let cfg_clone = detector.config().clone();
                            let att = detector.attitude();
                            state_tx.send_modify(|s| {
                                s.gesture_config = cfg_clone;
                                s.attitude = att;
                            });
                        }
                    }
                    Some(DaemonCmd::Calibrate) => {
                        detector.begin_guided_calibration();
                        let att = detector.attitude();
                        state_tx.send_modify(|s| {
                            s.attitude = att;
                        });
                    }
                    Some(DaemonCmd::UpdateConfig {
                        invert_h,
                        require_lift_to_arm,
                        swipe_accel_g,
                        lift_accel_g,
                        auto_off_minutes,
                    }) => {
                        let mut next = detector.config().clone();
                        if let Some(v) = invert_h { next.invert_h = v; }
                        if let Some(v) = require_lift_to_arm { next.require_lift_to_arm = v; }
                        if let Some(v) = swipe_accel_g { next.swipe_accel_g = v.clamp(0.40, 1.80); }
                        if let Some(v) = lift_accel_g { next.lift_accel_g = v.clamp(0.40, 1.80); }
                        if let Some(v) = auto_off_minutes {
                            next.auto_off_minutes = v.clamp(1, 120);
                            expires_at = Instant::now() + Duration::from_secs((next.auto_off_minutes * 60) as u64);
                        }
                        detector.set_config(next.clone());
                        let _ = next.save(config_path);
                        state_tx.send_modify(|s| {
                            s.gesture_config = next;
                        });
                    }
                    Some(other) => {
                        deferred_cmd = Some(other);
                        break;
                    }
                    None => break,
                }
            }
        }
    }

    // Mandatory teardown: always turn off ACM real-time streaming, but KEEP the
    // warm BLE link open in low-power idle so next gesture toggle is < 100 ms!
    let mut link_healthy = true;
    if let Some((ref c, _)) = warm {
        if c.transport().write(&protocol::req_realtime_off()).await.is_err() {
            link_healthy = false;
        }
    }
    if !link_healthy {
        if let Some((c, _)) = warm.take() {
            let _ = c.transport().disconnect().await;
        }
    }

    state_tx.send_modify(|s| {
        s.connected = warm.is_some();
        s.state = "idle".into();
        s.gestures_enabled = false;
        s.gestures_remaining_sec = 0;
        s.attitude.h_deg = 0.0;
        s.attitude.v_deg = 0.0;
        s.attitude.acm_hz = 0;
        s.attitude.nav_armed = false;
        s.attitude.nav_armed_ms = 0;
        s.attitude.calibration_stage = None;
    });

    deferred_cmd
}

async fn handle_client(
    stream: UnixStream,
    cmd_tx: mpsc::Sender<DaemonCmd>,
    mut state_rx: watch::Receiver<DaemonSnapshot>,
) {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    let Ok(Some(line)) = lines.next_line().await else {
        return;
    };
    let req: Request = match serde_json::from_str(&line) {
        Ok(r) => r,
        Err(e) => {
            let resp = Response {
                ok: false,
                error: Some(format!("invalid request: {e}")),
                snapshot: None,
            };
            if let Ok(mut out) = serde_json::to_string(&resp) {
                out.push('\n');
                let _ = writer.write_all(out.as_bytes()).await;
            }
            return;
        }
    };

    match req {
        Request::Subscribe => {
            loop {
                let snap = state_rx.borrow_and_update().clone();
                if let Ok(mut out) = serde_json::to_string(&snap) {
                    out.push('\n');
                    if writer.write_all(out.as_bytes()).await.is_err() {
                        break;
                    }
                }
                if state_rx.changed().await.is_err() {
                    break;
                }
            }
            return;
        }
        Request::Status => {}
        Request::Sync => {
            let _ = cmd_tx.send(DaemonCmd::Sync).await;
        }
        Request::LiveHr { seconds } => {
            let _ = cmd_tx.send(DaemonCmd::LiveHr { seconds }).await;
        }
        Request::Gestures { mode } => {
            let _ = cmd_tx.send(DaemonCmd::Gestures { mode }).await;
        }
        Request::ZeroNeutral => {
            let _ = cmd_tx.send(DaemonCmd::ZeroNeutral).await;
        }
        Request::Calibrate => {
            let _ = cmd_tx.send(DaemonCmd::Calibrate).await;
        }
        Request::UpdateConfig {
            invert_h,
            require_lift_to_arm,
            swipe_accel_g,
            lift_accel_g,
            auto_off_minutes,
        } => {
            let _ = cmd_tx
                .send(DaemonCmd::UpdateConfig {
                    invert_h,
                    require_lift_to_arm,
                    swipe_accel_g,
                    lift_accel_g,
                    auto_off_minutes,
                })
                .await;
        }
    }

    let resp = Response {
        ok: true,
        error: None,
        snapshot: Some(state_rx.borrow().clone()),
    };
    if let Ok(mut out) = serde_json::to_string(&resp) {
        out.push('\n');
        let _ = writer.write_all(out.as_bytes()).await;
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "warn,ourad=info,oura_daemon=info,btleplug=off".into()),
        )
        .with_target(false)
        .init();

    let args = Args::parse();
    let db_path = args.db.clone().unwrap_or_else(default_db_path);
    let config_path = args.config_file.clone().unwrap_or_else(default_config_path);
    let key_path = args.key_file.clone().unwrap_or_else(default_key_path);
    let sock_path = args.socket.clone().unwrap_or_else(default_socket_path);

    ensure_parent(&db_path);
    ensure_parent(&config_path);
    ensure_parent(&sock_path);
    let _ = Store::open(&db_path);

    let gcfg = GestureConfig::load(&config_path);
    let mut detector = GestureDetector::new(gcfg.clone());
    let cached = load_cached_device(&db_path);
    let trends = compute_daily_trends(&db_path);

    let initial = DaemonSnapshot {
        connected: false,
        state: "idle".into(),
        ring_name: cached.hardware_id.clone(),
        serial: cached.serial,
        hardware_id: cached.hardware_id,
        firmware: cached.firmware,
        battery_percent: cached.battery_percent,
        charging: None,
        latest_hr: trends.latest_hr,
        live_hr: None,
        live_hr_active: false,
        spo2_percent: None,
        last_sync_unix: cached.last_sync_unix,
        gestures_enabled: false,
        gestures_remaining_sec: 0,
        attitude: detector.attitude(),
        last_gesture: None,
        last_gesture_unix: None,
        gesture_config: gcfg,
        trends,
        last_error: None,
    };

    let (state_tx, state_rx) = watch::channel(initial);
    let (cmd_tx, mut cmd_rx) = mpsc::channel::<DaemonCmd>(32);

    // Bind Unix socket.
    if sock_path.exists() {
        let _ = std::fs::remove_file(&sock_path);
    }
    let listener = UnixListener::bind(&sock_path)
        .with_context(|| format!("binding Unix socket {}", sock_path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&sock_path, std::fs::Permissions::from_mode(0o600));
    }

    tracing::info!(
        socket = %sock_path.display(),
        db = %db_path.display(),
        key = %key_path.display(),
        "ourad listening"
    );

    // Accept IPC connections in background.
    let ipc_cmd_tx = cmd_tx.clone();
    let ipc_state_rx = state_rx.clone();
    tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    tokio::spawn(handle_client(
                        stream,
                        ipc_cmd_tx.clone(),
                        ipc_state_rx.clone(),
                    ));
                }
                Err(e) => {
                    tracing::warn!("socket accept error: {e}");
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
            }
        }
    });

    // Forward SIGINT / SIGTERM into clean shutdown so ACM is always torn down.
    let sig_tx = cmd_tx.clone();
    tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        let _ = sig_tx.send(DaemonCmd::Shutdown).await;
    });

    let mut sync_tick = if args.sync_interval_minutes > 0 {
        let period = Duration::from_secs(args.sync_interval_minutes * 60);
        // Delay first background sync by 45s so startup stays immediately responsive.
        let mut iv = tokio::time::interval_at(
            tokio::time::Instant::now() + Duration::from_secs(45),
            period,
        );
        iv.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        Some(iv)
    } else {
        None
    };

    // Main single-BLE-owner event loop with persistent warm idle link.
    let mut warm: Option<(OuraClient<BleTransport>, bool)> = None;
    let mut pending: Option<DaemonCmd> = None;
    loop {
        let cmd = if let Some(c) = pending.take() {
            c
        } else {
            tokio::select! {
                Some(c) = cmd_rx.recv() => c,
                _ = async {
                    if let Some(ref mut iv) = sync_tick {
                        iv.tick().await;
                    } else {
                        std::future::pending::<()>().await;
                    }
                } => DaemonCmd::Sync,
            }
        };

        match cmd {
            DaemonCmd::Shutdown => {
                tracing::info!("ourad shutting down");
                if let Some((c, _)) = warm.take() {
                    let _ = c.transport().write(&protocol::req_realtime_off()).await;
                    let _ = c.transport().disconnect().await;
                }
                break;
            }
            DaemonCmd::Sync => {
                pending = run_sync(&mut warm, &args, &key_path, &db_path, &mut cmd_rx, &state_tx).await;
            }
            DaemonCmd::LiveHr { seconds } => {
                run_live_hr(&mut warm, &args, &key_path, &db_path, seconds, &state_tx).await;
            }
            DaemonCmd::Gestures {
                mode: GestureToggleMode::On | GestureToggleMode::Toggle,
            } => {
                pending = run_gesture_session(
                    &mut warm,
                    &args,
                    &key_path,
                    &config_path,
                    &mut detector,
                    &mut cmd_rx,
                    &state_tx,
                )
                .await;
            }
            DaemonCmd::Gestures {
                mode: GestureToggleMode::Off,
            } => {}
            DaemonCmd::ZeroNeutral => {
                if detector.zero_now().is_some() {
                    let _ = detector.config().save(&config_path);
                }
            }
            DaemonCmd::Calibrate => {
                // Start calibration by entering gesture mode first.
                detector.begin_guided_calibration();
                pending = run_gesture_session(
                    &mut warm,
                    &args,
                    &key_path,
                    &config_path,
                    &mut detector,
                    &mut cmd_rx,
                    &state_tx,
                )
                .await;
            }
            DaemonCmd::UpdateConfig {
                invert_h,
                require_lift_to_arm,
                swipe_accel_g,
                lift_accel_g,
                auto_off_minutes,
            } => {
                let mut next = detector.config().clone();
                if let Some(v) = invert_h {
                    next.invert_h = v;
                }
                if let Some(v) = require_lift_to_arm {
                    next.require_lift_to_arm = v;
                }
                if let Some(v) = swipe_accel_g {
                    next.swipe_accel_g = v.clamp(0.40, 1.80);
                }
                if let Some(v) = lift_accel_g {
                    next.lift_accel_g = v.clamp(0.40, 1.80);
                }
                if let Some(v) = auto_off_minutes {
                    next.auto_off_minutes = v.clamp(1, 120);
                }
                detector.set_config(next.clone());
                let _ = next.save(&config_path);
                state_tx.send_modify(|s| {
                    s.gesture_config = next;
                });
            }
        }
    }

    let _ = std::fs::remove_file(&sock_path);
    Ok(())
}
