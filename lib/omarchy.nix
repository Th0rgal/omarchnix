{
  lib,
  omarchySrc ? null,
}:
let
  normalizeThemeName =
    raw:
    let
      lowered = lib.toLower (lib.trim raw);
    in
    builtins.replaceStrings [ " " "_" ] [ "-" "-" ] lowered;

  hexCharVal =
    ch:
    let
      c = lib.toLower ch;
      table = {
        "0" = 0;
        "1" = 1;
        "2" = 2;
        "3" = 3;
        "4" = 4;
        "5" = 5;
        "6" = 6;
        "7" = 7;
        "8" = 8;
        "9" = 9;
        "a" = 10;
        "b" = 11;
        "c" = 12;
        "d" = 13;
        "e" = 14;
        "f" = 15;
      };
    in
    table.${c} or (throw "lib.omarchy: invalid hex digit '${ch}'");

  hexPairToInt =
    hex: offset:
    (hexCharVal (builtins.substring offset 1 hex)) * 16
    + (hexCharVal (builtins.substring (offset + 1) 1 hex));

  intToHex2 =
    n:
    let
      clamped =
        if n < 0 then
          0
        else if n > 255 then
          255
        else
          n;
      digits = [
        "0"
        "1"
        "2"
        "3"
        "4"
        "5"
        "6"
        "7"
        "8"
        "9"
        "a"
        "b"
        "c"
        "d"
        "e"
        "f"
      ];
      hi = clamped / 16;
      lo = clamped - (hi * 16);
    in
    "${builtins.elemAt digits hi}${builtins.elemAt digits lo}";

  stripHash =
    s:
    let
      trimmed = lib.trim (toString s);
    in
    lib.toLower (lib.removePrefix "#" trimmed);

  isHex6 = s: builtins.match "#?[0-9A-Fa-f]{6}" (lib.trim (toString s)) != null;

  ensureHashHex =
    s:
    let
      stripped = stripHash s;
    in
    if builtins.stringLength stripped >= 6 then
      "#${builtins.substring 0 6 stripped}"
    else
      "#${stripped}";

  hexToRgb =
    hex:
    let
      h = stripHash hex;
      r = hexPairToInt h 0;
      g = hexPairToInt h 2;
      b = hexPairToInt h 4;
    in
    "${toString r}, ${toString g}, ${toString b}";

  hexToRgbCompact =
    hex:
    let
      h = stripHash hex;
      r = hexPairToInt h 0;
      g = hexPairToInt h 2;
      b = hexPairToInt h 4;
    in
    "${toString r},${toString g},${toString b}";

  mixHex =
    startHex: endHex: pct:
    let
      s = stripHash startHex;
      e = stripHash endHex;
      sr = hexPairToInt s 0;
      sg = hexPairToInt s 2;
      sb = hexPairToInt s 4;
      er = hexPairToInt e 0;
      eg = hexPairToInt e 2;
      eb = hexPairToInt e 4;
      blend = a: b: (a * (100 - pct) + b * pct + 50) / 100;
    in
    "#${intToHex2 (blend sr er)}${intToHex2 (blend sg eg)}${intToHex2 (blend sb eb)}";

  resolvePalette =
    rawAttrs: themeDir:
    let
      raw = lib.mapAttrs (_: v: toString v) rawAttrs;
      pick =
        keys: default:
        let
          found = lib.findFirst (k: (raw.${k} or "") != "") null keys;
        in
        if found != null then raw.${found} else default;

      background = ensureHashHex (pick [ "background" "bg" "color0" ] "#1a1b26");
      foreground = ensureHashHex (pick [ "foreground" "fg" "color7" ] "#a9b1d6");

      red = ensureHashHex (pick [ "red" "color1" ] "#f7768e");
      green = ensureHashHex (pick [ "green" "color2" ] "#9ece6a");
      yellow = ensureHashHex (pick [ "yellow" "color3" ] "#e0af68");
      blue = ensureHashHex (pick [ "blue" "color4" ] "#7aa2f7");
      magenta = ensureHashHex (pick [ "magenta" "purple" "color5" ] "#ad8ee6");
      cyan = ensureHashHex (pick [ "cyan" "color6" ] "#449dab");

      accent = ensureHashHex (pick [ "accent" ] blue);

      light_foreground = ensureHashHex (pick [ "light_foreground" "light_fg" "color7" ] foreground);
      bright_foreground = ensureHashHex (pick [ "bright_foreground" "bright_fg" "color15" ] foreground);
      cursor = ensureHashHex (pick [ "cursor" ] bright_foreground);
      lighter_background = ensureHashHex (pick [ "lighter_background" "lighter_bg" "color0" ] background);
      dark_foreground = ensureHashHex (pick [ "dark_foreground" "dark_fg" "color8" ] foreground);
      muted = ensureHashHex (pick [ "muted" "color8" ] dark_foreground);
      selection = ensureHashHex (
        pick [ "selection" "selection_background" "color8" "color0" ] background
      );
      selection_background = ensureHashHex (pick [ "selection_background" ] selection);
      selection_foreground = ensureHashHex (pick [ "selection_foreground" ] bright_foreground);
      orange = ensureHashHex (pick [ "orange" ] yellow);
      brown = if (raw.brown or "") != "" then ensureHashHex raw.brown else mixHex orange "#000000" 50;

      dark_background =
        let
          explicit = pick [ "dark_background" "dark_bg" ] "";
        in
        if explicit != "" then ensureHashHex explicit else mixHex background "#000000" 25;

      darker_background =
        let
          explicit = pick [ "darker_background" "darker_bg" ] "";
        in
        if explicit != "" then ensureHashHex explicit else mixHex background "#000000" 50;

      bright_red =
        let
          explicit = pick [ "bright_red" "color9" ] "";
        in
        if explicit != "" then ensureHashHex explicit else mixHex red "#ffffff" 20;

      bright_green =
        let
          explicit = pick [ "bright_green" "color10" ] "";
        in
        if explicit != "" then ensureHashHex explicit else mixHex green "#ffffff" 20;

      bright_yellow =
        let
          explicit = pick [ "bright_yellow" "color11" ] "";
        in
        if explicit != "" then ensureHashHex explicit else mixHex yellow "#ffffff" 20;

      bright_blue =
        let
          explicit = pick [ "bright_blue" "color12" ] "";
        in
        if explicit != "" then ensureHashHex explicit else mixHex blue "#ffffff" 20;

      bright_magenta =
        let
          explicit = pick [ "bright_magenta" "bright_purple" "color13" ] "";
        in
        if explicit != "" then ensureHashHex explicit else mixHex magenta "#ffffff" 20;

      bright_cyan =
        let
          explicit = pick [ "bright_cyan" "color14" ] "";
        in
        if explicit != "" then ensureHashHex explicit else mixHex cyan "#ffffff" 20;

      bgHex = stripHash background;
      bgLuminance = (hexPairToInt bgHex 0) + (hexPairToInt bgHex 2) + (hexPairToInt bgHex 4);
      detectedMode =
        let
          explicit = lib.toLower (pick [ "mode" "theme_type" ] "");
        in
        if explicit == "light" || explicit == "dark" then
          explicit
        else if themeDir != null && builtins.pathExists (themeDir + "/light.mode") then
          "light"
        else if bgLuminance > 382 then
          "light"
        else
          "dark";
    in
    raw
    // {
      mode = detectedMode;
      theme_type = detectedMode;
      inherit
        accent
        background
        dark_background
        darker_background
        lighter_background
        foreground
        dark_foreground
        light_foreground
        bright_foreground
        cursor
        muted
        selection
        selection_background
        selection_foreground
        red
        orange
        yellow
        green
        cyan
        blue
        magenta
        brown
        bright_red
        bright_yellow
        bright_green
        bright_cyan
        bright_blue
        bright_magenta
        ;
      purple = ensureHashHex (pick [ "purple" ] magenta);
      bright_purple = ensureHashHex (pick [ "bright_purple" ] bright_magenta);
      bg = background;
      dark_bg = dark_background;
      darker_bg = darker_background;
      lighter_bg = lighter_background;
      fg = foreground;
      dark_fg = dark_foreground;
      light_fg = light_foreground;
      bright_fg = bright_foreground;
      color0 = background;
      color1 = red;
      color2 = green;
      color3 = yellow;
      color4 = blue;
      color5 = magenta;
      color6 = cyan;
      color7 = foreground;
      color8 = muted;
      color9 = bright_red;
      color10 = bright_green;
      color11 = bright_yellow;
      color12 = bright_blue;
      color13 = bright_magenta;
      color14 = bright_cyan;
      color15 = bright_foreground;
    };

  mkThemeAttrset =
    {
      name,
      rawPalette,
      sourceDir ? null,
      pkgs ? null,
      ui ? { },
      fonts ? { },
    }:
    let
      palette = resolvePalette rawPalette sourceDir;
      bgHex = stripHash palette.background;
      surfaceHex = stripHash (
        if palette.mode == "light" then
          mixHex palette.background palette.foreground 8
        else if palette.lighter_background != palette.background then
          palette.lighter_background
        else
          mixHex palette.background palette.foreground 10
      );
      bgAltHex = stripHash palette.dark_background;
      defaultSerifPkg =
        if pkgs == null then
          null
        else if pkgs ? michelangelus-font then
          pkgs.michelangelus-font
        else if (pkgs ? omarchnix) && (pkgs.omarchnix ? michelangelus-font) then
          pkgs.omarchnix.michelangelus-font
        else
          pkgs.callPackage ../pkgs/michelangelus-font.nix { };
    in
    {
      inherit name palette sourceDir;
      mode = palette.mode;

      fonts = lib.recursiveUpdate {
        sans = {
          name = "IBM Plex Sans";
          package = if pkgs != null then pkgs.ibm-plex else null;
          size = 9;
        };
        serif = {
          name = "Michelangelus";
          package = defaultSerifPkg;
          size = 10;
        };
        mono = {
          name = "Lilex Nerd Font";
          package = if pkgs != null then pkgs.nerd-fonts.lilex else null;
          size = 11;
        };
        icon = {
          name = "Font Awesome 7 Free";
          package = if pkgs != null then pkgs.font-awesome else null;
        };
      } fonts;

      cursor = {
        name = "Bibata-Modern-Classic";
        package = if pkgs != null then pkgs.bibata-cursors else null;
        size = 24;
      };

      ui = {
        gapsIn = 5;
        gapsOut = 10;
        borderSize = 2;
        rounding = 10;
        barHeight = 32;
      }
      // ui;

      colors = {
        bg = bgHex;
        bgRgb = hexToRgb palette.background;
        bgRgbCompact = hexToRgbCompact palette.background;
        bgAlt = bgAltHex;
        surface = surfaceHex;
        border = stripHash palette.muted;
        fg = stripHash palette.foreground;
        fgBright = stripHash palette.bright_foreground;
        fgMuted = stripHash palette.dark_foreground;
        selection = stripHash palette.selection;
        accent = stripHash palette.accent;
        accentAlt = stripHash palette.bright_cyan;
        urgent = stripHash palette.red;
        warning = stripHash palette.yellow;
        success = stripHash palette.green;
        magenta = stripHash palette.magenta;
        cyan = stripHash palette.cyan;
        blue = stripHash palette.blue;
        orange = stripHash palette.orange;
      };
    };

  importThemeFromPalette =
    {
      name,
      palette,
      pkgs ? null,
      ui ? { },
      fonts ? { },
    }:
    mkThemeAttrset {
      name = normalizeThemeName name;
      rawPalette = palette;
      inherit pkgs ui fonts;
    };

  importThemeFromDir =
    {
      name,
      dir,
      pkgs ? null,
      ui ? { },
      fonts ? { },
    }:
    let
      colorsFile = dir + "/colors.toml";
      _ =
        if !(builtins.pathExists colorsFile) then
          throw "lib.omarchy.importTheme: missing colors.toml in '${toString dir}' (theme '${name}')"
        else
          true;
      rawPalette = builtins.fromTOML (builtins.readFile colorsFile);
    in
    assert _;
    mkThemeAttrset {
      inherit
        name
        rawPalette
        pkgs
        ui
        fonts
        ;
      sourceDir = dir;
    };

  renderColorsToml =
    paletteAttrs:
    let
      orderedKeys = [
        "mode"
        "accent"
        "selection"
        "muted"
        "hyprland_active_border"
        "hyprland_inactive_border"
        "background"
        "dark_background"
        "darker_background"
        "lighter_background"
        "foreground"
        "dark_foreground"
        "light_foreground"
        "bright_foreground"
        "red"
        "yellow"
        "orange"
        "green"
        "cyan"
        "blue"
        "magenta"
        "brown"
        "bright_red"
        "bright_yellow"
        "bright_green"
        "bright_cyan"
        "bright_blue"
        "bright_magenta"
      ];
      extraKeys = lib.filter (k: !(builtins.elem k orderedKeys)) (builtins.attrNames paletteAttrs);
      presentOrdered = lib.filter (k: paletteAttrs ? ${k} && paletteAttrs.${k} != null) orderedKeys;
      presentExtra = lib.filter (k: paletteAttrs.${k} != null) extraKeys;
      allKeys = presentOrdered ++ presentExtra;
    in
    lib.concatMapStringsSep "\n" (k: "${k} = ${builtins.toJSON (toString paletteAttrs.${k})}") allKeys
    + "\n";

  buildThemePkg =
    {
      pkgs,
      name,
      palette,
      wallpaper ? { },
    }:
    let
      slug = normalizeThemeName name;
      resolved = resolvePalette palette null;
      colorsTomlText = renderColorsToml palette;
      colorsTomlFile = pkgs.writeText "${slug}-colors.toml" colorsTomlText;

      stop0 = wallpaper.stop0 or resolved.darker_background;
      stop1 = wallpaper.stop1 or resolved.dark_background;
      stop2 = wallpaper.stop2 or resolved.background;
      glowPrimary = wallpaper.glowPrimary or resolved.accent;
      glowSecondary = wallpaper.glowSecondary or resolved.blue;
      glowPrimaryOpacity = toString (wallpaper.accentOpacity or "0.09");
      glowSecondaryOpacity = toString (wallpaper.secondaryOpacity or "0.04");
      cx = wallpaper.cx or "72%";
      cy = wallpaper.cy or "24%";
      r = wallpaper.r or "58%";

      wallpaperSvg = pkgs.writeText "${slug}-wallpaper.svg" ''
        <svg xmlns="http://www.w3.org/2000/svg" width="2560" height="1664" viewBox="0 0 2560 1664">
          <defs>
            <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0%" stop-color="${stop0}"/>
              <stop offset="55%" stop-color="${stop1}"/>
              <stop offset="100%" stop-color="${stop2}"/>
            </linearGradient>
            <radialGradient id="glow" cx="${cx}" cy="${cy}" r="${r}">
              <stop offset="0%" stop-color="${glowPrimary}" stop-opacity="${glowPrimaryOpacity}"/>
              <stop offset="50%" stop-color="${glowSecondary}" stop-opacity="${glowSecondaryOpacity}"/>
              <stop offset="100%" stop-color="${stop0}" stop-opacity="0"/>
            </radialGradient>
          </defs>
          <rect width="2560" height="1664" fill="url(#bg)"/>
          <rect width="2560" height="1664" fill="url(#glow)"/>
        </svg>
      '';
    in
    pkgs.runCommand "omarchy-theme-${slug}"
      {
        nativeBuildInputs = [ pkgs.librsvg ];
        passthru = {
          themeName = slug;
          themeMode = resolved.mode;
        };
      }
      ''
        mkdir -p "$out/backgrounds"
        cp "${colorsTomlFile}" "$out/colors.toml"
        rsvg-convert -f png -o "$out/backgrounds/1-${slug}.png" "${wallpaperSvg}"
        rsvg-convert -w 960 -h 600 -f png -o "$out/preview.png" "${wallpaperSvg}"
      '';

  bundledThemeDirs =
    if omarchySrc == null then
      { }
    else
      let
        themesRoot = omarchySrc + "/themes";
        entries = builtins.readDir themesRoot;
      in
      lib.mapAttrs (themeName: _: themesRoot + "/${themeName}") (
        lib.filterAttrs (
          themeName: kind:
          kind == "directory" && builtins.pathExists (themesRoot + "/${themeName}/colors.toml")
        ) entries
      );

  themeNames = builtins.attrNames bundledThemeDirs;

  importTheme =
    {
      theme ? null,
      name ? null,
      palette ? null,
      ui ? { },
      fonts ? { },
      pkgs ? null,
      themesSrc ? omarchySrc,
    }:
    if palette != null then
      importThemeFromPalette {
        name =
          if name != null then
            name
          else if builtins.isString theme then
            theme
          else
            throw "lib.omarchy.importTheme: 'name' is required when importing from 'palette'";
        inherit
          palette
          pkgs
          ui
          fonts
          ;
      }
    else if builtins.isPath theme || (builtins.isAttrs theme && theme ? outPath) then
      importThemeFromDir {
        name = if name != null then normalizeThemeName name else builtins.baseNameOf (toString theme);
        dir = theme;
        inherit pkgs ui fonts;
      }
    else if builtins.isString theme then
      let
        normalized = normalizeThemeName theme;
        themesRoot =
          if themesSrc != null then
            themesSrc + "/themes"
          else
            throw "lib.omarchy.importTheme: themesSrc is null while looking up named theme '${theme}'";
        candidateDir = themesRoot + "/${normalized}";
      in
      if builtins.pathExists (candidateDir + "/colors.toml") then
        importThemeFromDir {
          name = normalized;
          dir = candidateDir;
          inherit pkgs ui fonts;
        }
      else
        throw "lib.omarchy.importTheme: unknown Omarchy theme '${theme}' (normalized '${normalized}'). Available bundled themes: ${lib.concatStringsSep ", " themeNames}"
    else
      throw "lib.omarchy.importTheme: pass 'theme' (name or directory path) or '{ name, palette }'";

  allBundledThemes =
    pkgs:
    lib.mapAttrs (
      themeName: dir:
      importThemeFromDir {
        name = themeName;
        inherit dir pkgs;
      }
    ) bundledThemeDirs;

  validatePluginManifest =
    manifestPath:
    let
      raw = builtins.fromJSON (builtins.readFile manifestPath);
      schemaVersion = raw.schemaVersion or null;
      id = raw.id or "";
      name = raw.name or "";
      version = raw.version or "";
      kinds = raw.kinds or [ ];
      entryPoints = raw.entryPoints or null;
      validSections = [
        "left"
        "centerBegin"
        "center"
        "centerEnd"
        "tray"
        "right"
      ];
      defaultSection =
        if (raw ? barWidget) && builtins.isAttrs raw.barWidget && (raw.barWidget ? defaultSection) then
          raw.barWidget.defaultSection
        else
          null;
      kindEntryMap = {
        bar = "bar";
        "bar-widget" = "barWidget";
        menu = "menu";
        overlay = "overlay";
        panel = "panel";
        service = "service";
      };
      missingEntryPoints = lib.filter (
        kind:
        let
          epKey = kindEntryMap.${kind} or null;
        in
        epKey != null && !(entryPoints ? ${epKey})
      ) kinds;
      unsafeEntryPoints = lib.filter (
        ep:
        !(builtins.isString ep)
        || ep == ""
        || lib.hasPrefix "/" ep
        || lib.hasInfix ".." ep
        || lib.hasInfix "\n" ep
      ) (builtins.attrValues entryPoints);
    in
    if !(builtins.isInt schemaVersion && schemaVersion == 1) then
      throw "lib.omarchy.buildPlugin: unsupported schemaVersion in ${toString manifestPath} (expected integer 1)"
    else if
      !(
        builtins.isString id
        && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" id != null
        && !(lib.hasInfix ".." id)
      )
    then
      throw "lib.omarchy.buildPlugin: invalid plugin id '${toString id}' in ${toString manifestPath}"
    else if lib.hasPrefix "omarchy." id then
      throw "lib.omarchy.buildPlugin: plugin id '${id}' uses reserved first-party 'omarchy.*' namespace"
    else if !(builtins.isString name && name != "" && builtins.isString version && version != "") then
      throw "lib.omarchy.buildPlugin: missing name or version in ${toString manifestPath}"
    else if !(builtins.isList kinds && kinds != [ ]) then
      throw "lib.omarchy.buildPlugin: 'kinds' must be a non-empty list in ${toString manifestPath}"
    else if !(builtins.isAttrs entryPoints) then
      throw "lib.omarchy.buildPlugin: 'entryPoints' must be an attribute set in ${toString manifestPath}"
    else if defaultSection != null && !(builtins.elem defaultSection validSections) then
      throw "lib.omarchy.buildPlugin: invalid barWidget.defaultSection '${toString defaultSection}' in ${toString manifestPath}"
    else if missingEntryPoints != [ ] then
      throw "lib.omarchy.buildPlugin: kinds [${lib.concatStringsSep ", " missingEntryPoints}] missing required entryPoints in ${toString manifestPath}"
    else if unsafeEntryPoints != [ ] then
      throw "lib.omarchy.buildPlugin: unsafe entryPoint path(s) in ${toString manifestPath}"
    else
      raw;

  buildPlugin =
    {
      pkgs,
      src,
      subdir ? "",
    }:
    let
      pluginSrc = if subdir == "" then src else "${src}/${subdir}";
      manifestPath = "${pluginSrc}/manifest.json";
      manifest = validatePluginManifest manifestPath;
      missingFiles = lib.filter (ep: !(builtins.pathExists "${pluginSrc}/${ep}")) (
        builtins.attrValues manifest.entryPoints
      );
      scanNoSymlinks =
        dir: relPrefix:
        let
          entries = builtins.readDir dir;
        in
        lib.concatMap (
          name:
          let
            kind = entries.${name};
            relPath = if relPrefix == "" then name else "${relPrefix}/${name}";
            childPath = dir + "/${name}";
          in
          if name == ".git" then
            [ ]
          else if kind == "symlink" then
            [ relPath ]
          else if kind == "directory" then
            scanNoSymlinks childPath relPath
          else
            [ ]
        ) (builtins.attrNames entries);
      foundSymlinks = scanNoSymlinks pluginSrc "";
      _ =
        if missingFiles != [ ] then
          throw "lib.omarchy.buildPlugin (${manifest.id}): missing entryPoint file(s): ${lib.concatStringsSep ", " missingFiles}"
        else if foundSymlinks != [ ] then
          throw "lib.omarchy.buildPlugin (${manifest.id}): symlinks are forbidden inside Omarchy plugins: ${lib.concatStringsSep ", " foundSymlinks}"
        else
          true;
    in
    assert _;
    pkgs.runCommand "omarchy-plugin-${manifest.id}-${manifest.version}"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.findutils
        ];
        passthru = {
          pluginId = manifest.id;
          pluginManifest = manifest;
        };
      }
      ''
        mkdir -p "$out"
        cp -r --no-preserve=mode "${pluginSrc}/." "$out/"
        rm -rf "$out/.git"

        link="$(find "$out" -type l -print -quit)"
        if [ -n "$link" ]; then
          echo "lib.omarchy.buildPlugin: symlinks are forbidden inside Omarchy plugins: $link" >&2
          exit 1
        fi

        jq -e '.schemaVersion == 1' "$out/manifest.json" >/dev/null
      '';
in
{
  inherit
    normalizeThemeName
    isHex6
    hexToRgb
    mixHex
    resolvePalette
    importTheme
    importThemeFromDir
    importThemeFromPalette
    renderColorsToml
    buildThemePkg
    themeNames
    bundledThemeDirs
    allBundledThemes
    validatePluginManifest
    buildPlugin
    ;
}
