//! Newline-delimited JSON IPC protocol between `ourad` and `ouractl` / `Service.qml`.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::gesture::{AttitudeSnapshot, GestureConfig};
use crate::summary::DailyTrends;

pub fn default_socket_path() -> PathBuf {
    let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(runtime).join("ourad.sock")
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Request {
    Status,
    Subscribe,
    Sync,
    LiveHr {
        #[serde(default = "default_live_hr_secs")]
        seconds: u64,
    },
    Gestures {
        mode: GestureToggleMode,
    },
    ZeroNeutral,
    Calibrate,
    UpdateConfig {
        #[serde(default)]
        invert_h: Option<bool>,
        #[serde(default)]
        require_lift_to_arm: Option<bool>,
        #[serde(default)]
        swipe_accel_g: Option<f64>,
        #[serde(default)]
        lift_accel_g: Option<f64>,
        #[serde(default)]
        auto_off_minutes: Option<u32>,
    },
}

fn default_live_hr_secs() -> u64 {
    15
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GestureToggleMode {
    On,
    Off,
    Toggle,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DaemonSnapshot {
    pub connected: bool,
    pub state: String,
    pub ring_name: Option<String>,
    pub serial: Option<String>,
    pub hardware_id: Option<String>,
    pub firmware: Option<String>,
    pub battery_percent: Option<u8>,
    pub charging: Option<bool>,
    pub latest_hr: Option<u16>,
    pub live_hr: Option<u16>,
    pub live_hr_active: bool,
    pub spo2_percent: Option<u8>,
    pub last_sync_unix: Option<i64>,
    pub gestures_enabled: bool,
    pub gestures_remaining_sec: u32,
    pub attitude: AttitudeSnapshot,
    pub last_gesture: Option<String>,
    pub last_gesture_unix: Option<i64>,
    pub gesture_config: GestureConfig,
    pub trends: DailyTrends,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Response {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<DaemonSnapshot>,
}
