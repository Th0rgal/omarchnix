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
    ./sharing.nix
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

      defaultTimeZone = lib.mkOption {
        type = lib.types.str;
        default = "UTC";
        example = "Europe/Lisbon";
        description = ''
          Default IANA timezone seeded into `/etc/localtime` when `time.timeZone`
          is left `null` (imperative timezone mode), so Omarchy's World Clock
          (`omarchy.elsewhen`) and `omarchy-menu-timezone` (`timedatectl set-timezone`)
          can switch timezones live at runtime while still applying declarative
          default timezone updates.
        '';
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

          backlight = {
            step = lib.mkOption {
              type = lib.types.ints.between 1 100;
              default = 10;
              description = "Default percentage step per keypress for keyboard backlight shortcuts passed into Home Manager.";
            };

            dimOnIdle = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Default keyboard backlight idle blanking toggle passed into Home Manager.";
            };
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

        murmure = {
          enable = lib.mkEnableOption "Murmure on-device Wayland dictation (`Fn + Right Shift` + shared `voiced` Cohere Transcribe daemon)";
        };

        macos = {
          enable = lib.mkEnableOption "macOS-style desktop suite (Mission Control & contiguous Spaces, auto-hide Dock, Spotlight, slanted Workspaces, minimal bar, and per-Space preloaded Wallpapers)";

          dock = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable the frosted-glass auto-hide bottom Dock (`th0rgal.macos-dock`) when `omarchnix.desktop.macos.enable` is active (`false` keeps a dockless top-bar layout).";
          };

          persistentWorkspaces = lib.mkOption {
            type = lib.types.ints.between 1 10;
            default = 5;
            description = "Number of contiguous persistent workspace chips (`1..N`) shown in `th0rgal.workspaces`.";
          };

          gestures = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable 3-finger trackpad swipe up/down gestures for Mission Control when `omarchnix.desktop.macos.enable` is active.";
          };

          touchIdHud = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = "Enable the Touch ID HUD overlay (`null` auto-enables when `omarchnix.hardware.m2air.touchId.enable` is true).";
          };

          wallpapers = {
            default = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Default fallback wallpaper file path passed into Home Manager.";
            };

            workspaces = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Per-Space wallpaper file paths passed into Home Manager.";
            };
          };
        };

        autostartTty = {
          enable = lib.mkEnableOption "autostart the Hyprland session on a bare TTY (no display manager)";

          tty = lib.mkOption {
            type = lib.types.str;
            default = "tty1";
            description = "TTY (without `/dev/`) that hosts the autostarted Hyprland session.";
          };

          unlockKeyringFromLuks = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Automatically unlock GNOME Keyring (`login.keyring`) at session
              start using the Stage-1 `systemd-cryptsetup` LUKS passphrase
              cached in the kernel keyring when `services.gnome.gnome-keyring.enable`
              is active.
            '';
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
          backupFileExtension = lib.mkDefault "hm-bak";
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
                  backlight = {
                    step = lib.mkDefault cfg.desktop.keyboard.backlight.step;
                    dimOnIdle = lib.mkDefault cfg.desktop.keyboard.backlight.dimOnIdle;
                  };
                };
                touchpad = {
                  naturalScroll = lib.mkDefault cfg.desktop.touchpad.naturalScroll;
                  scrollFactor = lib.mkDefault cfg.desktop.touchpad.scrollFactor;
                };
                murmure.enable = lib.mkDefault cfg.desktop.murmure.enable;
                macos = {
                  enable = lib.mkDefault cfg.desktop.macos.enable;
                  dock.enable = lib.mkDefault (cfg.desktop.macos.enable && cfg.desktop.macos.dock);
                  slantedWorkspaces.persistentCount = lib.mkDefault cfg.desktop.macos.persistentWorkspaces;
                  missionControl.gestures = lib.mkDefault cfg.desktop.macos.gestures;
                  touchIdHud.enable = lib.mkDefault (
                    if cfg.desktop.macos.touchIdHud != null then
                      cfg.desktop.macos.touchIdHud
                    else
                      cfg.desktop.macos.enable && cfg.hardware.m2air.touchId.enable
                  );
                  wallpapers = {
                    default = lib.mkDefault cfg.desktop.macos.wallpapers.default;
                    workspaces = lib.mkDefault cfg.desktop.macos.wallpapers.workspaces;
                  };
                };
                sharing = {
                  airdrop.enable = lib.mkDefault cfg.services.sharing.airdrop.enable;
                  quickshare.enable = lib.mkDefault cfg.services.sharing.quickshare.enable;
                  nearby.enable = lib.mkDefault cfg.services.sharing.nearby.enable;
                  kdeconnect.enable = lib.mkDefault cfg.services.sharing.kdeconnect.enable;
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
        userGroup = config.users.users.${user}.group;
        runtimeDir = "/run/user/${toString config.users.users.${user}.uid}";
        unlockKeyring =
          cfg.desktop.autostartTty.unlockKeyringFromLuks && config.services.gnome.gnome-keyring.enable;
        keyctl = lib.getExe' pkgs.keyutils "keyctl";
        setpriv = lib.getExe' pkgs.util-linux "setpriv";
        gnomeKeyringWrapper = "${config.security.wrapperDir}/gnome-keyring-daemon";

        stageLuksKeyringScript = pkgs.writeShellScript "omarchnix-stage-luks-keyring-${tty}" ''
          set -euo pipefail
          key_id="$(${keyctl} request user cryptsetup 2>/dev/null || ${keyctl} search @u user cryptsetup 2>/dev/null || true)"
          if [[ -z "$key_id" ]]; then
            exit 0
          fi

          last_pw=""
          while IFS= read -r -d "" entry || [[ -n "$entry" ]]; do
            if [[ -n "$entry" ]]; then
              last_pw="$entry"
            fi
          done < <(${keyctl} pipe "$key_id" 2>/dev/null || true)

          if [[ -z "$last_pw" ]]; then
            exit 0
          fi

          printf '%s' "$last_pw" | ${setpriv} --reuid "${user}" --regid "${userGroup}" --clear-groups \
            ${keyctl} session - ${pkgs.runtimeShell} -euo pipefail -c '
              kid="$(${keyctl} padd user omarchnix-login-keyring @s)"
              ${keyctl} setperm "$kid" 0x3f3f0000
              ${keyctl} timeout "$kid" 60
              ${keyctl} link "$kid" @u
            '
        '';

        sessionScript = pkgs.writeShellScript "hyprland-${tty}-session" (
          ''
            export XDG_RUNTIME_DIR="${runtimeDir}"
            export XDG_SESSION_TYPE=wayland
            export XDG_CURRENT_DESKTOP=Hyprland
          ''
          + lib.optionalString unlockKeyring ''
            if kid="$(${keyctl} search @u user omarchnix-login-keyring 2>/dev/null)"; then
              export GNOME_KEYRING_CONTROL="${runtimeDir}/keyring"
              if unlock_env="$(${keyctl} pipe "$kid" 2>/dev/null | ${gnomeKeyringWrapper} --daemonize --replace --unlock 2>/dev/null)"; then
                eval "$unlock_env"
                export GNOME_KEYRING_CONTROL
              fi
              ${keyctl} revoke "$kid" 2>/dev/null || true
              ${keyctl} unlink "$kid" @u 2>/dev/null || true
            fi
          ''
          + ''
            exec ${lib.getExe pkgs.uwsm} start -e -D Hyprland hyprland.desktop
          ''
        );
      in
      {
        # getty.target pulls in autovt@tty1, which `switch-to-configuration`
        # starts on every activation and thereby kills the live session.
        systemd.targets.getty.wants = lib.mkForce [ ];

        systemd.services."omarchnix-stage-luks-keyring-${tty}" = lib.mkIf unlockKeyring {
          description = "Stage LUKS passphrase for automatic GNOME Keyring unlock on ${tty}";
          wantedBy = [ "hyprland-${tty}.service" ];
          before = [ "hyprland-${tty}.service" ];
          after = [ "systemd-user-sessions.service" ];
          restartIfChanged = false;
          stopIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            KeyringMode = "shared";
            ExecStart = stageLuksKeyringScript;
          };
        };

        systemd.services."hyprland-${tty}" = {
          description = "Hyprland (uwsm) session on /dev/${tty}";
          wantedBy = [ "multi-user.target" ];
          wants = lib.optional unlockKeyring "omarchnix-stage-luks-keyring-${tty}.service";
          after = [
            "systemd-user-sessions.service"
            "nss-lookup.target"
            "network.target"
            "home-manager-${user}.service"
          ]
          ++ lib.optional unlockKeyring "omarchnix-stage-luks-keyring-${tty}.service";
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
            KeyringMode = "shared";
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
      time.timeZone = lib.mkDefault null;
      i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
      console.keyMap = lib.mkDefault "us";

      system.activationScripts.omarchnixDefaultTimeZone = lib.mkIf (config.time.timeZone == null) {
        deps = [ "etc" ];
        text = ''
          state_dir="/var/lib/omarchnix"
          stamp="$state_dir/configured-default-timezone"
          desired=${lib.escapeShellArg cfg.defaultTimeZone}
          zone_target="/etc/zoneinfo/$desired"
          if [ -e "$zone_target" ]; then
            prev=""
            if [ -f "$stamp" ]; then
              prev="$(cat "$stamp")"
            fi
            if [ ! -e /etc/localtime ] || [ "$prev" != "$desired" ]; then
              ln -sfn "$zone_target" /etc/localtime
              mkdir -p "$state_dir"
              printf '%s\n' "$desired" > "$stamp"
            fi
          fi
        '';
      };

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
        pkgs.ghostty.terminfo
      ]
      ++ lib.optional (omarchnixCliPkg != null) omarchnixCliPkg;

      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        auto-optimise-store = lib.mkDefault false;
      };

      nix.optimise.automatic = lib.mkDefault true;

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

        chromiumDeviceColorPolicyDir = pkgs.runCommand "omarchnix-chromium-managed-policies" { } ''
          mkdir -p "$out"
          cat > "$out/10-omarchnix-color-scheme.json" <<'EOF'
          {
            "BrowserColorScheme": "device"
          }
          EOF
        '';

        chromiumRecommendedPolicyDir = pkgs.runCommand "omarchnix-chromium-recommended-policies" { } ''
          mkdir -p "$out"
          cat > "$out/10-omarchnix-performance.json" <<'EOF'
          {
            "HighEfficiencyModeEnabled": true,
            "MemorySaverModeSavings": 1
          }
          EOF
        '';
      in
      {
        hardware.graphics.enable = lib.mkDefault true;

        # Managed policy directories as `/etc` symlinks so Chromium & Brave
        # follow the XDG Settings portal (`prefer-dark` / `prefer-light`)
        # globally across all desktops without triggering upstream
        # `omarchy-theme-set-browser-policy` root prompts (`[[ ! -L $dir ]]`).
        # Recommended policy directories enable Balanced Memory Saver by default
        # while keeping the UI toggle unlocked in `brave://settings/performance`.
        environment.etc = {
          "brave/policies/managed".source = lib.mkDefault chromiumDeviceColorPolicyDir;
          "chromium/policies/managed".source = lib.mkDefault chromiumDeviceColorPolicyDir;
          "brave/policies/recommended".source = lib.mkDefault chromiumRecommendedPolicyDir;
          "chromium/policies/recommended".source = lib.mkDefault chromiumRecommendedPolicyDir;
        };

        fonts = {
          enableDefaultPackages = lib.mkForce false;
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
        programs.xfconf.enable = lib.mkDefault true;

        programs.thunar = {
          enable = lib.mkDefault true;
          plugins = [
            pkgs.thunar-archive-plugin
            pkgs.thunar-volman
          ];
        };

        services.gvfs = {
          enable = lib.mkDefault true;
          package = lib.mkDefault pkgs.gvfs;
        };
        services.tumbler.enable = lib.mkDefault true;

        programs.hyprland = {
          enable = true;
          withUWSM = true;
          xwayland.enable = true;
        };

        environment.systemPackages = [
          pkgs.adw-gtk3
          pkgs.adwaita-icon-theme
          pkgs.morewaita-icon-theme
          pkgs.xarchiver
          pkgs.hyprsunset
          pkgs.lm_sensors
          pkgs.mission-center
        ];

        # Declaratively satisfy Mission Center's "Additional Setup" requirements on NixOS:
        # 1. Capability-wrapped `nethogs` (wheel-only) for live per-process Network bandwidth
        #    without imperative `setcap` on read-only `/nix/store`.
        # 2. `powercap` udev rule for CPU energy readings on RAPL-capable hosts.
        # 3. Setuid `pkexec` wrapper (`enablePkexecWrapper`) so killing root processes and
        #    controlling systemd units in Mission Center prompts via `omarchy.polkit`.
        security.wrappers.nethogs = {
          source = lib.getExe pkgs.nethogs;
          capabilities = "cap_net_admin,cap_net_raw,cap_dac_read_search,cap_sys_ptrace+eip";
          owner = "root";
          group = "wheel";
          permissions = "u+rx,g+x";
        };

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

        # Grant the active local seat user read access to hardware keyboard evdev
        # nodes (such as Apple MTP `KEY_FN` + `KEY_RIGHTSHIFT`) for Murmure global
        # push-to-talk / tap-to-toggle dictation without root or uinput grabs.
        # Must run at priority 70 (after `60-input-id.rules` sets `ID_INPUT_KEYBOARD=1`
        # and before `71-seat.rules` / `73-seat-late.rules` apply `uaccess` ACLs).
        services.udev.packages = lib.optional cfg.desktop.murmure.enable (
          pkgs.writeTextDir "etc/udev/rules.d/70-murmure-keyboard.rules" ''
            SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEYBOARD}=="1", TAG+="uaccess"
          ''
        );

        services.udev.extraRules = ''
          SUBSYSTEM=="powercap", KERNEL=="intel-rapl*", RUN+="${pkgs.coreutils}/bin/chmod a+r /sys/%p/energy_uj"
        '';

        security.pam.services.hyprlock = { };
        security.pam.services.omarchy-lock-password = { };
        security.polkit.enable = true;
        security.polkit.enablePkexecWrapper = lib.mkDefault true;
        security.polkit.extraConfig = ''
          polkit.addRule(function(action, subject) {
            if (action.id === "org.freedesktop.timedate1.set-timezone"
                && subject.isInGroup("wheel")
                && subject.local
                && subject.active) {
              return polkit.Result.YES;
            }
          });
        '';
      }
    ))
  ];
}
