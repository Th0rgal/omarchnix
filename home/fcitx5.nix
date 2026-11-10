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

  escapeXCompose = builtins.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ];

  asciiAlphaNum = map (c: {
    char = c;
    sym = c;
  }) (lib.stringToCharacters "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789");

  asciiPunct = [
    {
      char = "!";
      sym = "exclam";
    }
    {
      char = "\"";
      sym = "quotedbl";
    }
    {
      char = "#";
      sym = "numbersign";
    }
    {
      char = "$";
      sym = "dollar";
    }
    {
      char = "%";
      sym = "percent";
    }
    {
      char = "&";
      sym = "ampersand";
    }
    {
      char = "'";
      sym = "apostrophe";
    }
    {
      char = "(";
      sym = "parenleft";
    }
    {
      char = ")";
      sym = "parenright";
    }
    {
      char = "*";
      sym = "asterisk";
    }
    {
      char = "+";
      sym = "plus";
    }
    {
      char = ",";
      sym = "comma";
    }
    {
      char = "-";
      sym = "minus";
    }
    {
      char = ".";
      sym = "period";
    }
    {
      char = "/";
      sym = "slash";
    }
    {
      char = ":";
      sym = "colon";
    }
    {
      char = ";";
      sym = "semicolon";
    }
    {
      char = "<";
      sym = "less";
    }
    {
      char = "=";
      sym = "equal";
    }
    {
      char = ">";
      sym = "greater";
    }
    {
      char = "?";
      sym = "question";
    }
    {
      char = "@";
      sym = "at";
    }
    {
      char = "[";
      sym = "bracketleft";
    }
    {
      char = "\\";
      sym = "backslash";
    }
    {
      char = "]";
      sym = "bracketright";
    }
    {
      char = "^";
      sym = "asciicircum";
    }
    {
      char = "_";
      sym = "underscore";
    }
    {
      char = "`";
      sym = "grave";
    }
    {
      char = "{";
      sym = "braceleft";
    }
    {
      char = "|";
      sym = "bar";
    }
    {
      char = "}";
      sym = "braceright";
    }
    {
      char = "~";
      sym = "asciitilde";
    }
  ];

  keypadSyms =
    (map (d: {
      char = d;
      sym = "KP_${d}";
    }) (lib.stringToCharacters "0123456789"))
    ++ [
      {
        char = "/";
        sym = "KP_Divide";
      }
      {
        char = "*";
        sym = "KP_Multiply";
      }
      {
        char = "-";
        sym = "KP_Subtract";
      }
      {
        char = "+";
        sym = "KP_Add";
      }
      {
        char = ".";
        sym = "KP_Decimal";
      }
    ];

  deadKeySpecs = [
    {
      dead = "dead_tilde";
      ascii = "~";
      accents = {
        a = "ã";
        A = "Ã";
        n = "ñ";
        N = "Ñ";
        o = "õ";
        O = "Õ";
      };
    }
    {
      dead = "dead_grave";
      ascii = "`";
      accents = {
        a = "à";
        A = "À";
        e = "è";
        E = "È";
        i = "ì";
        I = "Ì";
        o = "ò";
        O = "Ò";
        u = "ù";
        U = "Ù";
      };
    }
    {
      dead = "dead_acute";
      ascii = "'";
      accents = {
        a = "á";
        A = "Á";
        e = "é";
        E = "É";
        i = "í";
        I = "Í";
        o = "ó";
        O = "Ó";
        u = "ú";
        U = "Ú";
        y = "ý";
        Y = "Ý";
        c = "ç";
        C = "Ç";
      };
    }
    {
      dead = "dead_diaeresis";
      ascii = "\"";
      accents = {
        a = "ä";
        A = "Ä";
        e = "ë";
        E = "Ë";
        i = "ï";
        I = "Ï";
        o = "ö";
        O = "Ö";
        u = "ü";
        U = "Ü";
        y = "ÿ";
        Y = "Ÿ";
      };
    }
    {
      dead = "dead_circumflex";
      ascii = "^";
      accents = {
        a = "â";
        A = "Â";
        e = "ê";
        E = "Ê";
        i = "î";
        I = "Î";
        o = "ô";
        O = "Ô";
        u = "û";
        U = "Û";
      };
    }
  ];

  allSecondKeys =
    asciiAlphaNum
    ++ asciiPunct
    ++ keypadSyms
    ++ (map (s: {
      char = s.ascii;
      sym = s.dead;
    }) deadKeySpecs);

  macosUsIntlXCompose = pkgs.writeText "omarchnix-macos-us-intl-XCompose" (
    "# macOS \"U.S. International - PC\" dead-key compose table (managed by omarchnix)\n"
    + lib.concatMapStrings (
      spec:
      "\n# ${spec.dead} (${spec.ascii})\n"
      + "<${spec.dead}> <space> : \"${escapeXCompose spec.ascii}\"\n"
      + lib.concatMapStrings (
        k:
        let
          out = spec.accents.${k.sym} or "${spec.ascii}${k.char}";
        in
        "<${spec.dead}> <${k.sym}> : \"${escapeXCompose out}\"\n"
      ) allSecondKeys
    ) deadKeySpecs
  );

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

  waylandImConf = pkgs.writeText "omarchnix-fcitx5-waylandim.conf" ''
    DetectApplication=True
    PreferKeyEvent=True
    PersistentVirtualKeyboard=True
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
        Wayland apps and commit unambiguous sequences automatically like macOS `U.S. International - PC`.
      '';
    };

    macosUsIntlCompose = lib.mkOption {
      type = lib.types.bool;
      default = cfg.keyboard.layout == "us" && cfg.keyboard.variant == "intl";
      defaultText = lib.literalExpression ''config.programs.omarchnix.keyboard.layout == "us" && config.programs.omarchnix.keyboard.variant == "intl"'';
      description = ''
        Provision `~/.XCompose` with the exact macOS `U.S. International - PC` dead-key rules
        so unambiguous pairs (`~/`, `~e`, `'s`, `'t`, `'c` -> `ç`, `"hello"`, `` `ls ``, `^1`)
        commit immediately without pressing `Space`.
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

    home.file.".XCompose" = lib.mkIf cfg.ime.macosUsIntlCompose {
      source = macosUsIntlXCompose;
    };

    home.activation.omarchnixFcitx5 = hmLib.entryAfter [ "writeBoundary" ] ''
      fcitx_dir="$HOME/.config/fcitx5"
      mkdir -p "$fcitx_dir/conf"
      cp --remove-destination --no-preserve=mode "${profileText}" "$fcitx_dir/profile"
      cp --remove-destination --no-preserve=mode "${configText}" "$fcitx_dir/config"
      cp --remove-destination --no-preserve=mode "${xkbPassthroughConf}" "$fcitx_dir/conf/wayland.conf"
      cp --remove-destination --no-preserve=mode "${xkbPassthroughConf}" "$fcitx_dir/conf/xcb.conf"
      cp --remove-destination --no-preserve=mode "${waylandImConf}" "$fcitx_dir/conf/waylandim.conf"
      cp --remove-destination --no-preserve=mode "${keyboardConf}" "$fcitx_dir/conf/keyboard.conf"
      chmod 0644 \
        "$fcitx_dir/profile" \
        "$fcitx_dir/config" \
        "$fcitx_dir/conf/wayland.conf" \
        "$fcitx_dir/conf/xcb.conf" \
        "$fcitx_dir/conf/waylandim.conf" \
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
