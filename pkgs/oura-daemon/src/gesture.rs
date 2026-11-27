//! 2-stage accelerometer gesture engine for Omarchnix:
//!
//! 1. **Standby (palm-down desk posture):** lateral movements and typing are
//!    completely ignored.
//! 2. **Wake / Mission Control (`Palm-Up + Upward Lift`):** invert your hand
//!    (palm facing up, `dot(u, u0) < -0.45`) and make a brisk upward lift
//!    (`dot(lin_g, u) >= lift_accel_g`). This summons Mission Control and arms
//!    lateral air-swipes for `armed_timeout_ms`.
//! 3. **Armed Lateral Air-Swipes (speed / acceleration gated):**
//!    - Slap **Right → Left** (`a_h <= -swipe_accel_g`) → `SpaceRight` (`m+1`, natural pull).
//!    - Slap **Left → Right** (`a_h >= +swipe_accel_g`) → `SpaceLeft` (`m-1`, natural pull).
//!    - Braking deceleration is ignored by the refractory cooldown.
//!    - After `armed_timeout_ms` of stillness, automatically hides Mission Control
//!      and returns to Standby.

use std::collections::VecDeque;
use std::path::Path;

use anyhow::Result;
use serde::{Deserialize, Serialize};

use oura_link::client::AcmSample;

const COUNTS_PER_G: f64 = 1024.0;
const SAMPLE_DT_MS: u32 = 20;

/// Per-class cosine similarity thresholds for the 3D sliding-window matched filter.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct TemplateThresholds {
    pub open_mc: f64,
    pub close_mc: f64,
    pub swipe_right: f64,
    pub swipe_left: f64,
}

impl Default for TemplateThresholds {
    fn default() -> Self {
        Self {
            open_mc: 0.74,
            close_mc: 0.74,
            swipe_right: 0.76,
            swipe_left: 0.75,
        }
    }
}

/// L2-normalized 3D `(x, y, z)` waveform templates (length `3 * window_len` each).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TemplateVectors {
    pub open_mc: Vec<f64>,
    pub close_mc: Vec<f64>,
    pub swipe_right: Vec<f64>,
    pub swipe_left: Vec<f64>,
}

/// Calibrated 3D sliding-window matched-filter templates (generated from
/// `~/.local/state/oura/labeled-gestures.json` into `gesture-templates.json`).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GestureTemplates {
    pub window_len: usize,
    pub sample_dt_ms: u32,
    pub min_lin_g: f64,
    pub peak_confirm_samples: u32,
    pub cooldown_ms: u32,
    #[serde(default)]
    pub thresholds: TemplateThresholds,
    pub templates: TemplateVectors,
}

impl GestureTemplates {
    pub fn load(path: &Path) -> Option<Self> {
        let raw = std::fs::read_to_string(path).ok()?;
        let mut t: Self = serde_json::from_str(&raw).ok()?;
        let expected = t.window_len.checked_mul(3)?;
        if expected == 0
            || t.templates.open_mc.len() != expected
            || t.templates.close_mc.len() != expected
            || t.templates.swipe_right.len() != expected
            || t.templates.swipe_left.len() != expected
        {
            return None;
        }
        // Ensure every template vector is strictly L2-normalized.
        l2_normalize(&mut t.templates.open_mc);
        l2_normalize(&mut t.templates.close_mc);
        l2_normalize(&mut t.templates.swipe_right);
        l2_normalize(&mut t.templates.swipe_left);
        Some(t)
    }

    fn threshold_for(&self, cls: TemplateClass) -> f64 {
        match cls {
            TemplateClass::OpenMc => self.thresholds.open_mc,
            TemplateClass::CloseMc => self.thresholds.close_mc,
            TemplateClass::SwipeRight => self.thresholds.swipe_right,
            TemplateClass::SwipeLeft => self.thresholds.swipe_left,
        }
    }

    fn vector_for(&self, cls: TemplateClass) -> &[f64] {
        match cls {
            TemplateClass::OpenMc => &self.templates.open_mc,
            TemplateClass::CloseMc => &self.templates.close_mc,
            TemplateClass::SwipeRight => &self.templates.swipe_right,
            TemplateClass::SwipeLeft => &self.templates.swipe_left,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TemplateClass {
    OpenMc,
    CloseMc,
    SwipeRight,
    SwipeLeft,
}

const ALL_CLASSES: [TemplateClass; 4] = [
    TemplateClass::OpenMc,
    TemplateClass::CloseMc,
    TemplateClass::SwipeRight,
    TemplateClass::SwipeLeft,
];

fn l2_normalize(v: &mut [f64]) {
    let n = v.iter().map(|x| x * x).sum::<f64>().sqrt();
    if n > 1e-9 {
        for x in v.iter_mut() {
            *x /= n;
        }
    }
}

/// Discrete desktop gesture emitted by [`GestureDetector`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GestureAction {
    SpaceLeft,
    SpaceRight,
    MissionControlShow,
    MissionControlHide,
}

impl GestureAction {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SpaceLeft => "space_left",
            Self::SpaceRight => "space_right",
            Self::MissionControlShow => "mission_control_show",
            Self::MissionControlHide => "mission_control_hide",
        }
    }
}

/// Persisted gesture settings & neutral-pose calibration.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct GestureConfig {
    /// Gravity EMA factor (0.04..0.20). Lower keeps fast swipe impulses in `lin_g`.
    pub alpha: f64,
    /// Minimum lateral linear acceleration (in g) to trigger a Space air-swipe.
    pub swipe_accel_g: f64,
    /// Minimum upward linear acceleration (in g) while palm-up to summon Mission Control.
    pub lift_accel_g: f64,
    /// Minimum palm-inversion cosine (`dot(u, u0) < -palm_invert_cos`, e.g. 0.40 ≈ >113°).
    pub palm_invert_cos: f64,
    /// Require Palm-Up + Lift to arm lateral swipes (prevents desk/typing false triggers).
    pub require_lift_to_arm: bool,
    /// How long (ms) lateral swipes remain armed after Mission Control opens or last swipe.
    pub armed_timeout_ms: u32,
    /// Refractory cooldown (ms) after a lateral swipe (ignores the braking deceleration peak).
    pub swipe_cooldown_ms: u32,
    /// Refractory cooldown (ms) after summoning Mission Control before accepting the first swipe.
    pub lift_settle_ms: u32,
    /// Invert horizontal Space swipe direction.
    pub invert_h: bool,
    /// Auto-disable ACM gesture streaming after this many minutes of inactivity.
    pub auto_off_minutes: u32,
    /// Stored neutral palm-down calibration basis (`u0`, `b_r`, `b_f`).
    pub calibration: Option<Calibration>,
}

impl Default for GestureConfig {
    fn default() -> Self {
        Self {
            alpha: 0.08,
            swipe_accel_g: 0.65,
            lift_accel_g: 0.38,
            palm_invert_cos: 0.25,
            require_lift_to_arm: true,
            armed_timeout_ms: 8000,
            swipe_cooldown_ms: 480,
            lift_settle_ms: 300,
            invert_h: false,
            auto_off_minutes: 20,
            calibration: None,
        }
    }
}

impl GestureConfig {
    pub fn load(path: &Path) -> Self {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(tmp, path)?;
        Ok(())
    }
}

/// Orthonormal tangent frame anchored to the ring's palm-down neutral pose `u0`.
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct Calibration {
    pub u0: [f64; 3],
    pub b_r: [f64; 3],
    pub b_f: [f64; 3],
}

impl Calibration {
    pub fn from_neutral(neutral: [f64; 3]) -> Self {
        let u0 = norm(neutral);
        let (a0, a1, a2) = (u0[0].abs(), u0[1].abs(), u0[2].abs());
        let seed = if a0 <= a1 && a0 <= a2 {
            [1.0, 0.0, 0.0]
        } else if a1 <= a2 {
            [0.0, 1.0, 0.0]
        } else {
            [0.0, 0.0, 1.0]
        };
        let b_r = norm(sub(seed, scale(u0, dot(seed, u0))));
        let b_f = cross(u0, b_r);
        Self { u0, b_r, b_f }
    }

    pub fn from_neutral_and_right(neutral: [f64; 3], right_tilt: [f64; 3]) -> Self {
        let u0 = norm(neutral);
        let u_r = norm(right_tilt);
        let proj = sub(u_r, scale(u0, dot(u_r, u0)));
        if vlen(proj) < 0.15 {
            return Self::from_neutral(u0);
        }
        let b_r = norm(proj);
        let b_f = cross(u0, b_r);
        Self { u0, b_r, b_f }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CalibrationStage {
    Idle,
    HoldNeutral,
    TiltRight,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NavState {
    Standby {
        cooldown_ms: u32,
    },
    Armed {
        remaining_ms: u32,
        cooldown_ms: u32,
    },
}

/// Snapshot of the detector's live orientation & acceleration for the status bar.
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize)]
pub struct AttitudeSnapshot {
    pub h_deg: f64,
    pub v_deg: f64,
    pub lin_g: f64,
    pub accel_h_g: f64,
    pub accel_up_g: f64,
    pub palm_inverted: bool,
    pub nav_armed: bool,
    pub nav_armed_ms: u32,
    pub acm_hz: u16,
    pub calibrated: bool,
    pub calibration_stage: Option<CalibrationStage>,
}

pub struct GestureDetector {
    config: GestureConfig,
    templates: Option<GestureTemplates>,
    window: VecDeque<([f64; 3], f64)>,
    cand_cls: Option<TemplateClass>,
    cand_score: f64,
    cand_age: u32,
    sync_grace_ms: u32,
    gravity: Option<[f64; 3]>,
    state: NavState,
    calib_stage: CalibrationStage,
    calib_acc: [f64; 3],
    calib_count: u32,
    calib_u0: Option<[f64; 3]>,
    calib_best_right: Option<([f64; 3], f64)>,
    last_attitude: AttitudeSnapshot,
}

impl GestureDetector {
    pub fn new(config: GestureConfig) -> Self {
        let calibrated = config.calibration.is_some();
        Self {
            config,
            templates: None,
            window: VecDeque::with_capacity(64),
            cand_cls: None,
            cand_score: 0.0,
            cand_age: 0,
            sync_grace_ms: 0,
            gravity: None,
            state: NavState::Standby { cooldown_ms: 0 },
            calib_stage: CalibrationStage::Idle,
            calib_acc: [0.0; 3],
            calib_count: 0,
            calib_u0: None,
            calib_best_right: None,
            last_attitude: AttitudeSnapshot {
                calibrated,
                ..Default::default()
            },
        }
    }

    pub fn set_templates(&mut self, templates: Option<GestureTemplates>) {
        self.templates = templates;
        self.window.clear();
        self.cand_cls = None;
        self.cand_score = 0.0;
        self.cand_age = 0;
    }

    pub fn has_templates(&self) -> bool {
        self.templates.is_some()
    }

    /// Synchronize internal `Standby` / `Armed` state with Hyprland's actual
    /// Mission Control layer state (e.g. when the user opens/closes Mission
    /// Control with the keyboard or mouse). Respects a short grace window after
    /// ring-triggered transitions so we never clobber a layer that is still mounting.
    pub fn sync_mission_control_open(&mut self, mc_open: bool) {
        if self.sync_grace_ms > 0 {
            return;
        }
        match (mc_open, self.state) {
            (true, NavState::Standby { .. }) => {
                self.state = NavState::Armed {
                    remaining_ms: self.config.armed_timeout_ms,
                    cooldown_ms: 250,
                };
                self.last_attitude.nav_armed = true;
                self.last_attitude.nav_armed_ms = self.config.armed_timeout_ms;
            }
            (false, NavState::Armed { .. }) => {
                self.state = NavState::Standby { cooldown_ms: 250 };
                self.last_attitude.nav_armed = false;
                self.last_attitude.nav_armed_ms = 0;
            }
            _ => {}
        }
    }

    pub fn config(&self) -> &GestureConfig {
        &self.config
    }

    pub fn set_config(&mut self, mut next: GestureConfig) {
        if next.calibration.is_none() {
            next.calibration = self.config.calibration;
        }
        self.config = next;
        self.last_attitude.calibrated = self.config.calibration.is_some();
    }

    pub fn attitude(&self) -> AttitudeSnapshot {
        self.last_attitude
    }

    pub fn zero_now(&mut self) -> Option<Calibration> {
        let g = self.gravity?;
        let cal = Calibration::from_neutral(g);
        self.config.calibration = Some(cal);
        self.state = NavState::Standby { cooldown_ms: 300 };
        self.last_attitude.calibrated = true;
        Some(cal)
    }

    pub fn begin_guided_calibration(&mut self) {
        self.calib_stage = CalibrationStage::HoldNeutral;
        self.calib_acc = [0.0; 3];
        self.calib_count = 0;
        self.calib_u0 = None;
        self.calib_best_right = None;
        self.state = NavState::Standby { cooldown_ms: 300 };
        self.last_attitude.calibration_stage = Some(CalibrationStage::HoldNeutral);
    }

    pub fn is_calibrating(&self) -> bool {
        self.calib_stage != CalibrationStage::Idle
    }

    /// Feed one accelerometer sample with elapsed `dt_ms`.
    /// Returns `(Option<GestureAction>, calibration_completed)`.
    pub fn feed(&mut self, sample: AcmSample, dt_ms: u32) -> (Option<GestureAction>, bool) {
        let dt = dt_ms.clamp(2, 100);
        let raw = [sample.x as f64, sample.y as f64, sample.z as f64];
        let alpha = self.config.alpha.clamp(0.03, 0.25);

        let g = match self.gravity {
            Some(prev) => add(scale(prev, 1.0 - alpha), scale(raw, alpha)),
            None => raw,
        };
        self.gravity = Some(g);

        let lin = scale(sub(raw, g), 1.0 / COUNTS_PER_G);
        let lin_g = vlen(lin);
        let u = norm(g);

        // Guided 2-step calibration (Hold palm-down neutral -> Tilt Right once).
        match self.calib_stage {
            CalibrationStage::HoldNeutral => {
                self.calib_acc = add(self.calib_acc, u);
                self.calib_count += 1;
                self.last_attitude = AttitudeSnapshot {
                    lin_g,
                    acm_hz: self.last_attitude.acm_hz,
                    calibrated: self.config.calibration.is_some(),
                    calibration_stage: Some(CalibrationStage::HoldNeutral),
                    ..Default::default()
                };
                if self.calib_count >= 75 {
                    self.calib_u0 = Some(norm(self.calib_acc));
                    self.calib_stage = CalibrationStage::TiltRight;
                    self.calib_count = 0;
                    self.calib_best_right = None;
                    self.last_attitude.calibration_stage = Some(CalibrationStage::TiltRight);
                }
                return (None, false);
            }
            CalibrationStage::TiltRight => {
                let u0 = self.calib_u0.unwrap_or(u);
                let proj = sub(u, scale(u0, dot(u, u0)));
                let plen = vlen(proj);
                if self
                    .calib_best_right
                    .map(|(_, best)| plen > best)
                    .unwrap_or(true)
                {
                    self.calib_best_right = Some((u, plen));
                }
                self.calib_count += 1;
                self.last_attitude.lin_g = lin_g;
                self.last_attitude.calibration_stage = Some(CalibrationStage::TiltRight);
                if self.calib_count >= 100 {
                    let cal = match self.calib_best_right {
                        Some((u_r, plen)) if plen >= 0.25 => {
                            Calibration::from_neutral_and_right(u0, u_r)
                        }
                        _ => Calibration::from_neutral(u0),
                    };
                    self.config.calibration = Some(cal);
                    self.calib_stage = CalibrationStage::Idle;
                    self.state = NavState::Standby { cooldown_ms: 400 };
                    self.last_attitude.calibrated = true;
                    self.last_attitude.calibration_stage = None;
                    return (None, true);
                }
                return (None, false);
            }
            CalibrationStage::Idle => {}
        }

        let cal = match self.config.calibration {
            Some(c) => c,
            None => {
                let c = Calibration::from_neutral(g);
                self.config.calibration = Some(c);
                c
            }
        };

        // Palm orientation relative to palm-down neutral `u0`:
        // - `palm_inverted`: palm facing up (`dot(u, u0) < -palm_invert_cos`)
        // - `palm_down`: palm facing down (`dot(u, u0) > +palm_invert_cos`)
        let palm_dot = dot(u, cal.u0);
        let palm_inverted = palm_dot < -self.config.palm_invert_cos;
        let palm_down = palm_dot > self.config.palm_invert_cos;

        // World-UP linear acceleration: `u = norm(G)` always points along world UP
        // in the ring's current body frame, so lifting UP gives +accel_up_g and
        // pushing DOWN gives -accel_up_g.
        let accel_up_g = dot(lin, u);

        // World-RIGHT linear acceleration: flipping palm-up rotates `b_r` by 180°
        // around the finger axis, so `palm_sign` keeps Left/Right consistent in world space.
        let palm_sign = if palm_dot < 0.0 { -1.0 } else { 1.0 };
        let raw_ah = dot(lin, cal.b_r) * palm_sign;
        let accel_h_g = if self.config.invert_h { -raw_ah } else { raw_ah };

        // Orientation angles for reticle visual feedback.
        let h_deg = dot(u, cal.b_r).clamp(-1.0, 1.0).asin().to_degrees();
        let v_deg = dot(u, cal.b_f).clamp(-1.0, 1.0).asin().to_degrees();

        self.sync_grace_ms = self.sync_grace_ms.saturating_sub(dt);

        let mut emitted: Option<GestureAction> = None;

        if self.templates.is_some() {
            emitted = self.feed_matched_filter(
                [raw[0] / 1000.0, raw[1] / 1000.0, raw[2] / 1000.0],
                lin_g,
                dt,
            );
        } else {
            match self.state {
                NavState::Standby { mut cooldown_ms } => {
                    cooldown_ms = cooldown_ms.saturating_sub(dt);

                    if cooldown_ms == 0 {
                        // Stage 1: Palm-up inverted + brisk upward lift -> open Mission Control & arm swipes!
                        if palm_inverted
                            && accel_up_g >= self.config.lift_accel_g
                            && accel_up_g >= 0.9 * accel_h_g.abs()
                        {
                            self.state = NavState::Armed {
                                remaining_ms: self.config.armed_timeout_ms,
                                cooldown_ms: self.config.lift_settle_ms,
                            };
                            self.sync_grace_ms = 1400;
                            emitted = Some(GestureAction::MissionControlShow);
                        } else {
                            self.state = NavState::Standby { cooldown_ms };
                        }
                    } else {
                        self.state = NavState::Standby { cooldown_ms };
                    }
                }
                NavState::Armed {
                    mut remaining_ms,
                    mut cooldown_ms,
                } => {
                    cooldown_ms = cooldown_ms.saturating_sub(dt);
                    remaining_ms = remaining_ms.saturating_sub(dt);

                    if cooldown_ms == 0
                        && palm_down
                        && accel_up_g <= -self.config.lift_accel_g
                        && accel_up_g.abs() >= 1.1 * accel_h_g.abs()
                    {
                        // Inverse close gesture: palm-down + brisk downward move -> close Mission Control!
                        self.state = NavState::Standby { cooldown_ms: 450 };
                        self.sync_grace_ms = 1400;
                        emitted = Some(GestureAction::MissionControlHide);
                    } else if cooldown_ms == 0
                        && accel_h_g.abs() >= self.config.swipe_accel_g
                        && accel_h_g.abs() >= 1.15 * accel_up_g.abs()
                    {
                        // Stage 2: Brisk lateral slap-swipe (only while Armed in Mission Control).
                        self.state = NavState::Armed {
                            remaining_ms: self.config.armed_timeout_ms,
                            cooldown_ms: self.config.swipe_cooldown_ms,
                        };
                        emitted = Some(swipe_action(accel_h_g));
                    } else if remaining_ms == 0 {
                        // Stillness timeout -> close Mission Control and lock back to Standby.
                        self.state = NavState::Standby { cooldown_ms: 400 };
                        self.sync_grace_ms = 1400;
                        emitted = Some(GestureAction::MissionControlHide);
                    } else {
                        self.state = NavState::Armed {
                            remaining_ms,
                            cooldown_ms,
                        };
                    }
                }
            }
        }

        let (nav_armed, nav_armed_ms) = match self.state {
            NavState::Armed { remaining_ms, .. } => (true, remaining_ms),
            NavState::Standby { .. } => (false, 0),
        };

        self.last_attitude = AttitudeSnapshot {
            h_deg,
            v_deg,
            lin_g,
            accel_h_g,
            accel_up_g,
            palm_inverted,
            nav_armed,
            nav_armed_ms,
            acm_hz: self.last_attitude.acm_hz,
            calibrated: true,
            calibration_stage: None,
        };

        (emitted, false)
    }

    pub fn feed_50hz(&mut self, sample: AcmSample) -> (Option<GestureAction>, bool) {
        self.feed(sample, SAMPLE_DT_MS)
    }

    fn feed_matched_filter(
        &mut self,
        raw_g: [f64; 3],
        lin_g: f64,
        dt: u32,
    ) -> Option<GestureAction> {
        let tpl = self.templates.as_ref()?;
        let w_len = tpl.window_len;
        let fast_span = (w_len * 3 / 5).max(8);
        let slow_span = (w_len * 7 / 5).max(w_len);
        let max_buf = slow_span + 2;
        let min_lin_g = tpl.min_lin_g;
        let peak_confirm = tpl.peak_confirm_samples;
        let cooldown_default = tpl.cooldown_ms;

        self.window.push_back((raw_g, lin_g));
        while self.window.len() > max_buf {
            self.window.pop_front();
        }

        // Advance timers on NavState.
        let mut in_cooldown = false;
        match &mut self.state {
            NavState::Standby { cooldown_ms } => {
                *cooldown_ms = cooldown_ms.saturating_sub(dt);
                in_cooldown = *cooldown_ms > 0;
            }
            NavState::Armed {
                remaining_ms,
                cooldown_ms,
            } => {
                *cooldown_ms = cooldown_ms.saturating_sub(dt);
                *remaining_ms = remaining_ms.saturating_sub(dt);
                if *remaining_ms == 0 {
                    self.state = NavState::Standby { cooldown_ms: 400 };
                    self.sync_grace_ms = 1400;
                    self.cand_cls = None;
                    self.cand_score = 0.0;
                    self.cand_age = 0;
                    return Some(GestureAction::MissionControlHide);
                }
                in_cooldown = *cooldown_ms > 0;
            }
        }

        if self.window.len() < fast_span || in_cooldown {
            return None;
        }

        // Peak linear acceleration over the most recent 14 samples (~280 ms).
        let recent_n = 14.min(self.window.len());
        let max_lg = self
            .window
            .iter()
            .skip(self.window.len() - recent_n)
            .map(|(_, lg)| *lg)
            .fold(0.0_f64, f64::max);

        if max_lg < min_lin_g {
            if let Some(cls) = self.cand_cls.take() {
                self.cand_score = 0.0;
                self.cand_age = 0;
                return self.commit_template_class(cls, cooldown_default);
            }
            return None;
        }

        // Multi-scale cosine similarity across 3 gesture speeds:
        // fast (0.6x), nominal (1.0x), and slow (1.4x) resampled onto `w_len` points.
        let spans = [fast_span, w_len, slow_span];
        let mut resampled = vec![0.0_f64; w_len * 3];
        let mut best_cls = TemplateClass::OpenMc;
        let mut best_score = f64::NEG_INFINITY;
        let buf_len = self.window.len();

        for &span in &spans {
            if buf_len < span {
                continue;
            }
            let start = buf_len - span;
            let mut norm_sq = 0.0;
            let denom = (w_len.saturating_sub(1)).max(1) as f64;
            let span_max = (span.saturating_sub(1)) as f64;
            for i in 0..w_len {
                let pos = start as f64 + (i as f64 / denom) * span_max;
                let lo = pos.floor() as usize;
                let hi = (lo + 1).min(buf_len - 1);
                let a = pos - lo as f64;
                let p0 = self.window[lo].0;
                let p1 = self.window[hi].0;
                let x = p0[0] * (1.0 - a) + p1[0] * a;
                let y = p0[1] * (1.0 - a) + p1[1] * a;
                let z = p0[2] * (1.0 - a) + p1[2] * a;
                let base = i * 3;
                resampled[base] = x;
                resampled[base + 1] = y;
                resampled[base + 2] = z;
                norm_sq += x * x + y * y + z * z;
            }
            let win_norm = norm_sq.sqrt();
            if win_norm < 1e-6 {
                continue;
            }
            for cls in ALL_CLASSES {
                let tv = tpl.vector_for(cls);
                let acc: f64 = resampled
                    .iter()
                    .zip(tv.iter())
                    .map(|(a, b)| a * b)
                    .sum();
                let score = acc / win_norm;
                if score > best_score {
                    best_score = score;
                    best_cls = cls;
                }
            }
        }

        if best_score >= tpl.threshold_for(best_cls) {
            if best_score > self.cand_score {
                self.cand_cls = Some(best_cls);
                self.cand_score = best_score;
                self.cand_age = 0;
            } else {
                self.cand_age += 1;
            }
        } else if self.cand_cls.is_some() {
            self.cand_age += 1;
        }

        if self.cand_cls.is_some() && self.cand_age >= peak_confirm {
            let cls = self.cand_cls.take().unwrap();
            self.cand_score = 0.0;
            self.cand_age = 0;
            return self.commit_template_class(cls, cooldown_default);
        }

        None
    }

    fn commit_template_class(
        &mut self,
        cls: TemplateClass,
        cooldown_ms: u32,
    ) -> Option<GestureAction> {
        let invert_h = self.config.invert_h;
        match (self.state, cls) {
            (NavState::Standby { .. }, TemplateClass::OpenMc) => {
                self.state = NavState::Armed {
                    remaining_ms: self.config.armed_timeout_ms,
                    cooldown_ms: cooldown_ms.max(self.config.lift_settle_ms),
                };
                self.sync_grace_ms = 1400;
                Some(GestureAction::MissionControlShow)
            }
            (NavState::Armed { .. }, TemplateClass::CloseMc) => {
                self.state = NavState::Standby { cooldown_ms };
                self.sync_grace_ms = 1400;
                Some(GestureAction::MissionControlHide)
            }
            (NavState::Armed { .. }, TemplateClass::SwipeRight) => {
                self.state = NavState::Armed {
                    remaining_ms: self.config.armed_timeout_ms,
                    cooldown_ms,
                };
                Some(if invert_h {
                    GestureAction::SpaceRight
                } else {
                    GestureAction::SpaceLeft
                })
            }
            (NavState::Armed { .. }, TemplateClass::SwipeLeft) => {
                self.state = NavState::Armed {
                    remaining_ms: self.config.armed_timeout_ms,
                    cooldown_ms,
                };
                Some(if invert_h {
                    GestureAction::SpaceLeft
                } else {
                    GestureAction::SpaceRight
                })
            }
            // Non-allowed class for current state (e.g. lateral swipe while MC closed) -> ignore.
            _ => None,
        }
    }
}

/// Lateral slap-swipe direction (calibrated to user's Ring 5 axis):
fn swipe_action(accel_h_g: f64) -> GestureAction {
    if accel_h_g > 0.0 {
        GestureAction::SpaceRight
    } else {
        GestureAction::SpaceLeft
    }
}

fn add(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn scale(a: [f64; 3], s: f64) -> [f64; 3] {
    [a[0] * s, a[1] * s, a[2] * s]
}
fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn vlen(a: [f64; 3]) -> f64 {
    (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).sqrt()
}
fn norm(a: [f64; 3]) -> [f64; 3] {
    let l = vlen(a);
    if l < 1e-9 {
        [0.0, 1.0, 0.0]
    } else {
        scale(a, 1.0 / l)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_from(g_unit: [f64; 3], lin_g: [f64; 3]) -> AcmSample {
        let v = add(scale(norm(g_unit), COUNTS_PER_G), scale(lin_g, COUNTS_PER_G));
        AcmSample {
            x: v[0].round() as i16,
            y: v[1].round() as i16,
            z: v[2].round() as i16,
        }
    }

    #[test]
    fn palm_down_typing_and_lateral_moves_stay_locked_in_standby() {
        let cal = Calibration::from_neutral([0.0, 1.0, 0.0]);
        let mut det = GestureDetector::new(GestureConfig {
            calibration: Some(cal),
            ..Default::default()
        });
        for _ in 0..20 {
            assert_eq!(det.feed_50hz(sample_from(cal.u0, [0.0; 3])).0, None);
        }
        // Even strong lateral or upward jerks while palm-down must not trigger in Standby.
        for _ in 0..10 {
            assert_eq!(det.feed_50hz(sample_from(cal.u0, [1.2, 1.2, 0.0])).0, None);
        }
        assert!(!det.attitude().nav_armed);
    }

    #[test]
    fn palm_up_lift_opens_mc_and_arms_lateral_slap_swipes() {
        let cal = Calibration::from_neutral([0.0, 1.0, 0.0]);
        let mut det = GestureDetector::new(GestureConfig {
            calibration: Some(cal),
            ..Default::default()
        });
        let palm_up = scale(cal.u0, -1.0);

        // Settle palm-up (inverted)
        for _ in 0..40 {
            assert_eq!(det.feed_50hz(sample_from(palm_up, [0.0; 3])).0, None);
        }
        assert!(det.attitude().palm_inverted);

        // Big upward lift while palm-up (world UP = palm_up direction) -> MissionControlShow!
        let (act, _) = det.feed_50hz(sample_from(palm_up, scale(palm_up, 0.95)));
        assert_eq!(act, Some(GestureAction::MissionControlShow));
        assert!(det.attitude().nav_armed);

        // Wait past lift_settle_ms (360ms = 18 samples)
        for _ in 0..18 {
            assert_eq!(det.feed_50hz(sample_from(palm_up, [0.0; 3])).0, None);
        }

        // Slow lateral movement (0.3g < 0.65g) must NOT trigger
        assert_eq!(
            det.feed_50hz(sample_from(palm_up, scale(cal.b_r, 0.3))).0,
            None
        );

        // Slap in -b_r while palm-up (accel_h_g > 0) -> SpaceRight!
        let (act, _) = det.feed_50hz(sample_from(palm_up, scale(cal.b_r, -1.0)));
        assert_eq!(act, Some(GestureAction::SpaceRight));

        // Immediate braking deceleration in opposite direction must be ignored by cooldown
        let (act, _) = det.feed_50hz(sample_from(palm_up, scale(cal.b_r, 1.1)));
        assert_eq!(act, None);

        // Wait past swipe_cooldown_ms (560ms = 28 samples)
        for _ in 0..28 {
            assert_eq!(det.feed_50hz(sample_from(palm_up, [0.0; 3])).0, None);
        }

        // Slap in +b_r while palm-up (accel_h_g < 0) -> SpaceLeft!
        let (act, _) = det.feed_50hz(sample_from(palm_up, scale(cal.b_r, 1.0)));
        assert_eq!(act, Some(GestureAction::SpaceLeft));

        // Wait past cooldown, flip palm-down, and push downward -> MissionControlHide!
        for _ in 0..40 {
            assert_eq!(det.feed_50hz(sample_from(cal.u0, [0.0; 3])).0, None);
        }
        let (act, _) = det.feed_50hz(sample_from(cal.u0, scale(cal.u0, -0.6)));
        assert_eq!(act, Some(GestureAction::MissionControlHide));
        assert!(!det.attitude().nav_armed);
    }

    #[test]
    fn matched_filter_2stage_gating_and_classification() {
        let w = 8;
        let make_tpl = |axis: [f64; 3]| -> Vec<f64> {
            let mut v = Vec::with_capacity(w * 3);
            for i in 0..w {
                let amp = if i >= 3 && i <= 5 { 2.0 } else { 0.2 };
                v.push(axis[0] * amp);
                v.push(axis[1] * amp);
                v.push(axis[2] * amp);
            }
            l2_normalize(&mut v);
            v
        };
        let tpls = GestureTemplates {
            window_len: w,
            sample_dt_ms: 20,
            min_lin_g: 0.8,
            peak_confirm_samples: 2,
            cooldown_ms: 200,
            thresholds: TemplateThresholds {
                open_mc: 0.85,
                close_mc: 0.85,
                swipe_right: 0.85,
                swipe_left: 0.85,
            },
            templates: TemplateVectors {
                open_mc: make_tpl([-1.0, 0.0, 1.0]),
                close_mc: make_tpl([0.0, 0.0, -1.0]),
                swipe_right: make_tpl([-1.0, 0.0, 0.0]),
                swipe_left: make_tpl([1.0, 0.0, 0.0]),
            },
        };

        let mut det = GestureDetector::new(GestureConfig::default());
        det.set_templates(Some(tpls));

        let feed_wave = |det: &mut GestureDetector, axis: [f64; 3]| -> Vec<GestureAction> {
            let mut out = Vec::new();
            for i in 0..(w + 6) {
                let amp = if i >= 3 && i <= 5 { 2.0 } else { 0.2 };
                let s = AcmSample {
                    x: (axis[0] * amp * 1000.0) as i16,
                    y: (axis[1] * amp * 1000.0) as i16,
                    z: (axis[2] * amp * 1000.0) as i16,
                };
                if let Some(a) = det.feed_50hz(s).0 {
                    out.push(a);
                }
            }
            out
        };

        // In Standby, swipe_right must NOT trigger.
        assert_eq!(feed_wave(&mut det, [-1.0, 0.0, 0.0]), vec![]);
        assert!(!det.attitude().nav_armed);

        // open_mc transitions to Armed and emits MissionControlShow.
        assert_eq!(
            feed_wave(&mut det, [-1.0, 0.0, 1.0]),
            vec![GestureAction::MissionControlShow]
        );
        assert!(det.attitude().nav_armed);

        // Wait past cooldown.
        for _ in 0..20 {
            det.feed_50hz(AcmSample { x: 0, y: 0, z: -1000 });
        }

        // In Armed, swipe_right template emits SpaceLeft (user's natural direction) and stays Armed.
        assert_eq!(
            feed_wave(&mut det, [-1.0, 0.0, 0.0]),
            vec![GestureAction::SpaceLeft]
        );
        assert!(det.attitude().nav_armed);

        for _ in 0..20 {
            det.feed_50hz(AcmSample { x: 0, y: 0, z: -1000 });
        }

        // close_mc returns to Standby and emits MissionControlHide.
        assert_eq!(
            feed_wave(&mut det, [0.0, 0.0, -1.0]),
            vec![GestureAction::MissionControlHide]
        );
        assert!(!det.attitude().nav_armed);
    }
}
