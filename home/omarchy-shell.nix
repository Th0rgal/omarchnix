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
    in
    assert _;
    {
      inherit id drv manifest;
      enable = pluginCfg.enable;
      section = pluginCfg.section;
    }
  ) cfg.plugins.locked;

  enabledBarWidgetsBySection =
    sectionName:
    lib.concatMap (
      entry:
      let
        isBarWidget =
          builtins.elem "bar-widget" (entry.manifest.kinds or [ ])
          && !(builtins.elem "bar" (entry.manifest.kinds or [ ]));
        manifestDefault =
          if
            (entry.manifest ? barWidget)
            && builtins.isAttrs entry.manifest.barWidget
            && (entry.manifest.barWidget ? defaultSection)
          then
            let
              raw = entry.manifest.barWidget.defaultSection;
            in
            if raw == "center" then "centerEnd" else raw
          else
            "centerEnd";
        effectiveSection = if entry.section != null then entry.section else manifestDefault;
      in
      if entry.enable && isBarWidget && effectiveSection == sectionName then
        [ { id = entry.id; } ]
      else
        [ ]
    ) lockedPluginEntries;

  enabledNonBarPlugins = lib.concatMap (
    entry:
    let
      isBarOrWidget =
        builtins.elem "bar" (entry.manifest.kinds or [ ])
        || builtins.elem "bar-widget" (entry.manifest.kinds or [ ]);
    in
    if entry.enable && !isBarOrWidget then [ { id = entry.id; } ] else [ ]
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

  baseLayout = {
    left = [
      { id = "omarchy.menu"; }
      { id = "omarchy.workspaces"; }
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
      { id = "omarchy.elsewhen"; }
      { id = "omarchy.weather"; }
    ];
    tray = [ ];
    right = [
      { id = "omarchy.tray"; }
      {
        id = "omarchy.indicators";
        items = [ "StayAwake" ];
        alwaysShow = true;
      }
      { id = "omarchy.keyboard-layout"; }
      { id = "omarchy.agents"; }
      { id = "omarchy.bluetooth"; }
      { id = "omarchy.network"; }
      { id = "omarchy.audio"; }
      { id = "omarchy.monitor"; }
      { id = "omarchy.power"; }
    ];
  };

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
        right = appendUniqueById baseLayout.right (enabledBarWidgetsBySection "right");
      };
    }
    // lib.optionalAttrs (selectedBarOverride != null) {
      id = selectedBarOverride;
    };
    plugins = appendUniqueById [ ] enabledNonBarPlugins;
  }
  // cfg.shell.extraSettings;

  defaultShellJson = pkgs.writeText "omarchnix-shell.json" (builtins.toJSON mergedShellConfig + "\n");

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
    programs.omarchnix.plugins.locked."omarchnix.clipboard" = {
      package = lib.mkDefault clipboardBarPlugin;
      enable = lib.mkDefault true;
      section = lib.mkDefault "right";
    };

    home.sessionVariables = {
      OMARCHY_PATH = "${omarchyShellPkg.sharePath}";
    };

    home.packages = [
      omarchyShellPkg
      pkgs.nerd-fonts.jetbrains-mono
    ]
    ++ lib.optional (cfg.cliPackage != null) cfg.cliPackage;

    home.activation.omarchnixStateAndPlugins = hmLib.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/.config/omarchy/plugins" "$HOME/.local/state/omarchy/current"

      ${lib.concatMapStringsSep "\n" (entry: ''
        target_plugin_dir="$HOME/.config/omarchy/plugins/${lib.escapeShellArg entry.id}"
        rm -rf "$target_plugin_dir"
        mkdir -p "$target_plugin_dir"
        cp -r --no-preserve=mode "${entry.drv}/." "$target_plugin_dir/"
        chmod -R u+w "$target_plugin_dir"
        "${omarchyShellPkg}/bin/omarchy-plugin-validate" "$target_plugin_dir" >/dev/null
      '') lockedPluginEntries}

      if [ ! -f "$HOME/.config/omarchy/shell.json" ] || [ -L "$HOME/.config/omarchy/shell.json" ]; then
        rm -f "$HOME/.config/omarchy/shell.json"
        cp --no-preserve=mode "${defaultShellJson}" "$HOME/.config/omarchy/shell.json"
        chmod 0644 "$HOME/.config/omarchy/shell.json"
      else
        tmp_json="$(mktemp "$HOME/.config/omarchy/shell.json.XXXXXX")"
        ${pkgs.jq}/bin/jq '.version = 1 | .bar.background = (.bar.background // "glassy") | del(.bar.transparent)' \
          "$HOME/.config/omarchy/shell.json" > "$tmp_json" && mv "$tmp_json" "$HOME/.config/omarchy/shell.json"
        ${lib.concatMapStringsSep "\n" (
          entry:
          lib.optionalString entry.enable (
            let
              isBarWidget =
                builtins.elem "bar-widget" (entry.manifest.kinds or [ ])
                && !(builtins.elem "bar" (entry.manifest.kinds or [ ]));
              section =
                if entry.section != null then
                  entry.section
                else if
                  (entry.manifest ? barWidget)
                  && builtins.isAttrs entry.manifest.barWidget
                  && (entry.manifest.barWidget ? defaultSection)
                then
                  (
                    if entry.manifest.barWidget.defaultSection == "center" then
                      "centerEnd"
                    else
                      entry.manifest.barWidget.defaultSection
                  )
                else
                  "centerEnd";
            in
            if isBarWidget then
              ''
                tmp_json="$(mktemp "$HOME/.config/omarchy/shell.json.XXXXXX")"
                ${pkgs.jq}/bin/jq --arg id ${lib.escapeShellArg entry.id} --arg sec ${lib.escapeShellArg section} '
                  .version = 1
                  | .bar.layout[$sec] = (
                      (.bar.layout[$sec] // [])
                      | if any(.[]; .id == $id) then . else . + [{ id: $id }] end
                    )
                ' "$HOME/.config/omarchy/shell.json" > "$tmp_json" && mv "$tmp_json" "$HOME/.config/omarchy/shell.json"
              ''
            else
              ''
                tmp_json="$(mktemp "$HOME/.config/omarchy/shell.json.XXXXXX")"
                ${pkgs.jq}/bin/jq --arg id ${lib.escapeShellArg entry.id} '
                  .version = 1
                  | .plugins = (
                      [(.plugins // [])[] | if type == "string" then { id: . } else . end]
                      | if any(.[]; .id == $id) then . else . + [{ id: $id }] end
                    )
                ' "$HOME/.config/omarchy/shell.json" > "$tmp_json" && mv "$tmp_json" "$HOME/.config/omarchy/shell.json"
              ''
          )
        ) lockedPluginEntries}
      fi

      if [ ! -e "$HOME/.local/state/omarchy/current/background" ] || [ -L "$HOME/.local/state/omarchy/current/background" ]; then
        ln -sfn "${wallpaperPng}" "$HOME/.local/state/omarchy/current/background"
      fi

      if [ ! -f "$HOME/.local/state/omarchy/current/theme/colors.toml" ]; then
        OMARCHY_PATH="${omarchyShellPkg.sharePath}" \
        OMARCHY_THEME_OFFLINE=1 \
        OMARCHY_THEME_SKIP_BACKGROUND=1 \
          "${omarchyShellPkg}/bin/omarchy-theme-set" ${lib.escapeShellArg theme.name} >/dev/null 2>&1 || true
      fi
    '';

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
