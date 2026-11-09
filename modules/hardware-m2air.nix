{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.omarchnix.hardware.m2air;
  displayCutoutsJson = pkgs.writeText "m2air-display-cutouts.json" (
    builtins.toJSON {
      panels = [
        {
          connector = "eDP-1";
          width = 300;
          height = 64;
          top = 0;
        }
        {
          connector = "eDP";
          width = 300;
          height = 64;
          top = 0;
        }
      ];
    }
  );
in
{
  imports = [
    ./aurora-sep.nix
  ];

  options.omarchnix.hardware.m2air = {
    enable = lib.mkEnableOption "MacBook Air M2 (J413 / J415) hardware polish: Asahi DSP audio, Liquid Retina HiDPI + notch metadata, SMC power/battery charge thresholds, and s2idle sleep tuning";

    displayScale = lib.mkOption {
      type = lib.types.str;
      default = "1.6";
      description = "Fractional Wayland scale for the 2560x1664 Liquid Retina eDP-1 panel (1.6 -> 1600x1040 logical).";
    };

    chargeControlEndThreshold = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 50 100);
      default = 80;
      description = "Apple SMC battery charge upper threshold (%) written to macsmc-battery when present; null leaves at 100%.";
    };

    chargeControlStartThreshold = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 40 95);
      default = 75;
      description = "Apple SMC battery charge start threshold (%) written to macsmc-battery when present.";
    };
  };

  config = lib.mkMerge [
    (lib.optionalAttrs (options ? hardware && options.hardware ? asahi) (
      lib.mkIf cfg.enable {
        hardware.asahi = {
          enable = true;
          setupAsahiSound = true;
          extractPeripheralFirmware = true;
          avd = {
            enable = true;
            vaapi-support = true;
          };
        };
      }
    ))

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = options ? hardware && options.hardware ? asahi;
          message = "omarchnix.hardware.m2air requires apple-silicon-support.nixosModules.apple-silicon-support to be imported.";
        }
        {
          assertion =
            cfg.chargeControlEndThreshold == null
            || cfg.chargeControlStartThreshold == null
            || cfg.chargeControlStartThreshold < cfg.chargeControlEndThreshold;
          message = "omarchnix.hardware.m2air: chargeControlStartThreshold must be strictly less than chargeControlEndThreshold.";
        }
      ];

      hardware.graphics.enable = true;

      # Ensure Apple SPI/DockChannel/USB keyboard HID support is always present in
      # stage-1 initrd for LUKS2 passphrase entry, even when includeDefaultModules = false.
      boot.initrd.availableKernelModules = [ "hid_apple" ];

      hardware.bluetooth = {
        enable = true;
        powerOnBoot = true;
      };

      networking.networkmanager = {
        enable = true;
        wifi = {
          powersave = true;
          scanRandMacAddress = true;
        };
      };

      services.upower = {
        enable = true;
        percentageLow = 15;
        percentageCritical = 7;
        percentageAction = 4;
        criticalPowerAction = "PowerOff";
      };

      services.power-profiles-daemon.enable = true;

      services.logind.settings.Login = {
        HandleLidSwitch = "suspend";
        HandleLidSwitchExternalPower = "suspend";
        HandleLidSwitchDocked = "ignore";
        HandlePowerKey = "ignore";
        HandlePowerKeyLongPress = "poweroff";
      };

      systemd.sleep.settings.Sleep = {
        AllowSuspend = "yes";
        AllowHibernation = "no";
        AllowHybridSleep = "no";
        AllowSuspendThenHibernate = "no";
        SuspendState = "freeze";
      };

      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 50;
      };

      environment.sessionVariables = {
        NIXOS_OZONE_WL = "1";
        MOZ_ENABLE_WAYLAND = "1";
        QT_QPA_PLATFORM = "wayland;xcb";
        GDK_BACKEND = "wayland,x11,*";
        SDL_VIDEODRIVER = "wayland";
      };

      environment.systemPackages =
        with pkgs;
        [
          exfatprogs
          wf-recorder
          wiremix
          bluetui
          impala
          brightnessctl
          pamixer
        ]
        ++ lib.optionals (pkgs.stdenv.hostPlatform.system == "aarch64-linux" && pkgs ? asahi-bless) [
          pkgs.asahi-bless
        ];

      systemd.tmpfiles.rules = [
        "d /usr/share/omarchy-platform 0755 root root - -"
        "L+ /usr/share/omarchy-platform/display-cutouts.json - - - - ${displayCutoutsJson}"
      ];

      systemd.services.macsmc-battery-thresholds = lib.mkIf (cfg.chargeControlEndThreshold != null) {
        description = "Configure Apple SMC battery charge thresholds on MacBook Air M2";
        wantedBy = [ "multi-user.target" ];
        after = [ "multi-user.target" ];
        unitConfig.ConditionPathExistsGlob = "/sys/class/power_supply/macsmc-battery/charge_control_end_threshold";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          bat="/sys/class/power_supply/macsmc-battery"
          if [ -w "$bat/charge_control_end_threshold" ]; then
            echo ${toString cfg.chargeControlEndThreshold} > "$bat/charge_control_end_threshold"
          fi
          ${lib.optionalString (cfg.chargeControlStartThreshold != null) ''
            if [ -w "$bat/charge_control_start_threshold" ]; then
              echo ${toString cfg.chargeControlStartThreshold} > "$bat/charge_control_start_threshold"
            fi
          ''}
        '';
      };
    })
  ];
}
