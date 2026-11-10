{ pkgs, ... }:
let
  hyprctl = "${pkgs.hyprland}/bin/hyprctl";
  hyprlock = "${pkgs.hyprlock}/bin/hyprlock";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  pidof = "${pkgs.procps}/bin/pidof";
  loginctl = "${pkgs.systemd}/bin/loginctl";
  systemctl = "${pkgs.systemd}/bin/systemctl";
in
{
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "${pidof} hyprlock || ${hyprlock}";
        before_sleep_cmd = "${loginctl} lock-session";
        after_sleep_cmd = "${hyprctl} dispatch 'hl.dsp.dpms(\"on\")'";
        ignore_dbus_inhibit = false;
      };

      listener = [
        {
          timeout = 180;
          on-timeout = "[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ] || ${brightnessctl} -s set 10%";
          on-resume = "[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ] || ${brightnessctl} -r";
        }
        {
          timeout = 300;
          on-timeout = "[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ] || ${loginctl} lock-session";
        }
        {
          timeout = 360;
          on-timeout = "[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ] || ${hyprctl} dispatch 'hl.dsp.dpms(\"off\")'";
          on-resume = "${hyprctl} dispatch 'hl.dsp.dpms(\"on\")'";
        }
        {
          timeout = 900;
          on-timeout = "[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ] || ${systemctl} suspend";
        }
      ];
    };
  };
}
