//! `ouractl` — lightweight IPC client for `ourad` (used by `Service.qml`,
//! Hyprland keybindings, and terminal debugging).

use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use oura_daemon::ipc::{default_socket_path, GestureToggleMode, Request};

#[derive(Parser, Debug)]
#[command(name = "ouractl", version, about = "Control the Omarchnix Oura Ring daemon")]
struct Cli {
    /// Path to the `ourad` Unix socket.
    #[arg(long, global = true)]
    socket: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Print the current daemon snapshot as JSON.
    Status,
    /// Stream newline-delimited JSON snapshots as state updates.
    Subscribe,
    /// Trigger an immediate BLE sync (battery, HR, history events).
    Sync,
    /// Stream live heart rate for N seconds.
    LiveHr {
        #[arg(long, default_value_t = 15)]
        seconds: u64,
    },
    /// Enable, disable, or toggle accelerometer gesture navigation.
    Gestures {
        #[arg(value_parser = ["on", "off", "toggle"])]
        mode: String,
    },
    /// Immediately re-zero the neutral hand pose.
    Zero,
    /// Start guided 2-step calibration (Hold Neutral -> Tilt Right).
    Calibrate,
    /// Update gesture settings.
    Config {
        #[arg(long)]
        invert_h: Option<bool>,
        #[arg(long)]
        require_lift_to_arm: Option<bool>,
        #[arg(long)]
        swipe_accel_g: Option<f64>,
        #[arg(long)]
        lift_accel_g: Option<f64>,
        #[arg(long)]
        auto_off_minutes: Option<u32>,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let sock_path = cli.socket.unwrap_or_else(default_socket_path);
    let stream = UnixStream::connect(&sock_path)
        .await
        .with_context(|| format!("connecting to ourad at {}", sock_path.display()))?;

    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    let (req, streaming) = match cli.command {
        Command::Status => (Request::Status, false),
        Command::Subscribe => (Request::Subscribe, true),
        Command::Sync => (Request::Sync, false),
        Command::LiveHr { seconds } => (Request::LiveHr { seconds }, false),
        Command::Gestures { mode } => {
            let m = match mode.as_str() {
                "on" => GestureToggleMode::On,
                "off" => GestureToggleMode::Off,
                _ => GestureToggleMode::Toggle,
            };
            (Request::Gestures { mode: m }, false)
        }
        Command::Zero => (Request::ZeroNeutral, false),
        Command::Calibrate => (Request::Calibrate, false),
        Command::Config {
            invert_h,
            require_lift_to_arm,
            swipe_accel_g,
            lift_accel_g,
            auto_off_minutes,
        } => (
            Request::UpdateConfig {
                invert_h,
                require_lift_to_arm,
                swipe_accel_g,
                lift_accel_g,
                auto_off_minutes,
            },
            false,
        ),
    };

    let mut payload = serde_json::to_string(&req)?;
    payload.push('\n');
    writer.write_all(payload.as_bytes()).await?;
    writer.flush().await?;

    if streaming {
        while let Some(line) = lines.next_line().await? {
            println!("{line}");
        }
    } else if let Some(line) = lines.next_line().await? {
        println!("{line}");
    }

    Ok(())
}
