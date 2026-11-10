{
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}:
let
  cfg = config.omarchnix;
  sCfg = cfg.services.sharing;

  buildPlugin =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? buildPlugin) then pkgs.omarchnix.buildPlugin else null;

  omarchyShell =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? omarchy-shell) then
      pkgs.omarchnix.omarchy-shell
    else
      null;

  omdropPkg =
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
in
{
  options.omarchnix.services.sharing = {
    airdrop = {
      enable = lib.mkEnableOption "Apple AirDrop wireless file sharing over Broadcom AWDL (omdrop)";

      warmupAtBoot = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run `awdl-warmup` instead of `awdl-up` at boot. Disabled by default
          because `awdl-warmup` leaves `awdl=1` and `PROMISC` active 24/7, keeping
          the Broadcom Wi-Fi radio channel-hopping on its AWDL slot schedule at idle.
          When `false`, `awdl0.service` (`awdl-up`) creates `awdl0` configured and
          idle (`awdl=0`) at zero idle radio cost until an AirDrop window is opened.
        '';
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Allow IPv6 link-local AirDrop HTTPS (`TCP 8771`) and mDNS (`UDP 5353`) strictly on `awdl0`.";
      };
    };

    quickshare = {
      enable = lib.mkEnableOption "Android & Chromebook Quick Share wireless file sharing (omarchy-quickshare)";

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open Quick Share transport `TCP 47593` and mDNS `UDP 5353` in the NixOS firewall.";
      };
    };

    nearby = {
      enable = lib.mkEnableOption "Cross-platform LocalSend v2 LAN file sharing (omarchy-nearby)";

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open LocalSend v2 `TCP/UDP 53317` in the NixOS firewall.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf (sCfg.airdrop.enable && omdropPkg != null) {
        # Installing `core` and `awdl` into `systemPackages` links both Polkit
        # action policies (`org.omarchy.omdrop.radio.policy` & `org.omarchy.omdrop.policy`)
        # into `/run/current-system/sw/share/polkit-1/actions/`.
        environment.systemPackages = [
          omdropPkg
          omdropPkg.passthru.awdl
          omdropPkg.passthru.core
        ];

        services.avahi = {
          enable = lib.mkDefault true;
          nssmdns4 = lib.mkDefault true;
          nssmdns6 = lib.mkDefault true;
        };

        networking.networkmanager.unmanaged = [
          "interface-name:awdl0"
        ];

        environment.etc."NetworkManager/conf.d/99-awdl-unmanaged.conf".text = ''
          [keyfile]
          unmanaged-devices=interface-name:awdl0
        '';

        networking.firewall = lib.mkIf sCfg.airdrop.openFirewall {
          extraCommands = ''
            ip6tables -w -A nixos-fw -i awdl0 -s fe80::/10 -d fe80::/10 -p tcp --dport 8771 -j nixos-fw-accept
            ip6tables -w -A nixos-fw -i awdl0 -s fe80::/10 -p udp --dport 5353 -j nixos-fw-accept
          '';
          extraStopCommands = ''
            ip6tables -w -D nixos-fw -i awdl0 -s fe80::/10 -d fe80::/10 -p tcp --dport 8771 -j nixos-fw-accept 2>/dev/null || true
            ip6tables -w -D nixos-fw -i awdl0 -s fe80::/10 -p udp --dport 5353 -j nixos-fw-accept 2>/dev/null || true
          '';
        };

        systemd.services.awdl0 = lib.mkIf (!sCfg.airdrop.warmupAtBoot) {
          description = "Create and configure idle Broadcom awdl0 for AirDrop";
          after = [ "NetworkManager.service" ];
          wantedBy = [ "multi-user.target" ];
          restartIfChanged = false;
          unitConfig = {
            ConditionPathExists = "/sys/module/brcmfmac/parameters/awdl";
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${omdropPkg.passthru.awdl}/lib/omdrop/awdl-up";
            TimeoutStartSec = "infinity";
            TimeoutStopSec = 30;
          };
        };

        systemd.services.awdl-warmup = lib.mkIf sCfg.airdrop.warmupAtBoot {
          description = "Warm up Broadcom awdl0 for instant AirDrop windows";
          after = [ "NetworkManager.service" ];
          wantedBy = [ "multi-user.target" ];
          restartIfChanged = false;
          unitConfig = {
            ConditionPathExists = "/sys/module/brcmfmac/parameters/awdl";
          };
          serviceConfig = {
            Type = "exec";
            ExecStart = "${omdropPkg.passthru.awdl}/lib/omdrop/awdl-warmup";
            TimeoutStartSec = "infinity";
            TimeoutStopSec = 30;
            Restart = "no";
          };
        };

        # Protect BCM4387 `wlan0` association across `s2idle` suspend/resume (#67)
        # by cleanly stopping any active AirDrop window and destroying `awdl0`
        # before entering `sleep.target`, then clearing the sleep marker on resume.
        systemd.services.omdrop-awdl-sleep = {
          description = "Tear down Broadcom awdl0 before suspend and clear sleep marker on resume";
          before = [ "sleep.target" ];
          wantedBy = [ "sleep.target" ];
          restartIfChanged = false;
          unitConfig = {
            StopWhenUnneeded = true;
            ConditionPathExists = "/sys/module/brcmfmac/parameters/awdl";
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${omdropPkg.passthru.awdl}/bin/omdrop-awdl-sleep pre";
            ExecStop = "${omdropPkg.passthru.awdl}/bin/omdrop-awdl-sleep post";
            TimeoutStartSec = 90;
            TimeoutStopSec = 15;
          };
        };
      })

      (lib.mkIf sCfg.quickshare.enable {
        services.avahi = {
          enable = lib.mkDefault true;
          nssmdns4 = lib.mkDefault true;
          nssmdns6 = lib.mkDefault true;
        };

        hardware.bluetooth.enable = lib.mkDefault true;

        # Provide `dnsmasq` on NetworkManager's service PATH so Quick Share's
        # Wi-Fi Hotspot transport works out-of-the-box without running a global daemon.
        systemd.services.NetworkManager.path = lib.mkIf config.networking.networkmanager.enable [
          pkgs.dnsmasq
        ];

        networking.firewall = lib.mkIf sCfg.quickshare.openFirewall {
          allowedTCPPorts = [ 47593 ];
          allowedUDPPorts = [ 5353 ];
        };
      })

      (lib.mkIf sCfg.nearby.enable {
        networking.firewall = lib.mkIf sCfg.nearby.openFirewall {
          allowedTCPPorts = [ 53317 ];
          allowedUDPPorts = [ 53317 ];
        };
      })
    ]
  );
}
