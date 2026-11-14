{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omarchnix;
  mCfg = cfg.macos;
  inherit (lib.generators) mkLuaInline;

  mkBind = keys: dsp: {
    _args = [
      keys
      (mkLuaInline dsp)
    ];
  };

  omarchyLib = import ../lib/omarchy.nix { inherit lib; };

  buildPlugin =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? buildPlugin) then
      pkgs.omarchnix.buildPlugin
    else
      (args: omarchyLib.buildPlugin ({ inherit pkgs; } // args));

  overlayPlugins =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? plugins) then pkgs.omarchnix.plugins else { };

  touchIdMonitorBin =
    pkgs.runCommandCC "omarchnix-touchid-monitor"
      {
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [
          pkgs.glib
          pkgs.json-glib
        ];
      }
      ''
        mkdir -p "$out/bin"
        $CC -O2 -Wall -Wextra \
          "${../pkgs/plugins/touchid/touchid-monitor.c}" \
          $(pkg-config --cflags --libs gio-2.0 gio-unix-2.0 json-glib-1.0) \
          -o "$out/bin/touchid-monitor"
      '';

  missionControlId = "io.github.joaovitor2763.mission-control";
  macosDockId = "th0rgal.macos-dock";
  spotlightId = "th0rgal.spotlight";
  touchIdId = "th0rgal.touchid";
  workspaceWallpapersId = "th0rgal.workspace-wallpapers";
  slantedWorkspacesId = "th0rgal.workspaces";

  missionControlPlugin =
    overlayPlugins.mission-control or (buildPlugin {
      src = ../pkgs/plugins/mission-control;
    });

  macosDockPlugin =
    overlayPlugins.macos-dock or (buildPlugin {
      src = ../pkgs/plugins/macos-dock;
    });

  spotlightPlugin =
    overlayPlugins.spotlight or (buildPlugin {
      src = ../pkgs/plugins/spotlight;
    });

  touchIdPlugin =
    overlayPlugins.touchid or (buildPlugin {
      src = ../pkgs/plugins/touchid;
      postInstall = ''
        rm -f "$out/touchid-monitor.c"
        substituteInPlace "$out/TouchId.qml" \
          --replace-fail '@TOUCHID_MONITOR_BIN@' "${touchIdMonitorBin}/bin/touchid-monitor"
      '';
    });

  workspaceWallpapersPlugin =
    overlayPlugins.workspace-wallpapers or (buildPlugin {
      src = ../pkgs/plugins/workspace-wallpapers;
    });

  slantedWorkspacesPlugin =
    overlayPlugins.workspaces or (buildPlugin {
      src = ../pkgs/plugins/workspaces;
    });

  omarchyShellExe =
    if cfg.shell.package != null then "${cfg.shell.package}/bin/omarchy-shell" else "omarchy-shell";

  mcSummonCmd = "${omarchyShellExe} shell summon ${missionControlId} '{}'";
  mcHideCmd = "${omarchyShellExe} shell hide ${missionControlId}";
  mcToggleCmd = "${omarchyShellExe} shell toggle ${missionControlId} '{}'";
  spotlightToggleCmd = "${omarchyShellExe} shell toggle ${spotlightId} '{}'";
  spotlightAppsCmd = "${omarchyShellExe} shell toggle ${spotlightId} '{\"expand\":true}'";

  focusCursorMonitorBeforeExec = cmd: ''
    function()
      local m = hl.get_monitor_at_cursor and hl.get_monitor_at_cursor()
      if m and not m.focused then
        hl.dispatch(hl.dsp.focus({ monitor = m.name }))
      end
      hl.dispatch(hl.dsp.exec_cmd(${builtins.toJSON cmd}))
    end
  '';

  contiguousSpacesLua = ''
    do
      local SLOTS = 10
      local MAX_BLOCKS = 8
      local state_path = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/omarchnix-spaces-max"
      local blocks_path = (os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")) .. "/omarchy/monitors/workspaces"

      local function block_of(id)
        return math.floor((id - 1) / SLOTS)
      end

      local function slot_of(id)
        return ((id - 1) % SLOTS) + 1
      end

      local function clamp_slots(n)
        local v = math.floor(tonumber(n) or 1)
        if v < 1 then return 1 end
        if v > SLOTS then return SLOTS end
        return v
      end

      local function read_manual_max()
        local map = {}
        local sf = io.open(state_path, "r")
        if not sf then return map end
        local raw = sf:read("*a") or ""
        sf:close()
        local single = tonumber(raw)
        if single then
          map[0] = clamp_slots(single)
          return map
        end
        for line in raw:gmatch("[^\r\n]+") do
          local b, cnt = line:match("^(%d+)%s+(%d+)$")
          if b and cnt then
            map[tonumber(b)] = clamp_slots(cnt)
          end
        end
        return map
      end

      local state = {
        rules = {},
        enabled = {},
        manual_max = read_manual_max(),
        syncing = false,
        reordering = false,
      }

      local function save_manual_max()
        local sf = io.open(state_path, "w")
        if not sf then return end
        local keys = {}
        for b in pairs(state.manual_max) do keys[#keys + 1] = b end
        table.sort(keys)
        for _, b in ipairs(keys) do
          sf:write(string.format("%d %d\n", b, clamp_slots(state.manual_max[b])))
        end
        sf:close()
      end

      local function set_manual_max(block, count)
        state.manual_max[block] = clamp_slots(count)
        save_manual_max()
      end

      local function connector_blocks()
        local by_conn = {}
        local f = io.open(blocks_path, "r")
        if f then
          for line in f:lines() do
            local blk, conn = line:match("^(%d+)\t([^\t]+)\t")
            if blk and conn ~= "" then
              by_conn[conn] = tonumber(blk)
            end
          end
          f:close()
        end
        for _, m in ipairs(hl.get_monitors()) do
          if not m.is_mirror and by_conn[m.name] == nil then
            local aw = m.active_workspace
            if aw and aw.id and aw.id >= 1 and aw.id < 9000 then
              by_conn[m.name] = block_of(aw.id)
            end
          end
        end
        return by_conn
      end

      local function compute_live_slot_max(block, owner_name)
        local max_slot = 1
        local base = block * SLOTS
        for _, ws in ipairs(hl.get_workspaces()) do
          local id = ws.id
          if id and id > base and id <= base + SLOTS and not ws.special then
            if (ws.windows and ws.windows > 0) or ws.active or ws.visible then
              if not owner_name or not ws.monitor or ws.monitor.name == owner_name then
                local sl = slot_of(id)
                if sl > max_slot then max_slot = sl end
              end
            end
          end
        end
        return max_slot
      end

      local function set_rule_enabled(id, mon_name, en)
        if en then
          local cur = state.rules[id]
          if not cur or cur.mon ~= mon_name then
            if cur and cur.handle and state.enabled[id] then
              pcall(function() cur.handle:set_enabled(false) end)
            end
            local spec = {
              workspace = tostring(id),
              persistent = true,
            }
            if mon_name and mon_name ~= "" then
              spec.monitor = mon_name
            end
            state.rules[id] = {
              handle = hl.workspace_rule(spec),
              mon = mon_name,
            }
            state.enabled[id] = true
          elseif not state.enabled[id] or hl.get_workspace(id) == nil then
            cur.handle:set_enabled(true)
            state.enabled[id] = true
          end
        else
          local cur = state.rules[id]
          if cur and cur.handle and state.enabled[id] then
            cur.handle:set_enabled(false)
            state.enabled[id] = false
          end
        end
      end

      function state.sync()
        if state.syncing or state.reordering then return end
        state.syncing = true
        pcall(function()
          local by_conn = connector_blocks()
          local active_blocks = {}
          for conn, blk in pairs(by_conn) do
            if blk >= 0 and blk < MAX_BLOCKS then
              active_blocks[blk] = conn
            end
          end
          if next(active_blocks) == nil then
            active_blocks[0] = ""
          end

          local wanted = {}
          for blk, conn in pairs(active_blocks) do
            local manual = state.manual_max[blk] or 1
            local live = compute_live_slot_max(blk, conn ~= "" and conn or nil)
            local count = clamp_slots(math.max(1, manual, live))
            local base = blk * SLOTS
            for sl = 1, count do
              wanted[base + sl] = conn
            end
          end

          for id, cur in pairs(state.rules) do
            if not wanted[id] and state.enabled[id] then
              set_rule_enabled(id, cur.mon, false)
            end
          end
          for id, conn in pairs(wanted) do
            set_rule_enabled(id, conn, true)
          end
        end)
        state.syncing = false
      end

      function state.add_space(target_id)
        local wanted_id = math.floor(tonumber(target_id) or 0)
        if wanted_id < 1 or wanted_id >= 9000 then
          local am = (hl.get_monitor_at_cursor and hl.get_monitor_at_cursor()) or hl.get_active_monitor()
          local by_conn = connector_blocks()
          local blk = (am and by_conn[am.name]) or 0
          local cur = math.max(state.manual_max[blk] or 1, compute_live_slot_max(blk, am and am.name or nil))
          set_manual_max(blk, math.min(SLOTS, cur + 1))
        else
          local blk = block_of(wanted_id)
          local sl = slot_of(wanted_id)
          set_manual_max(blk, math.max(state.manual_max[blk] or 1, sl))
        end
        state.sync()
      end

      function state.reorder(moves)
        if not moves or #moves == 0 then return end
        state.reordering = true
        pcall(function()
          for id, cur in pairs(state.rules) do
            set_rule_enabled(id, cur.mon, false)
          end
          local items = {}
          local next_tmp = 9001
          for _, m in ipairs(moves) do
            if m[1] ~= m[2] and hl.get_workspace(m[1]) then
              while hl.get_workspace(next_tmp) ~= nil do next_tmp = next_tmp + 1 end
              items[#items + 1] = { from = m[1], to = m[2], tmp = next_tmp }
              next_tmp = next_tmp + 1
            end
          end
          for _, it in ipairs(items) do
            hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(it.from), id = it.tmp }))
          end
          for _, it in ipairs(items) do
            hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(it.tmp), id = it.to }))
          end
        end)
        state.reordering = false
        state.sync()
      end

      function state.close_space(space_id)
        local sid = math.floor(tonumber(space_id) or 0)
        if sid < 1 or sid >= MAX_BLOCKS * SLOTS then return end
        local target_ws = hl.get_workspace(sid)
        if target_ws and target_ws.windows and target_ws.windows > 0 then return end

        local blk = block_of(sid)
        local sl = slot_of(sid)
        local base = blk * SLOTS
        local by_conn = connector_blocks()
        local mon_name = nil
        for conn, b in pairs(by_conn) do
          if b == blk then mon_name = conn break end
        end
        local upper_slot = clamp_slots(math.max(1, state.manual_max[blk] or 1, compute_live_slot_max(blk, mon_name)))
        if upper_slot <= 1 or sl > upper_slot then return end
        local upper_id = base + upper_slot

        state.reordering = true
        pcall(function()
          local mon = mon_name and hl.get_monitor(mon_name) or nil
          local active_on_mon = mon and mon.active_workspace or hl.get_active_workspace()
          if active_on_mon and active_on_mon.id == sid then
            local fallback = sid < upper_id and (sid + 1) or (upper_id - 1)
            if mon and not mon.focused then
              hl.dispatch(hl.dsp.focus({ monitor = mon.name }))
            end
            hl.dispatch(hl.dsp.focus({ workspace = fallback }))
          end
          for id = base + 1, base + SLOTS do
            local cur = state.rules[id]
            if cur then set_rule_enabled(id, cur.mon, false) end
          end
          local items = {}
          local next_tmp = 9001
          for id = sid + 1, upper_id do
            if hl.get_workspace(id) then
              while hl.get_workspace(next_tmp) ~= nil do next_tmp = next_tmp + 1 end
              items[#items + 1] = { from = id, to = id - 1, tmp = next_tmp }
              next_tmp = next_tmp + 1
            end
          end
          for _, it in ipairs(items) do
            hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(it.from), id = it.tmp }))
          end
          for _, it in ipairs(items) do
            hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(it.tmp), id = it.to }))
          end
          set_manual_max(blk, math.max(1, upper_slot - 1))
        end)
        state.reordering = false
        state.sync()
      end

      _G.__omarchnix_spaces = state

      for _, ev in ipairs({
        "hyprland.start",
        "config.reloaded",
        "monitor.added",
        "monitor.removed",
        "workspace.created",
        "workspace.removed",
        "workspace.active",
        "window.open",
        "window.close",
        "window.move_to_workspace",
      }) do
        hl.on(ev, function()
          if ev == "monitor.added" or ev == "monitor.removed" or ev == "hyprland.start" or ev == "config.reloaded" then
            hl.timer(function() state.sync() end, { type = "oneshot", timeout = 20 })
          else
            state.sync()
          end
        end)
      end

      hl.timer(function() state.sync() end, { type = "oneshot", timeout = 20 })
    end
  '';
in
{
  options.programs.omarchnix.macos = {
    enable = lib.mkEnableOption "macOS-style desktop suite (Mission Control, contiguous Spaces, auto-hide Dock, Spotlight, slanted Workspaces, minimal bar, and per-Space preloaded Wallpapers)";

    missionControl = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = mCfg.enable;
        defaultText = lib.literalExpression "config.programs.omarchnix.macos.enable";
        description = "Enable the Mission Control & Spaces overview overlay (`Ctrl+Up`/`Ctrl+Down`).";
      };

      gestures = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Bind 3-finger trackpad swipe up/down to Mission Control when Mission Control is enabled.";
      };

      contiguousSpaces = lib.mkOption {
        type = lib.types.bool;
        default = mCfg.missionControl.enable;
        defaultText = lib.literalExpression "config.programs.omarchnix.macos.missionControl.enable";
        description = "Maintain contiguous macOS-style Spaces `1..N` via lightweight persistent Hyprland Lua workspace rules.";
      };
    };

    dock = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = mCfg.enable;
        defaultText = lib.literalExpression "config.programs.omarchnix.macos.enable";
        description = "Enable the frosted-glass auto-hide bottom Dock (`th0rgal.macos-dock`) and disable upstream `omarchy.dock`.";
      };
    };

    spotlight = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = mCfg.enable;
        defaultText = lib.literalExpression "config.programs.omarchnix.macos.enable";
        description = "Enable the frosted-glass Spotlight launcher (`Cmd+Space` / `Ctrl+Cmd+Space`).";
      };
    };

    slantedWorkspaces = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = mCfg.enable;
        defaultText = lib.literalExpression "config.programs.omarchnix.macos.enable";
        description = "Replace `omarchy.workspaces` with forward-slanted `/` parallelogram workspace chips (`th0rgal.workspaces`).";
      };

      persistentCount = lib.mkOption {
        type = lib.types.ints.between 1 10;
        default = 5;
        description = "Number of contiguous persistent workspace chips (`1..N`) always shown in `th0rgal.workspaces`.";
      };
    };

    minimalBar = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = mCfg.enable;
        defaultText = lib.literalExpression "config.programs.omarchnix.macos.enable";
        description = "Keep the right status bar minimal by moving Appearance into the collapsible tray drawer and hiding the standalone clipboard icon.";
      };
    };

    touchIdHud = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable the macOS-style biometric Touch ID HUD (`th0rgal.touchid` + native C `fprintd` monitor).";
      };
    };

    wallpapers = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = (mCfg.wallpapers.default != null || mCfg.wallpapers.workspaces != { });
        defaultText = lib.literalExpression "default != null || workspaces != {}";
        description = "Enable preloaded zero-latency per-Space wallpapers (`th0rgal.workspace-wallpapers`).";
      };

      default = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Default fallback wallpaper file path written to `~/.config/omarchy/workspace-wallpapers.json`.";
      };

      workspaces = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Per-workspace (`\"1\"`, `\"2\"`, ...) wallpaper file paths written to `~/.config/omarchy/workspace-wallpapers.json`.";
      };
    };
  };

  config = lib.mkIf (cfg.enable && cfg.shell.backend == "omarchy-shell") (
    lib.mkMerge [
      (lib.mkIf mCfg.enable {
        wayland.windowManager.hyprland.extraConfig = lib.mkOrder 200 ''
          local theme_hyprland = (os.getenv("HOME") or "") .. "/.local/state/omarchy/current/theme/hyprland.lua"
          local f = io.open(theme_hyprland, "r")
          if f then
            f:close()
            pcall(dofile, theme_hyprland)
          end
        '';
      })

      (lib.mkIf mCfg.missionControl.enable {
        programs.omarchnix.plugins.locked.${missionControlId} = {
          package = missionControlPlugin;
          enable = true;
        };

        wayland.windowManager.hyprland = {
          extraConfig = lib.mkIf mCfg.missionControl.contiguousSpaces (lib.mkOrder 1100 contiguousSpacesLua);
          settings = {
            layer_rule = lib.mkAfter [
              {
                name = "omarchy-mission-control";
                match.namespace = "^omarchy-mission-control$";
                no_anim = true;
                animation = "none";
              }
            ];

            gesture = lib.mkIf mCfg.missionControl.gestures (
              lib.mkAfter [
                {
                  fingers = 3;
                  direction = "up";
                  scale = 1.5;
                  disable_inhibit = true;
                  action.start = mkLuaInline (focusCursorMonitorBeforeExec mcSummonCmd);
                }
                {
                  fingers = 3;
                  direction = "down";
                  scale = 1.5;
                  disable_inhibit = true;
                  action.start = mkLuaInline "function() hl.dispatch(hl.dsp.exec_cmd(${builtins.toJSON mcHideCmd})) end";
                }
              ]
            );

            bind = lib.mkAfter [
              # Mission Control shortcut (Option + Esc toggles on cursor's screen; Esc inside Mission Control closes)
              (mkBind "ALT + ESCAPE" (focusCursorMonitorBeforeExec mcToggleCmd))
            ];
          };
        };
      })

      (lib.mkIf (mCfg.enable && !mCfg.dock.enable) {
        programs.omarchnix.shell.disabledPlugins = [
          "omarchy.dock"
          "omarchy.dev-gallery"
        ];
      })

      (lib.mkIf mCfg.dock.enable {
        programs.omarchnix.plugins.locked.${macosDockId} = {
          package = macosDockPlugin;
          enable = true;
        };

        programs.omarchnix.shell = {
          disabledPlugins = [
            "omarchy.dock"
            "omarchy.dev-gallery"
          ];
          dock = {
            position = "bottom";
            autohide = true;
            allWorkspaces = true;
          };
        };
      })

      (lib.mkIf mCfg.spotlight.enable {
        programs.omarchnix.plugins.locked.${spotlightId} = {
          package = spotlightPlugin;
          enable = true;
        };

        wayland.windowManager.hyprland.settings = {
          launcher._var = lib.mkForce spotlightToggleCmd;
          appLauncher._var = lib.mkForce spotlightAppsCmd;
          layer_rule = lib.mkAfter [
            {
              name = "omarchnix-spotlight";
              match.namespace = "^omarchnix-spotlight$";
              blur = true;
              ignore_alpha = 0.05;
              no_anim = true;
              animation = "none";
            }
          ];
        };
      })

      (lib.mkIf mCfg.slantedWorkspaces.enable {
        programs.omarchnix.plugins.locked.${slantedWorkspacesId} = {
          package = slantedWorkspacesPlugin;
          enable = true;
          section = "left";
        };

        programs.omarchnix.shell.workspaceWidgetId = slantedWorkspacesId;

        xdg.configFile."omarchy/workspaces.json".text =
          builtins.toJSON {
            persistentCount = mCfg.slantedWorkspaces.persistentCount;
          }
          + "\n";
      })

      (lib.mkIf mCfg.minimalBar.enable {
        programs.omarchnix.plugins.locked = {
          "omarchnix.appearance".section = "tray";
        };

        programs.omarchnix.shell.trayWidgetIds = [
          "omarchnix.appearance"
          "omarchy.agents"
          "omarchy.monitor"
        ];
      })

      (lib.mkIf mCfg.touchIdHud.enable {
        programs.omarchnix.plugins.locked.${touchIdId} = {
          package = touchIdPlugin;
          enable = true;
        };

        wayland.windowManager.hyprland.settings.layer_rule = lib.mkAfter [
          {
            name = "omarchnix-touchid";
            match.namespace = "^omarchnix-touchid$";
            blur = true;
            ignore_alpha = 0.05;
            no_anim = true;
            animation = "none";
          }
        ];
      })

      (lib.mkIf mCfg.wallpapers.enable {
        programs.omarchnix.plugins.locked.${workspaceWallpapersId} = {
          package = workspaceWallpapersPlugin;
          enable = true;
        };

        programs.omarchnix.shell.disabledPlugins = [ "omarchy.background" ];

        xdg.configFile."omarchy/workspace-wallpapers.json".text =
          builtins.toJSON (
            lib.optionalAttrs (mCfg.wallpapers.default != null) {
              default = mCfg.wallpapers.default;
            }
            // {
              workspaces = mCfg.wallpapers.workspaces;
            }
          )
          + "\n";

        services.hyprpaper.enable = lib.mkForce false;
      })
    ]
  );
}
