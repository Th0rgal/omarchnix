{
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}:
let
  cfg = config.programs.omarchnix;
  omarchySrc =
    if cfg.omarchySrc != null then
      cfg.omarchySrc
    else if inputs ? omarchy then
      inputs.omarchy
    else if (pkgs ? omarchnix) && (pkgs.omarchnix ? omarchySrc) then
      pkgs.omarchnix.omarchySrc
    else
      null;

  marketplaceSrc =
    if cfg.marketplaceSrc != null then
      cfg.marketplaceSrc
    else if inputs ? omarchy-plugin-marketplace then
      inputs.omarchy-plugin-marketplace
    else if (pkgs ? omarchnix) && (pkgs.omarchnix ? marketplaceSrc) then
      pkgs.omarchnix.marketplaceSrc
    else
      null;

  omarchyLib = import ../lib/omarchy.nix {
    inherit lib omarchySrc;
  };

  defaultOmarchyShell =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? omarchy-shell) then
      pkgs.omarchnix.omarchy-shell
    else if omarchySrc != null then
      import ../pkgs/omarchy-shell.nix {
        inherit
          lib
          pkgs
          omarchySrc
          marketplaceSrc
          ;
      }
    else
      null;

  defaultCli =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? cli) then
      pkgs.omarchnix.cli
    else if defaultOmarchyShell != null then
      import ../pkgs/omarchnix-cli.nix {
        inherit pkgs marketplaceSrc;
        omarchyShell = defaultOmarchyShell;
      }
    else
      null;

  defaultThemeFonts = (import ./theme.nix { inherit pkgs; }).fonts;

  rawTheme =
    if cfg.theme.attrset != null then
      cfg.theme.attrset
    else if omarchySrc != null then
      omarchyLib.importTheme {
        theme = cfg.theme.name;
        inherit pkgs;
      }
    else
      (import ./theme.nix { inherit pkgs; }) // { name = cfg.theme.name; };

  theme = rawTheme // {
    fonts = lib.recursiveUpdate defaultThemeFonts (rawTheme.fonts or { });
  };
in
{
  options.programs.omarchnix = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the omarchnix Home Manager desktop, theme, shell, plugin, and agent environment.";
    };

    omarchySrc = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional explicit upstream omacom/omarchy source path override.";
    };

    marketplaceSrc = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional explicit omacom/omarchy-plugin-marketplace source path override.";
    };

    cliPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = defaultCli;
      defaultText = lib.literalExpression "pkgs.omarchnix.cli";
      description = "Package providing the `omarchnix` CLI.";
    };

    terminal = lib.mkOption {
      type = lib.types.enum [
        "ghostty"
        "foot"
      ];
      default = "ghostty";
      description = "Primary terminal emulator (`ghostty` for GPU HarfBuzz ligatures like `!=`/`->`, or `foot`).";
    };

    theme = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "tokyo-night";
        description = "Active Omarchy theme name (all 23+ upstream palettes and custom themes supported).";
      };

      darkName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Preferred dark theme slug used by `omarchnix theme toggle` and the status bar Appearance button (defaults to `theme.name` when dark, else `tokyo-night`).";
      };

      lightName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Preferred light theme slug used by `omarchnix theme toggle` and the status bar Appearance button (defaults to `theme.name` when light, else `white`).";
      };

      attrset = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
        default = null;
        description = "Optional custom theme attrset override (e.g. from lib.omarchy.importTheme).";
      };

      customThemes = lib.mkOption {
        type = lib.types.attrsOf lib.types.package;
        default = { };
        description = "Declarative custom Omarchy theme packages materialized into `~/.config/omarchy/themes/<slug>`.";
      };
    };

    shell = {
      backend = lib.mkOption {
        type = lib.types.enum [
          "waybar"
          "omarchy-shell"
        ];
        default = "waybar";
        description = ''
          Active bar/panel runtime:
          - `omarchy-shell`: Upstream Quickshell (`Qt 6.12`) QML bar, notifications, menus, lock/polkit surfaces, and `plugins.omarchy.org` host.
          - `waybar`: Lightweight Waybar status bar.
        '';
      };

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = defaultOmarchyShell;
        defaultText = lib.literalExpression "pkgs.omarchnix.omarchy-shell";
        description = "Packaged Omarchy Quickshell runtime and theme/plugin scripts.";
      };

      extraSettings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Additional top-level fields merged into the initial `~/.config/omarchy/shell.json`.";
      };

      disabledPlugins = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Built-in Omarchy plugin IDs disabled in `~/.config/omarchy/shell.json` (e.g. `omarchy.dock`, `omarchy.background`).";
      };

      purgedPluginIds = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Plugin/widget IDs removed from `~/.config/omarchy/plugins/` and from all `bar.layout` sections and `.plugins`.";
      };

      workspaceWidgetId = lib.mkOption {
        type = lib.types.str;
        default = "omarchy.workspaces";
        description = "Workspace widget ID placed in `bar.layout.left` (replaces `omarchy.workspaces` when overridden).";
      };

      trayWidgetIds = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "omarchy.agents"
          "omarchy.monitor"
        ];
        description = "Widget IDs placed inside the collapsible `bar.layout.tray` drawer and deduplicated out of `bar.layout.right`.";
      };

      elsewhenCities = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
        default = [ ];
        description = "Default cities seeded on `omarchy.elsewhen` in `bar.layout.centerEnd` when none are configured yet.";
      };

      dock = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
        default = null;
        description = "Declarative `.dock` defaults merged into `~/.config/omarchy/shell.json` (`position`, `autohide`, `allWorkspaces`).";
      };
    };

    keyboard = {
      layout = lib.mkOption {
        type = lib.types.str;
        default = "us";
        description = "XKB keyboard layout configured in Hyprland (`us`, `fr`, etc.).";
      };

      variant = lib.mkOption {
        type = lib.types.str;
        default = "intl";
        description = "XKB keyboard variant configured in Hyprland (`intl` matches macOS `USInternational-PC`, `\"\"` for plain layout).";
      };

      backlight = {
        step = lib.mkOption {
          type = lib.types.ints.between 1 100;
          default = 10;
          description = "Percentage step per keypress for keyboard backlight shortcuts (`Ctrl + F1/F2`, `Cmd + F1/F2`, `XF86KbdBrightnessUp/Down`).";
        };

        dimOnIdle = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Automatically turn off the keyboard backlight on idle timeout and restore the previous level on resume.";
        };
      };
    };

    touchpad = {
      naturalScroll = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether touchpad scrolling is natural (`true`) or traditional/inverted (`false`, so content moves up when fingers move up).";
      };

      scrollFactor = lib.mkOption {
        type = lib.types.float;
        default = 0.5;
        description = "Touchpad scroll speed factor in Hyprland (`0.5` smooths Apple MTP trackpad scrolling to match macOS inertia feel).";
      };
    };

    plugins = {
      locked = lib.mkOption {
        default = { };
        description = "Declarative Nix-locked `plugins.omarchy.org` / Omarchy shell plugins validated at build time and materialized symlink-free into `~/.config/omarchy/plugins/<id>`.";
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              package = lib.mkOption {
                type = lib.types.package;
                description = "Validated plugin derivation built with `lib.omarchy.buildPlugin`.";
              };
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Enable the plugin in `~/.config/omarchy/shell.json`.";
              };
              section = lib.mkOption {
                type = lib.types.nullOr (
                  lib.types.enum [
                    "left"
                    "centerBegin"
                    "center"
                    "centerEnd"
                    "tray"
                    "right"
                  ]
                );
                default = null;
                description = "Optional bar section override for `bar-widget` plugins.";
              };
            };
          }
        );
      };
    };

    agents = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Provision the governed `omarchnix` system skill and agent ergonomics configs.";
      };

      targets = lib.mkOption {
        type = lib.types.listOf (
          lib.types.enum [
            "opencode"
            "claude"
            "codex"
            "hermes"
          ]
        );
        default = [
          "opencode"
          "claude"
          "codex"
          "hermes"
        ];
        description = "Coding agents for which `omarchnix` provisions skills and live theme hooks.";
      };

      orbSync = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Sync Omarchy's `omarchy.agents` status-bar plugin (`~/.local/state/omarchy/agents/usage/*.json`)
            bidirectionally with Orb Core (`~/.orb/connection.json`) and Orb Desktop, falling back cleanly
            to upstream local collectors when Orb is not configured.
          '';
        };

        launchInOrb = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Route `omarchy-agent` and `omarchy-agent-prompt` bar/tile actions into Orb Desktop's
            New Agent composer (pre-selecting the requested harness and prompt), while keeping
            `--local`, `--local-model`, `--terminal`, and `--inline` on upstream CLI launch.
          '';
        };

        pollInterval = lib.mkOption {
          type = lib.types.str;
          default = "2m";
          description = "Background systemd user timer interval for `omarchy-orb-agent usage-update`.";
        };
      };
    };
  };

  imports = [
    ./hyprland.nix
    ./waybar.nix
    ./omarchy-shell.nix
    ./macos.nix
    ./murmure.nix
    ./sharing.nix
    ./thunar.nix
    ./agents.nix
    ./fcitx5.nix
    ./foot.nix
    ./ghostty.nix
    ./fuzzel.nix
    ./hyprlock.nix
    ./hypridle.nix
    ./hyprpaper.nix
  ];

  config = lib.mkIf cfg.enable {
    _module.args.theme = theme;

    home = {
      username = lib.mkDefault "thomas";
      homeDirectory = lib.mkDefault "/home/thomas";
      stateVersion = lib.mkDefault "25.05";

      pointerCursor = {
        enable = true;
        name = theme.cursor.name;
        package = theme.cursor.package;
        size = theme.cursor.size;
        gtk.enable = true;
        x11.enable = true;
      };

      sessionVariables = {
        NIXOS_OZONE_WL = "1";
        GTK_USE_PORTAL = "1";
        QT_QPA_PLATFORMTHEME = lib.mkDefault "xdgdesktopportal";
        QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
        BROWSER = "brave";
      };

      packages =
        lib.filter (p: p != null) [
          theme.fonts.sans.package
          theme.fonts.serif.package
          theme.fonts.mono.package
          theme.fonts.icon.package
        ]
        ++ [
          pkgs.lilex
          pkgs.eb-garamond
          pkgs.noto-fonts
          pkgs.noto-fonts-color-emoji
          pkgs.brightnessctl
          pkgs.hyprsunset
          pkgs.playerctl
          pkgs.grim
          pkgs.slurp
          pkgs.hyprpicker
          pkgs.wf-recorder
          pkgs.wl-clipboard
          pkgs.libnotify
          pkgs.xdg-user-dirs
          pkgs.fastfetch
          pkgs.mission-center
        ];
    };

    xdg.userDirs = {
      enable = lib.mkDefault true;
      createDirectories = lib.mkDefault true;
      setSessionVariables = lib.mkDefault false;
      download = lib.mkDefault "${config.home.homeDirectory}/Downloads";
      documents = lib.mkDefault "${config.home.homeDirectory}/Documents";
      music = lib.mkDefault "${config.home.homeDirectory}/Music";
      pictures = lib.mkDefault "${config.home.homeDirectory}/Pictures";
      videos = lib.mkDefault "${config.home.homeDirectory}/Videos";
      # Match upstream Omarchy: point unused XDG directories at $HOME so
      # Desktop / Public / Templates clutter folders are not created.
      desktop = lib.mkDefault config.home.homeDirectory;
      publicShare = lib.mkDefault config.home.homeDirectory;
      templates = lib.mkDefault config.home.homeDirectory;
      extraConfig = {
        SCREENSHOTS = lib.mkDefault "${config.xdg.userDirs.pictures}/Screenshots";
      };
    };

    home.activation.omarchnixUserDirs = config.lib.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p \
        ${lib.escapeShellArg config.xdg.userDirs.download} \
        ${lib.escapeShellArg config.xdg.userDirs.pictures} \
        ${lib.escapeShellArg "${config.xdg.userDirs.pictures}/Screenshots"} \
        ${lib.escapeShellArg config.xdg.userDirs.videos} \
        "$HOME/.config/gtk-3.0"
      bookmarks_file="$HOME/.config/gtk-3.0/bookmarks"
      touch "$bookmarks_file"
      if [ -s "$bookmarks_file" ]; then
        tmp_bm="$(mktemp "$bookmarks_file.XXXXXX")"
        while IFS= read -r line || [ -n "$line" ]; do
          uri="''${line%% *}"
          if [ "''${uri#file://}" != "$uri" ]; then
            bm_path="''${uri#file://}"
            if [ "$bm_path" = "$HOME" ] || [ ! -d "$bm_path" ]; then
              continue
            fi
          fi
          printf '%s\n' "$line" >> "$tmp_bm"
        done < "$bookmarks_file"
        mv "$tmp_bm" "$bookmarks_file"
        chmod 0644 "$bookmarks_file"
      fi
      for dir in \
        ${lib.escapeShellArg config.xdg.userDirs.download} \
        ${lib.escapeShellArg config.xdg.userDirs.pictures} \
        ${lib.escapeShellArg config.xdg.userDirs.videos}; do
        [ "$dir" != "$HOME" ] && [ -d "$dir" ] || continue
        entry="file://$dir $(basename "$dir")"
        grep -qxF "$entry" "$bookmarks_file" 2>/dev/null || printf '%s\n' "$entry" >> "$bookmarks_file"
      done
    '';

    fonts.fontconfig = {
      enable = true;
      defaultFonts = {
        sansSerif = [
          theme.fonts.sans.name
          "Noto Sans"
        ];
        serif = [
          theme.fonts.serif.name
          "EB Garamond"
          "IBM Plex Serif"
          "Noto Serif"
        ];
        monospace = [
          theme.fonts.mono.name
          "Lilex"
          "IBM Plex Mono"
          "Noto Sans Mono"
        ];
        emoji = [
          "Noto Color Emoji"
        ];
      };
    };

    xdg.configFile."fontconfig/conf.d/60-omarchnix-ui-aliases.conf".text =
      let
        mkFontAliasRules =
          families: preferred:
          lib.concatMapStringsSep "\n" (family: ''
            <match target="pattern">
              <test name="family" qual="any">
                <string>${family}</string>
              </test>
              <edit name="family" mode="prepend" binding="strong">
                ${lib.concatMapStringsSep "\n                " (p: "<string>${p}</string>") preferred}
              </edit>
            </match>'') families;
      in
      ''
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
        <fontconfig>
        ${mkFontAliasRules
          [
            "system-ui"
            "ui-sans-serif"
            "-apple-system"
            "BlinkMacSystemFont"
            "Segoe UI"
            "DejaVu Sans"
            "Liberation Sans"
            "FreeSans"
            "Arial"
            "Helvetica"
            "Helvetica Neue"
            "Open Sans"
          ]
          [
            theme.fonts.sans.name
            "Noto Sans"
          ]
        }
        ${mkFontAliasRules
          [
            "ui-serif"
            "DejaVu Serif"
            "Liberation Serif"
            "FreeSerif"
            "Times New Roman"
            "Times"
            "Georgia"
          ]
          [
            theme.fonts.serif.name
            "EB Garamond"
            "IBM Plex Serif"
            "Noto Serif"
          ]
        }
        ${mkFontAliasRules
          [
            "ui-monospace"
            "DejaVu Sans Mono"
            "Liberation Mono"
            "FreeMono"
            "Courier New"
            "Courier"
          ]
          [
            theme.fonts.mono.name
            "Lilex"
            "IBM Plex Mono"
            "Noto Sans Mono"
          ]
        }
        </fontconfig>
      '';

    home.activation.omarchnixBrowserFontDefaults = config.lib.dag.entryAfter [ "writeBoundary" ] ''
      for pair in \
        "brave:$HOME/.config/BraveSoftware/Brave-Browser/Default/Preferences" \
        "chromium:$HOME/.config/chromium/Default/Preferences"; do
        proc="''${pair%%:*}"
        prefs="''${pair#*:}"
        if [ -f "$prefs" ] && [ ! -L "$prefs" ] && ! ${pkgs.procps}/bin/pgrep -u "$USER" -f "/$proc/$proc " >/dev/null 2>&1; then
          tmp_prefs="$(mktemp "$prefs.XXXXXX")"
          if ${pkgs.jq}/bin/jq \
            --arg sans ${lib.escapeShellArg theme.fonts.sans.name} \
            --arg serif ${lib.escapeShellArg theme.fonts.serif.name} \
            --arg mono ${lib.escapeShellArg theme.fonts.mono.name} '
            .webkit.webprefs.fonts = ((.webkit.webprefs.fonts // {})
              | .standard.Zyyy = (.standard.Zyyy // $sans)
              | .sansserif.Zyyy = (.sansserif.Zyyy // $sans)
              | .serif.Zyyy = (.serif.Zyyy // $serif)
              | .fixed.Zyyy = (.fixed.Zyyy // $mono))
          ' "$prefs" > "$tmp_prefs" 2>/dev/null; then
            chmod --reference="$prefs" "$tmp_prefs" 2>/dev/null || chmod 0600 "$tmp_prefs"
            mv "$tmp_prefs" "$prefs"
          else
            rm -f "$tmp_prefs"
          fi
        fi
      done
    '';

    xdg.mimeApps = {
      enable = lib.mkDefault true;
      defaultApplications = {
        "text/html" = lib.mkDefault [ "brave-browser.desktop" ];
        "x-scheme-handler/http" = lib.mkDefault [ "brave-browser.desktop" ];
        "x-scheme-handler/https" = lib.mkDefault [ "brave-browser.desktop" ];
        "x-scheme-handler/about" = lib.mkDefault [ "brave-browser.desktop" ];
        "x-scheme-handler/unknown" = lib.mkDefault [ "brave-browser.desktop" ];
        "application/xhtml+xml" = lib.mkDefault [ "brave-browser.desktop" ];
      };
    };

    programs.fastfetch.enable = lib.mkDefault true;

    programs.zsh = {
      enable = true;
      shellAliases = {
        neofetch = "fastfetch";
        screenfetch = "fastfetch";
      };
    };

    systemd.user.sessionVariables = {
      GTK_USE_PORTAL = "1";
    };

    gtk = {
      enable = true;
      font = {
        name = theme.fonts.sans.name;
        size = theme.fonts.sans.size;
      };
      # Unset gtk-xft-dpi is -1. WebKitGTK 4.1 then multiplies that by the
      # Wayland buffer scale and divides by 96, producing a negative DPR.
      # Do NOT set gtk-application-prefer-dark-theme in static settings.ini:
      # GtkSettings treats keyfile entries as higher priority than live portal/dconf
      # changes, locking GTK3 and WebKitGTK 4.1 (`Orb`) into dark mode even when
      # dconf switches `gtk-theme` to `Adwaita` and `color-scheme` to `prefer-light`.
      # Hide client-side minimize/maximize/close buttons (`:`) across GTK3/4,
      # Chromium/Brave, PWAs, and Electron on tiling Hyprland (`Cmd+W`/`Cmd+Q` closes).
      gtk3.extraConfig = {
        gtk-xft-dpi = 98304;
        gtk-decoration-layout = ":";
      };
      gtk4.extraConfig = {
        gtk-xft-dpi = 98304;
        gtk-decoration-layout = ":";
      };
    };

    dconf.settings =
      let
        isLight = (theme.mode or "dark") == "light";
        # When omarchy-shell is active, `omarchnix theme sync-mode` / `toggle` /
        # `set` owns live dark/light dconf keys (`color-scheme`, `gtk-theme`,
        # `wm/preferences/theme`) so Home Manager's offline `dbus-run-session`
        # `dconf load` never clobbers runtime mode behind `xdg-desktop-portal-gtk`.
        dynamicShellTheme = cfg.shell.backend == "omarchy-shell";
      in
      {
        "org/gnome/desktop/interface" = {
          font-name = "${theme.fonts.sans.name} ${toString theme.fonts.sans.size}";
          document-font-name = "${theme.fonts.serif.name} ${toString theme.fonts.serif.size}";
          monospace-font-name = "${theme.fonts.mono.name} ${toString theme.fonts.mono.size}";
        }
        // lib.optionalAttrs (!dynamicShellTheme) {
          color-scheme = if isLight then "prefer-light" else "prefer-dark";
          gtk-theme = if isLight then "Adwaita" else "Adwaita-dark";
        };
        "org/gnome/desktop/wm/preferences" = {
          button-layout = ":";
        }
        // lib.optionalAttrs (!dynamicShellTheme) {
          theme = if isLight then "Adwaita" else "Adwaita-dark";
        };
        "io/missioncenter/MissionCenter" = {
          first-time-running = false;
        };
      };
  };
}
