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
  jq = "${pkgs.jq}/bin/jq";
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
  # Wake every enabled display except one explicitly dimmed to 0% (`omarchy-brightness-zero`),
  # so external monitors still power off at 360s idle and wake on seat activity while a
  # manually 0%-blanked built-in panel stays dark until Brightness Up / Power wakes it.
  dpmsResumeCmd = pkgs.writeShellScript "omarchnix-hypridle-dpms-resume" ''
    zero_file="''${XDG_RUNTIME_DIR:-/tmp}/omarchy-brightness-zero"
    if [ -f "$zero_file" ]; then
      zero_mon="$(cat "$zero_file" 2>/dev/null || true)"
      if [ -n "$zero_mon" ]; then
        for mon in $(${hyprctl} monitors -j 2>/dev/null | ${jq} -r --arg z "$zero_mon" '.[] | select(.disabled == false and .name != $z) | .name'); do
          ${hyprctl} dispatch "hl.dsp.dpms({ action = \"enable\", monitor = \"$mon\" })" >/dev/null 2>&1 || true
        done
      fi
      exit 0
    fi
    ${hyprctl} dispatch 'hl.dsp.dpms("on")' >/dev/null 2>&1 || true
  '';
in
{
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "${lockCmd}";
        before_sleep_cmd = "${lockCmd}";
        after_sleep_cmd = "${
          if shellPkg != null then
            "${shellPkg}/bin/omarchy-brightness-display on >/dev/null 2>&1 || ${hyprctl} dispatch 'hl.dsp.dpms(\"on\")'"
          else
            "${hyprctl} dispatch 'hl.dsp.dpms(\"on\")'"
        }${lib.optionalString dimKbd "; ${kbdRestoreCmd}"}${
          lib.optionalString (
            shellPkg != null
          ) "; ${shellPkg}/bin/omarchy-shell lock resume >/dev/null 2>&1 || true"
        }";
        ignore_dbus_inhibit = false;
      };

      listener = [
        {
          timeout = 180;
          on-timeout = "[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ] || { { [ -f \"\${XDG_RUNTIME_DIR:-/tmp}/omarchy-brightness-zero\" ] || ${brightnessctl} -s set 10%; }${lib.optionalString dimKbd "; ${kbdOffCmd}"}; }";
          on-resume = "[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ] || { { [ -f \"\${XDG_RUNTIME_DIR:-/tmp}/omarchy-brightness-zero\" ] || ${brightnessctl} -r; }${lib.optionalString dimKbd "; ${kbdRestoreCmd}"}; }";
        }
        {
          timeout = 360;
          on-timeout = "[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ] || ${hyprctl} dispatch 'hl.dsp.dpms(\"off\")'";
          on-resume = "${dpmsResumeCmd}";
        }
        {
          timeout = 900;
          on-timeout = "[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ] || ${systemctl} suspend";
        }
      ];
    };
  };
}
