{
  config,
  lib,
  options,
  pkgs,
  inputs ? { },
  ...
}:
let
  cfg = config.omarchnix;
  omarchnixShellPkg =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? omarchy-shell) then
      pkgs.omarchnix.omarchy-shell
    else if inputs ? omarchy then
      import ../pkgs/omarchy-shell.nix {
        inherit lib pkgs;
        marketplaceSrc = inputs.omarchy-plugin-marketplace or null;
        omarchySrc = inputs.omarchy;
      }
    else
      null;
  omarchnixMarketplaceSrc =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? marketplaceSrc) then
      pkgs.omarchnix.marketplaceSrc
    else
      inputs.omarchy-plugin-marketplace or null;
  omarchnixCliPkg =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? cli) then
      pkgs.omarchnix.cli
    else if omarchnixShellPkg != null then
      import ../pkgs/omarchnix-cli.nix {
        inherit pkgs;
        omarchyShell = omarchnixShellPkg;
        marketplaceSrc = omarchnixMarketplaceSrc;
      }
    else
      null;
in
{
  imports = [
    ./hardware-m2air.nix
    ./hardening.nix
    ./containers.nix
    ./secrets.nix
  ];

  options = {
    omarchnix = {
      enable = lib.mkEnableOption "omarchnix reusable NixOS workstation & server module (Apple Silicon Asahi, NVIDIA Grace / DGX Spark, and x86_64-linux)";

      profile = lib.mkOption {
        type = lib.types.enum [
          "asahi"
          "spark"
          "workstation"
          "vm"
        ];
        default = "workstation";
        description = ''
          Hardware/boot profile:
          - `asahi`: Apple Silicon (M-series) external BootROM/m1n1/U-Boot boot chain (defaults `boot.loader.*` and `canTouchEfiVariables` to `false`; standalone UEFI hosts like `m2air` opt into removable ARM64 UEFI GRUB while keeping `m1n1/boot.bin` untouched).
          - `spark`: ARM64 (`aarch64-linux`) UEFI server/workstation (e.g. NVIDIA Grace / DGX Spark) with systemd-boot.
          - `workstation`: Generic `x86_64-linux` or `aarch64-linux` UEFI workstation with systemd-boot.
          - `vm`: QEMU/KVM virtual machine target with systemd-boot.
        '';
      };

      hardening.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable defense-in-depth hardening (default-deny firewall, key-only AppArmor-confined sshd, wheel-only sudo, kernel sysctls).";
      };

      containers.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable user-namespaced, network-isolated dev-untrusted NixOS container + bubblewrap.";
      };

      secrets.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable sops-nix age secret decryption wiring.";
      };

      desktop = {
        enable = lib.mkEnableOption "omarchnix Hyprland Wayland desktop stack";

        user = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Primary desktop user account to wire into Home Manager when non-null.";
        };

        theme = lib.mkOption {
          type = lib.types.str;
          default = "tokyo-night";
          description = "Default Omarchy theme name passed into Home Manager.";
        };

        shellBackend = lib.mkOption {
          type = lib.types.enum [
            "waybar"
            "omarchy-shell"
          ];
          default = "waybar";
          description = "Default desktop bar/panel backend passed into Home Manager (`omarchy-shell` or `waybar`).";
        };

        keyboard = {
          layout = lib.mkOption {
            type = lib.types.str;
            default = "us";
            description = "Default XKB keyboard layout passed into Home Manager (`us`, `fr`, etc.).";
          };

          variant = lib.mkOption {
            type = lib.types.str;
            default = "intl";
            description = "Default XKB keyboard variant passed into Home Manager (`intl` matches macOS `USInternational-PC`, `\"\"` for plain layout).";
          };
        };

        touchpad = {
          naturalScroll = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Default touchpad scroll direction passed into Home Manager (`false` inverts scroll so content goes up when fingers go up).";
          };

          scrollFactor = lib.mkOption {
            type = lib.types.float;
            default = 0.5;
            description = "Default touchpad scroll speed factor passed into Home Manager (`0.5` smooths Apple MTP trackpad scrolling).";
          };
        };

        autostartTty = {
          enable = lib.mkEnableOption "autostart the Hyprland session on a bare TTY (no display manager)";

          tty = lib.mkOption {
            type = lib.types.str;
            default = "tty1";
            description = "TTY (without `/dev/`) that hosts the autostarted Hyprland session.";
          };
        };
      };
    };
  };

  config = lib.mkMerge [
    (lib.optionalAttrs (options ? home-manager) (
      lib.mkIf (cfg.enable && cfg.desktop.enable && cfg.desktop.user != null) {
        home-manager = {
          useGlobalPkgs = lib.mkDefault true;
          useUserPackages = lib.mkDefault true;
          # Keep pre-existing (hand-written) dotfiles instead of aborting
          # activation: a machine that already has ~/.config/hypr or ~/.zshrc
          # otherwise fails with "Existing file ... would be clobbered".
          backupFileExtension = lib.mkDefault "hm-backup";
          extraSpecialArgs = lib.optionalAttrs (inputs != { }) {
            inherit inputs;
          };
          users.${cfg.desktop.user} =
            { ... }:
            {
              imports = [ ../home ];
              programs.omarchnix = {
                theme.name = lib.mkDefault cfg.desktop.theme;
                shell.backend = lib.mkDefault cfg.desktop.shellBackend;
                keyboard = {
                  layout = lib.mkDefault cfg.desktop.keyboard.layout;
                  variant = lib.mkDefault cfg.desktop.keyboard.variant;
                };
                touchpad = {
                  naturalScroll = lib.mkDefault cfg.desktop.touchpad.naturalScroll;
                  scrollFactor = lib.mkDefault cfg.desktop.touchpad.scrollFactor;
                };
              };
            };
        };
      }
    ))

    (lib.mkIf (cfg.enable && cfg.desktop.enable && cfg.desktop.autostartTty.enable) (
      let
        tty = cfg.desktop.autostartTty.tty;
        user = if cfg.desktop.user != null then cfg.desktop.user else "thomas";
        runtimeDir = "/run/user/${toString config.users.users.${user}.uid}";
        sessionScript = pkgs.writeShellScript "hyprland-${tty}-session" ''
          export XDG_RUNTIME_DIR="${runtimeDir}"
          export XDG_SESSION_TYPE=wayland
          export XDG_CURRENT_DESKTOP=Hyprland
          exec ${lib.getExe pkgs.uwsm} start -e -D Hyprland hyprland.desktop
        '';
      in
      {
        # getty.target pulls in autovt@tty1, which `switch-to-configuration`
        # starts on every activation and thereby kills the live session.
        systemd.targets.getty.wants = lib.mkForce [ ];

        systemd.services."hyprland-${tty}" = {
          description = "Hyprland (uwsm) session on /dev/${tty}";
          wantedBy = [ "multi-user.target" ];
          after = [
            "systemd-user-sessions.service"
            "nss-lookup.target"
            "network.target"
          ];
          conflicts = [ "autovt@${tty}.service" ];
          # A rebuild must never take the running desktop down.
          restartIfChanged = false;
          stopIfChanged = false;
          unitConfig = {
            StartLimitIntervalSec = 0;
            StartLimitBurst = 0;
          };
          serviceConfig = {
            User = user;
            Type = "exec";
            PAMName = "login";
            TTYPath = "/dev/${tty}";
            TTYReset = true;
            TTYVHangup = true;
            TTYVTDisallocate = false;
            StandardInput = "tty";
            StandardOutput = "tty";
            StandardError = "tty";
            UtmpIdentifier = tty;
            UtmpMode = "user";
            # Restart the desktop even after a clean exit (e.g. a killed
            # Hyprland leaves the TTY blank otherwise); `systemctl stop` is
            # still honoured and does not loop.
            Restart = "always";
            RestartSec = 3;
            ExecStart = sessionScript;
          };
        };
      }
    ))

    (lib.mkIf cfg.enable {
      time.timeZone = lib.mkDefault "Europe/Paris";
      i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
      console.keyMap = lib.mkDefault "us";

      services.openssh = {
        enable = lib.mkDefault true;
        settings = {
          PasswordAuthentication = lib.mkDefault false;
          KbdInteractiveAuthentication = lib.mkDefault false;
        };
      };

      environment.variables.EDITOR = "hx";
      programs.zsh.enable = lib.mkDefault true;

      environment.systemPackages = [
        pkgs.git
        pkgs.helix
        pkgs.jq
        pkgs.ripgrep
      ]
      ++ lib.optional (omarchnixCliPkg != null) omarchnixCliPkg;

      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        auto-optimise-store = lib.mkDefault true;
      };

      system.stateVersion = lib.mkDefault "25.05";
    })

    (lib.mkIf (cfg.enable && cfg.profile == "asahi") {
      boot.loader.systemd-boot.enable = lib.mkDefault false;
      boot.loader.grub.enable = lib.mkDefault false;
      boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;

      nix.settings = {
        substituters = [ "https://nixos-apple-silicon.cachix.org" ];
        trusted-public-keys = [
          "nixos-apple-silicon.cachix.org-1:8psDu5SA5dAD7qA0zMy5UT292TxeEPzIz8VVEr2Js20="
        ];
      };
    })

    (lib.mkIf (cfg.enable && cfg.profile != "asahi") {
      boot.loader.systemd-boot.enable = lib.mkDefault true;
      boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
    })

    (lib.mkIf (cfg.enable && cfg.profile == "spark") {
      zramSwap = {
        enable = lib.mkDefault true;
        algorithm = lib.mkDefault "zstd";
        memoryPercent = lib.mkDefault 25;
      };
    })

    (lib.mkIf (cfg.enable && cfg.desktop.enable) (
      let
        michelangelusPkg =
          if pkgs ? michelangelus-font then
            pkgs.michelangelus-font
          else if (pkgs ? omarchnix) && (pkgs.omarchnix ? michelangelus-font) then
            pkgs.omarchnix.michelangelus-font
          else
            pkgs.callPackage ../pkgs/michelangelus-font.nix { };
      in
      {
        hardware.graphics.enable = lib.mkDefault true;

        fonts = {
          enableDefaultPackages = false;
          packages = [
            pkgs.ibm-plex
            pkgs.lilex
            pkgs.nerd-fonts.lilex
            michelangelusPkg
            pkgs.eb-garamond
            pkgs.font-awesome
            pkgs.noto-fonts
            pkgs.noto-fonts-cjk-sans
            pkgs.noto-fonts-cjk-serif
            pkgs.noto-fonts-color-emoji
          ];
          fontconfig = {
            enable = lib.mkDefault true;
            defaultFonts = {
              sansSerif = lib.mkDefault [
                "IBM Plex Sans"
                "Noto Sans"
              ];
              serif = lib.mkDefault [
                "Michelangelus"
                "EB Garamond"
                "IBM Plex Serif"
                "Noto Serif"
              ];
              monospace = lib.mkDefault [
                "Lilex Nerd Font"
                "Lilex"
                "IBM Plex Mono"
                "Noto Sans Mono"
              ];
              emoji = lib.mkDefault [
                "Noto Color Emoji"
              ];
            };
          };
        };

        i18n.inputMethod = {
          enable = lib.mkDefault true;
          type = lib.mkDefault "fcitx5";
          fcitx5.waylandFrontend = lib.mkDefault true;
        };

        programs.dconf.enable = lib.mkDefault true;

        programs.hyprland = {
          enable = true;
          withUWSM = true;
          xwayland.enable = true;
        };

        environment.systemPackages = [
          pkgs.hyprsunset
        ];

        xdg.portal = {
          enable = lib.mkDefault true;
          extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
          config.hyprland = {
            default = [
              "hyprland"
              "gtk"
            ];
            "org.freedesktop.impl.portal.Settings" = [ "gtk" ];
          };
        };

        security.pam.services.hyprlock = { };
        security.pam.services.omarchy-lock-password = { };
        security.polkit.enable = true;
      }
    ))
  ];
}
