{
  config,
  lib,
  pkgs,
  theme,
  ...
}:
let
  cfg = config.programs.omarchnix;
  hmLib = config.lib.dag;
  omarchyShellPkg = cfg.shell.package;
  omarchyLib = import ../lib/omarchy.nix { inherit lib; };

  clipboardBarPlugin = omarchyLib.buildPlugin {
    inherit pkgs;
    src = ../pkgs/plugins/omarchnix-clipboard;
  };

  appearanceBarPlugin = omarchyLib.buildPlugin {
    inherit pkgs;
    src = ../pkgs/plugins/omarchnix-appearance;
    postInstall = lib.optionalString (cfg.cliPackage != null) ''
      substituteInPlace "$out/Widget.qml" \
        --replace-fail '"omarchnix theme toggle"' '"${cfg.cliPackage}/bin/omarchnix theme toggle"'
    '';
  };

  themeSetHookScript =
    if cfg.cliPackage != null then
      pkgs.writeShellScript "omarchnix-theme-set-hook" ''
        if [ "''${OMARCHNIX_SYNCING_MODE:-0}" != "1" ]; then
          "${cfg.cliPackage}/bin/omarchnix" theme sync-mode >/dev/null 2>&1 || true
        fi
      ''
    else
      null;

  effectiveDarkTheme = omarchyLib.normalizeThemeName (
    if cfg.theme.darkName != null then
      cfg.theme.darkName
    else if (theme.mode or "dark") == "dark" then
      cfg.theme.name
    else
      "tokyo-night"
  );

  effectiveLightTheme = omarchyLib.normalizeThemeName (
    if cfg.theme.lightName != null then
      cfg.theme.lightName
    else if (theme.mode or "dark") == "light" then
      cfg.theme.name
    else
      "white"
  );

  themePairJson = pkgs.writeText "omarchnix-theme-pair.json" (
    builtins.toJSON {
      dark = effectiveDarkTheme;
      light = effectiveLightTheme;
    }
    + "\n"
  );

  customThemeEntries = lib.mapAttrsToList (slug: drv: {
    slug = omarchyLib.normalizeThemeName slug;
    inherit drv;
  }) cfg.theme.customThemes;

  lockedPluginEntries = lib.mapAttrsToList (
    id: pluginCfg:
    let
      drv = pluginCfg.package;
      manifest =
        if drv ? pluginManifest then
          drv.pluginManifest
        else
          builtins.fromJSON (builtins.readFile "${drv}/manifest.json");
      _ =
        if (manifest.id or "") != id then
          throw "programs.omarchnix.plugins.locked.'${id}': manifest.json id '${manifest.id or ""}' does not match attribute key '${id}'"
        else
          true;
      isBarWidget =
        builtins.elem "bar-widget" (manifest.kinds or [ ])
        && !(builtins.elem "bar" (manifest.kinds or [ ]));
      hasNonBarKind = lib.any (k: k != "bar" && k != "bar-widget") (manifest.kinds or [ ]);
      manifestDefaultSection =
        if
          (manifest ? barWidget)
          && builtins.isAttrs manifest.barWidget
          && (manifest.barWidget ? defaultSection)
        then
          let
            raw = manifest.barWidget.defaultSection;
          in
          if raw == "center" then "centerEnd" else raw
        else
          "centerEnd";
      effectiveSection = if pluginCfg.section != null then pluginCfg.section else manifestDefaultSection;
    in
    assert _;
    {
      inherit
        id
        drv
        manifest
        isBarWidget
        hasNonBarKind
        effectiveSection
        ;
      enable = pluginCfg.enable;
    }
  ) cfg.plugins.locked;

  enabledBarWidgetsBySection =
    sectionName:
    lib.concatMap (
      entry:
      if entry.enable && entry.isBarWidget && entry.effectiveSection == sectionName then
        [ { id = entry.id; } ]
      else
        [ ]
    ) lockedPluginEntries;

  enabledNonBarPlugins = lib.concatMap (
    entry: if entry.enable && entry.hasNonBarKind then [ { id = entry.id; } ] else [ ]
  ) lockedPluginEntries;

  selectedBarOverride =
    let
      barEntries = lib.filter (
        entry: entry.enable && builtins.elem "bar" (entry.manifest.kinds or [ ])
      ) lockedPluginEntries;
    in
    if barEntries == [ ] then null else (builtins.head barEntries).id;

  appendUniqueById =
    baseList: extraList:
    let
      existingIds = map (item: item.id or "") baseList;
      filteredExtra = lib.filter (item: !(builtins.elem item.id existingIds)) extraList;
    in
    baseList ++ filteredExtra;

  effectiveTrayIds = lib.unique cfg.shell.trayWidgetIds;
  effectiveDisabledPlugins = lib.unique cfg.shell.disabledPlugins;
  effectivePurgedIds = lib.unique cfg.shell.purgedPluginIds;

  elsewhenSeedEntry = {
    id = "omarchy.elsewhen";
  }
  // lib.optionalAttrs (cfg.shell.elsewhenCities != [ ]) {
    cities = cfg.shell.elsewhenCities;
  };

  baseLayout = {
    left = [
      { id = "omarchy.menu"; }
      { id = cfg.shell.workspaceWidgetId; }
    ];
    centerBegin = [
      { id = "omarchy.indicators"; }
    ];
    center = [
      {
        id = "omarchy.clock";
        format = "dddd HH:mm";
        formatAlt = "d MMMM 'W'ww yyyy";
      }
    ];
    centerEnd = [
      elsewhenSeedEntry
      { id = "omarchy.weather"; }
    ];
    tray = map (id: { inherit id; }) effectiveTrayIds;
    right = [
      { id = "omarchy.tray"; }
      { id = "omarchy.keyboard-layout"; }
      { id = "omarchy.bluetooth"; }
      { id = "omarchy.network"; }
      { id = "omarchy.audio"; }
      { id = "omarchy.power"; }
    ];
  };

  mergedRightLayout =
    let
      pluginRight = lib.filter (item: !(builtins.elem item.id effectiveTrayIds)) (
        enabledBarWidgetsBySection "right"
      );
      coreRight = [
        { id = "omarchy.keyboard-layout"; }
        { id = "omarchy.bluetooth"; }
        { id = "omarchy.network"; }
        { id = "omarchy.audio"; }
        { id = "omarchy.power"; }
      ];
    in
    appendUniqueById ([ { id = "omarchy.tray"; } ] ++ pluginRight) coreRight;

  mergedShellConfig = {
    version = 1;
    idle = {
      screensaver = 150;
      lock = 300;
    };
    bar = {
      position = "top";
      background = "glassy";
      layout = {
        left = appendUniqueById baseLayout.left (enabledBarWidgetsBySection "left");
        centerBegin = appendUniqueById baseLayout.centerBegin (enabledBarWidgetsBySection "centerBegin");
        center = appendUniqueById baseLayout.center (enabledBarWidgetsBySection "center");
        centerEnd = appendUniqueById baseLayout.centerEnd (enabledBarWidgetsBySection "centerEnd");
        tray = appendUniqueById baseLayout.tray (enabledBarWidgetsBySection "tray");
        right = mergedRightLayout;
      };
    }
    // lib.optionalAttrs (selectedBarOverride != null) {
      id = selectedBarOverride;
    };
    plugins = appendUniqueById [ ] enabledNonBarPlugins;
  }
  // lib.optionalAttrs (effectiveDisabledPlugins != [ ]) {
    disabledPlugins = effectiveDisabledPlugins;
  }
  // lib.optionalAttrs (cfg.shell.dock != null) {
    dock = cfg.shell.dock;
  }
  // cfg.shell.extraSettings;

  defaultShellJson = pkgs.writeText "omarchnix-shell.json" (builtins.toJSON mergedShellConfig + "\n");

  # Single-pass declarative spec reconciled atomically into `~/.config/omarchy/shell.json`,
  # preserving runtime user customizations (like World Clock cities) while converging
  # Nix-owned plugins, workspace widget, tray widgets, disabled builtins, and dock defaults.
  reconcileSpecJson = pkgs.writeText "omarchnix-shell-reconcile-spec.json" (
    builtins.toJSON {
      workspaceWidgetId = cfg.shell.workspaceWidgetId;
      trayWidgetIds = effectiveTrayIds;
      disabledPlugins = effectiveDisabledPlugins;
      purgedIds = effectivePurgedIds;
      dock = cfg.shell.dock;
      elsewhenCities = cfg.shell.elsewhenCities;
      lockedPlugins = map (entry: {
        inherit (entry)
          id
          enable
          isBarWidget
          hasNonBarKind
          effectiveSection
          ;
      }) lockedPluginEntries;
    }
    + "\n"
  );

  reconcileShellScript = pkgs.writeText "reconcile-omarchy-shell-json.py" ''
    import json
    import pathlib
    import sys
    import tempfile

    shell_path = pathlib.Path(sys.argv[1])
    default_path = pathlib.Path(sys.argv[2])
    spec = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))

    if not shell_path.is_file() or shell_path.is_symlink():
        if shell_path.is_symlink() or shell_path.exists():
            shell_path.unlink()
        data = json.loads(default_path.read_text(encoding="utf-8"))
    else:
        try:
            data = json.loads(shell_path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                data = json.loads(default_path.read_text(encoding="utf-8"))
        except Exception:
            data = json.loads(default_path.read_text(encoding="utf-8"))

    def item_id(entry):
        if isinstance(entry, str):
            return entry
        if isinstance(entry, dict):
            return str(entry.get("id") or "")
        return ""

    def norm_item(entry):
        if isinstance(entry, str):
            return {"id": entry}
        if isinstance(entry, dict):
            return dict(entry)
        return None

    def dedup_items(items):
        out = []
        seen = set()
        for raw in items or []:
            it = norm_item(raw)
            if not it:
                continue
            iid = item_id(it)
            if not iid or iid in seen:
                continue
            seen.add(iid)
            out.append(it)
        return out

    data["version"] = 1
    bar = data.setdefault("bar", {})
    bar["background"] = bar.get("background") or "glassy"
    bar.pop("transparent", None)
    layout = bar.setdefault("layout", {})
    for sec in ("left", "centerBegin", "center", "centerEnd", "tray", "right"):
        layout[sec] = dedup_items(layout.get(sec) or [])

    plugins = dedup_items(data.get("plugins") or [])

    purged = set(spec.get("purgedIds") or [])
    for lp in spec.get("lockedPlugins") or []:
        if not lp.get("enable"):
            purged.add(lp["id"])

    if purged:
        for sec in list(layout.keys()):
            layout[sec] = [it for it in layout[sec] if item_id(it) not in purged]
        plugins = [it for it in plugins if item_id(it) not in purged]

    ws_id = spec.get("workspaceWidgetId") or "omarchy.workspaces"
    if ws_id != "omarchy.workspaces":
        replaced = []
        for it in layout.get("left", []):
            if item_id(it) == "omarchy.workspaces":
                replaced.append({"id": ws_id})
            else:
                replaced.append(it)
        layout["left"] = dedup_items(replaced)
        if not any(item_id(it) == ws_id for it in layout["left"]):
            layout["left"].append({"id": ws_id})

    for lp in spec.get("lockedPlugins") or []:
        if not lp.get("enable"):
            continue
        pid = lp["id"]
        if lp.get("isBarWidget"):
            target_sec = lp["effectiveSection"]
            for sec in list(layout.keys()):
                if sec != target_sec:
                    layout[sec] = [it for it in layout[sec] if item_id(it) != pid]
            cur = layout.setdefault(target_sec, [])
            if not any(item_id(it) == pid for it in cur):
                if target_sec == "right":
                    bt_idx = next(
                        (i for i, it in enumerate(cur) if item_id(it) == "omarchy.bluetooth"),
                        None,
                    )
                    if bt_idx is not None:
                        cur.insert(bt_idx, {"id": pid})
                    else:
                        cur.append({"id": pid})
                else:
                    cur.append({"id": pid})
        if lp.get("hasNonBarKind"):
            if not any(item_id(it) == pid for it in plugins):
                plugins.append({"id": pid})

    tray_ids = spec.get("trayWidgetIds") or []
    if tray_ids:
        tray_set = set(tray_ids)
        layout["right"] = [
            it
            for it in layout.get("right", [])
            if item_id(it) not in tray_set and item_id(it) != "omarchy.indicators"
        ]
        cur_tray = layout.setdefault("tray", [])
        for tid in tray_ids:
            if tid not in purged and not any(item_id(it) == tid for it in cur_tray):
                cur_tray.append({"id": tid})

    seed_cities = spec.get("elsewhenCities") or []
    if seed_cities:
        for it in layout.get("centerEnd", []):
            if item_id(it) == "omarchy.elsewhen" and not it.get("cities"):
                it["cities"] = seed_cities

    disabled = list(data.get("disabledPlugins") or [])
    for did in spec.get("disabledPlugins") or []:
        if did not in disabled:
            disabled.append(did)
    if disabled:
        data["disabledPlugins"] = disabled

    dock_spec = spec.get("dock")
    if isinstance(dock_spec, dict):
        cur_dock = data.get("dock")
        if not isinstance(cur_dock, dict):
            cur_dock = {}
        for k, v in dock_spec.items():
            cur_dock.setdefault(k, v)
        data["dock"] = cur_dock

    data["plugins"] = plugins

    shell_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=str(shell_path.parent),
        prefix="shell.json.",
        delete=False,
    ) as tf:
        json.dump(data, tf, indent=2, ensure_ascii=False)
        tf.write("\n")
        tmp_name = tf.name
    pathlib.Path(tmp_name).chmod(0o644)
    pathlib.Path(tmp_name).replace(shell_path)
  '';

  wallpaperSvg = pkgs.writeText "omarchnix-wallpaper-${theme.name}.svg" ''
    <svg xmlns="http://www.w3.org/2000/svg" width="2560" height="1664" viewBox="0 0 2560 1664">
      <defs>
        <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#${theme.colors.bg}"/>
          <stop offset="55%" stop-color="#${theme.colors.bgAlt}"/>
          <stop offset="100%" stop-color="#${theme.colors.surface}"/>
        </linearGradient>
        <radialGradient id="glow" cx="72%" cy="28%" r="55%">
          <stop offset="0%" stop-color="#${theme.colors.accent}" stop-opacity="0.55"/>
          <stop offset="45%" stop-color="#${theme.colors.accentAlt}" stop-opacity="0.28"/>
          <stop offset="100%" stop-color="#${theme.colors.bg}" stop-opacity="0"/>
        </radialGradient>
        <radialGradient id="glow2" cx="18%" cy="82%" r="45%">
          <stop offset="0%" stop-color="#${theme.colors.accentAlt}" stop-opacity="0.40"/>
          <stop offset="100%" stop-color="#${theme.colors.bg}" stop-opacity="0"/>
        </radialGradient>
      </defs>
      <rect width="2560" height="1664" fill="url(#bg)"/>
      <rect width="2560" height="1664" fill="url(#glow)"/>
      <rect width="2560" height="1664" fill="url(#glow2)"/>
    </svg>
  '';

  wallpaperPng =
    pkgs.runCommand "omarchnix-wallpaper-${theme.name}.png"
      {
        nativeBuildInputs = [ pkgs.librsvg ];
      }
      ''
        rsvg-convert -f png -o "$out" "${wallpaperSvg}"
      '';
in
{
  config = lib.mkIf (cfg.enable && omarchyShellPkg != null) {
    programs.omarchnix.plugins.locked = {
      "omarchnix.appearance" = {
        package = lib.mkDefault appearanceBarPlugin;
        enable = lib.mkDefault true;
        section = lib.mkDefault "right";
      };
      "omarchnix.clipboard" = {
        package = lib.mkDefault clipboardBarPlugin;
        enable = lib.mkDefault true;
        section = lib.mkDefault "right";
      };
    };

    home.sessionVariables = {
      OMARCHY_PATH = "${omarchyShellPkg.sharePath}";
      OMARCHY_MENU_FONT = theme.fonts.sans.name;
    };

    home.packages = [
      omarchyShellPkg
    ]
    ++ lib.optional (theme.fonts.mono.package != null) theme.fonts.mono.package
    ++ lib.optional (theme.fonts.sans.package != null) theme.fonts.sans.package
    ++ lib.optional (cfg.cliPackage != null) cfg.cliPackage;

    home.activation.omarchnixStateAndPlugins = hmLib.entryAfter [ "writeBoundary" "dconfSettings" ] ''
      mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy/plugins" "$HOME/.config/omarchy/themes" "$HOME/.local/state/omarchy/current"

      if [ -f "${omarchyShellPkg.sharePath}/config/hypr/hyprsunset.conf" ] && { [ ! -f "$HOME/.config/hypr/hyprsunset.conf" ] || [ -L "$HOME/.config/hypr/hyprsunset.conf" ]; }; then
        rm -f "$HOME/.config/hypr/hyprsunset.conf"
        cp --no-preserve=mode "${omarchyShellPkg.sharePath}/config/hypr/hyprsunset.conf" "$HOME/.config/hypr/hyprsunset.conf"
        chmod 0644 "$HOME/.config/hypr/hyprsunset.conf"
      fi

      ${lib.concatMapStringsSep "\n" (entry: ''
        target_theme_dir="$HOME/.config/omarchy/themes/${lib.escapeShellArg entry.slug}"
        rm -rf "$target_theme_dir"
        mkdir -p "$target_theme_dir"
        cp -r --no-preserve=ownership "${entry.drv}/." "$target_theme_dir/"
        chmod -R u+w "$target_theme_dir"
      '') customThemeEntries}

      cp --remove-destination --no-preserve=mode "${themePairJson}" "$HOME/.config/omarchy/theme-pair.json"
      chmod 0644 "$HOME/.config/omarchy/theme-pair.json"
      if ! cmp -s "$HOME/.config/omarchy/theme-pair.json" "$HOME/.local/state/omarchy/configured-theme-pair.json" 2>/dev/null; then
        printf '%s\n' ${lib.escapeShellArg effectiveDarkTheme} > "$HOME/.local/state/omarchy/last-dark-theme"
        printf '%s\n' ${lib.escapeShellArg effectiveLightTheme} > "$HOME/.local/state/omarchy/last-light-theme"
        cp --remove-destination --no-preserve=mode "${themePairJson}" "$HOME/.local/state/omarchy/configured-theme-pair.json"
      fi

      ${lib.concatMapStringsSep "\n" (entry: ''
        rm -rf "$HOME/.config/omarchy/plugins/${lib.escapeShellArg entry}"
      '') effectivePurgedIds}

      ${lib.concatMapStringsSep "\n" (entry: ''
        target_plugin_dir="$HOME/.config/omarchy/plugins/${lib.escapeShellArg entry.id}"
        rm -rf "$target_plugin_dir"
        ${lib.optionalString entry.enable ''
          mkdir -p "$target_plugin_dir"
          cp -r --no-preserve=ownership "${entry.drv}/." "$target_plugin_dir/"
          chmod -R u+w "$target_plugin_dir"
          "${omarchyShellPkg}/bin/omarchy-plugin-validate" "$target_plugin_dir" >/dev/null
        ''}
      '') lockedPluginEntries}

      "${pkgs.python3}/bin/python3" "${reconcileShellScript}" \
        "$HOME/.config/omarchy/shell.json" \
        "${defaultShellJson}" \
        "${reconcileSpecJson}"

      if [ ! -e "$HOME/.local/state/omarchy/current/background" ]; then
        custom_bg="$(find "$HOME/.config/omarchy/themes/${theme.name}/backgrounds" -maxdepth 1 -type f 2>/dev/null | sort | head -n 1 || true)"
        if [ -n "$custom_bg" ]; then
          ln -sfn "$custom_bg" "$HOME/.local/state/omarchy/current/background"
        else
          ln -sfn "${wallpaperPng}" "$HOME/.local/state/omarchy/current/background"
        fi
      fi

      if [ ! -f "$HOME/.local/state/omarchy/current/theme/colors.toml" ]; then
        OMARCHNIX_SYNCING_MODE=1 \
        OMARCHY_PATH="${omarchyShellPkg.sharePath}" \
        OMARCHY_THEME_OFFLINE=1 \
        OMARCHY_THEME_SKIP_BACKGROUND=1 \
          "${omarchyShellPkg}/bin/omarchy-theme-set" ${lib.escapeShellArg theme.name} >/dev/null 2>&1 || true
      else
        cur_slug="$(tr -d '\n' < "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true)"
        if [ -n "$cur_slug" ] && [ -d "$HOME/.config/omarchy/themes/$cur_slug" ]; then
          OMARCHNIX_SYNCING_MODE=1 \
          OMARCHY_PATH="${omarchyShellPkg.sharePath}" \
          OMARCHY_THEME_OFFLINE=1 \
          OMARCHY_THEME_SKIP_BACKGROUND=1 \
            "${omarchyShellPkg}/bin/omarchy-theme-set" "$cur_slug" >/dev/null 2>&1 || true
        fi
      fi

      ${lib.optionalString (cfg.cliPackage != null && themeSetHookScript != null) ''
        mkdir -p "$HOME/.config/omarchy/hooks"
        cp --remove-destination --no-preserve=mode "${themeSetHookScript}" "$HOME/.config/omarchy/hooks/theme-set"
        chmod 0755 "$HOME/.config/omarchy/hooks/theme-set"

        "${cfg.cliPackage}/bin/omarchnix" theme sync-mode --force-signal >/dev/null 2>&1 || true
      ''}
    '';

    systemd.user.services.omarchnix-portal-theme-sync =
      lib.mkIf (cfg.shell.backend == "omarchy-shell" && cfg.cliPackage != null)
        {
          Unit = {
            Description = "Eagerly start GTK Settings portal and sync active Omarchy Dark/Light mode";
            PartOf = [ "graphical-session.target" ];
            Wants = [
              "xdg-desktop-portal.service"
              "xdg-desktop-portal-gtk.service"
            ];
            After = [
              "graphical-session.target"
              "xdg-desktop-portal.service"
              "xdg-desktop-portal-gtk.service"
            ];
            ConditionEnvironment = "WAYLAND_DISPLAY";
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${cfg.cliPackage}/bin/omarchnix theme sync-mode --force-signal";
          };
          Install = {
            WantedBy = [
              "graphical-session.target"
              "xdg-desktop-portal.service"
              "xdg-desktop-portal-gtk.service"
            ];
          };
        };

    systemd.user.services.omarchy-shell = lib.mkIf (cfg.shell.backend == "omarchy-shell") {
      Unit = {
        Description = "Omarchy Quickshell desktop bar, panels, notifications, and plugin host";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        Type = "simple";
        Environment = [
          "OMARCHY_PATH=${omarchyShellPkg.sharePath}"
          "\"OMARCHY_MENU_FONT=${theme.fonts.sans.name}\""
          "GI_TYPELIB_PATH=${pkgs.glib.out}/lib/girepository-1.0"
          "QT_PLUGIN_PATH=${pkgs.qt6.qtimageformats}/lib/qt-6/plugins"
          "QT_QPA_PLATFORMTHEME=xdgdesktopportal"
        ];
        ExecStart = "${omarchyShellPkg}/bin/omarchy-launch-shell";
        Restart = "on-failure";
        RestartSec = 1;
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
