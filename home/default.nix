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

  theme =
    if cfg.theme.attrset != null then
      cfg.theme.attrset
    else if omarchySrc != null then
      omarchyLib.importTheme {
        theme = cfg.theme.name;
        inherit pkgs;
      }
    else
      (import ./theme.nix { inherit pkgs; }) // { name = cfg.theme.name; };
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

    theme = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "tokyo-night";
        description = "Active Omarchy theme name (all 23+ upstream palettes supported).";
      };

      attrset = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
        default = null;
        description = "Optional custom theme attrset override (e.g. from lib.omarchy.importTheme).";
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
    };
  };

  imports = [
    ./hyprland.nix
    ./waybar.nix
    ./omarchy-shell.nix
    ./agents.nix
    ./foot.nix
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
      };

      packages = [
        theme.fonts.sans.package
        theme.fonts.mono.package
        theme.fonts.icon.package
        pkgs.noto-fonts
        pkgs.brightnessctl
        pkgs.playerctl
        pkgs.grim
        pkgs.slurp
        pkgs.wl-clipboard
        pkgs.libnotify
      ];
    };

    fonts.fontconfig.enable = true;

    programs.zsh.enable = true;

    gtk =
      let
        isLight = (theme.mode or "dark") == "light";
      in
      {
        enable = true;
        font = {
          name = theme.fonts.sans.name;
          size = theme.fonts.sans.size;
        };
        # Unset gtk-xft-dpi is -1. WebKitGTK 4.1 then multiplies that by the
        # Wayland buffer scale and divides by 96, producing a negative DPR.
        gtk3.extraConfig.gtk-xft-dpi = 98304;
        gtk4.extraConfig.gtk-xft-dpi = 98304;
        gtk3.extraConfig.gtk-application-prefer-dark-theme = !isLight;
        gtk4.extraConfig.gtk-application-prefer-dark-theme = !isLight;
        gtk3.extraCss = ''
          window { backdrop-filter: blur(20px); }
        '';
        gtk4.extraCss = ''
          window { backdrop-filter: blur(20px); }
        '';
      };

    dconf.settings."org/gnome/desktop/interface" =
      let
        isLight = (theme.mode or "dark") == "light";
      in
      {
        color-scheme = if isLight then "prefer-light" else "prefer-dark";
        gtk-theme = if isLight then "Adwaita" else "Adwaita-dark";
      };
  };
}
