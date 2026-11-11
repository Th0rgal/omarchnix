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

  contiguousSpacesLua = ''
    do
      local MAX_SPACES = 32
      local state_path = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/omarchnix-spaces-max"

      local function read_manual_max()
        local sf = io.open(state_path, "r")
        if not sf then return 1 end
        local raw = sf:read("*a")
        sf:close()
        local n = tonumber(raw)
        if not n or n < 1 then return 1 end
        return math.min(MAX_SPACES, math.floor(n))
      end

      local state = {
        rules = {},
        enabled = {},
        max_rule_id = 0,
        manual_max = read_manual_max(),
        syncing = false,
        reordering = false,
      }

      local function write_manual_max(n)
        local clamped = math.max(1, math.min(MAX_SPACES, math.floor(tonumber(n) or 1)))
        state.manual_max = clamped
        local sf = io.open(state_path, "w")
        if sf then
          sf:write(tostring(clamped))
          sf:close()
        end
      end

      local function compute_live_max()
        local max_id = 1
        for _, ws in ipairs(hl.get_workspaces()) do
          local id = ws.id
          if id and id >= 1 and id <= MAX_SPACES and not ws.special then
            if (ws.windows and ws.windows > 0) or ws.active or ws.visible then
              if id > max_id then
                max_id = id
              end
            end
          end
        end
        return max_id
      end

      local function set_rule_enabled(id, en)
        if en then
          if not state.rules[id] then
            state.rules[id] = hl.workspace_rule({
              workspace = tostring(id),
              persistent = true,
            })
            state.enabled[id] = true
            if id > state.max_rule_id then
              state.max_rule_id = id
            end
          elseif not state.enabled[id] or hl.get_workspace(id) == nil then
            state.rules[id]:set_enabled(true)
            state.enabled[id] = true
          end
        else
          if state.rules[id] and state.enabled[id] then
            state.rules[id]:set_enabled(false)
            state.enabled[id] = false
          end
        end
      end

      function state.sync()
        if state.syncing or state.reordering then return end
        state.syncing = true
        pcall(function()
          local target = math.min(MAX_SPACES, math.max(1, state.manual_max, compute_live_max()))
          for id = 1, target do
            set_rule_enabled(id, true)
          end
          for id = target + 1, state.max_rule_id do
            set_rule_enabled(id, false)
          end
        end)
        state.syncing = false
      end

      function state.add_space(target_id)
        local cur = math.max(state.manual_max, compute_live_max())
        local wanted = tonumber(target_id) or (cur + 1)
        write_manual_max(math.max(state.manual_max, wanted))
        state.sync()
      end

      function state.reorder(moves)
        if not moves or #moves == 0 then return end
        state.reordering = true
        pcall(function()
          for id = 1, state.max_rule_id do
            set_rule_enabled(id, false)
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
        if sid < 1 or sid > MAX_SPACES then return end
        local target_ws = hl.get_workspace(sid)
        if target_ws and target_ws.windows and target_ws.windows > 0 then return end
        local upper = math.min(MAX_SPACES, math.max(1, state.manual_max, compute_live_max()))
        if upper <= 1 or sid > upper then return end

        state.reordering = true
        pcall(function()
          local active_ws = hl.get_active_workspace()
          if active_ws and active_ws.id == sid then
            local fallback = sid < upper and (sid + 1) or (upper - 1)
            hl.dispatch(hl.dsp.focus({ workspace = fallback }))
          end
          for id = 1, state.max_rule_id do
            set_rule_enabled(id, false)
          end
          local items = {}
          local next_tmp = 9001
          for id = sid + 1, upper do
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
          write_manual_max(math.max(1, upper - 1))
        end)
        state.reordering = false
        state.sync()
      end

      _G.__omarchnix_spaces = state

      for _, ev in ipairs({
        "workspace.created",
        "workspace.removed",
        "workspace.active",
        "window.open",
        "window.close",
        "window.move_to_workspace",
      }) do
        hl.on(ev, function() state.sync() end)
      end

      state.sync()
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
        wayland.windowManager.hyprland.extraConfig = lib.mkBefore ''
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
          extraConfig = lib.mkIf mCfg.missionControl.contiguousSpaces contiguousSpacesLua;
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
                  action.start = mkLuaInline "function() hl.dispatch(hl.dsp.exec_cmd(${builtins.toJSON mcSummonCmd})) end";
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
              (mkBind "CTRL + up" "hl.dsp.exec_cmd(${builtins.toJSON mcToggleCmd})")
              (mkBind "CTRL + down" "hl.dsp.exec_cmd(${builtins.toJSON mcHideCmd})")
            ];
          };
        };
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
              ignore_alpha = 0.15;
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
      })

      (lib.mkIf mCfg.minimalBar.enable {
        programs.omarchnix.plugins.locked = {
          "omarchnix.clipboard".enable = false;
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
            ignore_alpha = 0.15;
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
