{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omarchnix;
  oCfg = cfg.oura;
  inherit (lib.generators) mkLuaInline;

  omarchyLib = import ../lib/omarchy.nix { inherit lib; };

  buildPlugin =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? buildPlugin) then
      pkgs.omarchnix.buildPlugin
    else
      (args: omarchyLib.buildPlugin ({ inherit pkgs; } // args));

  daemonPkg =
    if oCfg.package != null then
      oCfg.package
    else if (pkgs ? omarchnix) && (pkgs.omarchnix ? oura-daemon) then
      pkgs.omarchnix.oura-daemon
    else
      null;

  defaultPlugin =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? plugins) && (pkgs.omarchnix.plugins ? oura) then
      pkgs.omarchnix.plugins.oura
    else if daemonPkg != null then
      buildPlugin {
        src = ../pkgs/plugins/omarchnix-oura;
        postInstall = ''
          substituteInPlace "$out/Service.qml" \
            --replace-fail '@OURACTL_BIN@' "${daemonPkg}/bin/ouractl"
        '';
      }
    else
      null;

  pluginPkg = if oCfg.pluginPackage != null then oCfg.pluginPackage else defaultPlugin;

  barSectionType = lib.types.nullOr (
    lib.types.enum [
      "left"
      "centerBegin"
      "center"
      "centerEnd"
      "tray"
      "right"
    ]
  );

  daemonArgs =
    [
      "${daemonPkg}/bin/ourad"
      "--name"
      oCfg.nameFilter
      "--sync-interval-minutes"
      (toString oCfg.syncIntervalMinutes)
    ]
    ++ lib.optionals (oCfg.address != null) [
      "--address"
      oCfg.address
    ]
    ++ lib.optionals (oCfg.keyFile != null) [
      "--key-file"
      oCfg.keyFile
    ];
in
{
  options.programs.omarchnix.oura = {
    enable = lib.mkEnableOption "cloud-free Oura Ring BLE daemon (`ourad`), daily HR trends, and ring tilt Space/Mission Control gestures (`omarchnix.oura`)";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      defaultText = lib.literalExpression "pkgs.omarchnix.oura-daemon";
      description = "Package providing `ourad` and `ouractl`.";
    };

    pluginPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      defaultText = lib.literalExpression "pkgs.omarchnix.plugins.oura";
      description = "Package providing the `omarchnix.oura` Quickshell bar plugin.";
    };

    nameFilter = lib.mkOption {
      type = lib.types.str;
      default = "Oura";
      description = "Case-insensitive BLE device-name substring filter passed to `ourad --name`.";
    };

    address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional exact BLE address/identifier to bind to a specific ring.";
    };

    keyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to the 16-byte hex Oura auth key file (e.g. sops-nix `/run/secrets/oura_auth_key`). Defaults to `~/.config/oura/key.hex`.";
    };

    syncIntervalMinutes = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 15;
      description = "Periodic background BLE sync interval in minutes (0 disables automatic sync).";
    };

    barSection = lib.mkOption {
      type = barSectionType;
      default = "right";
      description = "Status-bar section where the icon-only `omarchnix.oura` widget is placed.";
    };

    toggleShortcut = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "ALT + SHIFT + G";
      description = "Hyprland shortcut to toggle Oura Ring gesture navigation (`null` to disable).";
    };
  };

  config = lib.mkIf (cfg.enable && oCfg.enable && daemonPkg != null) {
    home.packages = [ daemonPkg ];

    systemd.user.services.ourad = {
      Unit = {
        Description = "Omarchnix Oura Ring BLE & Gesture Daemon (ourad)";
        After = [
          "graphical-session.target"
          "bluetooth.target"
        ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = lib.escapeShellArgs daemonArgs;
        Environment = [
          "PATH=${
            lib.makeBinPath (
              [
                pkgs.coreutils
                pkgs.hyprland
              ]
              ++ lib.optional (cfg.shell.package != null) cfg.shell.package
            )
          }:/run/current-system/sw/bin"
        ];
        Restart = "on-failure";
        RestartSec = 4;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    programs.omarchnix.plugins.locked."omarchnix.oura" = lib.mkIf (pluginPkg != null) {
      package = pluginPkg;
      enable = true;
      section = oCfg.barSection;
    };

    wayland.windowManager.hyprland.settings.bind = lib.mkIf (oCfg.toggleShortcut != null) (
      lib.mkAfter [
        {
          _args = [
            oCfg.toggleShortcut
            (mkLuaInline ''
              function()
                hl.dispatch(hl.dsp.exec_cmd(${builtins.toJSON "${daemonPkg}/bin/ouractl gestures toggle"}))
              end
            '')
          ];
        }
      ]
    );
  };
}
