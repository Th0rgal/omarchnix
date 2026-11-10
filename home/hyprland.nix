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
  flock = "${pkgs.util-linux}/bin/flock";
  grim = "${pkgs.grim}/bin/grim";
  slurp = "${pkgs.slurp}/bin/slurp";
  wlCopy = "${pkgs.wl-clipboard}/bin/wl-copy";
  regionScreenshot = pkgs.writeShellScript "omarchnix-region-screenshot" ''
    lockfile="''${XDG_RUNTIME_DIR:-/tmp}/omarchnix-screenshot.lock"
    exec 9>"$lockfile"
    ${flock} -n 9 || exit 0
    region="$(${slurp} 9>&-)" || exit 0
    exec 9>&-
    [ -n "$region" ] || exit 0
    ${grim} -g "$region" - | ${wlCopy} --type image/png
  '';
  omarchnixCli = if cfg.cliPackage != null then "${cfg.cliPackage}/bin/omarchnix" else "omarchnix";
  omarchyShellBin = if cfg.shell.package != null then "${cfg.shell.package}/bin" else "";
  themePickerCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-shell shell summon omarchy.image-picker '{\"source\":\"themes\"}'"
    else
      "choice=\"$(${omarchnixCli} theme list | ${fuzzel} --dmenu -p 'Theme: ')\"; [ -n \"$choice\" ] && ${omarchnixCli} theme set \"$choice\"";
  clipboardCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-shell shell toggle omarchy.clipboard"
    else
      "${omarchnixCli} status";
  idleToggleCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-shell idle toggle"
    else
      "mkdir -p \"$HOME/.local/state/omarchy/indicators\"; if [ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ]; then rm -f \"$HOME/.local/state/omarchy/indicators/stay-awake\"; else touch \"$HOME/.local/state/omarchy/indicators/stay-awake\"; fi";

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

  mkSendShortcutOnce = mods: key: ''
    function()
      hl.dispatch(hl.dsp.send_key_state({ mods = ${builtins.toJSON mods}, key = ${builtins.toJSON key}, state = "down" }))
      hl.timer(function()
        hl.dispatch(hl.dsp.send_key_state({ mods = ${builtins.toJSON mods}, key = ${builtins.toJSON key}, state = "up" }))
      end, { timeout = 50, type = "oneshot" })
    end
  '';

  mkUniversalClipboardBind = defaultMods: defaultKey: terminalMods: terminalKey: ''
    function()
      local w = hl.get_active_window()
      local is_term = false
      if w then
        for _, tag in ipairs(w.tags or {}) do
          if tag:gsub("%*$", "") == "terminal" then
            is_term = true
            break
          end
        end
        if not is_term then
          local cls = (w.class or w.initial_class or ""):lower()
          if cls:match("^(foot|foot%-scratchpad|alacritty|kitty|wezterm|.*ghostty.*|org%.omarchy%..*|tui%..*)$") then
            is_term = true
          end
        end
      end
      local mods = is_term and ${builtins.toJSON terminalMods} or ${builtins.toJSON defaultMods}
      local key = is_term and ${builtins.toJSON terminalKey} or ${builtins.toJSON defaultKey}
      hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
      hl.timer(function()
        hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
      end, { timeout = 50, type = "oneshot" })
    end
  '';

  workspaceIndices = lib.range 1 10;

  workspaceBinds = lib.concatMap (
    ws:
    let
      code = "code:${toString (ws + 9)}";
    in
    [
      (mkBind "CTRL + ${code}" "hl.dsp.focus({ workspace = ${toString ws} })")
      (mkBind "CTRL + SHIFT + ${code}" "hl.dsp.window.move({ workspace = ${toString ws} })")
      (mkBind "CTRL + SUPER + ${code}" ''hl.dsp.window.move({ workspace = "${toString ws} silent" })'')
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
            natural_scroll = cfg.touchpad.naturalScroll;
            scroll_factor = cfg.touchpad.scrollFactor;
            tap_to_click = true;
            tap_and_drag = true;
            disable_while_typing = true;
            clickfinger_behavior = true;
          };
        };

        gestures = {
          workspace_swipe_distance = 180;
          workspace_swipe_cancel_ratio = 0.15;
          workspace_swipe_min_speed_to_force = 5;
          workspace_swipe_direction_lock = true;
          workspace_swipe_direction_lock_threshold = 10;
          workspace_swipe_forever = true;
          workspace_swipe_invert = false;
          workspace_swipe_create_new = true;
        };

        misc = {
          disable_hyprland_logo = true;
          disable_splash_rendering = true;
          force_default_wallpaper = 0;
          font_family = theme.fonts.sans.name;
          background_color = "rgba(${theme.colors.bg}ff)";
          focus_on_activate = true;
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
          name = "terminal-tag";
          match = {
            class = "^(Alacritty|kitty|com\\.mitchellh\\.ghostty|foot|foot-scratchpad|org\\.codeberg\\.dnkl\\.foot|wezterm|org\\.omarchy\\..*|TUI\\..*)$";
          };
          tag = "+terminal";
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
        {
          name = "selection-layer";
          match = {
            namespace = "^selection$";
          };
          no_anim = true;
          animation = "none";
        }
      ];

      bind = [
        (mkBind "SUPER + Return" "hl.dsp.exec_cmd(terminal)")
        (mkBind "CTRL + SUPER + O" ''hl.dsp.exec_cmd("${orb}")'')
        (mkBind "SUPER + SPACE" "hl.dsp.exec_cmd(launcher)")
        (mkBind "CTRL + SUPER + SPACE" "hl.dsp.exec_cmd(launcher)")
        (mkBind "SUPER + ALT + SPACE" "hl.dsp.exec_cmd(launcher)")
        (mkBind "SUPER + Q" "hl.dsp.window.close()")
        (mkBind "SUPER + W" "hl.dsp.window.close()")
        (mkBind "SUPER + SHIFT + Q" "hl.dsp.window.kill()")

        # macOS-style universal Copy / Paste / Cut / Select All / Undo / Redo
        (mkBind "SUPER + C" (mkUniversalClipboardBind "CTRL" "C" "CTRL SHIFT" "C"))
        (mkBind "SUPER + V" (mkUniversalClipboardBind "CTRL" "V" "CTRL SHIFT" "V"))
        (mkBind "SUPER + X" (mkSendShortcutOnce "CTRL" "X"))
        (mkBind "SUPER + A" (mkSendShortcutOnce "CTRL" "A"))
        (mkBind "SUPER + Z" (mkSendShortcutOnce "CTRL" "Z"))
        (mkBind "SUPER + SHIFT + Z" (mkSendShortcutOnce "CTRL SHIFT" "Z"))

        # Window management uses CTRL + SUPER (Ctrl + Cmd) so bare Cmd+<letter> stays free for apps
        (mkBind "CTRL + SUPER + SHIFT + F" ''hl.dsp.window.float({ action = "toggle" })'')
        (mkBind "SUPER + ALT + V" ''hl.dsp.window.float({ action = "toggle" })'')
        (mkBind "CTRL + SUPER + F" ''hl.dsp.window.fullscreen({ mode = "fullscreen" })'')
        (mkBind "SUPER + M" ''hl.dsp.window.fullscreen({ mode = "maximized" })'')
        (mkBind "CTRL + SUPER + M" ''hl.dsp.window.fullscreen({ mode = "maximized" })'')
        (mkBind "CTRL + SUPER + P" "hl.dsp.window.pseudo()")
        (mkBind "CTRL + SUPER + E" ''hl.dsp.layout("togglesplit")'')
        (mkBind "SUPER + ESCAPE" "hl.dsp.exec_cmd(${builtins.toJSON shellLock})")
        (mkBind "CTRL + ALT + SUPER + Q" "hl.dsp.exit()")
        (mkBind "CTRL + SUPER + R" "hl.dsp.reload_config()")

        (mkBind "CTRL + SUPER + left" ''hl.dsp.focus({ direction = "left" })'')
        (mkBind "CTRL + SUPER + right" ''hl.dsp.focus({ direction = "right" })'')
        (mkBind "CTRL + SUPER + up" ''hl.dsp.focus({ direction = "up" })'')
        (mkBind "CTRL + SUPER + down" ''hl.dsp.focus({ direction = "down" })'')
        (mkBind "CTRL + SUPER + H" ''hl.dsp.focus({ direction = "left" })'')
        (mkBind "CTRL + SUPER + L" ''hl.dsp.focus({ direction = "right" })'')
        (mkBind "CTRL + SUPER + K" ''hl.dsp.focus({ direction = "up" })'')
        (mkBind "CTRL + SUPER + J" ''hl.dsp.focus({ direction = "down" })'')

        (mkBind "CTRL + SUPER + SHIFT + left" ''hl.dsp.window.move({ direction = "left" })'')
        (mkBind "CTRL + SUPER + SHIFT + right" ''hl.dsp.window.move({ direction = "right" })'')
        (mkBind "CTRL + SUPER + SHIFT + up" ''hl.dsp.window.move({ direction = "up" })'')
        (mkBind "CTRL + SUPER + SHIFT + down" ''hl.dsp.window.move({ direction = "down" })'')
        (mkBind "CTRL + SUPER + SHIFT + H" ''hl.dsp.window.move({ direction = "left" })'')
        (mkBind "CTRL + SUPER + SHIFT + L" ''hl.dsp.window.move({ direction = "right" })'')
        (mkBind "CTRL + SUPER + SHIFT + K" ''hl.dsp.window.move({ direction = "up" })'')
        (mkBind "CTRL + SUPER + SHIFT + J" ''hl.dsp.window.move({ direction = "down" })'')

        (mkBind "SUPER + grave" ''hl.dsp.workspace.toggle_special("scratchpad")'')
        (mkBind "CTRL + SUPER + S" ''hl.dsp.workspace.toggle_special("scratchpad")'')
        (mkBind "SUPER + SHIFT + grave" ''hl.dsp.window.move({ workspace = "special:scratchpad" })'')
        (mkBind "CTRL + SUPER + SHIFT + S" ''hl.dsp.window.move({ workspace = "special:scratchpad" })'')
        (mkBind "CTRL + SUPER + SHIFT + P" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "CTRL + SUPER + SHIFT + code:13" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "SUPER + SHIFT + code:13" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "SUPER + SHIFT + V" "hl.dsp.exec_cmd(${builtins.toJSON clipboardCmd})")
        (mkBind "SUPER + CTRL + V" "hl.dsp.exec_cmd(${builtins.toJSON clipboardCmd})")
        (mkBind "SUPER + SHIFT + I" "hl.dsp.exec_cmd(${builtins.toJSON idleToggleCmd})")
        (mkBind "CTRL + SUPER + SHIFT + T" "hl.dsp.exec_cmd(${builtins.toJSON themePickerCmd})")
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
