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
  configuredBrowser = config.home.sessionVariables.BROWSER or "helium";
  defaultBrowser =
    if configuredBrowser == "helium" && (pkgs ? helium) then
      "${pkgs.helium}/bin/helium"
    else
      configuredBrowser;
  defaultFileManager =
    if (cfg.flea.enable or false) && (cfg.flea.package or null) != null then
      "${cfg.flea.package}/bin/flea --gui"
    else if pkgs ? flea then
      "${pkgs.flea}/bin/flea --gui"
    else
      "${pkgs.xdg-utils}/bin/xdg-open ~";
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
  omarchySharePath =
    if cfg.shell.package != null && (cfg.shell.package ? sharePath) then
      cfg.shell.package.sharePath
    else
      "/usr/share/omarchy";
  omarchyShellCmd =
    if omarchyShellBin != "" then "${omarchyShellBin}/omarchy-shell" else "omarchy-shell";
  workspaceLayoutToggleCmd =
    if omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-hyprland-workspace-layout-toggle"
    else
      "omarchy-hyprland-workspace-layout-toggle";
  workspaceLayoutToggleBackCmd = "${workspaceLayoutToggleCmd} back";
  windowPopCmd =
    if omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-hyprland-window-pop"
    else
      "omarchy-hyprland-window-pop";
  monitorPanelToggleCmd = "${omarchyShellCmd} shell toggle omarchy.monitor";
  lidCloseCmd =
    if omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-system-lid-close"
    else
      "omarchy-system-lid-close";
  lidClamshellCmd =
    if omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-hyprland-monitor-clamshell"
    else
      "omarchy-hyprland-monitor-clamshell";
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

    # When all enabled displays are dark (e.g. single-screen laptop dimmed to 0%
    # or idle DPMS off), tapping the Power button wakes the display back up (to 5%)
    # rather than locking in the dark. When an external display remains lit, Power
    # still locks the session normally.
    if [ -n "$hyprctl_bin" ] && "$hyprctl_bin" monitors -j 2>/dev/null | ${jq} -e '[.[] | select(.disabled == false)] | length > 0 and all(.dpmsStatus == false)' >/dev/null 2>&1; then
      ${
        if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
          "${omarchyShellBin}/omarchy-brightness-display on"
        else
          ''rm -f "''${XDG_RUNTIME_DIR:-/tmp}/omarchy-brightness-zero"; "$hyprctl_bin" dispatch 'hl.dsp.dpms("on")' ''
      } >/dev/null 2>&1 || true
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
  displayBrightnessUpDsp =
    if cfg.shell.backend == "omarchy-shell" then
      ''hl.dsp.global("omarchy:brightness.raise")''
    else
      ''hl.dsp.exec_cmd("${brightnessctl} -e4 set 5%+")'';
  displayBrightnessDownDsp =
    if cfg.shell.backend == "omarchy-shell" then
      ''hl.dsp.global("omarchy:brightness.lower")''
    else
      ''hl.dsp.exec_cmd("${brightnessctl} -e4 set 5%-")'';
  audioRaiseDsp =
    if cfg.shell.backend == "omarchy-shell" then
      ''hl.dsp.global("omarchy:audio.raise")''
    else
      ''hl.dsp.exec_cmd("${wpctl} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+")'';
  audioLowerDsp =
    if cfg.shell.backend == "omarchy-shell" then
      ''hl.dsp.global("omarchy:audio.lower")''
    else
      ''hl.dsp.exec_cmd("${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%-")'';
  audioRaiseFineCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-audio-output-volume +1"
    else
      "${wpctl} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 1%+";
  audioLowerFineCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-audio-output-volume -1"
    else
      "${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 1%-";
  audioMuteDsp =
    if cfg.shell.backend == "omarchy-shell" then
      ''hl.dsp.global("omarchy:audio.mute-toggle")''
    else
      ''hl.dsp.exec_cmd("${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle")'';
  audioOutputSwitchCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-audio-output-switch"
    else
      "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle";
  audioMicMuteCmd =
    if cfg.shell.backend == "omarchy-shell" && omarchyShellBin != "" then
      "${omarchyShellBin}/omarchy-audio-input-mute"
    else
      "${wpctl} set-mute @DEFAULT_AUDIO_SOURCE@ toggle";
  mediaPlayPauseDsp =
    if cfg.shell.backend == "omarchy-shell" then
      ''hl.dsp.global("omarchy:ipc.media.playPause")''
    else
      ''hl.dsp.exec_cmd("${playerctl} play-pause")'';
  mediaNextDsp =
    if cfg.shell.backend == "omarchy-shell" then
      ''hl.dsp.global("omarchy:ipc.media.next")''
    else
      ''hl.dsp.exec_cmd("${playerctl} next")'';
  mediaPrevDsp =
    if cfg.shell.backend == "omarchy-shell" then
      ''hl.dsp.global("omarchy:ipc.media.previous")''
    else
      ''hl.dsp.exec_cmd("${playerctl} previous")'';

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
          local term_exact = {
            ["foot"] = true,
            ["foot-scratchpad"] = true,
            ["org.codeberg.dnkl.foot"] = true,
            ["alacritty"] = true,
            ["kitty"] = true,
            ["wezterm"] = true,
            ["org.wezfurlong.wezterm"] = true,
          }
          if
            term_exact[cls]
            or cls:find("ghostty", 1, true)
            or cls:find("^org%.omarchy%.")
            or cls:find("^tui%.")
          then
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

  # Float & center active window at an aspect-aware fraction of usable workarea
  # (`84%x85%` on standard 16:10/16:9 screens; `58%x88%` focused center column on
  # 21:9+ ultrawides, or `78%x88%` when `wide = true`). Pressing again when already
  # centered at that preset returns the window to normal WM tiling.
  #
  # Note on Hyprland 0.57+ Lua `hl.dsp.window.resize({ relative = false })`:
  # `Config::Actions::resize` computes `delta = target - w->reportedSize()` (the last
  # committed Wayland buffer size) and adds `delta` to the floating layout goal box
  # (`m_lastFloatingSize`). Never call `resize({ relative = false })` synchronously on
  # the same frame as `float({ action = "enable" })` or repeat it before `w.size`
  # commits, otherwise `delta` is subtracted from `m_lastFloatingSize` repeatedly.
  mkCenterShowcaseBind = wide: ''
    function()
      if _G.__omarchnix_window and _G.__omarchnix_window.showcase then
        _G.__omarchnix_window.showcase(${if wide then "true" else "false"})
      end
    end
  '';
  centerShowcaseBind = mkCenterShowcaseBind false;
  centerShowcaseWideBind = mkCenterShowcaseBind true;

  mkSnapSlotBind = slotSpec: ''
    function()
      if _G.__omarchnix_window and _G.__omarchnix_window.snap then
        _G.__omarchnix_window.snap(${builtins.toJSON slotSpec})
      end
    end
  '';

  focusCursorMonitorAndExec = cmdExpr: ''
    function()
      local m = hl.get_monitor_at_cursor and hl.get_monitor_at_cursor()
      if m and not m.focused then
        hl.dispatch(hl.dsp.focus({ monitor = m.name }))
      end
      hl.dispatch(hl.dsp.exec_cmd(${cmdExpr}))
    end
  '';

  # Toggle/summon Mission Center (Windows Task Manager / macOS Force Quit style):
  # closes if already focused, brings to current Space & centers if open elsewhere,
  # or launches fresh as a centered floating window.
  taskManagerBind = ''
    function()
      local cur_m = (hl.get_monitor_at_cursor and hl.get_monitor_at_cursor()) or hl.get_active_monitor()
      if cur_m and not cur_m.focused then
        hl.dispatch(hl.dsp.focus({ monitor = cur_m.name }))
      end
      local active = hl.get_active_window()
      if active and active.class == "io.missioncenter.MissionCenter" then
        hl.dispatch(hl.dsp.window.close())
        return
      end
      for _, w in ipairs(hl.get_windows()) do
        if w.class == "io.missioncenter.MissionCenter" then
          local ws = (cur_m and cur_m.active_workspace) or hl.get_active_workspace()
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
      slotStr = toString ws;
    in
    [
      # Mouse-aware default: operates on whichever monitor the pointer is currently inside
      (mkBind "ALT + ${code}" ''
        function()
          if _G.__omarchnix_multiscreen then
            _G.__omarchnix_multiscreen.focus_slot_at_cursor(${slotStr})
          else
            hl.dispatch(hl.dsp.focus({ workspace = ${slotStr} }))
          end
        end
      '')
      (mkBind "ALT + SHIFT + ${code}" ''
        function()
          if _G.__omarchnix_multiscreen then
            _G.__omarchnix_multiscreen.move_window_to_cursor_slot(${slotStr}, true)
          else
            hl.dispatch(hl.dsp.window.move({ workspace = ${slotStr} }))
          end
        end
      '')
      # Cmd + Right-Shift + 1..0: move active window to Space 1..10 on the OTHER screen (and follow).
      # Guarded by `hl.is_key_down("Shift_R")` so Cmd + Left-Shift + 4/5 screenshots keep working untouched.
      (mkBind "SUPER + SHIFT + ${code}" ''
        function()
          if hl.is_key_down and hl.is_key_down("Shift_R") then
            if _G.__omarchnix_multiscreen then
              _G.__omarchnix_multiscreen.move_window_to_other_slot(${slotStr}, true)
            end
            return
          end
          ${
            if ws == 4 then
              "hl.dispatch(hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"}))"
            else if ws == 5 then
              "hl.dispatch(hl.dsp.exec_cmd(${builtins.toJSON captureMenuCmd}))"
            else
              ""
          }
        end
      '')
    ]
  ) workspaceIndices;

  omarchyMultiScreenBootstrapLua = lib.optionalString (cfg.shell.backend == "omarchy-shell") ''
    do
      local omarchy_path = ${builtins.toJSON "${omarchySharePath}"}
      hl.env("OMARCHY_PATH", omarchy_path)
      local ok_boot, err_boot = pcall(dofile, omarchy_path .. "/default/hypr/bootstrap.lua")
      if ok_boot then
        pcall(require, "default.hypr.helpers")
        pcall(require, "default.hypr.wide-gamut")
        pcall(require, "default.hypr.monitor-workspaces")
        pcall(require, "default.hypr.pop")
      end
    end
  '';

  omarchyMultiScreenRuntimeLua = ''
    do
      local function active_monitors()
        local list = {}
        for _, m in ipairs(hl.get_monitors()) do
          if not m.is_mirror and not m.disabled then
            list[#list + 1] = m
          end
        end
        table.sort(list, function(a, b)
          if a.x ~= b.x then return a.x < b.x end
          if a.y ~= b.y then return a.y < b.y end
          return (a.id or 0) < (b.id or 0)
        end)
        return list
      end

      local function cursor_monitor()
        local m = hl.get_monitor_at_cursor and hl.get_monitor_at_cursor()
        if m and not m.is_mirror and not m.disabled then
          return m
        end
        return hl.get_active_monitor()
      end

      local function other_monitor(from_mon)
        local mons = active_monitors()
        if #mons < 2 then return nil end
        local origin = from_mon or cursor_monitor()
        if not origin then return mons[1] end
        local idx = 1
        for i, m in ipairs(mons) do
          if m.name == origin.name then
            idx = i
            break
          end
        end
        return mons[(idx % #mons) + 1]
      end

      local function workspace_id_for(mon, slot)
        if o and o.workspaces and o.workspaces.workspace_id then
          return o.workspaces.workspace_id(mon, slot)
        end
        return slot
      end

      local function center_cursor_on_monitor(mon)
        if not mon then return end
        local scale = (mon.scale and mon.scale > 0) and mon.scale or 1.0
        local pw, ph = mon.width or 1600, mon.height or 1000
        if ((mon.transform or 0) % 2) == 1 then pw, ph = ph, pw end
        local lw = math.floor(pw / scale + 0.5)
        local lh = math.floor(ph / scale + 0.5)
        local cx = math.floor(mon.x + lw / 2 + 0.5)
        local cy = math.floor(mon.y + lh / 2 + 0.5)
        hl.exec_cmd(string.format("hyprctl dispatch movecursor %d %d >/dev/null 2>&1", cx, cy))
      end

      local function fit_floating_window_to_monitor(w, target_mon)
        if not w or not target_mon then return end
        local addr = "address:" .. tostring(w.address or "")
        hl.timer(function()
          local win = hl.get_window(addr)
          local mon = hl.get_monitor(target_mon.name)
          if not win or not mon or not win.floating or (win.fullscreen or 0) ~= 0 then return end
          local scale = (mon.scale and mon.scale > 0) and mon.scale or 1.0
          local pw, ph = mon.width, mon.height
          if ((mon.transform or 0) % 2) == 1 then pw, ph = ph, pw end
          local mw = math.floor(pw / scale + 0.5)
          local mh = math.floor(ph / scale + 0.5)
          local res = mon.reserved or {}
          local rl, rr, rt, rb = res.left or 0, res.right or 0, res.top or 0, res.bottom or 0
          local aw = math.max(320, mw - rl - rr)
          local ah = math.max(240, mh - rt - rb)
          local ww = (win.size and win.size.x) or aw
          local wh = (win.size and win.size.y) or ah
          local max_w = math.floor(aw * 0.92 + 0.5)
          local max_h = math.floor(ah * 0.90 + 0.5)
          local nw = math.min(ww, max_w)
          local nh = math.min(wh, max_h)
          if nw < ww or nh < wh then
            hl.dispatch(hl.dsp.window.resize({ x = nw, y = nh, relative = false, window = win }))
            ww, wh = nw, nh
          end
          local nx = math.floor(mon.x + rl + (aw - ww) / 2 + 0.5)
          local ny = math.floor(mon.y + rt + (ah - wh) / 2 + 0.5)
          hl.dispatch(hl.dsp.window.move({ x = nx, y = ny, relative = false, window = win }))
        end, { timeout = 35, type = "oneshot" })
      end

      local ms = {}

      function ms.focus_slot_at_cursor(slot)
        local mon = cursor_monitor()
        if not mon then return end
        if o and o.workspaces and o.workspaces.focus then
          o.workspaces.focus(slot, mon.name)()
        else
          if not mon.focused then
            hl.dispatch(hl.dsp.focus({ monitor = mon.name }))
          end
          hl.dispatch(hl.dsp.focus({ workspace = tostring(workspace_id_for(mon, slot)) }))
        end
      end

      function ms.move_window_to_slot_on(mon, slot, follow)
        local w = hl.get_active_window()
        if not w or not mon then return end
        local src_mon = w.monitor
        local id = workspace_id_for(mon, slot)
        if _G.__omarchnix_spaces and _G.__omarchnix_spaces.add_space then
          _G.__omarchnix_spaces.add_space(id)
        end
        if o and o.workspaces and o.workspaces.focus and src_mon and src_mon.name ~= mon.name then
          -- Ensure destination workspace belongs to target monitor before moving window
          local ws_obj = hl.get_workspace(id)
          if ws_obj and ws_obj.monitor and ws_obj.monitor.name ~= mon.name then
            hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(id), monitor = mon.name }))
          end
        end
        local should_follow = (follow ~= false)
        hl.dispatch(hl.dsp.window.move({
          workspace = tostring(id),
          follow = should_follow,
          window = "address:" .. tostring(w.address),
        }))
        if src_mon and src_mon.name ~= mon.name then
          if w.floating and (w.fullscreen or 0) == 0 then
            fit_floating_window_to_monitor(w, mon)
          end
          if should_follow then
            if not mon.focused then
              hl.dispatch(hl.dsp.focus({ monitor = mon.name }))
            end
            center_cursor_on_monitor(mon)
          end
        end
      end

      function ms.move_window_to_cursor_slot(slot, follow)
        ms.move_window_to_slot_on(cursor_monitor(), slot, follow)
      end

      function ms.move_window_to_other_slot(slot, follow)
        local w = hl.get_active_window()
        local base = (w and w.monitor) or cursor_monitor()
        local target = other_monitor(base)
        if not target then return end
        ms.move_window_to_slot_on(target, slot, follow)
      end

      function ms.focus_other_monitor()
        local cur = cursor_monitor()
        local target = other_monitor(cur)
        if not target then return end
        hl.dispatch(hl.dsp.focus({ monitor = target.name }))
        center_cursor_on_monitor(target)
      end

      function ms.throw_window_to_other_monitor(follow)
        local w = hl.get_active_window()
        if not w then return end
        local base = w.monitor or cursor_monitor()
        local target = other_monitor(base)
        if not target then return end
        local active_ws = target.active_workspace
        local dest_id = (active_ws and active_ws.id) or workspace_id_for(target, 1)
        local should_follow = (follow ~= false)
        hl.dispatch(hl.dsp.window.move({
          workspace = tostring(dest_id),
          follow = should_follow,
          window = "address:" .. tostring(w.address),
        }))
        if w.floating and (w.fullscreen or 0) == 0 then
          fit_floating_window_to_monitor(w, target)
        end
        if should_follow then
          hl.dispatch(hl.dsp.focus({ monitor = target.name }))
          center_cursor_on_monitor(target)
        end
      end

      function ms.cycle_workspace_at_cursor(delta)
        local mon = cursor_monitor()
        if not mon then return end
        if not mon.focused then
          hl.dispatch(hl.dsp.focus({ monitor = mon.name }))
        end
        hl.dispatch(hl.dsp.focus({ workspace = delta > 0 and "m+1" or "m-1" }))
      end

      _G.__omarchnix_multiscreen = ms
    end

    do
      local state = rawget(_G, "__omarchnix_showcase")
      if not state or not state.active then
        state = { seq = {}, active = {}, float_ready = {}, committed = {} }
        rawset(_G, "__omarchnix_showcase", state)
      end

      local function workarea_of(mon)
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
        return {
          mon_w = mon_w,
          mon_h = mon_h,
          res_l = res_l,
          res_t = res_t,
          avail_w = avail_w,
          avail_h = avail_h,
          aspect = avail_w / math.max(1, avail_h),
          origin_x = mon.x + res_l,
          origin_y = mon.y + res_t,
          center_x = mon.x + res_l + avail_w / 2,
          center_y = mon.y + res_t + avail_h / 2,
        }
      end

      local function apply_floating_box(w, mon, box_fn, toggle_return_tile, tag_key)
        local addr = tostring(w.address or "")
        local wa = workarea_of(mon)
        local target_x, target_y, target_w, target_h = box_fn(wa)
        local was_floating = w.floating and (w.fullscreen or 0) == 0

        if was_floating and toggle_return_tile then
          local wx = (w.at and w.at.x) or 0
          local wy = (w.at and w.at.y) or 0
          local ww = (w.size and w.size.x) or 0
          local wh = (w.size and w.size.y) or 0
          local same_pos = math.abs(wx - target_x) <= 36 and math.abs(wy - target_y) <= 36
          local same_size = math.abs(ww - target_w) <= 40 and math.abs(wh - target_h) <= 40
          if (same_pos and same_size) or (state.active[addr] == tag_key and same_size) then
            state.seq[addr] = (state.seq[addr] or 0) + 1
            state.active[addr] = nil
            hl.dispatch(hl.dsp.window.pseudo({ action = "disable", window = w }))
            hl.dispatch(hl.dsp.window.float({ action = "disable", window = w }))
            return
          end
        end

        local my_seq = (state.seq[addr] or 0) + 1
        state.seq[addr] = my_seq
        state.active[addr] = tag_key

        local pre_w = (w.size and w.size.x) or 0
        local pre_h = (w.size and w.size.y) or 0

        if (w.fullscreen or 0) ~= 0 then
          local fs_mode = (w.fullscreen == 1) and "maximized" or "fullscreen"
          hl.dispatch(hl.dsp.window.fullscreen({ mode = fs_mode, action = "unset", window = w }))
        end

        local function place_exact()
          local cur_m = w.monitor or hl.get_active_monitor()
          if not cur_m then return end
          local tx, ty, tw, th = box_fn(workarea_of(cur_m))
          local wx = (w.at and w.at.x) or 0
          local wy = (w.at and w.at.y) or 0
          if math.abs(wx - tx) > 2 or math.abs(wy - ty) > 2 then
            hl.dispatch(hl.dsp.window.move({ x = tx, y = ty, relative = false, window = w }))
          end
          state.committed[addr] = { w = tw, h = th }
        end

        if was_floating then
          hl.dispatch(hl.dsp.window.resize({ x = target_w, y = target_h, relative = false, window = w }))
          hl.dispatch(hl.dsp.window.move({ x = target_x, y = target_y, relative = false, window = w }))
          state.float_ready[addr] = { w = target_w, h = target_h }
          state.committed[addr] = { w = target_w, h = target_h }
          for _, delay in ipairs({ 45, 120 }) do
            hl.timer(function()
              if state.seq[addr] ~= my_seq then return end
              local ok_mapped, is_mapped = pcall(function() return w.mapped end)
              if not ok_mapped or not is_mapped then return end
              if not w.floating or (w.fullscreen or 0) ~= 0 then return end
              place_exact()
            end, { timeout = delay, type = "oneshot" })
          end
          return
        end

        hl.dispatch(hl.dsp.window.pseudo({ action = "disable", window = w }))
        hl.dispatch(hl.dsp.window.float({ action = "enable", window = w }))
        hl.dispatch(hl.dsp.window.center({ window = w }))

        local ready = state.float_ready[addr]
        local already_sized = ready and ready.w == target_w and ready.h == target_h
        local did_resize = false

        for _, delay in ipairs({ 25, 60, 120, 190 }) do
          hl.timer(function()
            if state.seq[addr] ~= my_seq then return end
            local ok_mapped, is_mapped = pcall(function() return w.mapped end)
            if not ok_mapped or not is_mapped then return end
            if not w.floating or (w.fullscreen or 0) ~= 0 then return end
            local cur_m = w.monitor or hl.get_active_monitor()
            if not cur_m then return end
            local tx, ty, tw, th = box_fn(workarea_of(cur_m))
            local ww = (w.size and w.size.x) or 0
            local wh = (w.size and w.size.y) or 0
            local size_changed = (ww ~= pre_w) or (wh ~= pre_h)

            if not did_resize and (size_changed or (not already_sized and delay >= 60)) then
              did_resize = true
              state.float_ready[addr] = { w = tw, h = th }
              if math.abs(ww - tw) > 2 or math.abs(wh - th) > 2 then
                hl.dispatch(hl.dsp.window.resize({ x = tw, y = th, relative = false, window = w }))
                hl.dispatch(hl.dsp.window.move({ x = tx, y = ty, relative = false, window = w }))
                state.committed[addr] = { w = tw, h = th }
                return
              end
            end

            if size_changed or did_resize or delay >= 120 then
              place_exact()
            end
          end, { timeout = delay, type = "oneshot" })
        end
      end

      local win_ctl = {}

      function win_ctl.showcase(wide)
        local w = hl.get_active_window()
        if not w then return end
        local m = w.monitor or hl.get_active_monitor()
        if not m then return end
        local tag = wide and "showcase-wide" or "showcase"
        apply_floating_box(w, m, function(wa)
          local ultrawide = wa.aspect >= 2.05
          local frac_w = ultrawide and (wide and 0.78 or 0.58) or (wide and 0.92 or 0.84)
          local frac_h = ultrawide and 0.88 or (wide and 0.90 or 0.85)
          local tw = math.floor(wa.avail_w * frac_w + 0.5)
          local th = math.floor(wa.avail_h * frac_h + 0.5)
          local tx = math.floor(wa.origin_x + (wa.avail_w - tw) / 2 + 0.5)
          local ty = math.floor(wa.origin_y + (wa.avail_h - th) / 2 + 0.5)
          return tx, ty, tw, th
        end, true, tag)
      end

      function win_ctl.snap(slot)
        local w = hl.get_active_window()
        if not w then return end
        local m = w.monitor or hl.get_active_monitor()
        if not m then return end
        local gap = ${toString theme.ui.gapsOut}
        local inner = ${toString (theme.ui.gapsIn * 2)}
        apply_floating_box(w, m, function(wa)
          local usable_w = math.max(320, wa.avail_w - gap * 2)
          local usable_h = math.max(240, wa.avail_h - gap * 2)
          local y = math.floor(wa.origin_y + gap + 0.5)
          local h = math.floor(usable_h + 0.5)
          if slot == "left-half" then
            local hw = math.floor((usable_w - inner) / 2 + 0.5)
            return math.floor(wa.origin_x + gap + 0.5), y, hw, h
          elseif slot == "right-half" then
            local hw = math.floor((usable_w - inner) / 2 + 0.5)
            return math.floor(wa.origin_x + gap + usable_w - hw + 0.5), y, hw, h
          elseif slot == "left-third" then
            local tw = math.floor((usable_w - inner * 2) / 3 + 0.5)
            return math.floor(wa.origin_x + gap + 0.5), y, tw, h
          elseif slot == "center-third" then
            local tw = math.floor((usable_w - inner * 2) / 3 + 0.5)
            return math.floor(wa.origin_x + gap + (usable_w - tw) / 2 + 0.5), y, tw, h
          elseif slot == "right-third" then
            local tw = math.floor((usable_w - inner * 2) / 3 + 0.5)
            return math.floor(wa.origin_x + gap + usable_w - tw + 0.5), y, tw, h
          end
          return math.floor(wa.origin_x + gap + 0.5), y, math.floor(usable_w + 0.5), h
        end, true, "snap-" .. tostring(slot))
      end

      _G.__omarchnix_window = win_ctl
    end

    ${lib.optionalString (cfg.shell.backend == "omarchy-shell") ''
      do
        -- Load user monitor overrides (`~/.config/hypr/monitors.lua`) if present,
        -- then apply Omarchy's saved per-monitor Display Panel settings, toggles,
        -- and per-workspace layout modes (`dwindle` / `scrolling` / `floating`).
        local user_monitors = (os.getenv("HOME") or "") .. "/.config/hypr/monitors.lua"
        local mf = io.open(user_monitors, "r")
        if mf then
          mf:close()
          pcall(dofile, user_monitors)
        end
        pcall(require, "default.hypr.toggles")
      end
    ''}
  '';
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
    extraConfig = lib.mkMerge [
      (lib.mkOrder 100 omarchyMultiScreenBootstrapLua)
      (lib.mkOrder 900 omarchyMultiScreenRuntimeLua)
    ];

    settings = {
      mod = {
        _var = "ALT";
      };

      terminal = {
        _var = defaultTerminal;
      };

      browser = {
        _var = lib.mkDefault defaultBrowser;
      };

      fileManager = {
        _var = lib.mkDefault defaultFileManager;
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
            popups_ignorealpha = 0.05;
            special = true;
          };
        };

        animations = {
          enabled = true;
        };

        dwindle = {
          preserve_split = true;
        };

        scrolling = {
          column_width = 0.49;
        };

        cursor = {
          warp_on_change_workspace = 0;
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
          action = mkLuaInline ''
            function()
              local w = hl.get_active_window()
              if not w or not w.workspace then return end
              local id = tonumber(w.workspace.id) or 1
              local slot = ((id - 1) % 10) + 1
              if slot > 1 and _G.__omarchnix_multiscreen then
                _G.__omarchnix_multiscreen.move_window_to_slot_on(w.monitor or hl.get_active_monitor(), slot - 1, true)
              end
            end
          '';
        }
        {
          fingers = 4;
          direction = "left";
          action = mkLuaInline ''
            function()
              local w = hl.get_active_window()
              if not w or not w.workspace then return end
              local id = tonumber(w.workspace.id) or 1
              local slot = ((id - 1) % 10) + 1
              if slot < 10 and _G.__omarchnix_multiscreen then
                _G.__omarchnix_multiscreen.move_window_to_slot_on(w.monitor or hl.get_active_monitor(), slot + 1, true)
              end
            end
          '';
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
          name = "flea-picker";
          match = {
            class = "^com\\.thisisgm\\.flea\\.picker$";
          };
          float = true;
          center = true;
          size = "720 440";
        }
        {
          name = "hyprland-share-picker";
          match = {
            class = "^hyprland-share-picker$";
          };
          float = true;
          center = true;
          stay_focused = true;
          size = "620 440";
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
            class = "^(notion-calendar|(helium|chrome|brave)-calendar\\.notion\\.so.*)$";
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
            namespace = "^(omarchy-bar|omarchy-dock|omarchy-dock-apps|omarchy-menu|omarchy-notifications|omarchy-polkit|omarchy-reminders|omarchy-clipboard|omarchy-emojis|omarchy-image-selector|omarchy-keyboard-panel|omarchy-network-qr|fuzzel)$";
          };
          blur = true;
          ignore_alpha = 0.05;
        }
        {
          name = "omarchy-osd-layer";
          match = {
            namespace = "^omarchy-osd$";
          };
          blur = true;
          ignore_alpha = 0.05;
          no_anim = true;
          animation = "none";
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
        # Launchers, core apps & workspace back-and-forth use Option (ALT) so Cmd (SUPER) stays free for Orb & apps.
        # Launch on whichever monitor the mouse cursor is currently inside, even over an empty desktop.
        (mkBind "ALT + Return" (focusCursorMonitorAndExec "terminal"))
        (mkBind "ALT + B" (focusCursorMonitorAndExec "browser"))
        (mkBind "ALT + W" (focusCursorMonitorAndExec "fileManager"))
        (mkBind "ALT + O" (focusCursorMonitorAndExec ''"${orb}"''))
        (mkBind "ALT + SPACE" (focusCursorMonitorAndExec "launcher"))
        (mkBind "ALT + SHIFT + SPACE" (focusCursorMonitorAndExec "appLauncher"))
        (mkBind "ALT + TAB" ''
          function()
            local m = hl.get_monitor_at_cursor and hl.get_monitor_at_cursor()
            if m and not m.focused then
              hl.dispatch(hl.dsp.focus({ monitor = m.name }))
            end
            hl.dispatch(hl.dsp.focus({ workspace = "previous_per_monitor" }))
          end
        '')
        (mkBind "ALT + SHIFT + Q" "hl.dsp.window.close()")
        (mkBind "SUPER + SHIFT + Q" "hl.dsp.window.close()")
        (mkBind "CTRL + ALT + SHIFT + Q" "hl.dsp.window.kill()")

        # Cross-screen focus: Cmd + Shift + Right-Shift switches focus & centers cursor on the other monitor
        (mkBindOpts "SUPER + SHIFT + Shift_R" ''
          function()
            if hl.is_key_down and hl.is_key_down("Shift_L") and _G.__omarchnix_multiscreen then
              _G.__omarchnix_multiscreen.focus_other_monitor()
            end
          end
        '' { non_consuming = true; })
        (mkBindOpts "SUPER + SHIFT + Shift_L" ''
          function()
            if hl.is_key_down and hl.is_key_down("Shift_R") and _G.__omarchnix_multiscreen then
              _G.__omarchnix_multiscreen.focus_other_monitor()
            end
          end
        '' { non_consuming = true; })

        # macOS-style universal Copy / Paste / Cut / Select All / Undo / Redo / Find
        (mkBind "SUPER + C" (mkUniversalClipboardBind "CTRL" "C" "CTRL SHIFT" "C"))
        (mkBind "SUPER + V" (mkUniversalClipboardBind "CTRL" "V" "CTRL SHIFT" "V"))
        (mkBind "SUPER + F" (mkUniversalClipboardBind "CTRL" "F" "CTRL SHIFT" "F"))
        (mkBind "SUPER + X" (mkSendShortcutOnce "CTRL" "X"))
        (mkBind "SUPER + A" (mkSendShortcutOnce "CTRL" "A"))
        (mkBind "SUPER + Z" (mkSendShortcutOnce "CTRL" "Z"))
        (mkBind "SUPER + SHIFT + Z" (mkSendShortcutOnce "CTRL SHIFT" "Z"))

        # Window management & positioning uses Option (ALT) — AeroSpace style — so Cmd+<key> never collides with Orb or apps
        (mkBind "ALT + SHIFT + F" ''hl.dsp.window.float({ action = "toggle" })'')
        (mkBind "ALT + V" ''hl.dsp.window.float({ action = "toggle" })'')
        (mkBind "ALT + C" centerShowcaseBind)
        (mkBind "ALT + SHIFT + C" centerShowcaseWideBind)
        (mkBind "ALT + bracketleft" (mkSnapSlotBind "left-half"))
        (mkBind "ALT + bracketright" (mkSnapSlotBind "right-half"))
        (mkBind "ALT + CTRL + bracketleft" (mkSnapSlotBind "left-third"))
        (mkBind "ALT + CTRL + backslash" (mkSnapSlotBind "center-third"))
        (mkBind "ALT + CTRL + bracketright" (mkSnapSlotBind "right-third"))
        (mkBindOpts "ALT + minus" "hl.dsp.window.resize({ x = -100, y = 0, relative = true })" {
          repeating = true;
        })
        (mkBindOpts "ALT + equal" "hl.dsp.window.resize({ x = 100, y = 0, relative = true })" {
          repeating = true;
        })
        (mkBindOpts "ALT + SHIFT + minus" "hl.dsp.window.resize({ x = 0, y = -80, relative = true })" {
          repeating = true;
        })
        (mkBindOpts "ALT + SHIFT + equal" "hl.dsp.window.resize({ x = 0, y = 80, relative = true })" {
          repeating = true;
        })
        (mkBind "ALT + Y" (focusCursorMonitorAndExec (builtins.toJSON windowPopCmd)))
        (mkBind "ALT + backslash" (focusCursorMonitorAndExec (builtins.toJSON workspaceLayoutToggleCmd)))
        (mkBind "ALT + SHIFT + backslash" (
          focusCursorMonitorAndExec (builtins.toJSON workspaceLayoutToggleBackCmd)
        ))
        (mkBind "ALT + SHIFT + D" (focusCursorMonitorAndExec (builtins.toJSON monitorPanelToggleCmd)))
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
        # Laptop lid switch / clamshell handling (standard ACPI + Apple Silicon SMC)
        (mkBindOpts "switch:on:Lid Switch" "hl.dsp.exec_cmd(${builtins.toJSON lidCloseCmd})" {
          locked = true;
        })
        (mkBindOpts "switch:off:Lid Switch" "hl.dsp.exec_cmd(${builtins.toJSON lidClamshellCmd})" {
          locked = true;
        })
        (mkBindOpts "switch:on:Apple SMC power/lid events" "hl.dsp.exec_cmd(${builtins.toJSON lidCloseCmd})"
          {
            locked = true;
          }
        )
        (mkBindOpts "switch:off:Apple SMC power/lid events"
          "hl.dsp.exec_cmd(${builtins.toJSON lidClamshellCmd})"
          {
            locked = true;
          }
        )
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
        # Region screenshot & capture menu (Option + Shift + P, Ctrl + Cmd + Shift + 4/5, and Cmd + Left-Shift + 4/5 via workspaceBinds)
        (mkBind "ALT + SHIFT + P" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "SUPER + SHIFT + P" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "CTRL + SUPER + SHIFT + code:13" "hl.dsp.exec_cmd(${builtins.toJSON "${regionScreenshot}"})")
        (mkBind "CTRL + SUPER + SHIFT + code:14" "hl.dsp.exec_cmd(${builtins.toJSON captureMenuCmd})")
        (mkBind "SUPER + SHIFT + V" (focusCursorMonitorAndExec (builtins.toJSON clipboardCmd)))
        (mkBind "SUPER + CTRL + V" (focusCursorMonitorAndExec (builtins.toJSON clipboardCmd)))
        (mkBind "ALT + SHIFT + I" "hl.dsp.exec_cmd(${builtins.toJSON idleToggleCmd})")
        (mkBind "SUPER + SHIFT + I" "hl.dsp.exec_cmd(${builtins.toJSON idleToggleCmd})")
        (mkBind "ALT + CTRL + T" (focusCursorMonitorAndExec (builtins.toJSON themePickerCmd)))
        (mkBind "ALT + SHIFT + T" ''hl.dsp.exec_cmd("${omarchnixCli} theme toggle")'')

        (mkBind "ALT + mouse_down" ''
          function()
            if _G.__omarchnix_multiscreen then
              _G.__omarchnix_multiscreen.cycle_workspace_at_cursor(-1)
            else
              hl.dispatch(hl.dsp.focus({ workspace = "m-1" }))
            end
          end
        '')
        (mkBind "ALT + mouse_up" ''
          function()
            if _G.__omarchnix_multiscreen then
              _G.__omarchnix_multiscreen.cycle_workspace_at_cursor(1)
            else
              hl.dispatch(hl.dsp.focus({ workspace = "m+1" }))
            end
          end
        '')
        (mkBind "ALT + SHIFT + mouse_down" "hl.dsp.group.prev()")
        (mkBind "ALT + SHIFT + mouse_up" "hl.dsp.group.next()")

        (mkBindOpts "ALT + mouse:272" "hl.dsp.window.drag()" { mouse = true; })
        (mkBindOpts "ALT + mouse:273" "hl.dsp.window.resize()" { mouse = true; })

        (mkBindOpts "XF86MonBrightnessUp" displayBrightnessUpDsp {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "XF86MonBrightnessDown" displayBrightnessDownDsp {
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

        (mkBindOpts "XF86AudioRaiseVolume" audioRaiseDsp {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "XF86AudioLowerVolume" audioLowerDsp {
          locked = true;
          repeating = true;
        })
        # macOS-style fine 1% volume steps with Option (+ Shift) + Volume Up/Down
        (mkBindOpts "ALT + XF86AudioRaiseVolume" "hl.dsp.exec_cmd(${builtins.toJSON audioRaiseFineCmd})" {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "ALT + XF86AudioLowerVolume" "hl.dsp.exec_cmd(${builtins.toJSON audioLowerFineCmd})" {
          locked = true;
          repeating = true;
        })
        (mkBindOpts "ALT + SHIFT + XF86AudioRaiseVolume"
          "hl.dsp.exec_cmd(${builtins.toJSON audioRaiseFineCmd})"
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBindOpts "ALT + SHIFT + XF86AudioLowerVolume"
          "hl.dsp.exec_cmd(${builtins.toJSON audioLowerFineCmd})"
          {
            locked = true;
            repeating = true;
          }
        )
        (mkBindOpts "XF86AudioMute" audioMuteDsp {
          locked = true;
        })
        (mkBindOpts "SHIFT + XF86AudioMute" "hl.dsp.exec_cmd(${builtins.toJSON audioOutputSwitchCmd})" {
          locked = true;
        })
        (mkBindOpts "XF86AudioMicMute" "hl.dsp.exec_cmd(${builtins.toJSON audioMicMuteCmd})" {
          locked = true;
        })
        (mkBindOpts "XF86AudioPlay" mediaPlayPauseDsp {
          locked = true;
        })
        (mkBindOpts "XF86AudioPause" mediaPlayPauseDsp {
          locked = true;
        })
        (mkBindOpts "XF86AudioNext" mediaNextDsp { locked = true; })
        (mkBindOpts "XF86AudioPrev" mediaPrevDsp {
          locked = true;
        })
      ]
      ++ workspaceBinds;
    };
  };

  xdg.configFile."hypr/xdph.conf".text = ''
    screencopy {
      max_fps = 60
      allow_token_by_default = true
    }
  '';

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
