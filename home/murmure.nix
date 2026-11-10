{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omarchnix;
  mCfg = cfg.murmure;

  defaultMurmurePkg =
    if pkgs ? murmure then
      pkgs.murmure
    else
      let
        crispasr = pkgs.callPackage ../pkgs/crispasr-cohere.nix { };
        buildPlugin =
          if (pkgs ? omarchnix) && (pkgs.omarchnix ? buildPlugin) then pkgs.omarchnix.buildPlugin else null;
      in
      pkgs.callPackage ../pkgs/murmure {
        crispasr-cohere = crispasr;
        inherit buildPlugin;
      };

  murmurePkg = if mCfg.package != null then mCfg.package else defaultMurmurePkg;
  murmurePlugin = murmurePkg.passthru.plugin or null;
  murmureBin = "${murmurePkg}/bin/murmure";
in
{
  options.programs.omarchnix.murmure = {
    enable = lib.mkEnableOption "Murmure private on-device voice dictation (`Fn + Right Shift` + shared `voiced` Cohere Transcribe daemon)";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      defaultText = lib.literalExpression "pkgs.murmure";
      description = "Murmure package providing `voiced`, `murmured`, `murmure`, `murmure-settings`, and `orb-voice-bridge`.";
    };

    barSection = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "left"
          "centerBegin"
          "center"
          "centerEnd"
          "tray"
          "right"
        ]
      );
      default = "right";
      description = "Status-bar section where the `th0rgal.murmure` waveform/dictation indicator is placed.";
    };

    unloadSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Seconds of inactivity before `voiced` unloads the Cohere Transcribe model from memory.";
    };
  };

  config = lib.mkIf (cfg.enable && mCfg.enable) {
    home.packages = [
      murmurePkg
    ];

    home.sessionVariables = {
      ORB_VOICE_PYTHON = "${pkgs.python3}/bin/python3";
      ORB_VOICE_WORKER = "${murmurePkg}/libexec/murmure/voiced/orb_voice_bridge.py";
      VOICED_COHERE_LIB = "${murmurePkg.crispasr-cohere}/lib/libcohere_asr.so";
    };

    systemd.user.sessionVariables = {
      ORB_VOICE_PYTHON = "${pkgs.python3}/bin/python3";
      ORB_VOICE_WORKER = "${murmurePkg}/libexec/murmure/voiced/orb_voice_bridge.py";
      VOICED_COHERE_LIB = "${murmurePkg.crispasr-cohere}/lib/libcohere_asr.so";
    };

    programs.omarchnix.plugins.locked = lib.optionalAttrs (murmurePlugin != null) {
      "th0rgal.murmure" = {
        package = murmurePlugin;
        enable = true;
        section = mCfg.barSection;
      };
    };

    systemd.user.sockets.voiced = {
      Unit = {
        Description = "Shared on-device Cohere Transcribe speech daemon socket (md.thomas.voice)";
      };
      Socket = {
        ListenStream = "%h/.local/share/md.thomas.voice/voiced.sock";
        SocketMode = "0600";
        DirectoryMode = "0700";
        RemoveOnStop = true;
      };
      Install = {
        WantedBy = [ "sockets.target" ];
      };
    };

    systemd.user.services.voiced = {
      Unit = {
        Description = "Shared on-device Cohere Transcribe speech daemon (md.thomas.voice)";
        Requires = [ "voiced.socket" ];
        After = [ "voiced.socket" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${murmurePkg}/bin/voiced";
        Environment = [
          "VOICED_UNLOAD_SECS=${toString mCfg.unloadSeconds}"
          "VOICED_EXIT_SECS=1800"
        ];
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    systemd.user.services.murmure = {
      Unit = {
        Description = "Murmure Wayland dictation daemon (Fn + Right Shift)";
        PartOf = [ "graphical-session.target" ];
        After = [
          "graphical-session.target"
          "pipewire.service"
          "voiced.socket"
        ];
        Wants = [ "voiced.socket" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${murmurePkg}/bin/murmured";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };

    wayland.windowManager.hyprland = {
      extraConfig = lib.mkAfter ''
        hl.define_submap("murmure-recording", function()
          hl.bind("Escape", function()
            hl.dispatch(hl.dsp.submap("reset"))
            hl.dispatch(hl.dsp.exec_cmd(${builtins.toJSON "${murmureBin} cancel"}))
          end)
          hl.bind("Return", function()
            hl.dispatch(hl.dsp.submap("reset"))
            hl.dispatch(hl.dsp.exec_cmd(${builtins.toJSON "${murmureBin} commit"}))
          end)
          hl.bind("KP_Enter", function()
            hl.dispatch(hl.dsp.submap("reset"))
            hl.dispatch(hl.dsp.exec_cmd(${builtins.toJSON "${murmureBin} commit"}))
          end)
        end)
      '';

      settings.window_rule = lib.mkAfter [
        {
          name = "murmure-settings-dialog";
          match = {
            class = "^(murmure-settings|murmure_settings\\.py)$";
          };
          float = true;
          center = true;
        }
      ];

      settings.layer_rule = lib.mkAfter [
        {
          name = "omarchnix-murmure";
          match = {
            namespace = "^omarchnix-murmure$";
          };
          no_anim = true;
          animation = "none";
        }
      ];
    };
  };
}
