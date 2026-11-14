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
      default = 100;
      description = "Apple SMC battery charge upper threshold (%) written to macsmc-battery when present (100 charges to full, 80 caps at 80%).";
    };

    chargeControlStartThreshold = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 40 100);
      default = null;
      description = "Apple SMC battery charge start threshold (%) written to macsmc-battery when present.";
    };

    efficiencyCoreSteering = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Steer background daemons, real-time audio DSP (`PipeWire`, `WirePlumber`,
        `speakerguardd-v2`), cloud FUSE mounts, and routine `nix-daemon` builds
        toward the 4 Blizzard efficiency cores (`cpu0..3`) on MacBook Air M2 so
        periodic wakeups leave the 4 Avalanche performance cores (`cpu4..7`) in
        deep cluster power-down (`CPU PD`).
      '';
    };

    keyboardBacklight = {
      defaultBrightness = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 0 100);
        default = 50;
        description = ''
          Default keyboard backlight brightness (%) seeded on MacBook Air M2
          (`/sys/class/leds/kbd_backlight`) when uninitialized or when this
          declarative value changes. Runtime adjustments persist across normal
          reboots via `systemd-backlight`, unless `enforceOnBoot = true`.
          Set to `null` to leave keyboard backlight boot state untouched.
        '';
      };

      enforceOnBoot = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When `true`, always set `/sys/class/leds/kbd_backlight` to
          `defaultBrightness` on every boot instead of preserving the previous
          session's `systemd-backlight` level.
        '';
      };
    };

    isoLayout = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          (-1)
          0
          1
        ]
      );
      default = 0;
      description = ''
        Value written to `/sys/module/hid_apple/parameters/iso_layout` in Stage-2.
        Apple Silicon International English ISO keyboards (`apple_layout_id = 4`, HID `country = 0x0d`)
        already map the physical `` ` ``/`~` key next to Left Shift to `<TLDE>` in MTP firmware;
        setting `0` prevents `hid_apple` from swapping `<TLDE>` and `<LSGT>`, while leaving Stage-1
        initrd LUKS passphrase entry untouched.
      '';
    };

    bootloader = {
      enable = lib.mkEnableOption "removable ARM64 UEFI GRUB on the Asahi ESP (/boot/EFI/BOOT/BOOTAA64.EFI) without touching Apple NVRAM, m1n1/boot.bin, or vendorfw";

      efiSysMountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/boot";
        description = "Mount point of the Asahi EFI System Partition.";
      };

      configurationLimit = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Maximum GRUB generations kept on the ~500 MB Asahi ESP.";
      };
    };

    fileSystems = {
      enable = lib.mkEnableOption "UUID-mounted LUKS2 cryptroot (/) and FAT32 Asahi ESP (/boot) for MacBook Air M2";

      luksUuid = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "aa0403dd-9917-49e1-85b1-46b21b39f2d9";
        description = "UUID of the LUKS2 root partition (/dev/disk/by-uuid/<luksUuid>).";
      };

      espUuid = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "C650-1003";
        description = "UUID of the FAT32 Asahi EFI System Partition (/dev/disk/by-uuid/<espUuid>).";
      };
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

        services.pipewire.wireplumber.configPackages = [
          (pkgs.writeTextDir "share/wireplumber/scripts/linking/asahi-relink-rawmics.lua" ''
            -- Ensure the Apple Silicon HPAI beamforming mic filter (`audio_effect.*-mic`,
            -- `target.object = "alsa_input.platform-sound.RawMics"`) always links to
            -- `RawMics` after lid close/open (`Internal Mic Jack`) or `s2idle` resume.
            local cutils = require("common-utils")
            local lutils = require("linking-utils")
            local log = Log.open_topic("s-linking")

            local pending_timer = nil

            local function check_and_relink()
              pending_timer = nil
              local source = Plugin.find("standard-event-source")
              if not source then
                return
              end
              local om = source:call("get-object-manager", "session-item")
              if not om then
                return
              end

              local raw_si = nil
              local filter_si = nil

              for si in om:iterate({ type = "SiLinkable" }) do
                local p = si.properties
                local name = p["node.name"]
                if name == "alsa_input.platform-sound.RawMics" then
                  raw_si = si
                elseif p["target.object"] == "alsa_input.platform-sound.RawMics" then
                  filter_si = si
                end
              end

              if not raw_si or not filter_si then
                return
              end

              local existing_si_link = lutils.lookupLink(filter_si.id, raw_si.id)
              local pw_linked = false
              local filter_node_id = tonumber(filter_si.properties["node.id"])
              local raw_node_id = tonumber(raw_si.properties["node.id"])
              local links_om = source:call("get-object-manager", "link")
              if links_om and filter_node_id and raw_node_id then
                for l in links_om:iterate() do
                  local lp = l.properties
                  if tonumber(lp["link.output.node"]) == raw_node_id
                      and tonumber(lp["link.input.node"]) == filter_node_id then
                    pw_linked = true
                    break
                  end
                end
              end

              if existing_si_link and pw_linked then
                return
              end

              if existing_si_link then
                existing_si_link:remove()
              end

              log:notice(filter_si, "RawMics filter unlinked; pushing select-target + rescan")
              local flags = lutils:get_flags(filter_si.id)
              flags.peer_id = nil
              flags.failed_peer_id = nil
              flags.failed_count = 0
              source:call("push-event", "select-target", filter_si, nil)
              source:call("schedule-rescan", "linking")
            end

            local function schedule_relink(delay_ms)
              if pending_timer then
                pending_timer:destroy()
                pending_timer = nil
              end
              pending_timer = Core.timeout_add(delay_ms or 350, function()
                check_and_relink()
                return false
              end)
            end

            SimpleEventHook({
              name = "linking/asahi-relink-rawmics",
              interests = {
                EventInterest({
                  Constraint({ "event.type", "=", "session-item-added" }),
                  Constraint({ "event.session-item.interface", "=", "linkable" }),
                }),
                EventInterest({
                  Constraint({ "event.type", "=", "device-params-changed" }),
                  Constraint({ "event.subject.param-id", "c", "Route", "EnumRoute", "Profile" }),
                }),
              },
              execute = function(event)
                local eprops = event:get_properties()
                if eprops["event.type"] == "session-item-added" then
                  local si = event:get_subject()
                  local p = si and si.properties
                  if p then
                    local name = p["node.name"]
                    if name == "alsa_input.platform-sound.RawMics"
                        or p["target.object"] == "alsa_input.platform-sound.RawMics"
                        or (name and name:find("^pw%-cat"))
                        or (name and name:find("^pw%-record")) then
                      schedule_relink(250)
                    end
                  end
                else
                  schedule_relink(350)
                end
              end,
            }):register()

            schedule_relink(600)
          '')
          (
            let
              conf = pkgs.writeTextDir "share/wireplumber/wireplumber.conf.d/99-zz-asahi-mic.conf" ''
                monitor.alsa.rules = [
                  {
                    matches = [
                      { device.name = "~alsa_card.*", api.alsa.card.name = "~^Mac.* HPAI$" }
                      { device.name = "~alsa_card.*", api.alsa.card.name = "MacBook Neo J700 AOP" }
                    ]
                    actions = {
                      update-props = {
                        api.acp.disable-pro-audio = true
                      }
                    }
                  }
                ]

                wireplumber.components = [
                  {
                    name = linking/asahi-relink-rawmics.lua, type = script/lua
                    provides = custom.asahi-relink-rawmics
                  }
                ]

                wireplumber.profiles = {
                  main = {
                    custom.asahi-relink-rawmics = required
                  }
                }
              '';
            in
            conf
            // {
              passthru = (conf.passthru or { }) // {
                onlyConfigs = false;
              };
            }
          )
        ];
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
        priority = 100;
      };

      # Bound concurrent Nix sandbox builds on 8-core / 16 GiB unified-memory M2 Air
      # so parallel coding-agent evaluations/VMs/compiles cannot spawn 8 simultaneous
      # multi-GiB `qemu` / `lean` / `rustc` derivations and exhaust RAM + swap.
      nix.settings = {
        max-jobs = lib.mkDefault 2;
        cores = lib.mkDefault 4;
      };

      systemd.services.avahi-daemon.serviceConfig = lib.optionalAttrs cfg.efficiencyCoreSteering {
        CPUAffinity = "0-3";
      };
      systemd.services.upower.serviceConfig = lib.optionalAttrs cfg.efficiencyCoreSteering {
        CPUAffinity = "0-3";
      };
      systemd.services.bluetooth.serviceConfig = lib.optionalAttrs cfg.efficiencyCoreSteering {
        CPUAffinity = "0-3";
      };
      systemd.services.power-profiles-daemon.serviceConfig =
        lib.optionalAttrs cfg.efficiencyCoreSteering
          {
            CPUAffinity = "0-3";
          };
      systemd.services."container@".serviceConfig = lib.optionalAttrs cfg.efficiencyCoreSteering {
        CPUAffinity = "0-3";
      };

      systemd.user.services = lib.optionalAttrs cfg.efficiencyCoreSteering (
        lib.genAttrs
          [
            "pipewire"
            "pipewire-pulse"
            "wireplumber"
            "speakerguardd-v2-session"
            "murmure"
            "rclone-apple"
            "rclone-google"
            "omarchy-quickshare"
            "omarchnix-nearby"
            "kdeconnect"
            "kdeconnectd"
            "kdeconnect-indicator"
            "opencode"
          ]
          (_: {
            serviceConfig.CPUAffinity = "0-3";
          })
      );

      systemd.services.nix-daemon.serviceConfig = {
        MemoryHigh = lib.mkDefault "10G";
        CPUWeight = lib.mkDefault 25;
        IOWeight = lib.mkDefault 25;
      }
      // lib.optionalAttrs cfg.efficiencyCoreSteering {
        # Clamp nix-daemon utilization hint (`50% < 571/1024` Blizzard capacity)
        # so Linux EAS packs routine background evaluations/builds onto E-cores
        # (`cpu0..3`) first while still allowing spillover if all E-cores are full.
        ExecStartPost = [
          "+${pkgs.runtimeShell} -c 'echo 50.00 > /sys/fs/cgroup/system.slice/nix-daemon.service/cpu.uclamp.max 2>/dev/null || true'"
        ];
      };

      # Tune VM & zstd ZRAM reclaim for Apple Silicon 16 KiB pages and unified memory:
      # - page-cluster = 0 avoids 128 KiB (8x 16 KiB) read-ahead decompression per fault
      # - swappiness = 100 balances fast in-RAM zstd ZRAM compression against keeping
      #   warm V8/Electron anonymous heaps resident without excessive kswapd0 thrashing
      boot.kernel.sysctl = {
        "vm.swappiness" = lib.mkDefault 100;
        "vm.page-cluster" = lib.mkDefault 0;
        "vm.watermark_boost_factor" = lib.mkDefault 0;
        "vm.watermark_scale_factor" = lib.mkDefault 125;
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

      environment.etc =
        let
          dailyLimit =
            if cfg.chargeControlEndThreshold != null && cfg.chargeControlEndThreshold < 100 then
              cfg.chargeControlEndThreshold
            else
              90;
        in
        {
          "omarchnix/daily-charge-limit".text = "${toString dailyLimit}\n";
        };

      systemd.tmpfiles.rules = [
        "d /usr/share/omarchy-platform 0755 root root - -"
        "L+ /usr/share/omarchy-platform/display-cutouts.json - - - - ${displayCutoutsJson}"
        "z /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 0664 root wheel - -"
        "z /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq 0664 root wheel - -"
        "z /sys/devices/system/cpu/cpufreq/boost 0664 root wheel - -"
      ]
      ++ lib.optional (
        cfg.isoLayout != null
      ) "w /sys/module/hid_apple/parameters/iso_layout - - - - ${toString cfg.isoLayout}";

      services.udev.extraRules = ''
        SUBSYSTEM=="power_supply", KERNEL=="macsmc-battery", RUN+="${pkgs.coreutils}/bin/chgrp wheel /sys%p/charge_control_end_threshold /sys%p/charge_control_start_threshold", RUN+="${pkgs.coreutils}/bin/chmod 0664 /sys%p/charge_control_end_threshold /sys%p/charge_control_start_threshold"
        SUBSYSTEM=="leds", KERNEL=="*kbd_backlight*", RUN+="${pkgs.coreutils}/bin/chgrp wheel /sys%p/brightness", RUN+="${pkgs.coreutils}/bin/chmod 0664 /sys%p/brightness"
        SUBSYSTEM=="cpu", KERNEL=="cpu0|cpu4", RUN+="${pkgs.runtimeShell} -c '${pkgs.coreutils}/bin/chgrp wheel /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true; ${pkgs.coreutils}/bin/chmod 0664 /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true'"
        # Hide internal Apple Silicon iBoot, RecoveryOS, and SEP-encrypted APFS container partitions from desktop volume managers.
        SUBSYSTEM=="block", KERNEL=="nvme0n*", ENV{ID_PART_ENTRY_TYPE}=="69646961-6700-11aa-aa11-00306543ecac|52637672-7900-11aa-aa11-00306543ecac|7c3457ef-0000-11aa-aa11-00306543ecac", ENV{UDISKS_IGNORE}="1"
      '';

      systemd.services.m2air-kbd-backlight = lib.mkIf (cfg.keyboardBacklight.defaultBrightness != null) {
        description = "Seed or enforce MacBook Air M2 keyboard backlight brightness";
        wantedBy = [ "multi-user.target" ];
        after = [
          "multi-user.target"
          "systemd-backlight@leds:kbd_backlight.service"
        ];
        unitConfig.ConditionPathExistsGlob = "/sys/class/leds/*kbd_backlight*/brightness";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script =
          let
            desiredPct = cfg.keyboardBacklight.defaultBrightness;
            enforce = if cfg.keyboardBacklight.enforceOnBoot then "1" else "0";
          in
          ''
            state_dir="/var/lib/omarchnix"
            stamp="$state_dir/configured-kbd-backlight"
            desired="${toString desiredPct}"
            prev=""
            if [ -f "$stamp" ]; then
              prev="$(cat "$stamp" 2>/dev/null || true)"
            fi

            if [ "${enforce}" = "1" ] || [ ! -f "$stamp" ] || [ "$prev" != "$desired" ]; then
              for led in /sys/class/leds/*kbd_backlight*; do
                [ -f "$led/brightness" ] && [ -f "$led/max_brightness" ] || continue
                max_b="$(cat "$led/max_brightness" 2>/dev/null || echo 255)"
                case "$max_b" in
                  ""|*[!0-9]*) max_b=255 ;;
                esac
                raw=$(( (desired * max_b + 50) / 100 ))
                [ "$raw" -gt "$max_b" ] && raw="$max_b"
                [ "$raw" -lt 0 ] && raw=0
                echo "$raw" > "$led/brightness" || true
                for saved in /var/lib/systemd/backlight/*:"$(basename "$led")"; do
                  [ -f "$saved" ] && echo "$raw" > "$saved" || true
                done
              done
              mkdir -p "$state_dir"
              printf '%s\n' "$desired" > "$stamp"
            fi
          '';
      };

      systemd.services.macsmc-battery-thresholds = {
        description = "Configure Apple SMC battery charge thresholds on MacBook Air M2";
        wantedBy = [ "multi-user.target" ];
        after = [ "multi-user.target" ];
        unitConfig.ConditionPathExistsGlob = "/sys/class/power_supply/macsmc-battery/charge_control_end_threshold";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script =
          let
            endThreshold = if cfg.chargeControlEndThreshold != null then cfg.chargeControlEndThreshold else 100;
          in
          ''
            bat="/sys/class/power_supply/macsmc-battery"
            if [ -w "$bat/charge_control_end_threshold" ]; then
              echo ${toString endThreshold} > "$bat/charge_control_end_threshold" || true
            fi
            ${lib.optionalString (cfg.chargeControlStartThreshold != null && endThreshold < 100) ''
              if [ -w "$bat/charge_control_start_threshold" ]; then
                echo ${toString cfg.chargeControlStartThreshold} > "$bat/charge_control_start_threshold" || true
              fi
            ''}
          '';
      };
    })

    (lib.mkIf (cfg.enable && cfg.bootloader.enable) {
      boot.loader = {
        systemd-boot.enable = false;
        efi = {
          canTouchEfiVariables = false;
          efiSysMountPoint = cfg.bootloader.efiSysMountPoint;
        };
        grub = {
          enable = true;
          device = "nodev";
          efiSupport = true;
          efiInstallAsRemovable = true;
          enableCryptodisk = false;
          configurationLimit = cfg.bootloader.configurationLimit;
          extraFiles = lib.mkForce { };
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.fileSystems.enable) {
      assertions = [
        {
          assertion = cfg.fileSystems.luksUuid != null && cfg.fileSystems.espUuid != null;
          message = "omarchnix.hardware.m2air.fileSystems.enable requires both luksUuid and espUuid to be set.";
        }
      ];

      boot.initrd.luks.devices.cryptroot = {
        device = "/dev/disk/by-uuid/${cfg.fileSystems.luksUuid}";
        allowDiscards = true;
      };

      fileSystems."/" = {
        device = "/dev/mapper/cryptroot";
        fsType = "ext4";
        options = [
          "defaults"
          "noatime"
        ];
      };

      fileSystems."/boot" = {
        device = "/dev/disk/by-uuid/${cfg.fileSystems.espUuid}";
        fsType = "vfat";
        options = [
          "fmask=0077"
          "dmask=0077"
        ];
      };
    })
  ];
}
