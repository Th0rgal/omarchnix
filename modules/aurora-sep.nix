{
  config,
  lib,
  options,
  pkgs,
  inputs ? { },
  ...
}:
let
  m2Cfg = config.omarchnix.hardware.m2air;
  cfg = m2Cfg.touchId;
  hasAuroraPkgs = (pkgs ? aurora-sep) && (pkgs ? aurora-touchid-rearm) && (pkgs ? aurora-xart);

  auroraCachePublicKey = "aurora-nixos-1:ZxmPNEWsrzgXai+W+dlTE8cachb1xaatfXKK8X8go14=";

  omarchyShellPkg =
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

  peripheralAdmissionScript =
    if inputs ? nixos-aurora then
      "${inputs.nixos-aurora}/firmware/aurora-peripheral-firmware.sh"
    else
      pkgs.writeText "aurora-peripheral-firmware-fallback.sh" ''
        #!/bin/sh
        set -eu
        modprobe dockchannel-hid || true
        modprobe aop || true
      '';

  admission = pkgs.runCommand "aurora-peripheral-admission" { } ''
    install -Dm755 ${peripheralAdmissionScript} "$out/bin/aurora-peripheral-admission"
    patchShebangs "$out/bin/aurora-peripheral-admission"
  '';

  firmwareTools = [
    pkgs.coreutils
    pkgs.util-linux
    pkgs.cpio
    pkgs.kmod
    pkgs.gnugrep
    pkgs.bash
    pkgs.systemd
  ];

  extractFirmware = pkgs.writeShellApplication {
    name = "aurora-extract-vendor-firmware";
    runtimeInputs = firmwareTools;
    text = ''
      property=/sys/firmware/devicetree/base/chosen/asahi,efi-system-partition
      if [ ! -r "$property" ]; then exit 0; fi
      uuid=$(tr -d '\000' < "$property")
      [[ "$uuid" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] || {
        echo 'Invalid Apple EFI partition identity' >&2
        exit 1
      }
      uuid=''${uuid,,}
      device=/dev/disk/by-partuuid/$uuid
      destination=/run/aurora-firmware
      mkdir -p "$destination"
      if [ ! -s "$destination/vendorfw/.vendorfw.manifest" ]; then
        modprobe nvme_apple 2>/dev/null || true
        udevadm wait --timeout=60 "$device"
        esp=$(findmnt --noheadings --first-only --output TARGET --source "$device" || true)
        if [ -z "$esp" ]; then
          esp=/run/aurora-esp
          mkdir -p "$esp"
          mount -t vfat -o ro "$device" "$esp"
          trap 'umount /run/aurora-esp' EXIT
        fi
        if [ ! -s "$esp/vendorfw/firmware.cpio" ]; then
          echo '<4>Aurora: the ESP has no vendor firmware; admitting peripherals without it' >&2
          exit 0
        fi
        (
          cd "$destination"
          cpio --quiet --extract --unconditional --no-absolute-filenames < "$esp/vendorfw/firmware.cpio"
        )
      fi
    '';
  };

  loadFirmware = pkgs.writeShellApplication {
    name = "aurora-load-vendor-firmware";
    runtimeInputs = firmwareTools;
    text = ''
      destination=/run/aurora-firmware
      status=0
      ${extractFirmware}/bin/aurora-extract-vendor-firmware || status=$?
      if [[ "$status" != 0 && "''${1:-initrd}" != runtime ]]; then
        echo '<4>Aurora: vendor firmware handoff failed; the installed system will retry it' >&2
        status=0
      fi
      export AURORA_FIRMWARE_ROOT="$destination/vendorfw"
      export AURORA_ADMIT_BLUETOOTH=0
      if [[ "''${1:-initrd}" == runtime ]]; then
        if [[ ! -d /lib/firmware ]]; then
          mkdir -p /lib
          ln -sfn /run/current-system/firmware /lib/.firmware.tmp
          mv -Tf /lib/.firmware.tmp /lib/firmware
        fi
        [[ -d /lib/firmware ]] || {
          echo 'System firmware fallback is unavailable' >&2
          exit 1
        }
        printf '%s' "$destination/vendorfw" > /sys/module/firmware_class/parameters/path
        export AURORA_ADMIT_BLUETOOTH=1
      else
        # Preload Apple HID drivers so they bind synchronously as soon as
        # dockchannel-hid finishes uploading MTP firmware.
        modprobe hid_apple 2>/dev/null || true
        modprobe hid_magicmouse 2>/dev/null || true
      fi
      ${admission}/bin/aurora-peripheral-admission
      if [[ "''${1:-initrd}" != runtime ]]; then
        # Wait up to 5s for dockchannel-hid MTP firmware load to register the
        # built-in Apple MTP keyboard input device before LUKS passphrase prompt.
        for _ in $(seq 1 50); do
          if grep -qi "keyboard" /sys/class/input/input*/name 2>/dev/null; then
            break
          fi
          sleep 0.1
        done
        udevadm settle --timeout=5 || true
      fi
      exit "$status"
    '';
  };

  ibootIscUdevRules = pkgs.writeTextFile {
    name = "omarchnix-iboot-isc-udev-rules";
    destination = "/lib/udev/rules.d/61-omarchnix-iboot-isc.rules";
    text = ''
      # Apple_APFS_ISC (iBootSystemContainer) GPT partition type GUID.
      # Factory macOS GPT layouts may leave PARTLABEL empty or differently named;
      # guarantee /dev/disk/by-partlabel/iBootSystemContainer for apple_sep and
      # aurora-touchid-setup without altering existing GPT metadata.
      SUBSYSTEM=="block", ENV{ID_PART_ENTRY_SCHEME}=="gpt", ENV{ID_PART_ENTRY_TYPE}=="69646961-6700-11aa-aa11-00306543ecac", SYMLINK+="disk/by-partlabel/iBootSystemContainer"
    '';
  };

  checkStage2Script =
    if inputs ? nixos-aurora then "${inputs.nixos-aurora}/scripts/check-stage2.py" else null;

  auraPkg =
    if (pkgs ? m1n1) && (options ? boot) && (options.boot ? m1n1CustomLogo) then
      pkgs.m1n1.override (
        lib.optionalAttrs (config.boot.m1n1CustomLogo != null) {
          customLogo = config.boot.m1n1CustomLogo;
        }
      )
    else
      pkgs.m1n1 or null;

  hasAsahiStage2 =
    (options ? hardware)
    && (options.hardware ? asahi)
    && config.hardware.asahi.enable
    && (auraPkg != null)
    && (checkStage2Script != null);

  checkedAuroraStage2 =
    if hasAsahiStage2 then
      pkgs.runCommand "omarchnix-aurora-stage2"
        {
          nativeBuildInputs = [ pkgs.python3 ];
        }
        ''
          mkdir -p "$out"
          cp "${config.system.build.m1n1}" "$out/boot.bin"
          ln -s "${auraPkg}/lib/m1n1/m1n1.bin" "$out/aura.bin"
          python3 "${checkStage2Script}" \
            --stage2 "$out/boot.bin" \
            --aura "${auraPkg}/lib/m1n1/m1n1.bin" \
            --require-board j413 \
            --require-board j415 \
            > "$out/manifest.json"
          sha256sum "$out/boot.bin" | cut -d' ' -f1 > "$out/boot.bin.sha256"
        ''
    else
      null;

  defaultStage2Input = if checkedAuroraStage2 != null then "${checkedAuroraStage2}" else "";

  installStage2Cli = pkgs.writeShellApplication {
    name = "omarchnix-install-stage2";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      set -euo pipefail

      usage() {
        cat <<'EOF'
      Usage: omarchnix-install-stage2 [ESP_MOUNTPOINT] [--stage2-dir <dir>]

      Atomically install the verified Aurora Stage 2 (aura + linux-aurora DTBs + U-Boot)
      to <ESP_MOUNTPOINT>/m1n1/boot.bin while preserving the original pre-Aurora Stage 2
      at m1n1/boot.bin.pre-aurora and the immediately preceding Stage 2 at m1n1/boot.bin.old.
      Never modifies Stage 1 or NVRAM.
      EOF
      }

      esp="/boot"
      stage2_dir="${defaultStage2Input}"

      while (( $# > 0 )); do
        case "$1" in
          -h | --help)
            usage
            exit 0
            ;;
          --stage2-dir)
            [[ $# -ge 2 && -n "''${2:-}" ]] || {
              echo "omarchnix-install-stage2: --stage2-dir requires a path" >&2
              exit 2
            }
            stage2_dir="$2"
            shift 2
            ;;
          -*)
            echo "omarchnix-install-stage2: unknown option '$1'" >&2
            usage >&2
            exit 2
            ;;
          *)
            esp="$1"
            shift
            ;;
        esac
      done

      refuse() {
        echo "omarchnix-install-stage2: $*; ESP Stage 2 left unchanged" >&2
        exit 1
      }

      [[ -n "$stage2_dir" && -d "$stage2_dir" ]] || refuse "no verified Stage 2 directory configured (pass --stage2-dir)"
      src="$stage2_dir/boot.bin"
      sha_file="$stage2_dir/boot.bin.sha256"
      [[ -f "$src" && -s "$src" && -f "$sha_file" ]] || refuse "missing boot.bin or boot.bin.sha256 in $stage2_dir"

      expected="$(tr -d ' \t\r\n' < "$sha_file")"
      [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || refuse "invalid SHA-256 digest in $sha_file"
      actual="$(sha256sum "$src" | cut -d' ' -f1)"
      [[ "$actual" == "$expected" ]] || refuse "Stage 2 digest mismatch ($actual != $expected)"

      mountpoint -q "$esp" || refuse "$esp is not a mountpoint"
      fstype="$(findmnt -n -o FSTYPE --mountpoint "$esp" | tail -n 1)"
      [[ "$fstype" == "vfat" ]] || refuse "$esp is '$fstype', expected a FAT32 EFI System Partition (vfat)"

      dt_esp="''${OMARCHNIX_DT_ESP:-/proc/device-tree/chosen/asahi,efi-system-partition}"
      if [[ -r "$dt_esp" && "$esp" == "/boot" ]]; then
        booted_uuid="$(tr -d '\000' < "$dt_esp" | tr '[:upper:]' '[:lower:]')"
        dev="$(findmnt -n -o SOURCE --mountpoint "$esp" | tail -n 1)"
        mounted_uuid="$(lsblk -n -d -o PARTUUID "$dev" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d ' \t\r\n')"
        if [[ -n "$booted_uuid" && -n "$mounted_uuid" && "$booted_uuid" != "$mounted_uuid" ]]; then
          refuse "$esp ($mounted_uuid) does not match booted Apple ESP ($booted_uuid)"
        fi
      fi

      m1n1_dir="$esp/m1n1"
      [[ -d "$m1n1_dir" ]] || refuse "$esp has no m1n1/ directory (run alx.sh UEFI bootstrap first)"
      target="$m1n1_dir/boot.bin"
      [[ ! -L "$target" ]] || refuse "$target is a symlink"

      if [[ -f "$target" ]]; then
        current_sha="$(sha256sum "$target" | cut -d' ' -f1)"
        if [[ "$current_sha" == "$expected" ]]; then
          echo "omarchnix-install-stage2: $target is already up to date ($expected)"
          exit 0
        fi
        if [[ ! -f "$m1n1_dir/boot.bin.pre-aurora" ]]; then
          cp -- "$target" "$m1n1_dir/boot.bin.pre-aurora"
          sync "$m1n1_dir/boot.bin.pre-aurora"
        fi
        cp -- "$target" "$m1n1_dir/boot.bin.old"
        sync "$m1n1_dir/boot.bin.old"
      fi

      staged="$m1n1_dir/.boot.bin.omarchnix.$$"
      trap 'rm -f "$staged"' EXIT
      cp -- "$src" "$staged"
      chmod 0644 "$staged"
      sync "$staged"
      staged_sha="$(sha256sum "$staged" | cut -d' ' -f1)"
      [[ "$staged_sha" == "$expected" ]] || refuse "readback SHA-256 verification failed on $esp ($staged_sha != $expected)"

      mv -f -- "$staged" "$target"
      trap - EXIT
      sync "$m1n1_dir"

      verify_sha="$(sha256sum "$target" | cut -d' ' -f1)"
      [[ "$verify_sha" == "$expected" ]] || refuse "post-rename SHA-256 mismatch ($verify_sha != $expected)"

      echo "omarchnix-install-stage2: installed verified Aurora Stage 2 ($expected) -> $target"
      if [[ -f "$m1n1_dir/boot.bin.pre-aurora" ]]; then
        echo "omarchnix-install-stage2: fallback preserved at $m1n1_dir/boot.bin.pre-aurora"
      fi
    '';
  };

  touchIdStatusCli = pkgs.writeShellApplication {
    name = "omarchnix-touchid-status";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.systemd
      pkgs.util-linux
    ]
    ++ lib.optional (pkgs ? fprintd) pkgs.fprintd
    ++ lib.optional (pkgs ? aurora-fido) pkgs.aurora-fido;
    text = ''
      set -euo pipefail

      want_json=0
      if [[ "''${1:-}" == "--json" ]]; then
        want_json=1
      fi

      kernel_rel="$(uname -r)"
      isc_present=false
      [[ -e /dev/disk/by-partlabel/iBootSystemContainer ]] && isc_present=true
      sep_bio=false
      [[ -c /dev/sep-bio ]] && sep_bio=true
      sep_key=false
      [[ -c /dev/sep-key ]] && sep_key=true
      rearm_sock=false
      [[ -S /run/aurora-touchid-rearm.sock ]] && rearm_sock=true

      sep_service="$(systemctl is-active aurora-sep.service 2>/dev/null || true)"
      sep_ready="$(systemctl is-active aurora-sep-ready.service 2>/dev/null || true)"
      fprintd_state="$(systemctl is-active fprintd.service 2>/dev/null || true)"
      fido_state="$(systemctl is-active aurora-fido.service 2>/dev/null || true)"

      diag_json="{}"
      for d in /sys/bus/platform/devices/*.sep/diag; do
        [[ -d "$d" ]] || continue
        pairs=()
        for f in "$d"/*; do
          [[ -r "$f" ]] || continue
          k="$(basename "$f")"
          v="$(tr -d '\n' < "$f" 2>/dev/null || true)"
          pairs+=("$(jq -nc --arg k "$k" --arg v "$v" '{($k): $v}')")
        done
        if (( ''${#pairs[@]} > 0 )); then
          diag_json="$(printf '%s\n' "''${pairs[@]}" | jq -s 'add')"
        fi
        break
      done

      if (( want_json )); then
        jq -nc \
          --arg kernel "$kernel_rel" \
          --arg sepService "$sep_service" \
          --arg sepReady "$sep_ready" \
          --arg fprintd "$fprintd_state" \
          --arg auroraFido "$fido_state" \
          --argjson iscPresent "$isc_present" \
          --argjson sepBio "$sep_bio" \
          --argjson sepKey "$sep_key" \
          --argjson rearmSocket "$rearm_sock" \
          --argjson diag "$diag_json" \
          '{
            kernel: $kernel,
            iBootSystemContainer: $iscPresent,
            sepBioDevice: $sepBio,
            sepKeyDevice: $sepKey,
            rearmSocket: $rearmSocket,
            units: {
              auroraSep: $sepService,
              auroraSepReady: $sepReady,
              fprintd: $fprintd,
              auroraFido: $auroraFido
            },
            diag: $diag
          }'
      else
        echo "Kernel:               $kernel_rel"
        echo "iBootSystemContainer: $isc_present"
        echo "/dev/sep-bio:         $sep_bio"
        echo "/dev/sep-key:         $sep_key"
        echo "rearm socket:         $rearm_sock"
        echo "aurora-sep.service:   $sep_service"
        echo "aurora-sep-ready:     $sep_ready"
        echo "fprintd.service:      $fprintd_state"
        echo "aurora-fido.service:  $fido_state"
        if [[ "$diag_json" != "{}" ]]; then
          echo "SEP diag:             $(jq -c . <<<"$diag_json")"
        fi
      fi
    '';
  };

  fidoConf = pkgs.writeText "aurora-fido.conf" (lib.generators.toINI { } cfg.fido.settings);

  rearmServices = [
    "sudo"
    "polkit-1"
    "login"
    "hyprlock"
    "omarchy-lock-password"
  ];
in
{
  # Prevent services.fprintd.enable = true from adding pam_fprintd.so to sshd,
  # login, su, or display greeters unless explicitly requested below.
  options.security.pam.services = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        config.fprintAuth = lib.mkDefault false;
      }
    );
  };

  options.omarchnix.hardware.m2air.touchId = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable Apple Silicon Secure Enclave Processor (SEP) and Touch ID support
        from `aurora-silicon/nixos-aurora` (`apple_sep`, `aurora-sep`, patched
        `libfprint` + `fprintd`, post-boot password re-arming, and PAM integration
        for `sudo`, `polkit-1`, `hyprlock`, and `omarchy-shell`).
      '';
    };

    firmwareHandoff = lib.mkOption {
      type = lib.types.bool;
      default = pkgs.stdenv.hostPlatform.system == "aarch64-linux";
      defaultText = lib.literalExpression ''pkgs.stdenv.hostPlatform.system == "aarch64-linux"'';
      description = ''
        Maintain Aurora's initrd + runtime `/run/aurora-firmware/vendorfw` ESP
        firmware handoff and `/lib/firmware` store fallback so `touchid-publish`
        can link per-Mac Touch ID calibration blobs into the live firmware path.
      '';
    };

    requirePasswordAfterBoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Match macOS Touch ID policy after a reboot: require the user's password once
        after boot (`require_password_after_boot = yes` in `/etc/aurora/touchid.conf`),
        after which `pam_aurora_touchid.so` re-arms Touch ID automatically.
      '';
    };

    fido = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run `aurora-fidod` so the Secure Enclave + Touch ID acts as a local
          `/dev/uhid` FIDO2/WebAuthn security key for Brave, Firefox, Orb passkeys,
          and `ssh-keygen -t ecdsa-sk`.
        '';
      };

      settings = lib.mkOption {
        type =
          with lib.types;
          attrsOf (
            attrsOf (oneOf [
              str
              int
              bool
            ])
          );
        default = {
          touchid = {
            policy = "touchid-or-password";
          };
        };
        description = "Configuration sections written to `/etc/aurora-fido/aurora-fido.conf`.";
      };
    };
  };

  config = lib.mkMerge [
    # Ensure Aurora's binary cache + udev/Stage-2 helpers are active whenever Touch ID is enabled.
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = !cfg.enable || hasAuroraPkgs;
          message = "omarchnix.hardware.m2air.touchId.enable requires nixos-aurora packages (aurora-sep, aurora-touchid-rearm, aurora-xart) in nixpkgs.overlays.";
        }
      ];

      nix.settings = {
        substituters = [ "https://aurorasilicon.org/nixos-aurora/cache" ];
        trusted-public-keys = [ auroraCachePublicKey ];
      };

      # Apple Silicon Macs have no ACPI TPM2; linux-aurora omits tpm-tis/tpm-crb
      # and builds cpufreq_schedutil in without PS/2 atkbd.
      boot.initrd.systemd.tpm2.enable = lib.mkDefault false;
      environment.etc."modules-load.d/nixos.conf".source = lib.mkForce (
        pkgs.writeText "nixos.conf" (
          lib.concatStringsSep "\n" (
            lib.subtractLists [
              "atkbd"
              "cpufreq_schedutil"
            ] config.boot.kernelModules
          )
          + "\n"
        )
      );

      services.udev.packages = [ ibootIscUdevRules ];

      environment.systemPackages = [
        installStage2Cli
        touchIdStatusCli
      ]
      ++ lib.optionals (omarchyShellPkg != null) [
        # Expose /run/current-system/sw/bin/omarchy-hw-laptop-closed system-wide
        # for clamshell lid-state checks in PAM and Polkit.
        (pkgs.runCommand "omarchy-hw-laptop-closed-bin" { } ''
          mkdir -p "$out/bin"
          ln -s "${omarchyShellPkg}/bin/omarchy-hw-laptop-closed" "$out/bin/omarchy-hw-laptop-closed"
        '')
      ];

      system.build = lib.optionalAttrs (checkedAuroraStage2 != null) {
        auroraStage2 = checkedAuroraStage2;
      };
    })

    # Per-Mac ESP vendorfw handoff + /lib/firmware fallback for touchid-publish.
    (lib.optionalAttrs (options ? hardware && options.hardware ? asahi) (
      lib.mkIf (cfg.enable && cfg.firmwareHandoff) {
        hardware.asahi.extractPeripheralFirmware = lib.mkForce false;
      }
    ))

    (lib.mkIf (cfg.enable && cfg.firmwareHandoff) {
      # Keep the Apple Silicon / USB / NVMe / LUKS initrd module set explicit.
      # NixOS's generic PC default initrd module list asks for legacy x86/SATA/HCD
      # drivers (ata_piix, uhci_hcd, pata_marvell, etc.) that linux-aurora omits.
      boot.initrd.includeDefaultModules = lib.mkDefault false;
      boot.kernelParams = [ "firmware_class.path=/run/aurora-firmware/vendorfw" ];
      boot.blacklistedKernelModules = [
        "aop"
        "mt7932-fullmac"
        "mt7932_bt_pcie"
        "dockchannel-hid"
      ];
      boot.initrd.availableKernelModules = [
        "apple-mailbox"
        "apple_nvmem_spmi"
        "nvme_apple"
        "pinctrl-apple-gpio"
        "macsmc"
        "macsmc-power"
        "macsmc-input"
        "macsmc-hwmon"
        "macsmc-reboot"
        "i2c-pasemi-platform"
        "tps6598x"
        "sn201202x"
        "thunderbolt_apple"
        "apple-dart"
        "dwc3"
        "dwc3-of-simple"
        "xhci-pci"
        "pcie-apple"
        "gpio_macsmc"
        "phy-apple-atc"
        "nvmem_apple_efuses"
        "spi-apple"
        "spi-hid-apple"
        "spi-hid-apple-of"
        "rtc-macsmc"
        "spmi-apple-controller"
        "apple-dockchannel"
        "dockchannel-hid"
        "apple-rtkit-helper"
        "usb-storage"
        "xhci-plat-hcd"
        "usbhid"
        "hid_apple"
        "hid_magicmouse"
        "hid_generic"
        "nvme"
        "virtio_blk"
        "virtio_pci"
        "uas"
        "sd_mod"
        "vfat"
        "nls_iso8859-1"
        "dm-crypt"
        "btrfs"
        "ext4"
        "aop"
        "mt7932-fullmac"
        "mt7932_bt_pcie"
        "apple-pmp"
        "mux-apple-display-crossbar"
        "appledrm"
        "snd-seq"
      ];
      # Early Stage-1 unit: must set DefaultDependencies = false so systemd does not
      # add implicit After=sysinit.target (which creates a cycle with cryptsetup-pre.target
      # and blocks dockchannel-hid keyboard admission behind the LUKS passphrase prompt).
      boot.initrd.systemd.services.aurora-vendor-firmware = {
        description = "Extract this Mac's vendor firmware before peripheral admission";
        unitConfig.DefaultDependencies = false;
        wantedBy = [
          "sysinit.target"
          "initrd.target"
        ];
        after = [
          "systemd-udevd.service"
          "systemd-udev-trigger.service"
          "systemd-udev-settle.service"
        ];
        wants = [
          "systemd-udevd.service"
          "systemd-udev-settle.service"
          "cryptsetup-pre.target"
        ];
        conflicts = [ "shutdown.target" ];
        before = [
          "cryptsetup-pre.target"
          "cryptsetup.target"
          "systemd-ask-password-console.path"
          "systemd-ask-password-console.service"
          "sysinit.target"
          "sysroot.mount"
          "shutdown.target"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${loadFirmware}/bin/aurora-load-vendor-firmware";
        };
      };
      boot.initrd.systemd.storePaths = [
        loadFirmware
        extractFirmware
        admission
      ]
      ++ map lib.getBin firmwareTools;

      # NixOS's built-in `udevd` activation snippet writes `/nix/store/...-firmware/lib/firmware`
      # into `/sys/module/firmware_class/parameters/path` during Stage-2 `/activate`, wiping out
      # Stage 1's `/run/aurora-firmware/vendorfw` right before `systemd-udev-trigger.service`
      # coldplugs Broadcom Wi-Fi (`brcmfmac`) and Bluetooth (`hci_bcm4377`). Immediately link
      # `/lib/firmware` to the active system store firmware (standard kernel fallback) and
      # restore `/run/aurora-firmware/vendorfw` inside `/activate` itself.
      system.activationScripts.auroraFirmwareHandoff = lib.stringAfter [ "udevd" "specialfs" ] ''
        mkdir -p /lib
        if [ -d /lib/firmware ] && [ ! -L /lib/firmware ]; then
          rmdir /lib/firmware/vendor/apple /lib/firmware/vendor /lib/firmware 2>/dev/null || true
          if [ -d /lib/firmware ] && [ ! -L /lib/firmware ]; then
            rm -rf /lib/.firmware.pre-aurora
            mv /lib/firmware /lib/.firmware.pre-aurora
          fi
        fi
        ln -sfn "$(readlink -f "$systemConfig")/firmware" /lib/.firmware.tmp
        mv -Tf /lib/.firmware.tmp /lib/firmware
        if [ -e /sys/module/firmware_class/parameters/path ] && [ -d /run/aurora-firmware/vendorfw ]; then
          printf '%s' "/run/aurora-firmware/vendorfw" > /sys/module/firmware_class/parameters/path
        fi
      '';

      # Also run Stage-2 `aurora-vendor-firmware` early in `sysinit.target` strictly before
      # `systemd-udev-trigger.service` so coldplugged PCI/platform devices (`brcmfmac`,
      # `hci_bcm4377`, `iio_aop_als`, `ane_t6021`) always see `/run/aurora-firmware/vendorfw`
      # even if Stage 1 had to defer extraction.
      systemd.services.aurora-vendor-firmware = {
        description = "Maintain Aurora per-device firmware handoff";
        unitConfig.DefaultDependencies = false;
        wantedBy = [
          "sysinit.target"
          "multi-user.target"
        ];
        conflicts = [ "shutdown.target" ];
        after = [ "systemd-udevd.service" ];
        before = [
          "systemd-udev-trigger.service"
          "sysinit.target"
          "network-pre.target"
          "bluetooth.service"
          "shutdown.target"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${loadFirmware}/bin/aurora-load-vendor-firmware runtime";
        };
      };
    })

    # Aurora SEP + Touch ID + PAM + sleep recovery.
    (lib.mkIf (cfg.enable && hasAuroraPkgs) {
      boot.blacklistedKernelModules = [ "apple_sep" ];

      environment.etc."modprobe.d/aurora-sep-defaults.conf".text = ''
        # Aurora SEP driver defaults: APFS-validated xART writes and first-boot keybag provisioning.
        # Override with options apple_sep xart_writes=0 provision_keybag=0 in /etc/modprobe.d/aurora-sep.conf for read-only mode.
        options apple_sep xart_writes=1 provision_keybag=1
      '';

      environment.systemPackages = [
        pkgs.aurora-sep
        pkgs.aurora-xart
        pkgs.libfprint
      ]
      ++ lib.optional (pkgs ? aurora-userpages) pkgs.aurora-userpages
      ++ lib.optional (pkgs ? aurora-alsa-utils) pkgs.aurora-alsa-utils;

      hardware.firmware = lib.optional (pkgs ? aurora-avd-firmware) pkgs.aurora-avd-firmware;

      services.pipewire.package = lib.mkIf (pkgs ? aurora-pipewire) (lib.mkDefault pkgs.aurora-pipewire);

      services.fprintd.enable = true;

      security.pam.services = lib.mkMerge [
        # Ensure hyprlock and omarchy-lock-password exist before attaching re-arm rules.
        {
          hyprlock = { };
          omarchy-lock-password = { };
        }
        (lib.genAttrs rearmServices (
          name:
          let
            unix = config.security.pam.services.${name}.rules.auth.unix;
          in
          {
            rules.auth = {
              unix.control = lib.mkForce "[success=ok new_authtok_reqd=ok default=2]";
              aurora-touchid-rearm = {
                enable = unix.enable;
                order = unix.order + 1;
                control = "optional";
                modulePath = "${pkgs.aurora-touchid-rearm}/lib/security/pam_aurora_touchid.so";
              };
              aurora-touchid-rearm-done = {
                enable = unix.enable;
                order = unix.order + 2;
                control = "sufficient";
                modulePath = "${pkgs.pam}/lib/security/pam_permit.so";
              };
            }
            //
              lib.optionalAttrs
                (
                  (omarchyShellPkg != null)
                  && builtins.elem name [
                    "sudo"
                    "polkit-1"
                  ]
                )
                {
                  # Clamshell lid-closed gate: when the MacBook lid is shut in docked mode,
                  # skip pam_fprintd immediately (success=1) so PAM prompts for password
                  # without waiting on an unreachable Touch ID sensor.
                  omarchy-clamshell-gate = {
                    enable = true;
                    order = config.security.pam.services.${name}.rules.auth.fprintd.order - 1;
                    control = "[success=1 default=ignore]";
                    modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
                    args = [
                      "quiet"
                      "${omarchyShellPkg}/bin/omarchy-hw-laptop-closed"
                    ];
                  };
                };
          }
        ))
        {
          aurora-touchid-rearm.text = ''
            auth required ${pkgs.pam}/lib/security/pam_unix.so
            account required ${pkgs.pam}/lib/security/pam_unix.so
          '';

          # Dedicated fingerprint stack for omarchy-shell's Quickshell lock screen
          # (shell/plugins/lock/Service.qml checks /etc/pam.d/omarchy-lock-fingerprint).
          omarchy-lock-fingerprint.text = ''
            auth required ${config.services.fprintd.package}/lib/security/pam_fprintd.so
            account include login
          '';

          sudo.fprintAuth = true;
          polkit-1.fprintAuth = true;
          hyprlock.fprintAuth = true;
          omarchy-lock-password.fprintAuth = false;
          login.fprintAuth = false;
          su.fprintAuth = false;
          sshd = lib.mkIf config.services.openssh.enable {
            fprintAuth = false;
          };
        }
      ];

      systemd.sockets.aurora-touchid-rearm = {
        description = "Touch ID re-arm after a password authentication";
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = "/run/aurora-touchid-rearm.sock";
          SocketMode = "0666";
          Accept = true;
          MaxConnections = 8;
        };
      };

      environment.etc."aurora/touchid.conf".text = ''
        # Generated from omarchnix.hardware.m2air.touchId.requirePasswordAfterBoot.
        require_password_after_boot = ${if cfg.requirePasswordAfterBoot then "yes" else "no"}
      '';

      systemd.services.aurora-touchid-boot = {
        description = "Touch ID after a restart (require_password_after_boot)";
        wantedBy = [ "multi-user.target" ];
        wants = [ "aurora-sep-ready.service" ];
        after = [ "aurora-sep-ready.service" ];
        before = [
          "display-manager.service"
          "systemd-user-sessions.service"
          "fprintd.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.aurora-touchid-rearm}/libexec/aurora-touchid-rearm --boot";
          StandardOutput = "null";
          TimeoutStartSec = 45;
          CapabilityBoundingSet = [ "CAP_SYS_ADMIN" ];
          NoNewPrivileges = true;
          PrivateNetwork = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          LockPersonality = true;
          RestrictRealtime = true;
          RestrictNamespaces = true;
          SystemCallArchitectures = "native";
        };
      };

      systemd.services."aurora-touchid-rearm@" = {
        description = "Touch ID re-arm request";
        serviceConfig = {
          ExecStart = "${pkgs.aurora-touchid-rearm}/libexec/aurora-touchid-rearm";
          StandardInput = "socket";
          StandardOutput = "socket";
          StandardError = "journal";
          RuntimeMaxSec = 30;
          CapabilityBoundingSet = [
            "CAP_SYS_ADMIN"
            "CAP_DAC_READ_SEARCH"
            "CAP_AUDIT_WRITE"
          ];
          NoNewPrivileges = true;
          PrivateNetwork = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_NETLINK"
          ];
          ProtectSystem = "full";
          ProtectHome = true;
          PrivateTmp = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          LockPersonality = true;
          RestrictRealtime = true;
          RestrictNamespaces = true;
          SystemCallArchitectures = "native";
        };
      };

      systemd.timers.aurora-sep = {
        description = "Initialize Aurora SEP after persistent storage is available";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1";
          Unit = "aurora-sep.service";
        };
      };

      systemd.services.aurora-sep = {
        description = "Aurora SEP trusted keys and biometric services";
        after = [
          "local-fs.target"
        ]
        ++ lib.optional cfg.firmwareHandoff "aurora-vendor-firmware.service";
        wants = [
          "aurora-sep-ready.service"
          "aurora-touchid-setup.service"
        ]
        ++ lib.optional cfg.firmwareHandoff "aurora-vendor-firmware.service";
        unitConfig = {
          RequiresMountsFor = "/var/lib";
          ConditionPathExists = "/dev/disk/by-partlabel/iBootSystemContainer";
        };
        path = [
          pkgs.kmod
          pkgs.gnugrep
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecCondition = "${pkgs.runtimeShell} -c 'modinfo -F filename apple_sep 2>/dev/null | grep -Eq \"[.]ko([.](gz|xz|zst))?$\"'";
          ExecStartPre = "-${pkgs.aurora-sep}/libexec/aurora/touchid-publish";
          ExecStart = "${pkgs.aurora-sep}/libexec/aurora-sep-load";
          StateDirectory = "aurora-sep";
          StateDirectoryMode = "0700";
          TimeoutStartSec = 180;
        };
      };

      systemd.services.aurora-touchid-setup = {
        description = "Set up the Touch ID calibration when it is missing or refused";
        documentation = [ "file://${pkgs.aurora-sep}/share/doc/aurora-sep/README.md" ];
        after = [
          "local-fs.target"
        ]
        ++ lib.optional cfg.firmwareHandoff "aurora-vendor-firmware.service";
        before = [
          "aurora-sep-ready.service"
          "fprintd.service"
        ];
        unitConfig = {
          RequiresMountsFor = "/var/lib";
          ConditionPathExists = "/dev/disk/by-partlabel/iBootSystemContainer";
        };
        serviceConfig = {
          Type = "oneshot";
          ExecCondition = "${pkgs.aurora-sep}/libexec/aurora/touchid-setup-needed";
          ExecStart = "${pkgs.aurora-sep}/bin/aurora-touchid-setup --auto";
          TimeoutStartSec = 300;
        };
      };

      systemd.services.aurora-sep-ready = {
        description = "Activate Touch ID and restore its fingerprints";
        documentation = [ "file://${pkgs.aurora-sep}/share/doc/aurora-sep/README.md" ];
        requires = [ "aurora-sep.service" ];
        after = [ "aurora-sep.service" ];
        before = [ "fprintd.service" ];
        unitConfig = {
          ConditionPathExists = "/dev/sep-bio";
          JobTimeoutSec = 90;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecCondition = "${pkgs.aurora-sep}/libexec/aurora/sensor-present";
          ExecStart = "${pkgs.aurora-sep}/libexec/aurora-sep-ready";
          TimeoutStartSec = 60;
        };
      };

      systemd.services.fprintd = {
        requires = [ "aurora-sep.service" ];
        after = [
          "aurora-sep.service"
          "aurora-sep-ready.service"
        ];
        unitConfig.ConditionPathExists = "/dev/sep-bio";
        serviceConfig = {
          ExecCondition = "${pkgs.aurora-sep}/libexec/aurora/sensor-present";
          DeviceAllow = [
            "/dev/sep-bio rw"
            "char-input r"
          ];
          ExecStart = [
            ""
            "${config.services.fprintd.package}/libexec/fprintd --no-timeout"
          ];
          TimeoutStopSec = "3s";
        };
      };

      # Restart fprintd cleanly after s2idle resume so a lock screen waiting on
      # /dev/sep-bio across lid-close sleep never holds a stale sensor claim.
      powerManagement.resumeCommands = ''
        ${pkgs.systemd}/bin/systemctl --no-block try-restart fprintd.service 2>/dev/null || true
      '';
    })

    # Optional Touch ID FIDO2/U2F security key (WebAuthn passkeys + SSH ecdsa-sk).
    (lib.mkIf (cfg.enable && cfg.fido.enable && (pkgs ? aurora-fido)) {
      boot.kernelModules = [ "uhid" ];
      environment.systemPackages = [ pkgs.aurora-fido ];
      environment.etc."aurora-fido/aurora-fido.conf".source = fidoConf;
      services.udev.packages = [ pkgs.aurora-fido ];
      systemd.packages = [ pkgs.aurora-fido ];
      systemd.services.aurora-fido = {
        wantedBy = [ "multi-user.target" ];
        path = [
          config.systemd.package
          pkgs.util-linux
          pkgs.libnotify
          pkgs.glib.bin
        ];
        restartTriggers = [ fidoConf ];
      };
    })

    # Aurora kernel v2 speaker protection (`speakerguardd-v2` + legacy `speakersafetyd` gate)
    # so `linux-aurora` speaker amp controls (`Amp Gain Volume`) are managed by `speakerguardd-v2`
    # instead of panicking legacy `speakersafetyd` with EPERM.
    (lib.mkIf
      (
        cfg.enable
        && (pkgs ? speakerguardd)
        && (pkgs ? speakerguardd-v2)
        && (pkgs.asahi-audio.keepsBuiltinProfile or false)
      )
      (
        let
          sgPkg = pkgs.speakerguardd-v2;
          sgGate = "${sgPkg}/libexec/speakerguardd-v2/speakerguardd-gate";
          sgBundleDir = "/var/lib/speakerguardd/audio-tuning";
          sgTools = [
            (pkgs.aurora-alsa-utils or pkgs.alsa-utils)
            config.services.pipewire.package
            pkgs.systemd
            pkgs.util-linux
            pkgs.coreutils
            sgPkg
          ];
          auroraAudioTuningLink =
            pkgs.runCommand "aurora-audio-tuning-link"
              {
                passthru.compressFirmware = false;
              }
              ''
                mkdir -p "$out/lib/firmware/vendor/apple"
                ln -s "${sgBundleDir}" "$out/lib/firmware/vendor/apple/audio-tuning"
              '';
          auroraSpeakerTuningSetup = pkgs.writeShellApplication {
            name = "aurora-speaker-tuning-setup";
            runtimeInputs = [
              pkgs.python3
              pkgs.apfs-fuse
              pkgs.fuse3
              pkgs.fuse
              pkgs.util-linux
              pkgs.coreutils
              sgPkg
            ];
            text = ''
              exec python3 -I ${../pkgs/aurora-speaker-tuning-setup.py} \
                --output "${sgBundleDir}" \
                --cli "${sgPkg}/bin/aurora-speaker-tuning" \
                --lzfse-lib "${pkgs.lzfse}/lib/liblzfse.so" \
                "$@"
            '';
          };
        in
        {
          environment.systemPackages = [
            sgPkg
            auroraSpeakerTuningSetup
          ];
          environment.pathsToLink = [ "/lib/lv2" ];
          hardware.firmware = [ auroraAudioTuningLink ];
          environment.etc."speakerguardd/provision.conf".text = lib.mkDefault ''
            SGV2_BUNDLE=${sgBundleDir}
          '';
          services.pipewire = {
            extraLv2Packages = [ sgPkg ];
            wireplumber.extraLv2Packages = [ sgPkg ];
          };
          systemd.packages = [
            pkgs.speakerguardd
            sgPkg
          ];
          services.udev.packages = [ pkgs.speakerguardd ];
          systemd.services.aurora-speaker-tuning-setup = {
            description = "Extract and verify this Mac's speaker tuning bundle when missing";
            wantedBy = [ "multi-user.target" ];
            after = [
              "local-fs.target"
              "systemd-udev-settle.service"
            ]
            ++ lib.optional cfg.firmwareHandoff "aurora-vendor-firmware.service";
            before = [
              "speakerguardd-v2-provision.service"
              "speakerguardd-v2-selfcheck.service"
              "speakerguardd-v2.service"
              "speakerguardd.service"
              "speakersafetyd.service"
            ];
            unitConfig = {
              RequiresMountsFor = "/var/lib";
              ConditionPathExists = "/proc/device-tree/compatible";
            };
            serviceConfig = {
              Type = "oneshot";
              ExecCondition = "${auroraSpeakerTuningSetup}/bin/aurora-speaker-tuning-setup --check-needed";
              ExecStart = "${auroraSpeakerTuningSetup}/bin/aurora-speaker-tuning-setup";
              StateDirectory = "speakerguardd";
              StateDirectoryMode = "0755";
              TimeoutStartSec = 180;
            };
          };
          systemd.services.speakerguardd-v2 = {
            wantedBy = [ "multi-user.target" ];
            path = sgTools;
            environment.SGV2_GATE = "${sgPkg}/share/speakerguardd/gate.json";
            # Replace upstream hard Requires= with Wants= so boards gated to legacy
            # speakersafetyd skip cleanly instead of failing with 'dependency' during
            # nixos-rebuild switch.
            unitConfig.Requires = "";
            wants = [
              "aurora-speaker-tuning-setup.service"
              "speakerguardd-v2-provision.service"
              "speakerguardd-v2-selfcheck.service"
              "speakerguardd-v2-switchtest.service"
            ];
          };
          systemd.services.speakerguardd-v2-provision = {
            path = sgTools;
            environment.SGV2_GATE = "${sgPkg}/share/speakerguardd/gate.json";
          };
          systemd.services.speakerguardd-v2-selfcheck = {
            path = sgTools;
            environment.SGV2_GATE = "${sgPkg}/share/speakerguardd/gate.json";
          };
          systemd.services.speakerguardd-v2-switchtest = {
            path = sgTools;
            environment.SGV2_GATE = "${sgPkg}/share/speakerguardd/gate.json";
          };
          systemd.services.speakerguardd-v2-seat = {
            path = sgTools;
            environment.SGV2_GATE = "${sgPkg}/share/speakerguardd/gate.json";
          };
          systemd.services.speakerguardd-v2-sleep = {
            wantedBy = [ "sleep.target" ];
            path = sgTools;
            environment.SGV2_GATE = "${sgPkg}/share/speakerguardd/gate.json";
          };
          systemd.paths.speakerguardd-v2-seat.wantedBy = [ "multi-user.target" ];
          systemd.user.services.speakerguardd-v2-graph = {
            wantedBy = [ "pipewire.service" ];
            path = sgTools;
            environment.SGV2_GATE = "${sgPkg}/share/speakerguardd/gate.json";
          };
          systemd.user.services.speakerguardd-v2-session = {
            wantedBy = [ "pipewire.service" ];
            path = sgTools;
            environment.SGV2_GATE = "${sgPkg}/share/speakerguardd/gate.json";
          };
          systemd.services.speakerguardd.serviceConfig.ExecCondition = [ "${sgGate} legacy" ];
          systemd.services.speakersafetyd.serviceConfig = {
            ExecCondition = [
              "${pkgs.speakerguardd}/libexec/speakerguardd/use-feedback-guard"
              "${sgGate} legacy"
            ];
            ExecStartPre = "+${pkgs.runtimeShell} -c 'if [ -e /run/speakersafetyd.started ]; then : > /run/speakersafetyd/speakersafetyd.flag; fi'";
            ExecStopPost = "+${pkgs.coreutils}/bin/touch /run/speakersafetyd.started";
          };
        }
      )
    )
  ];
}
