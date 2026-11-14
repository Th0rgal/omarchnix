# Starship Subtle — Cursor / macOS cool neutral theme family (Dark & Light).
#
# Single source of truth for both variants:
# - Edit `shared` (`ui`, `wallpaper`, `colors`) to update Dark AND Light together.
# - Edit `variants.dark.colors` or `variants.light.colors` to override one mode only.
{
  pkgs,
  lib ? pkgs.lib,
}:
let
  omarchnix = pkgs.omarchnix or { };

  shared = {
    baseName = "starship-subtle";

    ui = {
      gapsIn = 5;
      gapsOut = 10;
      borderSize = 1;
      rounding = 10;
      barHeight = 32;
    };

    # Tokens shared across both Dark and Light unless overridden in `variants`.
    colors = {
      muted = "#8e8e93";
      brown = "#9e8c7a";
    };

    # Subtle ambient radial glow geometry shared by both wallpapers.
    wallpaper = {
      cx = "72%";
      cy = "24%";
      r = "58%";
    };
  };

  variants = {
    dark = {
      slug = shared.baseName; # "starship-subtle"
      wallpaper = {
        accentOpacity = "0.09";
        secondaryOpacity = "0.04";
      };
      colors = {
        mode = "dark";

        # Subtle Cursor/macOS cool silver-slate accent instead of loud amber-orange (#ff9f0a)
        accent = "#c7c7cc";
        selection = "#3a3a3c";

        # 1px neutral specular hairline on dark surfaces
        hyprland_active_border = "rgba(ffffff33)";
        hyprland_inactive_border = "rgba(ffffff10)";

        background = "#1c1c1e";
        dark_background = "#161618";
        darker_background = "#0e0e10";
        lighter_background = "#2c2c2e";

        foreground = "#f5f5f7";
        dark_foreground = "#98989d";
        light_foreground = "#fbfbfd";
        bright_foreground = "#ffffff";

        red = "#ff5f4a";
        yellow = "#e5c07b";
        orange = "#d89b72";
        green = "#8eb897";
        cyan = "#9cc7d8";
        blue = "#8fb8de";
        magenta = "#d89bb0";
        brown = "#b8a99a";

        bright_red = "#ff8373";
        bright_yellow = "#f0d399";
        bright_green = "#add0b5";
        bright_cyan = "#bfdcea";
        bright_blue = "#b5d0ea";
        bright_magenta = "#eab8c8";
      };
    };

    light = {
      slug = "${shared.baseName}-light"; # "starship-subtle-light"
      wallpaper = {
        glowPrimary = "#8fb8de";
        glowSecondary = "#48484a";
        accentOpacity = "0.08";
        secondaryOpacity = "0.03";
      };
      colors = {
        mode = "light";

        # Matching Cursor/macOS cool graphite-slate accent on alabaster surfaces
        accent = "#48484a";
        selection = "#d8d8de";

        # 1px neutral graphite hairline on light surfaces
        hyprland_active_border = "rgba(00000024)";
        hyprland_inactive_border = "rgba(0000000f)";

        background = "#f5f5f7";
        dark_background = "#ececf0";
        darker_background = "#e2e2e7";
        lighter_background = "#ffffff";

        foreground = "#1d1d1f";
        dark_foreground = "#6e6e73";
        light_foreground = "#3a3a3c";
        bright_foreground = "#000000";

        # Same cool desaturated Starship/Cursor hues tuned for crisp contrast on #f5f5f7
        red = "#d93829";
        yellow = "#9e6b14";
        orange = "#b85c28";
        green = "#2f7d46";
        cyan = "#24748a";
        blue = "#2f6599";
        magenta = "#9e4770";

        bright_red = "#e04f42";
        bright_yellow = "#b57d1e";
        bright_green = "#3b8f54";
        bright_cyan = "#2f89a1";
        bright_blue = "#3d78b0";
        bright_magenta = "#b35983";
      };
    };
  };

  renderColorsTomlFallback =
    paletteAttrs:
    lib.concatMapStringsSep "\n" (k: "${k} = ${builtins.toJSON (toString paletteAttrs.${k})}") (
      builtins.attrNames paletteAttrs
    )
    + "\n";

  buildThemeFallback =
    {
      name,
      palette,
      wallpaper,
    }:
    let
      colorsTomlFile = pkgs.writeText "${name}-colors.toml" (renderColorsTomlFallback palette);
      stop0 = wallpaper.stop0 or palette.darker_background;
      stop1 = wallpaper.stop1 or palette.dark_background;
      stop2 = wallpaper.stop2 or palette.background;
      glowPrimary = wallpaper.glowPrimary or palette.accent;
      glowSecondary = wallpaper.glowSecondary or palette.blue;
      wallpaperSvg = pkgs.writeText "${name}-wallpaper.svg" ''
        <svg xmlns="http://www.w3.org/2000/svg" width="2560" height="1664" viewBox="0 0 2560 1664">
          <defs>
            <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0%" stop-color="${stop0}"/>
              <stop offset="55%" stop-color="${stop1}"/>
              <stop offset="100%" stop-color="${stop2}"/>
            </linearGradient>
            <radialGradient id="glow" cx="${wallpaper.cx}" cy="${wallpaper.cy}" r="${wallpaper.r}">
              <stop offset="0%" stop-color="${glowPrimary}" stop-opacity="${wallpaper.accentOpacity}"/>
              <stop offset="50%" stop-color="${glowSecondary}" stop-opacity="${wallpaper.secondaryOpacity}"/>
              <stop offset="100%" stop-color="${stop0}" stop-opacity="0"/>
            </radialGradient>
          </defs>
          <rect width="2560" height="1664" fill="url(#bg)"/>
          <rect width="2560" height="1664" fill="url(#glow)"/>
        </svg>
      '';
    in
    pkgs.runCommand "omarchy-theme-${name}"
      {
        nativeBuildInputs = [ pkgs.librsvg ];
      }
      ''
        mkdir -p "$out/backgrounds"
        cp "${colorsTomlFile}" "$out/colors.toml"
        rsvg-convert -f png -o "$out/backgrounds/1-${name}.png" "${wallpaperSvg}"
        rsvg-convert -w 960 -h 600 -f png -o "$out/preview.png" "${wallpaperSvg}"
      '';

  # Cursor/macOS-style Balanced Readable Glass overrides for Omarchy Shell surfaces.
  # Design invariants:
  # 1. `surfaceAlpha` (~0.45 dark / ~0.48 light; 0.58 on compact tooltips) matches the
  #    frosted blur aesthetic of Status Bar / Dock / Spotlight while keeping dense
  #    multi-line text (Clipboard, Audio/Network panels, Notifications) effortless to read.
  # 2. `scrim-alpha = 0.0` (< Hyprland `ignore_alpha = 0.05`) ensures fullscreen
  #    `OverlayWindow` surfaces (Clipboard, Menu, Emojis, Polkit) skip blurring outside
  #    the card bounding box — keeping the surrounding desktop sharp and avoiding
  #    fullscreen Kawase blur GPU cost.
  # 3. Qt Quick `Rectangle.border` replaces outer pixel alpha directly rather than
  #    compositing over `color`, and `polkit`/`lock` share `border-alpha` with
  #    `border-error`. Pre-mixing ~18% `foreground` onto `background` (`#434346` dark /
  #    `#cfcfd3` light) at `border-alpha = 0.55` (`0.65` on `polkit`/`lock`) keeps the
  #    1px border well above `ignore_alpha = 0.05` (no unblurred halo) and keeps
  #    `border-error` vibrant.
  mkShellSectionOverrides =
    palette:
    let
      isLight = (palette.mode or "dark") == "light";
      surfaceAlpha = if isLight then "0.48" else "0.45";
      cardAlpha = "0.48";
      tooltipAlpha = "0.58";
      borderColor = if isLight then "#cfcfd3" else "#434346";
      borderActiveColor = if isLight then "#a8a8ae" else "#5c5c62";
      borderAlpha = "0.55";
      authBorderAlpha = "0.65";
      selectedBgAlpha = if isLight then "0.10" else "0.12";
      selectedBorderAlpha = "0.12";
      bg = builtins.toJSON palette.background;
      fg = builtins.toJSON palette.foreground;
      muted = builtins.toJSON palette.muted;
      accent = builtins.toJSON palette.accent;
      red = builtins.toJSON palette.red;
      border = builtins.toJSON borderColor;
      borderActive = builtins.toJSON borderActiveColor;
    in
    {
      notifications = ''
        background       = ${bg}
        background-alpha = ${cardAlpha}
        text             = ${fg}
        border           = ${border}
        border-alpha     = ${borderAlpha}
        border-width     = 1
        countdown        = ${muted}
      '';

      popups = ''
        background       = ${bg}
        background-alpha = ${surfaceAlpha}
        text             = ${fg}
        border           = ${border}
        border-alpha     = ${borderAlpha}
        border-width     = 1
      '';

      tooltip = ''
        background       = ${bg}
        background-alpha = ${tooltipAlpha}
        text             = ${fg}
        border           = ${border}
        border-alpha     = ${borderAlpha}
        border-width     = 1
      '';

      menu = ''
        background                = ${bg}
        background-alpha          = ${surfaceAlpha}
        text                      = ${fg}
        border                    = ${border}
        border-alpha              = ${borderAlpha}
        border-width              = 1
        scrim                     = "#000000"
        scrim-alpha               = 0.0
        selected-background       = ${fg}
        selected-background-alpha = ${selectedBgAlpha}
        selected-text             = ${fg}
        selected-border           = ${fg}
        selected-border-alpha     = ${selectedBorderAlpha}
      '';

      launcher = ''
        background                = ${bg}
        background-alpha          = ${surfaceAlpha}
        text                      = ${fg}
        border                    = ${border}
        border-alpha              = ${borderAlpha}
        border-width              = 1
        scrim                     = "#000000"
        scrim-alpha               = 0.0
        selected-background       = ${fg}
        selected-background-alpha = ${selectedBgAlpha}
        selected-text             = ${fg}
        selected-border           = ${fg}
        selected-border-alpha     = ${selectedBorderAlpha}
      '';

      polkit = ''
        background       = ${bg}
        background-alpha = ${cardAlpha}
        text             = ${fg}
        text-error       = ${red}
        border           = ${border}
        border-error     = ${red}
        border-alpha     = ${authBorderAlpha}
        border-width     = 1
        scrim            = "#000000"
        scrim-alpha      = 0.0
        accent           = ${accent}
      '';

      lock = ''
        background       = ${bg}
        background-alpha = ${cardAlpha}
        text             = ${fg}
        placeholder      = ${muted}
        text-error       = ${red}
        border           = ${border}
        border-active    = ${borderActive}
        border-error     = ${red}
        border-alpha     = ${authBorderAlpha}
        border-width     = 1
        selection        = ${accent}
        selection-alpha  = 0.35
      '';

      controls = ''
        normal-color              = ${fg}
        normal-fill-alpha         = 0.04
        normal-border             = ${fg}
        normal-border-width       = 1
        normal-border-alpha       = 0.12
        hover-cursor-color        = ${fg}
        hover-cursor-fill-alpha   = 0.08
        hover-cursor-border       = ${fg}
        hover-cursor-border-width = 1
        hover-cursor-border-alpha = 0.20
        focus-color               = ${fg}
        focus-fill-alpha          = 0.08
        focus-border              = ${fg}
        focus-border-width        = 1
        focus-border-alpha        = 0.22
        selected-color            = ${fg}
        selected-fill-alpha       = 0.14
        selected-border           = ${fg}
        selected-border-width     = 1
        selected-border-alpha     = 0.16
        pressed-fill-alpha        = 0.18
        selection-fill-alpha      = 0.30
      '';
    };

  mkVariant =
    variantCfg:
    let
      name = variantCfg.slug;
      palette = shared.colors // variantCfg.colors;
      wallpaper = shared.wallpaper // (variantCfg.wallpaper or { });
      shellSections = mkShellSectionOverrides palette;
      basePackage =
        if omarchnix ? buildTheme then
          omarchnix.buildTheme {
            inherit name palette wallpaper;
          }
        else
          buildThemeFallback {
            inherit name palette wallpaper;
          };
      package =
        pkgs.runCommand "omarchy-theme-${name}"
          {
            passthru = basePackage.passthru or { };
          }
          (
            ''
              mkdir -p "$out"
              cp -r --no-preserve=mode,ownership "${basePackage}/." "$out/"
            ''
            + lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                section: content:
                let
                  sectionFile = pkgs.writeText "${name}-shell.${section}.toml" content;
                in
                ''cp "${sectionFile}" "$out/shell.${section}.toml"''
              ) shellSections
            )
            + "\n"
          );
      attrset =
        if omarchnix ? buildTheme then
          omarchnix.importTheme {
            inherit name palette;
            inherit (shared) ui;
          }
        else if omarchnix ? importTheme then
          (omarchnix.importTheme package)
          // {
            inherit name;
            inherit (shared) ui;
          }
        else
          null;
    in
    {
      inherit
        name
        palette
        attrset
        package
        ;
    };
in
{
  inherit shared;
  dark = mkVariant variants.dark;
  light = mkVariant variants.light;
}
