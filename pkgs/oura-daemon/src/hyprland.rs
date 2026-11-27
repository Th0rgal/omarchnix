//! Hyprland & Omarchy Shell dispatchers for ring gestures.
//!
//! Mirrors Omarchnix's 3-finger swipe behavior:
//! - Respects `$XDG_RUNTIME_DIR/omarchnix-passthrough` (no-op while forwarding
//!   shortcuts to a remote/VM window).
//! - Targets the monitor currently under the cursor before stepping Spaces
//!   (`workspace m-1` / `m+1`), triggering Hyprland's native slide animation.
//! - Uses `omarchy-shell shell summon/hide io.github.joaovitor2763.mission-control`
//!   for big vertical Mission Control gestures.

use std::path::PathBuf;

use serde_json::Value;
use tokio::process::Command;

use crate::gesture::GestureAction;

const MISSION_CONTROL_ID: &str = "io.github.joaovitor2763.mission-control";

fn passthrough_active() -> bool {
    let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(runtime).join("omarchnix-passthrough").exists()
}

/// Check whether the Omarchy lock screen is currently active so `ourad` can
/// automatically shut down ACM streaming and save ring battery.
pub async fn is_session_locked() -> bool {
    let Ok(out) = Command::new("omarchy-shell")
        .args(["lock", "status"])
        .output()
        .await
    else {
        return false;
    };
    if !out.status.success() {
        return false;
    }
    let Ok(v) = serde_json::from_slice::<Value>(&out.stdout) else {
        return false;
    };
    v.get("locked").and_then(|x| x.as_bool()).unwrap_or(false)
        || v.get("sessionLocked")
            .and_then(|x| x.as_bool())
            .unwrap_or(false)
}

/// Focus the monitor currently under the mouse pointer, matching Omarchnix's
/// `hl.get_monitor_at_cursor()` convention.
async fn focus_cursor_monitor() {
    let Ok(pos_out) = Command::new("hyprctl")
        .args(["cursorpos", "-j"])
        .output()
        .await
    else {
        return;
    };
    let Ok(mons_out) = Command::new("hyprctl")
        .args(["monitors", "-j"])
        .output()
        .await
    else {
        return;
    };
    let (Ok(pos), Ok(mons)) = (
        serde_json::from_slice::<Value>(&pos_out.stdout),
        serde_json::from_slice::<Value>(&mons_out.stdout),
    ) else {
        return;
    };
    let (Some(cx), Some(cy)) = (
        pos.get("x").and_then(|x| x.as_f64()),
        pos.get("y").and_then(|y| y.as_f64()),
    ) else {
        return;
    };
    let Some(list) = mons.as_array() else {
        return;
    };
    for m in list {
        if m.get("disabled").and_then(|x| x.as_bool()).unwrap_or(false) {
            continue;
        }
        let mx = m.get("x").and_then(|x| x.as_f64()).unwrap_or(0.0);
        let my = m.get("y").and_then(|y| y.as_f64()).unwrap_or(0.0);
        let scale = m
            .get("scale")
            .and_then(|s| s.as_f64())
            .filter(|&s| s > 0.0)
            .unwrap_or(1.0);
        let transform = m.get("transform").and_then(|t| t.as_u64()).unwrap_or(0);
        let mut pw = m.get("width").and_then(|w| w.as_f64()).unwrap_or(0.0);
        let mut ph = m.get("height").and_then(|h| h.as_f64()).unwrap_or(0.0);
        if transform % 2 == 1 {
            std::mem::swap(&mut pw, &mut ph);
        }
        let lw = pw / scale;
        let lh = ph / scale;
        if cx >= mx && cx < mx + lw && cy >= my && cy < my + lh {
            let focused = m.get("focused").and_then(|f| f.as_bool()).unwrap_or(false);
            if !focused {
                if let Some(name) = m.get("name").and_then(|n| n.as_str()) {
                    let expr = format!(
                        "hl.dsp.focus({{ monitor = {:?} }})",
                        name
                    );
                    let _ = Command::new("hyprctl")
                        .args(["dispatch", &expr])
                        .status()
                        .await;
                }
            }
            return;
        }
    }
}

/// Return the currently active workspace ID on the focused monitor.
async fn active_workspace_id() -> Option<i64> {
    let out = Command::new("hyprctl")
        .args(["activeworkspace", "-j"])
        .output()
        .await
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let v = serde_json::from_slice::<Value>(&out.stdout).ok()?;
    v.get("id").and_then(|x| x.as_i64())
}

/// Check whether Mission Control overlay is currently mapped on any screen.
pub async fn is_mission_control_open() -> bool {
    let Ok(out) = Command::new("hyprctl")
        .args(["layers", "-j"])
        .output()
        .await
    else {
        return false;
    };
    if !out.status.success() {
        return false;
    }
    String::from_utf8_lossy(&out.stdout).contains("omarchy-mission-control")
}

pub async fn dispatch_gesture(action: GestureAction) {
    if passthrough_active() {
        tracing::debug!("ignoring ring gesture {:?} during passthrough", action);
        return;
    }

    match action {
        GestureAction::SpaceLeft => {
            if !is_mission_control_open().await {
                tracing::debug!("ignoring SpaceLeft because Mission Control is not open");
                return;
            }
            focus_cursor_monitor().await;
            let _ = Command::new("hyprctl")
                .args(["dispatch", r#"hl.dsp.focus({ workspace = "m-1" })"#])
                .status()
                .await;
        }
        GestureAction::SpaceRight => {
            if !is_mission_control_open().await {
                tracing::debug!("ignoring SpaceRight because Mission Control is not open");
                return;
            }
            focus_cursor_monitor().await;
            let _ = Command::new("hyprctl")
                .args(["dispatch", r#"hl.dsp.focus({ workspace = "m+1" })"#])
                .status()
                .await;
        }
        GestureAction::MissionControlShow => {
            focus_cursor_monitor().await;
            let _ = Command::new("omarchy-shell")
                .args(["shell", "summon", MISSION_CONTROL_ID, "{}"])
                .status()
                .await;
        }
        GestureAction::MissionControlHide => {
            // Capture the selected Space before hiding Mission Control. When the
            // overlay releases WlrKeyboardFocus.Exclusive, Hyprland's layer
            // focus-restore yanks back to the pre-overlay Space; temporarily
            // disabling the `workspaces` slide animation lets us snap straight
            // back to `target_ws` in 0 ms while Mission Control's 190 ms zoom
            // animation is still covering the screen, so the target Space never
            // slides in from the left or right.
            let target_ws = active_workspace_id().await;
            if target_ws.is_some() {
                let _ = Command::new("hyprctl")
                    .args([
                        "dispatch",
                        r#"function() hl.animation({ leaf = "workspaces", enabled = false }) end"#,
                    ])
                    .status()
                    .await;
            }
            let _ = Command::new("omarchy-shell")
                .args(["shell", "hide", MISSION_CONTROL_ID])
                .status()
                .await;
            if let Some(ws) = target_ws {
                tokio::time::sleep(std::time::Duration::from_millis(45)).await;
                let expr = format!("hl.dsp.focus({{ workspace = {ws} }})");
                let _ = Command::new("hyprctl")
                    .args(["dispatch", &expr])
                    .status()
                    .await;
                tokio::time::sleep(std::time::Duration::from_millis(35)).await;
                let _ = Command::new("hyprctl")
                    .args([
                        "dispatch",
                        r#"function() hl.animation({ leaf = "workspaces", enabled = true, speed = 3, bezier = "easeOutQuint", style = "slide" }) end"#,
                    ])
                    .status()
                    .await;
            }
        }
    }
}
