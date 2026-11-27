//! Local offline daily-trend summary read straight from `oura.db`.
//!
//! Uses quality-gated `green_ibi_quality` (`0x80`, `quality == 1`) and `hrv_event`
//! (`0x5d`) samples — mirroring `open_health`'s `hourly_hr.rs` — to produce
//! 5th–95th percentile hourly heart-rate candles, today's min/avg/max HR,
//! overnight HRV (RMSSD), and skin-temperature summary with zero cloud calls.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{Datelike, Local, TimeZone, Timelike};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use serde_json::Value;

const MIN_BPM: f64 = 30.0;
const MAX_BPM: f64 = 240.0;
const BINS: usize = MAX_BPM as usize + 1;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct HourlyHrBar {
    pub hour: u32,
    pub min: u16,
    pub p5: u16,
    pub mean: u16,
    pub p95: u16,
    pub max: u16,
    pub count: u64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct DailyTrends {
    pub date: String,
    pub latest_hr: Option<u16>,
    pub latest_hr_unix: Option<i64>,
    pub hr_min: Option<u16>,
    pub hr_avg: Option<u16>,
    pub hr_max: Option<u16>,
    pub overnight_hrv_ms: Option<u16>,
    pub skin_temp_c: Option<f64>,
    pub hourly_hr: Vec<HourlyHrBar>,
    pub total_events: usize,
}

struct HistBar {
    hist: Vec<u32>,
    sum: f64,
    min: f64,
    max: f64,
    count: u64,
}

impl Default for HistBar {
    fn default() -> Self {
        Self {
            hist: vec![0; BINS],
            sum: 0.0,
            min: f64::MAX,
            max: f64::MIN,
            count: 0,
        }
    }
}

impl HistBar {
    fn add(&mut self, bpm: f64) {
        if !(MIN_BPM..=MAX_BPM).contains(&bpm) {
            return;
        }
        self.min = self.min.min(bpm);
        self.max = self.max.max(bpm);
        self.sum += bpm;
        let idx = (bpm.round() as usize).min(BINS - 1);
        self.hist[idx] += 1;
        self.count += 1;
    }

    fn percentile(&self, p: f64) -> f64 {
        if self.count == 0 {
            return 0.0;
        }
        let rank = ((p / 100.0) * self.count as f64).ceil().max(1.0) as u64;
        let mut seen = 0u64;
        for (bpm, n) in self.hist.iter().enumerate() {
            seen += *n as u64;
            if seen >= rank {
                return bpm as f64;
            }
        }
        self.max
    }
}

/// Cached last-known device metadata / battery from `oura.db` for cold start.
#[derive(Clone, Debug, Default)]
pub struct CachedDevice {
    pub serial: Option<String>,
    pub hardware_id: Option<String>,
    pub firmware: Option<String>,
    pub battery_percent: Option<u8>,
    pub last_sync_unix: Option<i64>,
}

pub fn load_cached_device(db_path: &Path) -> CachedDevice {
    let Ok(conn) = Connection::open(db_path) else {
        return CachedDevice::default();
    };
    let mut out = CachedDevice::default();

    if let Ok(mut stmt) = conn.prepare(
        "SELECT serial, hardware_id, firmware FROM device ORDER BY updated_unix DESC LIMIT 1",
    ) {
        if let Ok(row) = stmt.query_row([], |r| {
            Ok((
                r.get::<_, String>(0).ok(),
                r.get::<_, Option<String>>(1).ok().flatten(),
                r.get::<_, Option<String>>(2).ok().flatten(),
            ))
        }) {
            out.serial = row.0;
            out.hardware_id = row.1;
            out.firmware = row.2;
        }
    }

    if let Ok(mut stmt) = conn.prepare(
        "SELECT value FROM readings WHERE kind IN ('battery_percent', 'battery') ORDER BY captured_unix DESC LIMIT 1",
    ) {
        if let Ok(val) = stmt.query_row([], |r| r.get::<_, f64>(0)) {
            out.battery_percent = Some(val.round().clamp(0.0, 100.0) as u8);
        }
    }

    if let Ok(mut stmt) =
        conn.prepare("SELECT MAX(last_sync_unix) FROM sync_state")
    {
        if let Ok(Some(ts)) = stmt.query_row([], |r| r.get::<_, Option<i64>>(0)) {
            out.last_sync_unix = Some(ts);
        }
    }

    out
}

/// Compute today's local-time trends from `oura.db`.
pub fn compute_daily_trends(db_path: &Path) -> DailyTrends {
    let now = Local::now();
    let date_str = format!("{:04}-{:02}-{:02}", now.year(), now.month(), now.day());
    let start_of_day = Local
        .with_ymd_and_hms(now.year(), now.month(), now.day(), 0, 0, 0)
        .single()
        .map(|dt| dt.timestamp())
        .unwrap_or(0);
    let hrv_cutoff = start_of_day - 6 * 3600; // include overnight sleep starting previous evening

    let mut trends = DailyTrends {
        date: date_str,
        ..Default::default()
    };

    let Ok(conn) = Connection::open(db_path) else {
        return trends;
    };

    if let Ok(total) = conn.query_row("SELECT COUNT(*) FROM events", [], |r| r.get::<_, i64>(0)) {
        trends.total_events = total.max(0) as usize;
    }

    // Build latest time_sync anchor (ring_timestamp deciseconds -> unix seconds).
    let anchor: Option<(i64, i64)> = conn
        .query_row(
            "SELECT ring_timestamp, decoded_json, captured_unix FROM events \
             WHERE tag = 66 AND decoded_json IS NOT NULL \
             ORDER BY captured_unix DESC, id DESC LIMIT 1",
            [],
            |r| {
                let rt: i64 = r.get(0)?;
                let dj: String = r.get(1)?;
                let cap: i64 = r.get(2)?;
                Ok((rt, dj, cap))
            },
        )
        .ok()
        .and_then(|(rt, dj, cap)| {
            let v: Value = serde_json::from_str(&dj).ok()?;
            let unix = v
                .get("unix_time")
                .or_else(|| v.get("unix_s"))
                .or_else(|| v.get("utc_seconds"))
                .or_else(|| v.get("timestamp_s"))
                .and_then(|x| x.as_i64())
                .unwrap_or(cap);
            Some((rt, unix))
        });

    let resolve_unix = |ring_ts: i64, captured_unix: i64| -> i64 {
        if let Some((a_rt, a_unix)) = anchor {
            let est = a_unix + (ring_ts - a_rt) / 10;
            // Guard against ring reboots where ring_timestamp reset to 0.
            if (est - captured_unix).abs() < 14 * 86400 {
                return est;
            }
        }
        captured_unix
    };

    let mut bars: BTreeMap<u32, HistBar> = BTreeMap::new();
    let mut day_min = f64::MAX;
    let mut day_max = f64::MIN;
    let mut day_sum = 0.0;
    let mut day_count = 0u64;
    let mut latest_hr: Option<(i64, u16)> = None;
    let mut hrv_samples: Vec<f64> = Vec::new();
    let mut latest_temp: Option<(i64, f64)> = None;

    // Query recent events (past 36h by captured_unix) with decoded JSON.
    let lookback_cap = now.timestamp() - 48 * 3600;
    if let Ok(mut stmt) = conn.prepare(
        "SELECT tag, ring_timestamp, decoded_json, captured_unix \
         FROM events \
         WHERE decoded_json IS NOT NULL AND captured_unix >= ?1 \
           AND tag IN (128, 93, 70, 74, 117) \
         ORDER BY id ASC",
    ) {
        if let Ok(rows) = stmt.query_map([lookback_cap], |r| {
            Ok((
                r.get::<_, i64>(0)? as u8,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)?,
            ))
        }) {
            for row in rows.flatten() {
                let (tag, rt, dj, cap) = row;
                let Ok(v) = serde_json::from_str::<Value>(&dj) else {
                    continue;
                };
                let ts = resolve_unix(rt, cap);

                match tag {
                    // 0x80 green_ibi_quality_event:
                    // `{"hr_bpm":[...],"ibi_ms":[...],"quality":[...]}`
                    0x80 => {
                        let mut bpms: Vec<f64> = Vec::new();
                        if let Some(arr) = v.get("hr_bpm").and_then(|x| x.as_array()) {
                            for b in arr.iter().filter_map(|x| x.as_f64()) {
                                if (MIN_BPM..=MAX_BPM).contains(&b) {
                                    bpms.push(b);
                                }
                            }
                        }
                        if bpms.is_empty() {
                            if let (Some(ibis), Some(quals)) = (
                                v.get("ibi_ms").and_then(|x| x.as_array()),
                                v.get("quality").and_then(|x| x.as_array()),
                            ) {
                                for (ibi_v, q_v) in ibis.iter().zip(quals.iter()) {
                                    if q_v.as_u64() == Some(1) {
                                        if let Some(ibi) = ibi_v.as_f64() {
                                            if (300.0..=2000.0).contains(&ibi) {
                                                let b = 60_000.0 / ibi;
                                                if (MIN_BPM..=MAX_BPM).contains(&b) {
                                                    bpms.push(b);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        for bpm in bpms {
                            if ts >= start_of_day {
                                if let Some(dt) = Local.timestamp_opt(ts, 0).single() {
                                    bars.entry(dt.hour()).or_default().add(bpm);
                                }
                                day_min = day_min.min(bpm);
                                day_max = day_max.max(bpm);
                                day_sum += bpm;
                                day_count += 1;
                            }
                            if latest_hr.map(|(t, _)| ts >= t).unwrap_or(true) {
                                latest_hr = Some((ts, bpm.round() as u16));
                            }
                        }
                    }
                    // 0x5d hrv_event:
                    // `{"hr_bpm":[59,0],"interval_min":5,"rmssd_ms":[68,0]}`
                    0x5d => {
                        let interval_s = v
                            .get("interval_min")
                            .and_then(|x| x.as_i64())
                            .unwrap_or(5)
                            .max(1)
                            * 60;
                        if let Some(hrs) = v.get("hr_bpm").and_then(|x| x.as_array()) {
                            for (i, h_v) in hrs.iter().enumerate() {
                                let Some(hr) = h_v.as_f64() else { continue };
                                let sample_ts = ts + (i as i64) * interval_s;
                                if (MIN_BPM..=MAX_BPM).contains(&hr) && sample_ts >= start_of_day {
                                    if let Some(dt) = Local.timestamp_opt(sample_ts, 0).single() {
                                        bars.entry(dt.hour()).or_default().add(hr);
                                    }
                                    day_min = day_min.min(hr);
                                    day_max = day_max.max(hr);
                                    day_sum += hr;
                                    day_count += 1;
                                }
                                if (MIN_BPM..=MAX_BPM).contains(&hr)
                                    && latest_hr.map(|(t, _)| sample_ts >= t).unwrap_or(true)
                                {
                                    latest_hr = Some((sample_ts, hr.round() as u16));
                                }
                            }
                        }
                        if let Some(rmssds) = v.get("rmssd_ms").and_then(|x| x.as_array()) {
                            for (i, r_v) in rmssds.iter().enumerate() {
                                let Some(rmssd) = r_v.as_f64() else { continue };
                                let sample_ts = ts + (i as i64) * interval_s;
                                if rmssd > 5.0 && rmssd < 300.0 && sample_ts >= hrv_cutoff {
                                    hrv_samples.push(rmssd);
                                }
                            }
                        }
                    }
                    // Temperature events (0x46 temp_event, 0x4a temp_period, 0x75 sleep_temp)
                    0x46 | 0x4a | 0x75 => {
                        let temp = v
                            .get("temp_c")
                            .or_else(|| v.get("temp"))
                            .and_then(|x| x.as_f64())
                            .or_else(|| {
                                v.get("temps_c")
                                    .and_then(|a| a.as_array())
                                    .and_then(|a| a.last())
                                    .and_then(|x| x.as_f64())
                            });
                        if let Some(t) = temp.filter(|t| (25.0..=42.0).contains(t)) {
                            if latest_temp.map(|(prev, _)| ts >= prev).unwrap_or(true) {
                                latest_temp = Some((ts, t));
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    // Also include live/latest HR readings logged in the `readings` table today.
    if let Ok(mut stmt) = conn.prepare(
        "SELECT value, captured_unix FROM readings \
         WHERE kind IN ('live_hr', 'latest_hr', 'hr') AND captured_unix >= ?1 \
         ORDER BY captured_unix ASC",
    ) {
        if let Ok(rows) = stmt.query_map([start_of_day], |r| {
            Ok((r.get::<_, f64>(0)?, r.get::<_, i64>(1)?))
        }) {
            for (bpm, ts) in rows.flatten() {
                if (MIN_BPM..=MAX_BPM).contains(&bpm) {
                    if let Some(dt) = Local.timestamp_opt(ts, 0).single() {
                        bars.entry(dt.hour()).or_default().add(bpm);
                    }
                    day_min = day_min.min(bpm);
                    day_max = day_max.max(bpm);
                    day_sum += bpm;
                    day_count += 1;
                    if latest_hr.map(|(t, _)| ts >= t).unwrap_or(true) {
                        latest_hr = Some((ts, bpm.round() as u16));
                    }
                }
            }
        }
    }

    trends.hourly_hr = bars
        .into_iter()
        .filter(|(_, b)| b.count > 0)
        .map(|(hour, b)| HourlyHrBar {
            hour,
            min: b.min.round() as u16,
            p5: b.percentile(5.0).round() as u16,
            mean: (b.sum / b.count as f64).round() as u16,
            p95: b.percentile(95.0).round() as u16,
            max: b.max.round() as u16,
            count: b.count,
        })
        .collect();

    if day_count > 0 {
        trends.hr_min = Some(day_min.round() as u16);
        trends.hr_avg = Some((day_sum / day_count as f64).round() as u16);
        trends.hr_max = Some(day_max.round() as u16);
    }
    if let Some((ts, bpm)) = latest_hr {
        trends.latest_hr = Some(bpm);
        trends.latest_hr_unix = Some(ts);
    }
    if !hrv_samples.is_empty() {
        let avg = hrv_samples.iter().sum::<f64>() / hrv_samples.len() as f64;
        trends.overnight_hrv_ms = Some(avg.round() as u16);
    }
    if let Some((_, t)) = latest_temp {
        trends.skin_temp_c = Some((t * 10.0).round() / 10.0);
    }

    trends
}
