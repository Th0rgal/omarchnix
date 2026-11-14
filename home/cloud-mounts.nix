# On-demand sparse-cached FUSE cloud mounts (`~/Cloud/Apple` & `~/Cloud/Google`)
# backed by `rclone mount --vfs-cache-mode full`, with Flea & GTK sidebar bookmarks.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omarchnix.cloudMounts;

  mounts = {
    apple = {
      remote = "apple";
      backend = "iclouddrive";
      label = "iCloud";
      description = "Apple iCloud Drive";
      mountPoint = "${cfg.baseDir}/Apple";
      # `iclouddrive` does not implement server-push ChangeNotify; 15m paired with
      # `rclone-keepwarm.timer` keeps root traversal instant in Flea while still
      # picking up external iPhone/Mac uploads promptly.
      dirCacheTime = "15m";
      extraArgs = [ ];
    };
    google = {
      remote = "google";
      backend = "drive";
      label = "Google Drive";
      description = "Google Drive";
      mountPoint = "${cfg.baseDir}/Google";
      # Google Drive polls its `changes` delta feed every minute, invalidating
      # modified directories automatically even with a 24h local dir cache.
      dirCacheTime = "24h";
      extraArgs = lib.optionals (cfg.googleDocsExportFormats != "") [
        "--drive-export-formats"
        cfg.googleDocsExportFormats
      ];
    };
  };

  mkServicePath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.rclone
    pkgs.util-linux
  ];

  mkMountService =
    _name: m:
    let
      checkRemote = pkgs.writeShellScript "rclone-check-${m.remote}" ''
        ${pkgs.rclone}/bin/rclone config dump 2>/dev/null | ${pkgs.jq}/bin/jq -e \
          --arg r ${lib.escapeShellArg m.remote} '
          (.[$r] // null) as $cfg
          | $cfg != null
          and (
            (($cfg.token // "") != "")
            or (($cfg.service_account_file // "") != "")
            or (($cfg.cookies // "") != "")
            or (($cfg.trust_token // "") != "")
            or (($cfg.password // "") != "")
          )
        ' >/dev/null 2>&1
      '';

      prepareMount = pkgs.writeShellScript "rclone-prepare-${m.remote}" ''
        set -eu
        mp=${lib.escapeShellArg m.mountPoint}
        # Heal any stale disconnected FUSE endpoint left behind after an abrupt kill.
        if ! ${pkgs.coreutils}/bin/stat "$mp" >/dev/null 2>&1; then
          /run/wrappers/bin/fusermount3 -uz "$mp" 2>/dev/null || true
        fi
        ${pkgs.coreutils}/bin/mkdir -p "$mp"
      '';

      warmMount = pkgs.writeShellScript "rclone-warm-${m.remote}" ''
        mp=${lib.escapeShellArg m.mountPoint}
        (
          ${pkgs.coreutils}/bin/timeout 25 ${pkgs.coreutils}/bin/ls -1 "$mp" >/dev/null 2>&1 || true
        ) >/dev/null 2>&1 &
        exit 0
      '';

      mountArgs = [
        "${pkgs.rclone}/bin/rclone"
        "mount"
        "${m.remote}:"
        m.mountPoint
        "--devname"
        m.label
        "--attr-timeout"
        "5s"
        "--vfs-cache-mode"
        "full"
        "--vfs-cache-max-size"
        cfg.cacheMaxSize
        "--vfs-cache-max-age"
        cfg.cacheMaxAge
        "--vfs-cache-min-free-space"
        cfg.cacheMinFreeSpace
        "--vfs-write-back"
        "5s"
        "--vfs-fast-fingerprint"
        "--vfs-read-chunk-size"
        "16M"
        "--vfs-read-chunk-size-limit"
        "256M"
        "--buffer-size"
        "16M"
        "--dir-cache-time"
        m.dirCacheTime
        "--log-level"
        "NOTICE"
      ]
      ++ m.extraArgs;
    in
    {
      Unit = {
        Description = "${m.description} on-demand FUSE mount (${m.mountPoint})";
        After = [ "network-online.target" ];
        ConditionPathExists = "%h/.config/rclone/rclone.conf";
        StartLimitIntervalSec = 0;
      };
      Service = {
        Type = "notify";
        Environment = [
          "PATH=/run/wrappers/bin:${mkServicePath}"
        ];
        # Exit 1 when the remote is not yet configured in rclone.conf so systemd
        # cleanly skips starting the unit instead of marking it failed.
        ExecCondition = "${checkRemote}";
        ExecStartPre = "${prepareMount}";
        ExecStart = lib.escapeShellArgs mountArgs;
        ExecStartPost = "-${warmMount}";
        ExecStop = "/run/wrappers/bin/fusermount3 -uz ${lib.escapeShellArg m.mountPoint}";
        Restart = "on-failure";
        RestartSec = 10;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };

  cloudHelper = pkgs.writeShellScriptBin "cloud" ''
    set -euo pipefail

    export PATH="/run/wrappers/bin:${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.rclone
        pkgs.systemd
        pkgs.util-linux
      ]
    }:$PATH"

    usage() {
      cat <<'EOF'
    Usage:
      cloud status                  Show iCloud & Google Drive mount status and local cache size
      cloud setup <apple|google>    Configure credentials interactively and mount immediately
      cloud reconnect <apple|google> Refresh OAuth / 30-day Apple 2FA token and remount
      cloud restart [apple|google]  Restart one or both cloud mount services
      cloud stop [apple|google]     Stop and unmount one or both cloud drives
      cloud clean-cache             Stop mounts, clear ~/.cache/rclone/vfs*, and remount
    EOF
    }

    has_remote() {
      rclone listremotes 2>/dev/null | grep -qxF "$1:"
    }

    show_one() {
      local name="$1" label="$2" mp="$3" unit="rclone-$1.service"
      local cfg_state="unconfigured" mnt_state="unmounted" svc_state
      if has_remote "$name"; then
        cfg_state="configured"
      fi
      if mountpoint -q "$mp" 2>/dev/null; then
        mnt_state="mounted"
      fi
      svc_state="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
      printf "%-14s %-14s %-12s service=%-10s %s\n" "$label" "[$cfg_state]" "[$mnt_state]" "$svc_state" "$mp"
    }

    cmd="''${1:-status}"
    target="''${2:-all}"

    case "$cmd" in
      status)
        show_one apple "iCloud" ${lib.escapeShellArg mounts.apple.mountPoint}
        show_one google "Google Drive" ${lib.escapeShellArg mounts.google.mountPoint}
        cache_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/rclone"
        if [ -d "$cache_dir" ]; then
          printf "\nLocal VFS cache (%s): %s\n" "$cache_dir" "$(du -sh "$cache_dir" 2>/dev/null | cut -f1)"
        else
          printf "\nLocal VFS cache (%s): 0B\n" "$cache_dir"
        fi
        ;;

      setup)
        case "$target" in
          apple)
            echo "Configuring iCloud Drive ('apple:' -> ${mounts.apple.mountPoint})"
            echo "Note: If Apple Advanced Data Protection is enabled, ensure 'Access iCloud Data on the Web' is ON in iCloud Settings."
            rclone config create apple iclouddrive service=drive --all --no-output
            systemctl --user restart rclone-apple.service
            systemctl --user status --no-pager rclone-apple.service || true
            ;;
          google)
            echo "Configuring Google Drive ('google:' -> ${mounts.google.mountPoint})"
            echo "Tip: Supplying your own Google Cloud Desktop OAuth client_id & client_secret avoids shared API rate limits."
            rclone config create google drive scope=drive --all --no-output
            systemctl --user restart rclone-google.service
            systemctl --user status --no-pager rclone-google.service || true
            ;;
          *)
            echo "Specify 'apple' or 'google': cloud setup <apple|google>" >&2
            exit 1
            ;;
        esac
        ;;

      reconnect)
        case "$target" in
          apple|google)
            rclone config reconnect "$target:"
            systemctl --user restart "rclone-$target.service"
            systemctl --user status --no-pager "rclone-$target.service" || true
            ;;
          *)
            echo "Specify 'apple' or 'google': cloud reconnect <apple|google>" >&2
            exit 1
            ;;
        esac
        ;;

      restart)
        case "$target" in
          apple|google) systemctl --user restart "rclone-$target.service" ;;
          all) systemctl --user restart rclone-apple.service rclone-google.service ;;
          *) usage >&2; exit 1 ;;
        esac
        ;;

      stop|unmount)
        case "$target" in
          apple|google) systemctl --user stop "rclone-$target.service" ;;
          all) systemctl --user stop rclone-apple.service rclone-google.service ;;
          *) usage >&2; exit 1 ;;
        esac
        ;;

      clean-cache)
        systemctl --user stop rclone-apple.service rclone-google.service || true
        rm -rf "''${XDG_CACHE_HOME:-$HOME/.cache}/rclone/vfs" "''${XDG_CACHE_HOME:-$HOME/.cache}/rclone/vfsMeta"
        systemctl --user start rclone-apple.service rclone-google.service || true
        ;;

      -h|--help|help)
        usage
        ;;

      *)
        usage >&2
        exit 1
        ;;
    esac
  '';
in
{
  options.programs.omarchnix.cloudMounts = {
    enable = lib.mkEnableOption "on-demand Google Drive (`~/Cloud/Google`) and iCloud Drive (`~/Cloud/Apple`) FUSE mounts via `rclone`";

    baseDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Cloud";
      description = "Parent directory containing the `Apple` and `Google` mountpoints.";
    };

    cacheMaxSize = lib.mkOption {
      type = lib.types.str;
      default = "20G";
      description = "Maximum local sparse VFS cache size per cloud mount before least-recently-used chunks are evicted.";
    };

    cacheMaxAge = lib.mkOption {
      type = lib.types.str;
      default = "168h";
      description = "Maximum time untouched cached files remain in `~/.cache/rclone` before automatic eviction.";
    };

    cacheMinFreeSpace = lib.mkOption {
      type = lib.types.str;
      default = "10G";
      description = "Minimum free disk space preserved on `/` before evicting VFS cache entries.";
    };

    googleDocsExportFormats = lib.mkOption {
      type = lib.types.str;
      default = "link.html";
      description = ''
        Preferred representation for native Google Docs/Sheets/Slides (`link.html`
        opens live web docs in Helium on double-click; set to `docx,xlsx,pptx,svg`
        for on-the-fly Office conversion).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.rclone
      cloudHelper
    ];

    home.activation.ensureCloudMountDirs = config.lib.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${lib.escapeShellArg mounts.apple.mountPoint} ${lib.escapeShellArg mounts.google.mountPoint}
    '';

    home.activation.cloudGtkBookmarks =
      config.lib.dag.entryAfter
        [
          "omarchnixUserDirs"
          "ensureCloudMountDirs"
          "personalGtkBookmarks"
        ]
        ''
          bookmarks_file="$HOME/.config/gtk-3.0/bookmarks"
          mkdir -p "$HOME/.config/gtk-3.0"
          touch "$bookmarks_file"
          for spec in \
            "file://${mounts.apple.mountPoint} ${mounts.apple.label}" \
            "file://${mounts.google.mountPoint} ${mounts.google.label}"; do
            uri="''${spec%% *}"
            label="''${spec#* }"
            dir="''${uri#file://}"
            grep -qE "^''${uri}( |$)" "$bookmarks_file" 2>/dev/null || printf '%s\n' "$spec" >> "$bookmarks_file"
            if [ -x "${pkgs.flea}/bin/flea" ]; then
              payload="$(${pkgs.jq}/bin/jq -nc --arg l "$label" --arg p "$dir" '{op:"add",record:{label:$l,path:$p}}')"
              "${pkgs.flea}/bin/flea" --favourites "$payload" >/dev/null 2>&1 || true
            fi
          done
        '';

    systemd.user.services = {
      rclone-apple = mkMountService "apple" mounts.apple;
      rclone-google = mkMountService "google" mounts.google;

      # Periodically warm the top-level cloud mount directories so OAuth / iCloud
      # sessions stay authenticated and root VFS listings remain cached in RAM
      # across overnight idle and laptop sleep/wake cycles.
      rclone-keepwarm = {
        Unit = {
          Description = "Keep iCloud Drive & Google Drive root VFS directory caches warm";
          After = [
            "rclone-apple.service"
            "rclone-google.service"
          ];
        };
        Service = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "rclone-keepwarm" ''
            for mp in ${lib.escapeShellArg mounts.apple.mountPoint} ${lib.escapeShellArg mounts.google.mountPoint}; do
              if ${pkgs.util-linux}/bin/mountpoint -q "$mp" 2>/dev/null; then
                ${pkgs.coreutils}/bin/timeout 25 ${pkgs.coreutils}/bin/ls -1 "$mp" >/dev/null 2>&1 || true
              fi
            done
          '';
        };
      };
    };

    systemd.user.timers.rclone-keepwarm = {
      Unit = {
        Description = "Periodic VFS root cache & session keepalive for cloud mounts";
      };
      Timer = {
        OnStartupSec = "45s";
        OnCalendar = "*:0/10";
        AccuracySec = "30s";
        Persistent = false;
      };
      Install = {
        WantedBy = [ "timers.target" ];
      };
    };
  };
}
