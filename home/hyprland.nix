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
  ghostty = "${pkgs.ghostty}/bin/ghostty";
  defaultTerminal = if (cfg.terminal or "foot") == "ghostty" then ghostty else foot;
  fuzzel = "${pkgs.fuzzel}/bin/fuzzel";
  missionCenter = "${pkgs.mission-center}/bin/missioncenter";
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
  omarchyShellCmd =
    if omarchyShellBin != "" then "${omarchyShellBin}/omarchy-shell" else "omarchy-shell";
  jq = "${pkgs.jq}/bin/jq";
  busctl = "${pkgs.systemd}/bin/busctl";
  gnugrep = "${pkgs.gnugrep}/bin/grep";
  powerKeyCmd = pkgs.writeShellScript "omarchnix-power-key" ''
    set -u
    lockfile="''${XDG_RUNTIME_DIR:-/tmp}/omarchnix-power-key.lock"
    exec 9>"$lockfile"
    ${flock} -n 9 || exit 0

    ${lib.optionalString (cfg.shell.backend == "omarchy-shell") ''
      status_json="$(${omarchyShellCmd} lock status 2>/dev/null || true)"
      if [ -n "$status_json" ]; then
        # When already locked, pressing the Power / Touch ID button wakes the display.
        if printf '%s\n' "$status_json" | ${jq} -e '.locked == true or .requested == true or .sessionLocked == true' >/dev/null 2>&1; then
          ${omarchyShellCmd} lock wake >/dev/null 2>&1 || true
          exit 0
        fi
        # Ignore the release of a firm Touch ID click that just unlocked the session.
        if printf '%s\n' "$status_json" | ${jq} -e '
          .lastEvent == "unlocked"
          and (.lastEventAt | type == "string" and length > 0)
          and ((now - ((.lastEventAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) // 0)) < 2.5)
        ' >/dev/null 2>&1; then
          exit 0
        fi
      fi

      # Do not lock while an in-session Touch ID HUD prompt (sudo / fprintd / FIDO) is open or animating.
      tid_json="$(${omarchyShellCmd} touchid state 2>/dev/null || true)"
      if [ -n "$tid_json" ] && printf '%s\n' "$tid_json" | ${jq} -e '.opened == true or .cardVisible == true' >/dev/null 2>&1; then
        exit 0
      fi
    ''}

    # Do not lock if fprintd is actively waiting for or reading a finger (sudo, polkit, fprintd-verify).
    for dev in /net/reactivated/Fprint/Device/0 /net/reactivated/Fprint/Device/1; do
      fprint_props="$(${busctl} get-property net.reactivated.Fprint "$dev" net.reactivated.Fprint.Device finger-needed finger-present 2>/dev/null || true)"
      if [ -n "$fprint_props" ] && printf '%s\n' "$fprint_props" | ${gnugrep} -q 'b true'; then
        exit 0
      fi
    done

    # Do not lock while the polkit authentication overlay is active.
    hyprctl_bin="$(PATH="/run/current-system/sw/bin:$PATH" command -v hyprctl 2>/dev/null || true)"
    if [ -n "$hyprctl_bin" ] && "$hyprctl_bin" layers -j 2>/dev/null | ${jq} -e '.. | objects | select(.namespace? == "omarchy-polkit")' >/dev/null 2>&1; then
      exit 0
    fi

    exec ${shellLock}
  '';
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
  captureMenuCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-capture-screenrecording --stop-recording || ${omarchyShellBin}/omarchy-menu toggle trigger.capture"
    else
      "${regionScreenshot}";
  kbdStep = toString (cfg.keyboard.backlight.step or 10);
  kbdBacklightUpCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-brightness-keyboard up ${kbdStep}"
    else
      "${brightnessctl} -d '*kbd_backlight*' set ${kbdStep}%+";
  kbdBacklightDownCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-brightness-keyboard down ${kbdStep}"
    else
      "${brightnessctl} -d '*kbd_backlight*' set ${kbdStep}%-";
  kbdBacklightCycleCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-brightness-keyboard cycle ${kbdStep}"
    else
      "${brightnessctl} -d '*kbd_backlight*' set ${kbdStep}%+";

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

  # macOS-style Cmd+W: close the active tab/surface in browsers, code editors, and
  # tabbed terminals (which natively close the window when closing the last tab),
  # ignore Orb so Cmd+W never closes Orb by mistake, and close single-window apps.
  # Option+Shift+Q always closes the whole window.
  smartCloseBind = ''
    function()
      local w = hl.get_active_window()
      if not w then return end
      local cls = (w.class or w.initial_class or ""):lower()
      if cls:match("^(orb%-desktop|%.orb%-desktop%-unwrapped|orb)$") then
        return
      end
      local mods = nil
      if cls:match("^(brave%-browser|chromium|chromium%-browser|google%-chrome.*|firefox.*|librewolf.*|zen.*|vivaldi.*|epiphany|antigravity|code|code%-url%-handler|codium|vscodium|cursor|dev%.zed%.zed|zed|thunar)$") then
        mods = "CTRL"
      elseif cls:match("^(.*ghostty.*|kitty|org%.wezfurlong%.wezterm|wezterm)$") then
        mods = "CTRL SHIFT"
      end
      if mods then
        hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = "W", state = "down" }))
        hl.timer(function()
          hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = "W", state = "up" }))
        end, { timeout = 50, type = "oneshot" })
      else
        hl.dispatch(hl.dsp.window.close())
      end
    end
  '';

  # Float & center active window at 84%x85% of usable workarea so a clean wallpaper
  # frame remains visible around it; pressing again when already centered returns
  # the window to normal WM tiling.
  #
  # Note on Hyprland 0.57+ Lua `hl.dsp.window.resize({ relative = false })`:
  # `Config::Actions::resize` computes `delta = target - w->reportedSize()` (the last
  # committed Wayland buffer size) and adds `delta` to the floating layout goal box
  # (`m_lastFloatingSize`). Never call `resize({ relative = false })` synchronously on
  # the same frame as `float({ action = "enable" })` or repeat it before `w.size`
  # commits, otherwise `delta` is subtracted from `m_lastFloatingSize` repeatedly.
  centerShowcaseBind = ''
    function()
      local w = hl.get_active_window()
      if not w then return end
      local m = w.monitor or hl.get_active_monitor()
      if not m then return end

      local state = rawget(_G, "__omarchnix_showcase")
      if not state or not state.active then
        state = { seq = {}, active = {}, float_ready = {}, committed = {} }
        rawset(_G, "__omarchnix_showcase", state)
      end
      local addr = tostring(w.address or "")

      local function compute_targets(mon)
        local scale = (mon.scale and mon.scale > 0) and mon.scale or 1.0
        local phys_w, phys_h = mon.width, mon.height
        if ((mon.transform or 0) % 2) == 1 then
          phys_w, phys_h = phys_h, phys_w
        end
        local mon_w = math.floor(phys_w / scale + 0.5)
        local mon_h = math.floor(phys_h / scale + 0.5)

        local res = mon.reserved or {}
        local res_l = res.left or 0
        local res_r = res.right or 0
        local res_t = res.top or 0
        local res_b = res.bottom or 0

        local avail_w = mon_w - res_l - res_r
        local avail_h = mon_h - res_t - res_b

        local target_w = math.floor(avail_w * 0.84 + 0.5)
        local target_h = math.floor(avail_h * 0.85 + 0.5)
        local target_x = math.floor(mon.x + res_l + (avail_w - target_w) / 2 + 0.5)
        local target_y = math.floor(mon.y + res_t + (avail_h - target_h) / 2 + 0.5)

        return {
          res_l = res_l,
          res_t = res_t,
          avail_w = avail_w,
          avail_h = avail_h,
          target_w = target_w,
          target_h = target_h,
          target_x = target_x,
          target_y = target_y,
          center_x = mon.x + res_l + avail_w / 2,
          center_y = mon.y + res_t + avail_h / 2,
        }
      end

      local t = compute_targets(m)
      local was_floating = w.floating and (w.fullscreen or 0) == 0

      if was_floating then
        local wx = (w.at and w.at.x) or 0
        local wy = (w.at and w.at.y) or 0
        local ww = (w.size and w.size.x) or 0
        local wh = (w.size and w.size.y) or 0
        local is_centered = math.abs((wx + ww / 2) - t.center_x) <= 36
          and math.abs((wy + wh / 2) - t.center_y) <= 36
        local prev = state.committed[addr]
        local is_showcase_size = (math.abs(ww - t.target_w) <= 40 and math.abs(wh - t.target_h) <= 40)
          or (prev and math.abs(ww - prev.w) <= 16 and math.abs(wh - prev.h) <= 16)
        if is_centered and (state.active[addr] or is_showcase_size) then
          state.seq[addr] = (state.seq[addr] or 0) + 1
          state.active[addr] = nil
          hl.dispatch(hl.dsp.window.pseudo({ action = "disable", window = w }))
          hl.dispatch(hl.dsp.window.float({ action = "disable", window = w }))
          return
        end
      end

      local my_seq = (state.seq[addr] or 0) + 1
      state.seq[addr] = my_seq
      state.active[addr] = true

      local pre_w = (w.size and w.size.x) or 0
      local pre_h = (w.size and w.size.y) or 0

      if (w.fullscreen or 0) ~= 0 then
        local fs_mode = (w.fullscreen == 1) and "maximized" or "fullscreen"
        hl.dispatch(hl.dsp.window.fullscreen({ mode = fs_mode, action = "unset", window = w }))
      end

      local function recenter_committed()
        local cur_m = w.monitor or hl.get_active_monitor()
        if not cur_m then return end
        local ct = compute_targets(cur_m)
        local ww = (w.size and w.size.x) or ct.target_w
        local wh = (w.size and w.size.y) or ct.target_h
        local cx = math.floor(cur_m.x + ct.res_l + (ct.avail_w - ww) / 2 + 0.5)
        local cy = math.floor(cur_m.y + ct.res_t + (ct.avail_h - wh) / 2 + 0.5)
        local wx = (w.at and w.at.x) or 0
        local wy = (w.at and w.at.y) or 0
        if math.abs(wx - cx) > 2 or math.abs(wy - cy) > 2 then
          hl.dispatch(hl.dsp.window.move({ x = cx, y = cy, relative = false, window = w }))
        end
        state.committed[addr] = { w = ww, h = wh }
      end

      if was_floating then
        -- Already floating: `w.size` matches the committed layout goal, so a single
        -- exact resize + move sets the showcase geometry without cumulative drift.
        hl.dispatch(hl.dsp.window.resize({ x = t.target_w, y = t.target_h, relative = false, window = w }))
        hl.dispatch(hl.dsp.window.move({ x = t.target_x, y = t.target_y, relative = false, window = w }))
        state.float_ready[addr] = { w = t.target_w, h = t.target_h }
        state.committed[addr] = { w = t.target_w, h = t.target_h }

        for _, delay in ipairs({ 45, 120 }) do
          hl.timer(function()
            if state.seq[addr] ~= my_seq then return end
            local ok_mapped, is_mapped = pcall(function() return w.mapped end)
            if not ok_mapped or not is_mapped then return end
            if not w.floating or (w.fullscreen or 0) ~= 0 then return end
            recenter_committed()
          end, { timeout = delay, type = "oneshot" })
        end
        return
      end

      -- Transitioning from tiled/maximized/fullscreen: enable floating & center first,
      -- then wait for the floating Wayland configure to settle before issuing at most
      -- ONE resize (and skip resizing when `m_lastFloatingSize` is already showcase
      -- size unless the client committed a different pre-tiled size such as GTK4).
      hl.dispatch(hl.dsp.window.pseudo({ action = "disable", window = w }))
      hl.dispatch(hl.dsp.window.float({ action = "enable", window = w }))
      hl.dispatch(hl.dsp.window.center({ window = w }))

      local ready = state.float_ready[addr]
      local already_sized = ready and ready.w == t.target_w and ready.h == t.target_h
      local did_resize = false

      for _, delay in ipairs({ 25, 60, 120, 190 }) do
        hl.timer(function()
          if state.seq[addr] ~= my_seq then return end
          local ok_mapped, is_mapped = pcall(function() return w.mapped end)
          if not ok_mapped or not is_mapped then return end
          if not w.floating or (w.fullscreen or 0) ~= 0 then return end
          local cur_m = w.monitor or hl.get_active_monitor()
          if not cur_m then return end
          local ct = compute_targets(cur_m)
          local ww = (w.size and w.size.x) or 0
          local wh = (w.size and w.size.y) or 0
          local size_changed = (ww ~= pre_w) or (wh ~= pre_h)

          if not did_resize and (size_changed or (not already_sized and delay >= 60)) then
            did_resize = true
            state.float_ready[addr] = { w = ct.target_w, h = ct.target_h }
            if math.abs(ww - ct.target_w) > 2 or math.abs(wh - ct.target_h) > 2 then
              hl.dispatch(hl.dsp.window.resize({ x = ct.target_w, y = ct.target_h, relative = false, window = w }))
              hl.dispatch(hl.dsp.window.move({ x = ct.target_x, y = ct.target_y, relative = false, window = w }))
              state.committed[addr] = { w = ct.target_w, h = ct.target_h }
              return
            end
          end

          if size_changed or did_resize or delay >= 120 then
            recenter_committed()
          end
        end, { timeout = delay, type = "oneshot" })
      end
    end
  '';

  # Toggle/summon Mission Center (Windows Task Manager / macOS Force Quit style):
  # closes if already focused, brings to current Space & centers if open elsewhere,
  # or launches fresh as a centered floating window.
  taskManagerBind = ''
    function()
      local active = hl.get_active_window()
      if active and active.class == "io.missioncenter.MissionCenter" then
        hl.dispatch(hl.dsp.window.close())
        return
      end
      for _, w in ipairs(hl.get_windows()) do
        if w.class == "io.missioncenter.MissionCenter" then
          local ws = hl.get_active_workspace()
          if ws and ws.id and (not w.workspace or w.workspace.id ~= ws.id) then
            hl.dispatch(hl.dsp.window.move({ workspace = ws.id, window = w }))
          end
          hl.dispatch(hl.dsp.focus({ window = w }))
          hl.dispatch(hl.dsp.window.center({ window = w }))
          return
        end
      end
      hl.dispatch(hl.dsp.exec_cmd(${builtins.toJSON missionCenter}))
    end
  '';

  workspaceIndices = lib.range 1 10;

  workspaceBinds = lib.concatMap (
    ws:
    let
      code = "code:${toString (ws + 9)}";
    in
    [
      (mkBind "ALT + ${code}" "hl.dsp.focus({ workspace = ${toString ws} })")
      (mkBind "ALT + SHIFT + ${code}" "hl.dsp.window.move({ workspace = ${toString ws} })")
      (mkBind "ALT + CTRL + ${code}" "hl.dsp.window.move({ workspace = ${toString ws}, follow = false })")
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
        _var = "ALT";
      };

      terminal = {
        _var = defaultTerminal;
      };

      launcher = {
        _var = fuzzel;
      };

      appLauncher = {
        _var = lib.mkDefault config.wayland.windowManager.hyprland.settings.launcher._var;
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
        {
          _args = [
            "GTK_USE_PORTAL"
            "1"
          ];
        }
        {
          _args = [
            "QT_QPA_PLATFORMTHEME"
            "xdgdesktopportal"
          ];
        }
        {
          _args = [
            "QT_WAYLAND_DISABLE_WINDOWDECORATION"
            "1"
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
          inactive_opacity = 1.0;
          dim_special = 0.25;
          shadow = {
            enabled = true;
            range = 12;
            render_power = 3;
            color = "rgba(00000066)";
          };
          blur = {
            enabled = true;
            size = 10;
            passes = 3;
            new_optimizations = true;
            xray = false;
            ignore_opacity = true;
            contrast = 0.85;
            brightness = 0.98;
            noise = 0.014;
            vibrancy = 0.25;
            vibrancy_darkness = 0.25;
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
          allow_session_lock_restore = true;
        };

        binds = {
          hide_special_on_workspace_change = true;
          allow_workspace_cycles = true;
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
        }
        {
          name = "mission-center";
          match = {
            class = "^io\\.missioncenter\\.MissionCenter$";
          };
          float = true;
          size = "75% 75%";
          center = true;
        }
        {
          name = "mission-center-gl-probe";
          match = {
            class = "^missioncenter$";
            title = "^$";
          };
          float = true;
          no_initial_focus = true;
          opacity = "0.0 0.0";
        }
        {
          name = "thunar-dialogs";
          match = {
            class = "^(thunar|Thunar)$";
            title = "^(File Operation Progress|Confirm to replace files|Rename .*)$";
          };
          float = true;
          center = true;
        }
        {
          name = "orb-vibrancy";
          match = {
            class = "^(orb-desktop|\\.orb-desktop-unwrapped|orb)$";
          };
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
        {
          name = "webcam-overlay";
          match = {
            class = "^WebcamOverlay-(small|medium|large)$";
            title = "^WebcamOverlay$";
          };
          float = true;
          pin = true;
          no_initial_focus = true;
          no_dim = true;
        }
        {
          name = "webcam-overlay-small";
          match = {
            class = "^WebcamOverlay-small$";
          };
          size = [
            "(monitor_h*4/25)"
            "(monitor_h*9/50)"
          ];
          move = [
            "(monitor_w-monitor_h*4/25-40)"
            "(monitor_h-monitor_h*9/50-40)"
          ];
        }
        {
          name = "webcam-overlay-medium";
          match = {
            class = "^WebcamOverlay-medium$";
          };
          size = [
            "(monitor_h*2/9)"
            "(monitor_h/4)"
          ];
          move = [
            "(monitor_w-monitor_h*2/9-40)"
            "(monitor_h-monitor_h/4-40)"
          ];
        }
        {
          name = "webcam-overlay-large";
          match = {
            class = "^WebcamOverlay-large$";
          };
          size = [
            "(monitor_h*3/10)"
            "(monitor_h*27/80)"
          ];
          move = [
            "(monitor_w-monitor_h*3/10-40)"
            "(monitor_h-monitor_h*27/80-40)"
          ];
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
        # Launchers, core apps & workspace back-and-forth use Option (ALT) so Cmd (SUPER) stays free for Orb & apps
        (mkBind "ALT + Return" "hl.dsp.exec_cmd(terminal)")
        (mkBind "ALT + O" ''hl.dsp.exec_cmd("${orb}")'')
        (mkBind "ALT + SPACE" "hl.dsp.exec_cmd(launcher)")
        (mkBind "ALT + SHIFT + SPACE" "hl.dsp.exec_cmd(appLauncher)")
        (mkBind "ALT + TAB" ''hl.dsp.focus({ workspace = "previous" })'')
        (mkBind "ALT + SHIFT + Q" "hl.dsp.window.close()")
        (mkBind "SUPER + W" smartCloseBind)
        (mkBind "CTRL + ALT + SHIFT + Q" "hl.dsp.window.kill()")

        # macOS-style universal Copy / Paste / Cut / Select All / Undo / Redo / Find
        (mkBind "SUPER + C" (mkUniversalClipboardBind "CTRL" "C" "CTRL SHIFT" "C"))
        (mkBind "SUPER + V" (mkUniversalClipboardBind "CTRL" "V" "CTRL SHIFT" "V"))
        (mkBind "SUPER + F" (mkUniversalClipboardBind "CTRL" "F" "CTRL SHIFT" "F"))
        (mkBind "SUPER + X" (mkSendShortcutOnce "CTRL" "X"))
        (mkBind "SUPER + A" (mkSendShortcutOnce "CTRL" "A"))
        (mkBind "SUPER + Z" (mkSendShortcutOnce "CTRL" "Z"))
        (mkBind "SUPER + SHIFT + Z" (mkSendShortcutOnce "CTRL SHIFT" "Z"))

        # Window management uses Option (ALT) — AeroSpace style — so Cmd+<key> never collides with Orb or apps
        (mkBind "ALT + SHIFT + F" ''hl.dsp.window.float({ action = "toggle" })'')
        (mkBind "ALT + V" ''hl.dsp.window.float({ action = "toggle" })'')
        (mkBind "ALT + C" centerShowcaseBind)
        (mkBind "ALT + F" ''hl.dsp.window.fullscreen({ mode = "fullscreen" })'')
        (mkBind "ALT + M" ''hl.dsp.window.fullscreen({ mode = "maximized" })'')
        (mkBind "ALT + P" "hl.dsp.window.pseudo()")
        (mkBind "ALT + E" ''hl.dsp.layout("togglesplit")'')
        (mkBind "CTRL + SHIFT + ESCAPE" taskManagerBind)
        (mkBind "SUPER + ALT + ESCAPE" taskManagerBind)
        (mkBind "SUPER + ESCAPE" "hl.dsp.exec_cmd(${builtins.toJSON shellLock})")
        (mkBind "CTRL + SUPER + Q" "hl.dsp.exec_cmd(${builtins.toJSON shellLock})")
        (mkBindOpts "XF86PowerOff" "hl.dsp.exec_cmd(${builtins.toJSON "${powerKeyCmd}"})" {
          locked = true;
          release = true;
        })
        (mkBind "CTRL + ALT + SUPER + Q" "hl.dsp.exit()")
        (mkBind "ALT + SHIFT + R" "hl.dsp.reload_config()")

        (mkBind "ALT + left" ''hl.dsp.focus({ direction = "left" })'')
        (mkBind "ALT + right" ''hl.dsp.focus({ direction = "right" })'')
        (mkBind "ALT + up" ''hl.dsp.focus({ direction = "up" })'')
        (mkBind "ALT + down" ''hl.dsp.focus({ direction = "down" })'')
        (mkBind "ALT + H" ''hl.dsp.focus({ direction = "left" })'')
        (mkBind "ALT + L" ''hl.dsp.focus({ direction = "right" })'')
        (mkBind "ALT + K" ''hl.dsp.focus({ direction = "up" })'')
        (mkBind "ALT + J" ''hl.dsp.focus({ direction = "down" })'')

        (mkBind "ALT + SHIFT + left" ''hl.dsp.window.move({ direction = "left" })'')
        (mkBind "ALT + SHIFT + right" ''hl.dsp.window.move({ direction = "right" })'')
        (mkBind "ALT + SHIFT + up" ''hl.dsp.window.move({ direction = "up" })'')
        (mkBind "ALT + SHIFT + down" ''hl.dsp.window.move({ direction = "down" })'')
        (mkBind "ALT + SHIFT + H" ''hl.dsp.window.move({ direction = "left" })'')
        (mkBind "ALT + SHIFT + L" ''hl.dsp.window.move({ direction = "right" })'')
        (mkBind "ALT + SHIFT + K" ''hl.dsp.window.move({ direction = "up" })'')
        (mkBind "ALT + SHIFT + J" ''hl.dsp.window.move({ direction = "down" })'')

        (mkBind "ALT + grave" ''hl.dsp.workspace.toggle_special("scratchpad")'')
        (mkBind "ALT + S" ''hl.dsp.workspace.toggle_special("scratchpad")'')
        (mkBind "ALT + SHIFT + grave" ''hl.dsp.window.move({ workspace = "special:scratchpad" })'')
        (mkBind "ALT + SHIFT + S" ''hl.dsp.window.move({ workspace = "special:scratchpad" })'')
        (mkBind "ALT + SHIFT + P" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "SUPER + SHIFT + P" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "CTRL + SUPER + SHIFT + P" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "ALT + SHIFT + code:13" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "SUPER + SHIFT + code:13" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "CTRL + SUPER + SHIFT + code:13" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "ALT + SHIFT + code:14" "hl.dsp.exec_cmd(${builtins.toJSON captureMenuCmd})")
        (mkBind "SUPER + SHIFT + code:14" "hl.dsp.exec_cmd(${builtins.toJSON captureMenuCmd})")
        (mkBind "CTRL + SUPER + SHIFT + code:14" "hl.dsp.exec_cmd(${builtins.toJSON captureMenuCmd})")
        (mkBind "SUPER + SHIFT + V" "hl.dsp.exec_cmd(${builtins.toJSON clipboardCmd})")
        (mkBind "SUPER + CTRL + V" "hl.dsp.exec_cmd(${builtins.toJSON clipboardCmd})")
        (mkBind "ALT + SHIFT + I" "hl.dsp.exec_cmd(${builtins.toJSON idleToggleCmd})")
        (mkBind "SUPER + SHIFT + I" "hl.dsp.exec_cmd(${builtins.toJSON idleToggleCmd})")
        (mkBind "ALT + CTRL + T" "hl.dsp.exec_cmd(${builtins.toJSON themePickerCmd})")
        (mkBind "ALT + SHIFT + T" ''hl.dsp.exec_cmd("${omarchnixCli} theme toggle")'')

        (mkBind "ALT + mouse_down" ''hl.dsp.focus({ workspace = "e-1" })'')
        (mkBind "ALT + mouse_up" ''hl.dsp.focus({ workspace = "e+1" })'')
        (mkBind "ALT + SHIFT + mouse_down" "hl.dsp.group.prev()")
        (mkBind "ALT + SHIFT + mouse_up" "hl.dsp.group.next()")

        (mkBindOpts "ALT + mouse:272" "hl.dsp.window.drag()" { mouse = true; })
        (mkBindOpts "ALT + mouse:273" "hl.dsp.window.resize()" { mouse = true; })

        (mkBindOpts "XF86MonBrightnessUp" ''hl.dsp.exec_cmd("${brightnessctl} -e4 -n2 set 5%+")'' {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "XF86MonBrightnessDown" ''hl.dsp.exec_cmd("${brightnessctl} -e4 -n2 set 5%-")'' {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "XF86KbdBrightnessUp" "hl.dsp.exec_cmd(${builtins.toJSON kbdBacklightUpCmd})" {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "XF86KbdBrightnessDown" "hl.dsp.exec_cmd(${builtins.toJSON kbdBacklightDownCmd})" {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "XF86KbdLightOnOff" "hl.dsp.exec_cmd(${builtins.toJSON kbdBacklightCycleCmd})" {
          locked = true;
        })
        # Apple Silicon MacBooks lack dedicated keyboard backlight keys (F5/F6 are
        # Dictation / Focus); drive keyboard backlight with Option/Ctrl/Cmd + F1/F2.
        (mkBindOpts "ALT + XF86MonBrightnessUp" "hl.dsp.exec_cmd(${builtins.toJSON kbdBacklightUpCmd})" {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "ALT + XF86MonBrightnessDown" "hl.dsp.exec_cmd(${builtins.toJSON kbdBacklightDownCmd})"
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBindOpts "CTRL + XF86MonBrightnessUp" "hl.dsp.exec_cmd(${builtins.toJSON kbdBacklightUpCmd})" {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "CTRL + XF86MonBrightnessDown" "hl.dsp.exec_cmd(${builtins.toJSON kbdBacklightDownCmd})"
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBindOpts "SUPER + XF86MonBrightnessUp" "hl.dsp.exec_cmd(${builtins.toJSON kbdBacklightUpCmd})" {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "SUPER + XF86MonBrightnessDown"
          "hl.dsp.exec_cmd(${builtins.toJSON kbdBacklightDownCmd})"
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

  # Hyprland in Lua configuration mode (`hyprland.lua`) does not auto-reload when
  # Home Manager updates the `~/.config/hypr/hyprland.lua` symlink during
  # `nixos-rebuild switch`, and `home-manager-thomas.service` runs without
  # `HYPRLAND_INSTANCE_SIGNATURE`. Discover all live compositor sockets in
  # `$XDG_RUNTIME_DIR/hypr` and trigger `hyprctl reload` automatically.
  home.activation.omarchnixReloadHyprland = config.lib.dag.entryAfter [ "linkGeneration" ] ''
    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    hyprctl_bin="$(PATH="/run/current-system/sw/bin:$PATH" command -v hyprctl 2>/dev/null || true)"
    if [ -n "$hyprctl_bin" ] && [ -d "$runtime_dir/hypr" ]; then
      for sock_dir in "$runtime_dir"/hypr/*; do
        [ -S "$sock_dir/.socket.sock" ] || continue
        sig="$(basename "$sock_dir")"
        XDG_RUNTIME_DIR="$runtime_dir" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
          "$hyprctl_bin" reload >/dev/null 2>&1 || true
      done
    fi
  '';
}
