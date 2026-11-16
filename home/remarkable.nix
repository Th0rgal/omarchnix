# reMarkable cloud in `~/Cloud/reMarkable` (next to Apple & Google in Flea):
# a timed one-way mirror of the reMarkable cloud as readable PDF / EPUB files,
# plus a watcher that uploads anything dropped into that folder right away.
# rclone has no reMarkable backend, so this uses rmapi instead of a FUSE mount.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omarchnix.cloudMounts;
  rCfg = cfg.remarkable;

  syncDir = "${cfg.baseDir}/reMarkable";
  # rmapi's token file (XDG location, as rmapi writes it when `~/.rmapi` does
  # not already exist); its presence means `remarkable setup` ran.
  tokenFile = "%h/.config/rmapi/rmapi.conf";

  remarkableSync = pkgs.writeShellApplication {
    name = "remarkable-sync";
    runtimeInputs = [
      pkgs.python3
      pkgs.rmapi
      pkgs.inotify-tools
      pkgs.libnotify
    ];
    text = ''
      exec python3 -I ${../pkgs/remarkable-sync/remarkable_sync.py} --dir ${lib.escapeShellArg syncDir} "$@"
    '';
  };

  remarkableHelper = pkgs.writeShellApplication {
    name = "remarkable";
    runtimeInputs = [
      pkgs.rmapi
      pkgs.systemd
      pkgs.coreutils
    ];
    text = ''
      usage() {
        cat <<'EOF'
      Usage:
        remarkable setup     Pair this laptop with your reMarkable account and start syncing
        remarkable status    Show sync services and the last pull
        remarkable pull      Pull from the reMarkable cloud now
        remarkable logs      Follow the sync logs
        remarkable reset     Forget the pairing and stop syncing
      EOF
      }

      case "''${1:-status}" in
        setup)
          echo "Open https://my.remarkable.com/device/desktop/connect, then paste the one-time code below."
          rmapi ls / >/dev/null
          systemctl --user start remarkable-pull.service
          systemctl --user restart remarkable-watch.service remarkable-pull.timer
          echo "Syncing into ${syncDir}"
          ;;
        status)
          systemctl --user --no-pager status remarkable-watch.service remarkable-pull.timer remarkable-pull.service || true
          ;;
        pull)
          systemctl --user start remarkable-pull.service
          ;;
        logs)
          journalctl --user -f -u remarkable-watch.service -u remarkable-pull.service
          ;;
        reset)
          systemctl --user stop remarkable-watch.service remarkable-pull.timer || true
          rmapi reset
          ;;
        -h | --help | help)
          usage
          ;;
        *)
          usage >&2
          exit 1
          ;;
      esac
    '';
  };
in
{
  options.programs.omarchnix.cloudMounts.remarkable = {
    enable = lib.mkEnableOption "reMarkable cloud mirror in `~/Cloud/reMarkable`, with drag-and-drop upload (pair once with `remarkable setup`)";

    pullInterval = lib.mkOption {
      type = lib.types.str;
      default = "10min";
      description = "How often to pull changes made on the tablet (systemd time span).";
    };
  };

  config = lib.mkIf (cfg.enable && rCfg.enable) {
    home.packages = [
      pkgs.rmapi
      remarkableSync
      remarkableHelper
    ];

    home.activation.remarkableBookmark =
      config.lib.dag.entryAfter
        [
          "writeBoundary"
          "cloudGtkBookmarks"
        ]
        ''
          mkdir -p ${lib.escapeShellArg syncDir} "$HOME/.config/gtk-3.0"
          bookmarks_file="$HOME/.config/gtk-3.0/bookmarks"
          touch "$bookmarks_file"
          uri=${lib.escapeShellArg "file://${syncDir}"}
          grep -qE "^''${uri}( |$)" "$bookmarks_file" 2>/dev/null || printf '%s reMarkable\n' "$uri" >> "$bookmarks_file"
          if [ -x "${pkgs.flea}/bin/flea" ]; then
            payload="$(${pkgs.jq}/bin/jq -nc --arg p ${lib.escapeShellArg syncDir} '{op:"add",record:{label:"reMarkable",path:$p}}')"
            "${pkgs.flea}/bin/flea" --favourites "$payload" >/dev/null 2>&1 || true
          fi
        '';

    systemd.user.services = {
      remarkable-pull = {
        Unit = {
          Description = "Pull the reMarkable cloud into ${syncDir}";
          After = [ "network-online.target" ];
          ConditionPathExists = tokenFile;
        };
        Service = {
          Type = "oneshot";
          ExecStart = "${remarkableSync}/bin/remarkable-sync pull";
          Nice = 10;
        };
      };

      remarkable-watch = {
        Unit = {
          Description = "Upload files dropped into ${syncDir} to the reMarkable cloud";
          After = [ "remarkable-pull.service" ];
          ConditionPathExists = tokenFile;
          StartLimitIntervalSec = 0;
        };
        Service = {
          ExecStart = "${remarkableSync}/bin/remarkable-sync watch";
          Restart = "always";
          RestartSec = 10;
        };
        Install.WantedBy = [ "default.target" ];
      };
    };

    systemd.user.timers.remarkable-pull = {
      Unit.Description = "Periodic reMarkable cloud pull";
      Timer = {
        OnStartupSec = "1min";
        OnUnitActiveSec = rCfg.pullInterval;
        AccuracySec = "30s";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
