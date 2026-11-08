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
  hyprlock = "${pkgs.hyprlock}/bin/hyprlock";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  playerctl = "${pkgs.playerctl}/bin/playerctl";
  wpctl = "${pkgs.wireplumber}/bin/wpctl";
  grim = "${pkgs.grim}/bin/grim";
  slurp = "${pkgs.slurp}/bin/slurp";
  wlCopy = "${pkgs.wl-clipboard}/bin/wl-copy";

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
    systemd.enable = true;
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
        {
          output = "eDP-1";
          mode = "2560x1664@60";
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
            size = 6;
            passes = 2;
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
          workspace_swipe_invert = true;
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
      ];

      bind = [
        (mkBind "SUPER + Return" "hl.dsp.exec_cmd(terminal)")
        (mkBind "SUPER + SPACE" "hl.dsp.exec_cmd(launcher)")
        (mkBind "SUPER + D" "hl.dsp.exec_cmd(launcher)")
        (mkBind "SUPER + Q" "hl.dsp.window.close()")
        (mkBind "SUPER + V" ''hl.dsp.window.float({ action = "toggle" })'')
        (mkBind "SUPER + F" ''hl.dsp.window.fullscreen({ mode = "fullscreen" })'')
        (mkBind "SUPER + M" ''hl.dsp.window.fullscreen({ mode = "maximized" })'')
        (mkBind "SUPER + P" "hl.dsp.window.pseudo()")
        (mkBind "SUPER + E" ''hl.dsp.layout("togglesplit")'')
        (mkBind "SUPER + ESCAPE" ''hl.dsp.exec_cmd("${hyprlock}")'')
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

        (mkBind "SUPER + mouse_down" ''hl.dsp.focus({ workspace = "e+1" })'')
        (mkBind "SUPER + mouse_up" ''hl.dsp.focus({ workspace = "e-1" })'')

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
          ''hl.dsp.exec_cmd("${brightnessctl} -d '*::kbd_backlight' set 10%+")''
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBindOpts "XF86KbdBrightnessDown"
          ''hl.dsp.exec_cmd("${brightnessctl} -d '*::kbd_backlight' set 10%-")''
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
