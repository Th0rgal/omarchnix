{
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}:
let
  cfg = config.programs.omarchnix;
  sCfg = cfg.sharing;

  omarchyLib = import ../lib/omarchy.nix { inherit lib; };

  buildPlugin =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? buildPlugin) then
      pkgs.omarchnix.buildPlugin
    else
      (args: omarchyLib.buildPlugin ({ inherit pkgs; } // args));

  omarchyShell = cfg.shell.package;

  defaultOmdropPkg =
    if pkgs ? omdrop then
      pkgs.omdrop
    else if (pkgs ? omarchnix) && (pkgs.omarchnix ? omdrop) then
      pkgs.omarchnix.omdrop
    else if (inputs ? omdrop-awdl) && (inputs ? omdrop-plugin) then
      pkgs.callPackage ../pkgs/omdrop.nix {
        omdropAwdlSrc = inputs.omdrop-awdl;
        omdropPluginSrc = inputs.omdrop-plugin;
        inherit buildPlugin omarchyShell;
      }
    else
      null;

  defaultQuicksharePkg =
    if pkgs ? omarchy-quickshare then
      pkgs.omarchy-quickshare
    else if (pkgs ? omarchnix) && (pkgs.omarchnix ? omarchy-quickshare) then
      pkgs.omarchnix.omarchy-quickshare
    else if inputs ? omarchy-quickshare then
      pkgs.callPackage ../pkgs/omarchy-quickshare.nix {
        omarchyQuickshareSrc = inputs.omarchy-quickshare;
        inherit buildPlugin omarchyShell;
      }
    else
      null;

  defaultNearbyPkg =
    if pkgs ? omarchy-nearby then
      pkgs.omarchy-nearby
    else if (pkgs ? omarchnix) && (pkgs.omarchnix ? omarchy-nearby) then
      pkgs.omarchnix.omarchy-nearby
    else if inputs ? omarchy-nearby then
      pkgs.callPackage ../pkgs/omarchy-nearby.nix {
        omarchyNearbySrc = inputs.omarchy-nearby;
        inherit buildPlugin;
      }
    else
      null;

  defaultKdeconnectPkg =
    if (pkgs ? kdePackages) && (pkgs.kdePackages ? kdeconnect-kde) then
      pkgs.kdePackages.kdeconnect-kde
    else
      null;

  omdropPkg = if sCfg.airdrop.package != null then sCfg.airdrop.package else defaultOmdropPkg;
  quicksharePkg =
    if sCfg.quickshare.package != null then sCfg.quickshare.package else defaultQuicksharePkg;
  nearbyPkg = if sCfg.nearby.package != null then sCfg.nearby.package else defaultNearbyPkg;
  kdeconnectPkg =
    if sCfg.kdeconnect.package != null then sCfg.kdeconnect.package else defaultKdeconnectPkg;

  omdropPlugin = if omdropPkg != null then (omdropPkg.passthru.plugin or null) else null;
  omdropSkillFile = if omdropPkg != null then (omdropPkg.passthru.skillFile or null) else null;
  quicksharePlugin = if quicksharePkg != null then (quicksharePkg.passthru.plugin or null) else null;
  nearbyPlugin = if nearbyPkg != null then (nearbyPkg.passthru.plugin or null) else null;

  airdropActive = sCfg.airdrop.enable && omdropPkg != null;
  quickshareActive = sCfg.quickshare.enable && quicksharePkg != null;
  nearbyActive = sCfg.nearby.enable && nearbyPkg != null;
  kdeconnectActive = sCfg.kdeconnect.enable && kdeconnectPkg != null;
  anySharingActive = airdropActive || quickshareActive || nearbyActive || kdeconnectActive;

  kdeconnectPython = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);

  kdeconnectCliShim =
    if kdeconnectPkg != null then
      pkgs.runCommand "kdeconnect-cli-shim-${kdeconnectPkg.version}" { } ''
        mkdir -p "$out/bin"
        cat > "$out/bin/kdeconnect-cli" <<'EOF'
        #!${pkgs.runtimeShell}
        export QT_QPA_PLATFORM="''${QT_QPA_PLATFORM:-wayland;xcb}"
        exec "${kdeconnectPkg}/bin/kdeconnect-cli" "$@"
        EOF
        chmod 0755 "$out/bin/kdeconnect-cli"
      ''
    else
      null;

  kdeconnectHelperPkg =
    if kdeconnectPkg != null then
      pkgs.runCommand "omarchnix-kdeconnect-helper"
        {
          nativeBuildInputs = [ pkgs.makeWrapper ];
        }
        ''
          mkdir -p "$out/bin" "$out/libexec"
          cp --no-preserve=mode,ownership "${../pkgs/omarchnix-kdeconnect-helper.py}" \
            "$out/libexec/omarchnix-kdeconnect-helper.py"
          substituteInPlace "$out/libexec/omarchnix-kdeconnect-helper.py" \
            --replace-fail "@KDECONNECT_CLI@" "${kdeconnectPkg}/bin/kdeconnect-cli" \
            --replace-fail "@IP_BIN@" "${pkgs.iproute2}/bin/ip" \
            --replace-fail "@SSHFS_BIN@" "${pkgs.sshfs}/bin/sshfs" \
            --replace-fail "@FUSERMOUNT3_BIN@" "/run/wrappers/bin/fusermount3" \
            --replace-fail "@GIO_BIN@" "${pkgs.glib}/bin/gio" \
            --replace-fail "@XDG_OPEN_BIN@" "${pkgs.xdg-utils}/bin/xdg-open"
          sed -i "1s|^#!/usr/bin/env python3$|#!${kdeconnectPython}/bin/python3|" \
            "$out/libexec/omarchnix-kdeconnect-helper.py"
          chmod 0755 "$out/libexec/omarchnix-kdeconnect-helper.py"

          makeWrapper "$out/libexec/omarchnix-kdeconnect-helper.py" "$out/bin/omarchnix-kdeconnect-helper" \
            --prefix GI_TYPELIB_PATH : "${pkgs.glib.out}/lib/girepository-1.0" \
            --prefix PATH : "/run/wrappers/bin:${
              lib.makeBinPath [
                pkgs.sshfs
                pkgs.fuse3
                pkgs.glib
                pkgs.iproute2
                pkgs.xdg-utils
              ]
            }:/run/current-system/sw/bin" \
            --set-default OMARCHNIX_KDECONNECT_SEED_ADDRESSES ${lib.escapeShellArg (builtins.toJSON sCfg.kdeconnect.customAddresses)}
        ''
    else
      null;

  omdropBinPath = if airdropActive then "${omdropPkg}/bin/omdrop" else "";
  quickshareBinPath = if quickshareActive then "${quicksharePkg}/bin/omarchy-quickshare" else "";
  nearbyHelperBinPath = if nearbyActive then "${nearbyPkg}/bin/omarchy-nearby-helper" else "";
  kdeconnectHelperBinPath =
    if kdeconnectActive && kdeconnectHelperPkg != null then
      "${kdeconnectHelperPkg}/bin/omarchnix-kdeconnect-helper"
    else
      "";
  fileSelectBinPath = if omarchyShell != null then "${omarchyShell}/bin/omarchy-file-select" else "";
  notifyBinPath =
    if omarchyShell != null then "${omarchyShell}/bin/omarchy-notification-send" else "";

  unifiedSharingPlugin =
    if buildPlugin != null then
      buildPlugin {
        src = ../pkgs/plugins/omarchnix-sharing;
        postInstall = ''
          substituteInPlace "$out/Service.qml" \
            --replace-fail "@OMDROP_BIN@" ${lib.escapeShellArg omdropBinPath} \
            --replace-fail "@QUICKSHARE_BIN@" ${lib.escapeShellArg quickshareBinPath} \
            --replace-fail "@NEARBY_HELPER_BIN@" ${lib.escapeShellArg nearbyHelperBinPath} \
            --replace-fail "@KDECONNECT_HELPER_BIN@" ${lib.escapeShellArg kdeconnectHelperBinPath} \
            --replace-fail "@FILE_SELECT_BIN@" ${lib.escapeShellArg fileSelectBinPath} \
            --replace-fail "@NOTIFY_BIN@" ${lib.escapeShellArg notifyBinPath} \
            --replace-fail "@XDG_OPEN_BIN@" "${pkgs.xdg-utils}/bin/xdg-open" \
            --replace-fail "@WL_COPY_BIN@" "${pkgs.wl-clipboard}/bin/wl-copy"
        '';
      }
    else
      null;

  barSectionType = lib.types.nullOr (
    lib.types.enum [
      "left"
      "centerBegin"
      "center"
      "centerEnd"
      "tray"
      "right"
    ]
  );

  mkOmdropSkillFor = prefix: {
    "${prefix}/SKILL.md".source = omdropSkillFile;
  };
in
{
  options.programs.omarchnix.sharing = {
    unifiedBar = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Combine AirDrop, Quick Share, and Nearby into a single `omarchnix.sharing` status-bar icon and popover.";
    };

    barSection = lib.mkOption {
      type = barSectionType;
      default = "right";
      description = "Status-bar section where the unified `omarchnix.sharing` widget is placed.";
    };

    airdrop = {
      enable = lib.mkEnableOption "Apple AirDrop wireless sharing (`omdrop`)";

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        defaultText = lib.literalExpression "pkgs.omdrop";
        description = "Package providing the `omdrop` CLI and `netmojo.omdrop` plugin.";
      };

      barSection = lib.mkOption {
        type = barSectionType;
        default = "right";
        description = "Status-bar section where `netmojo.omdrop` is placed when `unifiedBar = false`.";
      };

      computerName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional initial AirDrop display name seeded into `~/.config/airdrop/config.toml` when absent.";
      };

      installAgentSkill = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Provision the `omdrop` agent skill across `programs.omarchnix.agents.targets`.";
      };
    };

    quickshare = {
      enable = lib.mkEnableOption "Android & Chromebook Quick Share (`omarchy-quickshare`)";

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        defaultText = lib.literalExpression "pkgs.omarchy-quickshare";
        description = "Package providing `omarchy-quickshare` and the `macondo.quickshare` plugin.";
      };

      barSection = lib.mkOption {
        type = barSectionType;
        default = "right";
        description = "Status-bar section where `macondo.quickshare` is placed when `unifiedBar = false`.";
      };
    };

    nearby = {
      enable = lib.mkEnableOption "LocalSend v2 LAN sharing (`omarchy-nearby`)";

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        defaultText = lib.literalExpression "pkgs.omarchy-nearby";
        description = "Package providing `omarchy-nearby-helper` and the `oma.nearby` plugin.";
      };

      barSection = lib.mkOption {
        type = barSectionType;
        default = "right";
        description = "Status-bar section where `oma.nearby` is placed when `unifiedBar = false`.";
      };
    };

    kdeconnect = {
      enable = lib.mkEnableOption "KDE Connect bidirectional clipboard, file, and phone sync (`kdeconnectd`)";

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        defaultText = lib.literalExpression "pkgs.kdePackages.kdeconnect-kde";
        description = "Package providing `kdeconnectd` and `kdeconnect-cli`.";
      };

      customAddresses = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Declarative peer IPv4/IPv6 addresses (e.g. `lean-mesh` `10.88.x.x` or static LAN IPs)
          merged into KDE Connect's `customDevices` list without clobbering UI-added addresses.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf (sCfg.unifiedBar && anySharingActive) {
        programs.omarchnix.plugins.locked."omarchnix.sharing" = {
          package = unifiedSharingPlugin;
          enable = true;
          section = sCfg.barSection;
        };

        programs.omarchnix.shell.purgedPluginIds = [
          "netmojo.omdrop"
          "macondo.quickshare"
          "oma.nearby"
          "seb-krz.omarchy-connect"
          "omakdeconnect"
          "omaconnect"
          "omaconnect.plus"
        ];
      })

      (lib.mkIf airdropActive {
        home.packages = [ omdropPkg ];

        programs.omarchnix.plugins.locked = lib.optionalAttrs (!sCfg.unifiedBar && omdropPlugin != null) {
          "netmojo.omdrop" = {
            package = omdropPlugin;
            enable = true;
            section = sCfg.airdrop.barSection;
          };
        };

        home.file =
          lib.mkIf (cfg.agents.enable && sCfg.airdrop.installAgentSkill && omdropSkillFile != null)
            (
              (mkOmdropSkillFor ".agents/skills/omdrop")
              // lib.optionalAttrs (builtins.elem "claude" cfg.agents.targets) (
                mkOmdropSkillFor ".claude/skills/omdrop"
              )
              // lib.optionalAttrs (builtins.elem "codex" cfg.agents.targets) (
                mkOmdropSkillFor ".codex/skills/omdrop"
              )
              // lib.optionalAttrs (builtins.elem "hermes" cfg.agents.targets) (
                mkOmdropSkillFor ".hermes/skills/omdrop"
              )
              // lib.optionalAttrs (builtins.elem "opencode" cfg.agents.targets) (
                mkOmdropSkillFor ".config/opencode/skills/omdrop"
              )
            );

        home.activation.omarchnixAirDropSetup =
          config.lib.dag.entryAfter [ "writeBoundary" "omarchnixStateAndPlugins" ]
            ''
              mkdir -p "$HOME/.config/airdrop"
              ${lib.optionalString (sCfg.airdrop.computerName != null) ''
                if [ ! -f "$HOME/.config/airdrop/config.toml" ]; then
                  printf 'name = %s\n' ${lib.escapeShellArg (builtins.toJSON sCfg.airdrop.computerName)} > "$HOME/.config/airdrop/config.toml"
                  chmod 0600 "$HOME/.config/airdrop/config.toml"
                fi
              ''}
              "${omdropPkg}/bin/omdrop" setup >/dev/null 2>&1 || true
            '';
      })

      (lib.mkIf quickshareActive {
        home.packages = [ quicksharePkg ];

        programs.omarchnix.plugins.locked =
          lib.optionalAttrs (!sCfg.unifiedBar && quicksharePlugin != null)
            {
              "macondo.quickshare" = {
                package = quicksharePlugin;
                enable = true;
                section = sCfg.quickshare.barSection;
              };
            };

        xdg.dataFile."dbus-1/services/io.omarchy.QuickShare.service".text = ''
          [D-BUS Service]
          Name=io.omarchy.QuickShare
          Exec=${quicksharePkg}/bin/omarchy-quickshare serve
          SystemdService=omarchy-quickshare.service
        '';

        systemd.user.services.omarchy-quickshare = {
          Unit = {
            Description = "Quick Share for Omarchy";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };
          Service = {
            Type = "dbus";
            BusName = "io.omarchy.QuickShare";
            ExecStart = "${quicksharePkg}/bin/omarchy-quickshare serve";
            Environment = [
              "PATH=${
                lib.makeBinPath (
                  [
                    pkgs.bluez
                    pkgs.coreutils
                    pkgs.iw
                    pkgs.jq
                    pkgs.networkmanager
                  ]
                  ++ lib.optional (omarchyShell != null) omarchyShell
                )
              }:/run/current-system/sw/bin"
            ];
            Restart = "on-failure";
            RestartSec = 3;
            KillSignal = "SIGINT";
            TimeoutStopSec = 20;
            UMask = "0077";
            NoNewPrivileges = true;
          };
        };
      })

      (lib.mkIf nearbyActive {
        home.packages = [ nearbyPkg ];

        programs.omarchnix.plugins.locked = lib.optionalAttrs (!sCfg.unifiedBar && nearbyPlugin != null) {
          "oma.nearby" = {
            package = nearbyPlugin;
            enable = true;
            section = sCfg.nearby.barSection;
          };
        };
      })

      (lib.mkIf kdeconnectActive {
        home.packages = lib.filter (p: p != null) [
          kdeconnectCliShim
          kdeconnectHelperPkg
        ];

        xdg.dataFile."dbus-1/services/org.kde.kdeconnect.service".text = ''
          [D-BUS Service]
          Name=org.kde.kdeconnect
          Exec=${kdeconnectPkg}/bin/kdeconnectd
          SystemdService=kdeconnect.service
        '';

        systemd.user.services.kdeconnect = {
          Unit = {
            Description = "KDE Connect daemon for Omarchy phone clipboard and file sync";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
            ConditionEnvironment = "WAYLAND_DISPLAY";
          };
          Service = {
            Type = "dbus";
            BusName = "org.kde.kdeconnect";
            ExecStart = "${kdeconnectPkg}/bin/kdeconnectd";
            Environment = [
              "QT_QPA_PLATFORM=wayland;xcb"
              "PATH=/run/wrappers/bin:${
                lib.makeBinPath [
                  pkgs.sshfs
                  pkgs.fuse3
                  pkgs.glib
                  pkgs.wl-clipboard
                  pkgs.xdg-utils
                ]
              }:/run/current-system/sw/bin"
            ];
            Restart = "on-failure";
            RestartSec = 3;
          };
          Install = {
            WantedBy = [ "graphical-session.target" ];
          };
        };
      })
    ]
  );
}
