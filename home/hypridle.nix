{ config, pkgs, ... }:
let
  cfg = config.programs.omarchnix;
  hyprctl = "${pkgs.hyprland}/bin/hyprctl";
  # hyprlock 0.9.x exits on this host as soon as its PAM conversation runs,
  # which leaves Hyprland's "lockscreen app died" banner over the whole
  # session. The omarchy-shell lock service owns the ext-session-lock surface
  # in a long-lived process and recovers stranded locks, so use it instead.
  # Its idle service already locks the screen, so hypridle must not send a
  # second lock request: two requesters kept re-locking the session a few
  # seconds after every unlock and prompted for the password each time.
  shellPkg = if (cfg.shell.package or null) != null then cfg.shell.package else pkgs.omarchy-shell;
  lockCmd = "${shellPkg}/bin/omarchy-shell lock lock";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  systemctl = "${pkgs.systemd}/bin/systemctl";
in
{
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "${lockCmd}";
        after_sleep_cmd = "${hyprctl} dispatch dpms on";
        ignore_dbus_inhibit = false;
      };

      listener = [
        {
          timeout = 180;
          on-timeout = "${brightnessctl} -s set 10%";
          on-resume = "${brightnessctl} -r";
        }
        {
          timeout = 360;
          on-timeout = "${hyprctl} dispatch dpms off";
          on-resume = "${hyprctl} dispatch dpms on";
        }
        {
          timeout = 900;
          on-timeout = "${systemctl} suspend";
        }
      ];
    };
  };
}
