{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omarchnix;
  hmLib = config.lib.dag;
  fcitx5Pkg = pkgs.qt6Packages.fcitx5-with-addons;
  groupLayout =
    if cfg.keyboard.variant != "" then
      "${cfg.keyboard.layout}-${cfg.keyboard.variant}"
    else
      cfg.keyboard.layout;

  profileText = pkgs.writeText "omarchnix-fcitx5-profile" ''
    [Groups/0]
    Name=Default
    Default Layout=${groupLayout}
    DefaultIM=keyboard-${groupLayout}

    [Groups/0/Items/0]
    Name=keyboard-${groupLayout}
    Layout=

    [GroupOrder]
    0=Default
  '';

  configText = pkgs.writeText "omarchnix-fcitx5-config" ''
    # Leave Ctrl+Space to shells/tmux and Super keys to Hyprland/Omarchy.
    [Hotkey/TriggerKeys]
    0=Zenkaku_Hankaku
    1=Hangul

    [Hotkey/ActivateKeys]
    0=Henkan

    [Hotkey/DeactivateKeys]
    0=Muhenkan

    [Hotkey/AltTriggerKeys]

    [Hotkey/EnumerateGroupForwardKeys]

    [Hotkey/EnumerateGroupBackwardKeys]

    [Behavior]
    ActiveByDefault=False
    PreeditEnabledByDefault=True
    ShowInputMethodInformation=False
    ShowFirstInputMethodInformation=False
    showInputMethodInformationWhenFocusIn=False
  '';

  xkbPassthroughConf = pkgs.writeText "omarchnix-fcitx5-xkb.conf" ''
    Allow Overriding System XKB Settings=False
  '';

  keyboardConf = pkgs.writeText "omarchnix-fcitx5-keyboard.conf" ''
    EnableEmoji=False
    EnableQuickPhraseEmoji=False
    EnableHintByDefault=False
    UseNewComposeBehavior=True
    EnableLongPress=False
  '';
in
{
  options.programs.omarchnix.ime = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable Fcitx5 Wayland input method (`zwp_input_method_v2` / `zwp_text_input_v3`)
        so dead keys (`~`, `` ` ``, `'`, `"`, `^`) render underlined preedit in `foot` and
        Wayland apps and commit unmatched sequences like macOS `U.S. International - PC`.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.ime.enable) {
    home.packages = [ fcitx5Pkg ];

    home.sessionVariables = {
      XMODIFIERS = lib.mkDefault "@im=fcitx";
      SDL_IM_MODULE = lib.mkDefault "fcitx";
    };

    gtk = {
      gtk3.extraConfig.gtk-im-module = lib.mkDefault "fcitx";
      gtk4.extraConfig.gtk-im-module = lib.mkDefault "fcitx";
    };

    home.activation.omarchnixFcitx5 = hmLib.entryAfter [ "writeBoundary" ] ''
      fcitx_dir="$HOME/.config/fcitx5"
      mkdir -p "$fcitx_dir/conf"
      cp --remove-destination --no-preserve=mode "${profileText}" "$fcitx_dir/profile"
      cp --remove-destination --no-preserve=mode "${configText}" "$fcitx_dir/config"
      cp --remove-destination --no-preserve=mode "${xkbPassthroughConf}" "$fcitx_dir/conf/wayland.conf"
      cp --remove-destination --no-preserve=mode "${xkbPassthroughConf}" "$fcitx_dir/conf/xcb.conf"
      cp --remove-destination --no-preserve=mode "${keyboardConf}" "$fcitx_dir/conf/keyboard.conf"
      chmod 0644 \
        "$fcitx_dir/profile" \
        "$fcitx_dir/config" \
        "$fcitx_dir/conf/wayland.conf" \
        "$fcitx_dir/conf/xcb.conf" \
        "$fcitx_dir/conf/keyboard.conf"
    '';

    systemd.user.services.omarchy-fcitx5 = {
      Unit = {
        Description = "Fcitx5 input method and dead-key compose preedit";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        Type = "dbus";
        BusName = "org.fcitx.Fcitx5";
        ExecStart = "${fcitx5Pkg}/bin/fcitx5 --replace --disable notificationitem";
        Restart = "always";
        RestartSec = 2;
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
