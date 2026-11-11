{
  config,
  lib,
  pkgs,
  ...
}:
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
  shellPkg =
    if (cfg.shell.package or null) != null then
      cfg.shell.package
    else if pkgs ? omarchy-shell then
      pkgs.omarchy-shell
    else
      null;
  lockCmd =
    if shellPkg != null then
      "${shellPkg}/bin/omarchy-shell lock lock"
    else
      "${pkgs.hyprlock}/bin/hyprlock";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  systemctl = "${pkgs.systemd}/bin/systemctl";
  dimKbd = cfg.keyboard.backlight.dimOnIdle or true;
  kbdOffCmd =
    if shellPkg != null then
      "${shellPkg}/bin/omarchy-brightness-keyboard off >/dev/null 2>&1 || true"
    else
      "${brightnessctl} -sd '*kbd_backlight*' set 0 >/dev/null 2>&1 || true";
  kbdRestoreCmd =
    if shellPkg != null then
      "${shellPkg}/bin/omarchy-brightness-keyboard restore >/dev/null 2>&1 || true"
    else
      "${brightnessctl} -rd '*kbd_backlight*' >/dev/null 2>&1 || true";
in
{
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "${lockCmd}";
        after_sleep_cmd = "${hyprctl} dispatch 'hl.dsp.dpms(\"on\")'${lib.optionalString dimKbd "; ${kbdRestoreCmd}"}";
        ignore_dbus_inhibit = false;
      };

      listener = [
        {
          timeout = 180;
          on-timeout = "[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ] || { ${brightnessctl} -s set 10%${lib.optionalString dimKbd "; ${kbdOffCmd}"}; }";
          on-resume = "[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ] || { ${brightnessctl} -r${lib.optionalString dimKbd "; ${kbdRestoreCmd}"}; }";
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
