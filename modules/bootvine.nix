# bootvine: a live tree of systemd jobs on the boot console (initrd, stage 2 and
# shutdown; the initrd is always systemd on NixOS >= 26.05) instead of scrolling kernel and unit log lines. It also answers
# passphrase prompts such as the LUKS unlock, so systemd-cryptsetup still caches
# the passphrase in the kernel keyring for `autostartTty.unlockKeyringFromLuks`.
#
# bootvine draws on tty12 and, during boot, pulls the console back whenever another
# VT comes forward unless `display-manager.service` is running. omarchnix has no
# display manager (the session is a unit on a TTY), so that unit is aliased as
# `display-manager.service`; bootvine then waits for it instead of fighting it.
{ bootvineSrc }:
{ config, lib, ... }:
let
  cfg = config.omarchnix.boot.bootvine;
  desktop = config.omarchnix.desktop or { };
  autostart = desktop.autostartTty or { enable = false; };
in
{
  imports = [ "${bootvineSrc}/nix/nixos-module.nix" ];

  options.omarchnix.boot.bootvine = {
    enable = lib.mkEnableOption "bootvine, a live systemd job tree on the boot console";

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Passed to `services.bootvine.settings` (`/etc/bootvine.toml`).";
    };

    sessionUnit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default =
        if (desktop.enable or false) && autostart.enable then "hyprland-${autostart.tty}" else null;
      defaultText = lib.literalExpression ''"hyprland-''${omarchnix.desktop.autostartTty.tty}" when autostartTty is enabled'';
      description = ''
        Service (without `.service`) that owns the graphical session on a TTY. It is
        aliased as `display-manager.service` so bootvine hands the console over to it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.bootvine = {
      enable = true;
      inherit (cfg) settings;
    };

    systemd.services = lib.mkIf (cfg.sessionUnit != null) {
      ${cfg.sessionUnit}.aliases = [ "display-manager.service" ];
    };

    assertions = [
      {
        assertion = cfg.sessionUnit == null || !(config.services.displayManager.enable or false);
        message = "omarchnix.boot.bootvine.sessionUnit aliases display-manager.service; set it to null when a real display manager is enabled.";
      }
    ];
  };
}
