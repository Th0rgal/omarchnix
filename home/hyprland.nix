{
  config,
  lib,
  pkgs,
  theme,
  ...
}:
let
  cfg = config.programs.omarchnix;
  inherit (lib.generators) mkLuaInline;

  foot = "${pkgs.foot}/bin/foot";
  fuzzel = "${pkgs.fuzzel}/bin/fuzzel";
  orb = if pkgs ? orb-desktop then "${pkgs.orb-desktop}/bin/orb" else "orb";
  shellLock =
    if cfg.shell.package != null then
      "${cfg.shell.package}/bin/omarchy-shell lock lock"
    else
      "omarchy-shell lock lock";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  playerctl = "${pkgs.playerctl}/bin/playerctl";
  wpctl = "${pkgs.wireplumber}/bin/wpctl";
  grim = "${pkgs.grim}/bin/grim";
  slurp = "${pkgs.slurp}/bin/slurp";
  wlCopy = "${pkgs.wl-clipboard}/bin/wl-copy";
  omarchnixCli = if cfg.cliPackage != null then "${cfg.cliPackage}/bin/omarchnix" else "omarchnix";
  omarchyShellBin = if cfg.shell.package != null then "${cfg.shell.package}/bin" else "";
  themePickerCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-shell shell summon omarchy.image-picker '{\"source\":\"themes\"}'"
    else
      "choice=\"$(${omarchnixCli} theme list | ${fuzzel} --dmenu -p 'Theme: ')\"; [ -n \"$choice\" ] && ${omarchnixCli} theme set \"$choice\"";

  mkBind = keys: dsp: {
    _args = [
      keys
      (mkLuaInline dsp)
    ];
  };

  mkBindOpts = keys: dsp: opts: {
    _args = [
      keys
      (mkLuaInline dsp)
      opts
    ];
  };

  workspaceIndices = lib.range 1 10;

  workspaceBinds = lib.concatMap (
    ws:
    let
      code = "code:${toString (ws + 9)}";
    in
    [
      (mkBind "SUPER + ${code}" "hl.dsp.focus({ workspace = ${toString ws} })")
      (mkBind "SUPER + SHIFT + ${code}" "hl.dsp.window.move({ workspace = ${toString ws} })")
      (mkBind "SUPER + CTRL + ${code}" ''hl.dsp.window.move({ workspace = "${toString ws} silent" })'')
    ]
  ) workspaceIndices;
in
{
  wayland.windowManager.hyprland = {
    enable = true;
    package = null;
    portalPackage = null;
    configType = "lua";
    # UWSM (programs.hyprland.withUWSM) already owns graphical-session.target.
    # Home Manager's hyprland-session.target also BindsTo+PropagatesStopTo that
    # target, so the first startup exec that stops it tears the compositor down.
    systemd.enable = false;
    xwayland.enable = true;
    extraConfig = "";

    settings = {
      mod = {
        _var = "SUPER";
      };

      terminal = {
        _var = foot;
      };

      launcher = {
        _var = fuzzel;
      };

      monitor = [
        # Never pin an absolute panel timing here: appledrm only advertises the
        # modes the DCP reports (Linux Asahi 7.2.15 exposes 2560x1600 on J413,
        # not the 2560x1664 native panel geometry). Asking for a mode that does
        # not exist makes the atomic TEST_ONLY commit fail with EINVAL and forces
        # a live re-modeset while a page-flip is pending, which surfaces as
        # "Cannot commit when a page-flip is awaiting" and kills the session.
        {
          output = "eDP-1";
          mode = "preferred";
          position = "0x0";
          scale = "1.6";
        }
        {
          output = "";
          mode = "preferred";
          position = "auto";
          scale = "auto";
        }
      ];

      env = [
        {
          _args = [
            "XCURSOR_THEME"
            theme.cursor.name
          ];
        }
        {
          _args = [
            "XCURSOR_SIZE"
            (toString theme.cursor.size)
          ];
        }
        {
          _args = [
            "HYPRCURSOR_SIZE"
            (toString theme.cursor.size)
          ];
        }
      ];

      config = {
        xwayland = {
          force_zero_scaling = true;
        };

        general = {
          gaps_in = theme.ui.gapsIn;
          gaps_out = theme.ui.gapsOut;
          border_size = theme.ui.borderSize;
          layout = "dwindle";
          resize_on_border = true;
          allow_tearing = false;
          col = {
            active_border = {
              colors = [
                "rgba(${theme.colors.accent}ee)"
                "rgba(${theme.colors.accentAlt}ee)"
              ];
              angle = 45;
            };
            inactive_border = "rgba(${theme.colors.border}aa)";
          };
        };

        decoration = {
          rounding = theme.ui.rounding;
          rounding_power = 2;
          active_opacity = 1.0;
          inactive_opacity = 0.96;
          dim_special = 0.25;
          shadow = {
            enabled = true;
            range = 12;
            render_power = 3;
            color = "rgba(00000066)";
          };
          blur = {
            enabled = true;
            size = 8;
            passes = 3;
            new_optimizations = true;
            xray = false;
            ignore_opacity = true;
            contrast = 1.0;
            brightness = 0.85;
            noise = 0.01;
            vibrancy = 0.35;
            vibrancy_darkness = 0.2;
            popups = true;
            popups_ignorealpha = 0.2;
            special = true;
          };
        };

        animations = {
          enabled = true;
        };

        dwindle = {
          preserve_split = true;
        };

        input = {
          kb_layout = cfg.keyboard.layout;
          kb_variant = cfg.keyboard.variant;
          follow_mouse = 1;
          sensitivity = 0;
          touchpad = {
            natural_scroll = true;
            tap_to_click = true;
            tap_and_drag = true;
            disable_while_typing = true;
            clickfinger_behavior = true;
          };
        };

        gestures = {
          workspace_swipe_distance = 300;
          workspace_swipe_invert = false;
          workspace_swipe_create_new = true;
        };

        misc = {
          disable_hyprland_logo = true;
          disable_splash_rendering = true;
          force_default_wallpaper = 0;
          font_family = theme.fonts.sans.name;
          background_color = "rgba(${theme.colors.bg}ff)";
          key_press_enables_dpms = true;
          mouse_move_enables_dpms = true;
        };

        binds = {
          hide_special_on_workspace_change = true;
        };
      };

      curve = [
        {
          _args = [
            "easeOutQuint"
            {
              type = "bezier";
              points = [
                [
                  0.23
                  1
                ]
                [
                  0.32
                  1
                ]
              ];
            }
          ];
        }
        {
          _args = [
            "almostLinear"
            {
              type = "bezier";
              points = [
                [
                  0.5
                  0.5
                ]
                [
                  0.75
                  1
                ]
              ];
            }
          ];
        }
      ];

      animation = [
        {
          leaf = "global";
          enabled = true;
          speed = 6;
          bezier = "easeOutQuint";
        }
        {
          leaf = "windows";
          enabled = true;
          speed = 4;
          bezier = "easeOutQuint";
          style = "popin 88%";
        }
        {
          leaf = "fade";
          enabled = true;
          speed = 3;
          bezier = "almostLinear";
        }
        {
          leaf = "layers";
          enabled = true;
          speed = 3;
          bezier = "easeOutQuint";
          style = "fade";
        }
        {
          leaf = "workspaces";
          enabled = true;
          speed = 3;
          bezier = "easeOutQuint";
          style = "slide";
        }
      ];

      gesture = [
        {
          fingers = 3;
          direction = "horizontal";
          action = "workspace";
        }
        {
          fingers = 4;
          direction = "right";
          action = mkLuaInline ''function() hl.dispatch(hl.dsp.window.move({ workspace = "r-1" })) end'';
        }
        {
          fingers = 4;
          direction = "left";
          action = mkLuaInline ''function() hl.dispatch(hl.dsp.window.move({ workspace = "r+1" })) end'';
        }
      ];

      workspace_rule = [
        {
          workspace = "special:scratchpad";
          on_created_empty = "${foot} --app-id=foot-scratchpad";
        }
      ];

      window_rule = [
        {
          name = "suppress-maximize-events";
          match = {
            class = ".*";
          };
          suppress_event = "maximize";
        }
        {
          name = "scratchpad-terminal";
          match = {
            class = "^foot-scratchpad$";
          };
          float = true;
          size = "75% 70%";
          center = true;
          opacity = 0.94;
        }
        {
          name = "orb-vibrancy";
          match = {
            class = "^(orb-desktop|\\.orb-desktop-unwrapped|orb)$";
          };
          opacity = "0.86 0.86";
          rounding = theme.ui.rounding;
          border_size = theme.ui.borderSize;
        }
        {
          name = "notion-calendar-app";
          match = {
            class = "^(notion-calendar|brave-calendar\\.notion\\.so.*)$";
          };
          opacity = "0.97 0.97";
          rounding = theme.ui.rounding;
        }
      ];

      layer_rule = [
        {
          name = "waybar-layer";
          match = {
            namespace = "^waybar$";
          };
          blur = true;
          ignore_alpha = 0.2;
        }
        {
          name = "omarchy-glass";
          match = {
            namespace = "^(omarchy-bar|omarchy-dock|omarchy-menu|omarchy-notifications|omarchy-osd|omarchy-polkit|omarchy-reminders|omarchy-clipboard|omarchy-emojis|omarchy-image-selector|omarchy-keyboard-panel|omarchy-network-qr|fuzzel)$";
          };
          blur = true;
          ignore_alpha = 0.15;
        }
      ];

      bind = [
        (mkBind "SUPER + Return" "hl.dsp.exec_cmd(terminal)")
        (mkBind "SUPER + O" ''hl.dsp.exec_cmd("${orb}")'')
        (mkBind "SUPER + SPACE" "hl.dsp.exec_cmd(launcher)")
        (mkBind "SUPER + D" "hl.dsp.exec_cmd(launcher)")
        (mkBind "SUPER + Q" "hl.dsp.window.close()")
        (mkBind "SUPER + V" ''hl.dsp.window.float({ action = "toggle" })'')
        (mkBind "SUPER + F" ''hl.dsp.window.fullscreen({ mode = "fullscreen" })'')
        (mkBind "SUPER + M" ''hl.dsp.window.fullscreen({ mode = "maximized" })'')
        (mkBind "SUPER + P" "hl.dsp.window.pseudo()")
        (mkBind "SUPER + E" ''hl.dsp.layout("togglesplit")'')
        (mkBind "SUPER + ESCAPE" "hl.dsp.exec_cmd(${builtins.toJSON shellLock})")
        (mkBind "SUPER + SHIFT + E" "hl.dsp.exit()")
        (mkBind "SUPER + SHIFT + R" "hl.dsp.reload_config()")

        (mkBind "SUPER + left" ''hl.dsp.focus({ direction = "left" })'')
        (mkBind "SUPER + right" ''hl.dsp.focus({ direction = "right" })'')
        (mkBind "SUPER + up" ''hl.dsp.focus({ direction = "up" })'')
        (mkBind "SUPER + down" ''hl.dsp.focus({ direction = "down" })'')
        (mkBind "SUPER + H" ''hl.dsp.focus({ direction = "left" })'')
        (mkBind "SUPER + L" ''hl.dsp.focus({ direction = "right" })'')
        (mkBind "SUPER + K" ''hl.dsp.focus({ direction = "up" })'')
        (mkBind "SUPER + J" ''hl.dsp.focus({ direction = "down" })'')

        (mkBind "SUPER + SHIFT + left" ''hl.dsp.window.move({ direction = "left" })'')
        (mkBind "SUPER + SHIFT + right" ''hl.dsp.window.move({ direction = "right" })'')
        (mkBind "SUPER + SHIFT + up" ''hl.dsp.window.move({ direction = "up" })'')
        (mkBind "SUPER + SHIFT + down" ''hl.dsp.window.move({ direction = "down" })'')
        (mkBind "SUPER + SHIFT + H" ''hl.dsp.window.move({ direction = "left" })'')
        (mkBind "SUPER + SHIFT + L" ''hl.dsp.window.move({ direction = "right" })'')
        (mkBind "SUPER + SHIFT + K" ''hl.dsp.window.move({ direction = "up" })'')
        (mkBind "SUPER + SHIFT + J" ''hl.dsp.window.move({ direction = "down" })'')

        (mkBind "SUPER + S" ''hl.dsp.workspace.toggle_special("scratchpad")'')
        (mkBind "SUPER + SHIFT + S" ''hl.dsp.window.move({ workspace = "special:scratchpad" })'')
        (mkBind "SUPER + SHIFT + P" ''hl.dsp.exec_cmd("${grim} -g \"$(${slurp})\" - | ${wlCopy}")'')
        (mkBind "SUPER + SHIFT + T" "hl.dsp.exec_cmd(${builtins.toJSON themePickerCmd})")
        (mkBind "SUPER + CTRL + T" "hl.dsp.exec_cmd(${builtins.toJSON themePickerCmd})")
        (mkBind "SUPER + ALT + T" ''hl.dsp.exec_cmd("${omarchnixCli} theme toggle")'')

        (mkBind "SUPER + mouse_down" ''hl.dsp.focus({ workspace = "e-1" })'')
        (mkBind "SUPER + mouse_up" ''hl.dsp.focus({ workspace = "e+1" })'')
        (mkBind "SUPER + ALT + mouse_down" "hl.dsp.group.prev()")
        (mkBind "SUPER + ALT + mouse_up" "hl.dsp.group.next()")

        (mkBindOpts "SUPER + mouse:272" "hl.dsp.window.drag()" { mouse = true; })
        (mkBindOpts "SUPER + mouse:273" "hl.dsp.window.resize()" { mouse = true; })

        (mkBindOpts "XF86MonBrightnessUp" ''hl.dsp.exec_cmd("${brightnessctl} -e4 -n2 set 5%+")'' {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "XF86MonBrightnessDown" ''hl.dsp.exec_cmd("${brightnessctl} -e4 -n2 set 5%-")'' {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "XF86KbdBrightnessUp"
          ''hl.dsp.exec_cmd("${brightnessctl} -d '*kbd_backlight' set 10%+")''
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBindOpts "XF86KbdBrightnessDown"
          ''hl.dsp.exec_cmd("${brightnessctl} -d '*kbd_backlight' set 10%-")''
          {
            locked = true;
            repeating = true;
          }
        )

        (mkBindOpts "XF86AudioRaiseVolume"
          ''hl.dsp.exec_cmd("${wpctl} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+")''
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBindOpts "XF86AudioLowerVolume"
          ''hl.dsp.exec_cmd("${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%-")''
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBindOpts "XF86AudioMute" ''hl.dsp.exec_cmd("${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle")'' {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "XF86AudioMicMute"
          ''hl.dsp.exec_cmd("${wpctl} set-mute @DEFAULT_AUDIO_SOURCE@ toggle")''
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBindOpts "XF86AudioPlay" ''hl.dsp.exec_cmd("${playerctl} play-pause")'' {
          locked = true;
        })
        (mkBindOpts "XF86AudioPause" ''hl.dsp.exec_cmd("${playerctl} play-pause")'' {
          locked = true;
        })
        (mkBindOpts "XF86AudioNext" ''hl.dsp.exec_cmd("${playerctl} next")'' { locked = true; })
        (mkBindOpts "XF86AudioPrev" ''hl.dsp.exec_cmd("${playerctl} previous")'' {
          locked = true;
        })
      ]
      ++ workspaceBinds;
    };
  };
}
