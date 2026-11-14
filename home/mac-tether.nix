{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omarchnix;
  tCfg = cfg.macTether;

  omarchyLib = import ../lib/omarchy.nix { inherit lib; };

  buildPlugin =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? buildPlugin) then
      pkgs.omarchnix.buildPlugin
    else
      (args: omarchyLib.buildPlugin ({ inherit pkgs; } // args));

  defaultMacMeshPlugin =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? plugins) && (pkgs.omarchnix.plugins ? mac-mesh) then
      pkgs.omarchnix.plugins.mac-mesh
    else if buildPlugin != null then
      buildPlugin {
        src = ../pkgs/plugins/omarchnix-mac-mesh;
        postInstall = ''
          substituteInPlace "$out/Service.qml" \
            --replace-fail "@MAC_MESHCTL_BIN@" "/run/current-system/sw/bin/mac-meshctl" \
            --replace-fail "@XDG_OPEN_BIN@" "${pkgs.xdg-utils}/bin/xdg-open"
        '';
      }
    else
      null;

  pluginPkg = if tCfg.package != null then tCfg.package else defaultMacMeshPlugin;

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
in
{
  options.programs.omarchnix.macTether = {
    enable = lib.mkEnableOption "Omarchy Shell status-bar indicator and approval panel (`omarchnix.mac-mesh`) for the sovereign MacBook tether mesh";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      defaultText = lib.literalExpression "pkgs.omarchnix.plugins.mac-mesh";
      description = "Package providing the `omarchnix.mac-mesh` Quickshell plugin.";
    };

    barSection = lib.mkOption {
      type = barSectionType;
      default = "right";
      description = "Status-bar section where the `omarchnix.mac-mesh` widget is placed.";
    };
  };

  config = lib.mkIf (cfg.enable && tCfg.enable && pluginPkg != null) {
    programs.omarchnix.plugins.locked."omarchnix.mac-mesh" = {
      package = pluginPkg;
      enable = true;
      section = tCfg.barSection;
    };
  };
}
