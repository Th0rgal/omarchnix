{
  pkgs,
  lib,
  inputs,
  m2airConfig,
  m2airAuroraConfig,
  self,
}:
let
  authLines =
    c: name:
    lib.filter (lib.hasPrefix "auth ") (
      lib.splitString "\n" (c.security.pam.services.${name}.text or "")
    );

  offersFingerprint = c: name: lib.any (lib.hasInfix "/pam_fprintd.so") (authLines c name);

  fingerprintSufficientBeforeUnix =
    c: name:
    let
      lines = authLines c name;
      idx = lib.lists.findFirstIndex (lib.hasInfix "/pam_fprintd.so") null lines;
    in
    idx != null
    && lib.all (
      line: !(lib.hasInfix "/pam_fprintd.so" line) || lib.hasPrefix "auth sufficient " line
    ) lines
    && lib.any (lib.hasInfix "/pam_unix.so") (lib.drop idx lines);

  hasRearmHook =
    c: name:
    let
      txt = c.security.pam.services.${name}.text or "";
    in
    lib.hasInfix "/pam_aurora_touchid.so" txt && lib.hasInfix "/pam_permit.so" txt;

  auroraMockOverlay =
    final: prev:
    let
      mockSep = final.runCommand "mock-aurora-sep" { } ''
        mkdir -p "$out/bin" "$out/libexec/aurora" "$out/share/doc/aurora-sep"
        for f in \
          "$out/bin/aurora-touchid-setup" \
          "$out/libexec/aurora-sep-load" \
          "$out/libexec/aurora-sep-ready" \
          "$out/libexec/aurora/touchid-publish" \
          "$out/libexec/aurora/touchid-setup-needed" \
          "$out/libexec/aurora/sensor-present"; do
          cat > "$f" <<'EOF'
        #!/bin/sh
        exit 0
        EOF
          chmod +x "$f"
        done
        echo "mock aurora-sep docs" > "$out/share/doc/aurora-sep/README.md"
      '';

      mockRearm =
        final.runCommand "mock-aurora-touchid-rearm"
          {
            nativeBuildInputs = [ final.gcc ];
            buildInputs = [ final.pam ];
          }
          ''
            mkdir -p "$out/lib/security" "$out/libexec"
            cat > pam_aurora_touchid.c <<'EOF'
            #define PAM_SM_AUTH
            #include <security/pam_modules.h>
            #include <stdio.h>
            #include <sys/socket.h>
            #include <sys/un.h>
            #include <string.h>
            #include <unistd.h>

            PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
              (void)pamh; (void)flags; (void)argc; (void)argv;
              int fd = socket(AF_UNIX, SOCK_STREAM, 0);
              if (fd >= 0) {
                struct sockaddr_un addr;
                memset(&addr, 0, sizeof(addr));
                addr.sun_family = AF_UNIX;
                strncpy(addr.sun_path, "/run/aurora-touchid-rearm.sock", sizeof(addr.sun_path) - 1);
                if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
                  const char msg[] = "rearm\n";
                  char reply[16];
                  (void)write(fd, msg, sizeof(msg) - 1);
                  shutdown(fd, SHUT_WR);
                  (void)read(fd, reply, sizeof(reply));
                }
                close(fd);
              }
              return PAM_SUCCESS;
            }

            PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
              (void)pamh; (void)flags; (void)argc; (void)argv;
              return PAM_SUCCESS;
            }
            EOF
            gcc -shared -fPIC -O2 pam_aurora_touchid.c -lpam -o "$out/lib/security/pam_aurora_touchid.so"

            cat > "$out/libexec/aurora-touchid-rearm" <<'EOF'
            #!/bin/sh
            if [ "''${1:-}" = "--boot" ]; then
              echo "boot-armed" > /run/mock-touchid-boot-marker
              exit 0
            fi
            cat >/dev/null || true
            (
              flock -x 9
              count=0
              if [ -f /run/mock-touchid-rearm-count ]; then
                count=$(cat /run/mock-touchid-rearm-count)
              fi
              echo $((count + 1)) > /run/mock-touchid-rearm-count
            ) 9>/run/mock-touchid-rearm.lock
            echo "ok"
            EOF
            chmod +x "$out/libexec/aurora-touchid-rearm"
          '';

      mockXart = final.writeShellScriptBin "aurora-xart" ''
        echo "mock-aurora-xart ok"
      '';

      mockFido = final.writeTextFile {
        name = "mock-aurora-fido";
        destination = "/bin/aurora-fido";
        executable = true;
        text = ''
          #!/bin/sh
          echo "mock-aurora-fido status: ready"
        '';
      };

      mockFidoFull = final.symlinkJoin {
        name = "mock-aurora-fido-pkg";
        paths = [
          mockFido
          (final.writeTextFile {
            name = "mock-aurora-fido-unit";
            destination = "/lib/systemd/system/aurora-fido.service";
            text = ''
              [Unit]
              Description=Mock Aurora FIDO2 daemon

              [Service]
              Type=simple
              ExecStart=${final.coreutils}/bin/sleep infinity
            '';
          })
        ];
      };

      hasReal =
        (prev.stdenv.hostPlatform.system == "aarch64-linux")
        && (inputs ? nixos-aurora)
        && (inputs.nixos-aurora.packages ? aarch64-linux);
      realPkgs = inputs.nixos-aurora.packages.aarch64-linux;
    in
    if hasReal then
      {
        aurora-sep = realPkgs.sep;
        aurora-xart = realPkgs.xart;
        aurora-fido = realPkgs.fido;
        inherit (realPkgs) libfprint;
        inherit (realPkgs) fprintd;
        aurora-touchid-rearm = mockRearm;
      }
    else
      {
        aurora-sep = mockSep;
        aurora-touchid-rearm = mockRearm;
        aurora-xart = mockXart;
        aurora-fido = mockFidoFull;
      };

  testPkgs = pkgs.extend auroraMockOverlay;
in
assert m2airConfig.omarchnix.hardware.m2air.touchId.enable == false;
assert m2airAuroraConfig.omarchnix.hardware.m2air.touchId.enable == true;
assert m2airAuroraConfig.omarchnix.hardware.m2air.touchId.fido.enable == true;
assert m2airAuroraConfig.boot.kernelPackages.kernel.version == "7.3.0";
assert (m2airAuroraConfig.boot.kernelPackages.kernel.auroraCtxrExecmem or false) == true;
assert builtins.elem "https://aurorasilicon.org/nixos-aurora/cache"
  m2airAuroraConfig.nix.settings.substituters;
assert builtins.elem "apple_sep" m2airAuroraConfig.boot.blacklistedKernelModules;
assert m2airAuroraConfig.boot.initrd.includeDefaultModules == false;
assert
  let
    fwUnit = m2airAuroraConfig.boot.initrd.systemd.services.aurora-vendor-firmware;
    rtFwUnit = m2airAuroraConfig.systemd.services.aurora-vendor-firmware;
    fwAct = m2airAuroraConfig.system.activationScripts.auroraFirmwareHandoff;
  in
  (fwUnit.unitConfig.DefaultDependencies or true) == false
  && builtins.elem "sysinit.target" fwUnit.wantedBy
  && builtins.elem "cryptsetup-pre.target" fwUnit.wants
  && builtins.elem "cryptsetup.target" fwUnit.before
  && builtins.elem "systemd-ask-password-console.service" fwUnit.before
  && (rtFwUnit.unitConfig.DefaultDependencies or true) == false
  && builtins.elem "sysinit.target" rtFwUnit.wantedBy
  && builtins.elem "systemd-udev-trigger.service" rtFwUnit.before
  && builtins.elem "udevd" fwAct.deps;
assert m2airAuroraConfig.systemd.services ? aurora-speaker-tuning-setup;
assert m2airAuroraConfig.systemd.services ? speakerguardd-v2;
assert
  (m2airAuroraConfig.systemd.services.speakerguardd-v2-provision.environment.SGV2_GATE or "") != "";
assert m2airAuroraConfig.services.pipewire.extraLv2Packages != [ ];
assert m2airAuroraConfig.services.pipewire.wireplumber.extraLv2Packages != [ ];
assert builtins.elem "uhid" m2airAuroraConfig.boot.kernelModules;
assert m2airAuroraConfig.system.build ? auroraStage2;
assert fingerprintSufficientBeforeUnix m2airAuroraConfig "sudo";
assert fingerprintSufficientBeforeUnix m2airAuroraConfig "polkit-1";
assert fingerprintSufficientBeforeUnix m2airAuroraConfig "hyprlock";
assert offersFingerprint m2airAuroraConfig "omarchy-lock-fingerprint";
assert !(offersFingerprint m2airAuroraConfig "omarchy-lock-password");
assert !(offersFingerprint m2airAuroraConfig "login");
assert !(offersFingerprint m2airAuroraConfig "su");
assert !(offersFingerprint m2airAuroraConfig "sshd");
assert hasRearmHook m2airAuroraConfig "sudo";
assert hasRearmHook m2airAuroraConfig "polkit-1";
assert hasRearmHook m2airAuroraConfig "login";
assert hasRearmHook m2airAuroraConfig "hyprlock";
assert hasRearmHook m2airAuroraConfig "omarchy-lock-password";
assert
  let
    conf =
      lib.splitString "\n"
        m2airAuroraConfig.environment.etc."modules-load.d/nixos.conf".source.text;
  in
  !(builtins.elem "atkbd" conf) && !(builtins.elem "cpufreq_schedutil" conf);
testPkgs.testers.runNixOSTest {
  name = "omarchnix-aurora-sep";

  node.specialArgs = { inherit inputs; };

  nodes.sepvm =
    { pkgs, ... }:
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
        self.nixosModules.omarchnix
      ];

      networking.hostName = "sep-vm";

      virtualisation = {
        memorySize = 2048;
        emptyDiskImages = [ 128 ];
      };

      omarchnix = {
        enable = true;
        profile = "vm";
        hardening.enable = true;
        desktop = {
          enable = true;
          user = "thomas";
          shellBackend = "omarchy-shell";
        };
        hardware.m2air.touchId = {
          enable = true;
          firmwareHandoff = false;
          requirePasswordAfterBoot = true;
          fido.enable = true;
        };
      };

      security.sudo.wheelNeedsPassword = true;

      users.users.thomas = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = [ "wheel" ];
        initialPassword = "sep-test-password";
        shell = "/run/current-system/sw/bin/zsh";
      };

      environment.systemPackages = [
        pkgs.dosfstools
        pkgs.gptfdisk
        pkgs.jq
        pkgs.pamtester
        pkgs.util-linux
      ];
    };

  testScript = ''
    import hashlib
    import json

    start_all()
    sepvm.wait_for_unit("multi-user.target")
    sepvm.wait_for_unit("aurora-touchid-rearm.socket")
    sepvm.wait_for_unit("aurora-touchid-boot.service")

    with subtest("systemd-modules-load, touchid.conf, rearm socket, and modprobe defaults are healthy"):
        sepvm.succeed("systemctl is-active systemd-modules-load.service")
        sepvm.succeed("test -S /run/aurora-touchid-rearm.sock")
        conf = sepvm.succeed("cat /etc/aurora/touchid.conf")
        assert "require_password_after_boot = yes" in conf, f"unexpected touchid.conf: {conf!r}"
        modprobe_cfg = sepvm.succeed("cat /etc/modprobe.d/aurora-sep-defaults.conf")
        assert "options apple_sep xart_writes=1 provision_keybag=1" in modprobe_cfg

    with subtest("61-omarchnix-iboot-isc.rules creates /dev/disk/by-partlabel/iBootSystemContainer even with empty GPT label"):
        sepvm.succeed(
            "for cand in /dev/vdb /dev/vdc; do "
            "  if [ -b \"$cand\" ] && ! blkid \"$cand\" >/dev/null 2>&1; then "
            "    sgdisk --zap-all \"$cand\" && "
            "    sgdisk -n 1:1M:33M -t 1:69646961-6700-11AA-AA11-00306543ECAC -c 1:\"\" \"$cand\" && "
            "    sgdisk -n 2:34M:98M -t 2:EF00 -c 2:ESP \"$cand\" && "
            "    partprobe \"$cand\" 2>/dev/null || true; "
            "    udevadm trigger --action=change \"$cand\" \"''${cand}1\" \"''${cand}2\" && "
            "    udevadm settle; "
            "    echo \"$cand\" > /tmp/isc-disk; "
            "    break; "
            "  fi; "
            "done"
        )
        sepvm.wait_until_succeeds("test -b /dev/disk/by-partlabel/iBootSystemContainer", timeout=15)

    with subtest("Password fallback succeeds across sudo, hyprlock, and omarchy-lock-password without /dev/sep-bio and triggers rearm socket"):
        sudo_out = sepvm.succeed(
            "su - thomas -c \"printf 'sep-test-password\\n' | /run/wrappers/bin/sudo -S id -un\""
        ).strip()
        assert sudo_out == "root", f"expected root from sudo -S, got {sudo_out!r}"

        sepvm.succeed(
            "printf 'sep-test-password\\n' | pamtester hyprlock thomas authenticate"
        )
        sepvm.succeed(
            "printf 'sep-test-password\\n' | pamtester omarchy-lock-password thomas authenticate"
        )
        sepvm.fail(
            "printf 'wrong-password\\n' | pamtester omarchy-lock-password thomas authenticate"
        )

        sepvm.wait_until_succeeds("test -f /run/mock-touchid-rearm-count", timeout=10)
        rearm_count = int(sepvm.succeed("cat /run/mock-touchid-rearm-count").strip())
        assert rearm_count >= 3, f"expected >= 3 rearm invocations across sudo + hyprlock + omarchy-lock, got {rearm_count}"

    with subtest("omarchnix-install-stage2 safely backs up .pre-aurora, updates atomically, and refuses invalid mounts"):
        # Refuses non-vfat directory
        sepvm.succeed("mkdir -p /tmp/not-mounted/m1n1 /tmp/stage2-v1 /tmp/stage2-v2")
        sepvm.succeed("printf 'aurora-stage2-v1-payload' > /tmp/stage2-v1/boot.bin")
        sepvm.succeed("sha256sum /tmp/stage2-v1/boot.bin | cut -d' ' -f1 > /tmp/stage2-v1/boot.bin.sha256")
        sepvm.succeed("printf 'aurora-stage2-v2-payload' > /tmp/stage2-v2/boot.bin")
        sepvm.succeed("sha256sum /tmp/stage2-v2/boot.bin | cut -d' ' -f1 > /tmp/stage2-v2/boot.bin.sha256")

        sepvm.fail("omarchnix-install-stage2 /tmp/not-mounted --stage2-dir /tmp/stage2-v1")

        # Format the mock ESP on partition 2 as FAT32 and seed stock alx.sh boot.bin
        sepvm.succeed(
            "disk=$(cat /tmp/isc-disk) && "
            "mkfs.vfat -F 32 -n ESP \"''${disk}2\" && "
            "mkdir -p /tmp/mock-esp && "
            "mount -t vfat \"''${disk}2\" /tmp/mock-esp && "
            "mkdir -p /tmp/mock-esp/m1n1 && "
            "printf 'stock-alx-m1n1-boot-bin' > /tmp/mock-esp/m1n1/boot.bin"
        )

        stock_sha = hashlib.sha256(b"stock-alx-m1n1-boot-bin").hexdigest()
        v1_sha = hashlib.sha256(b"aurora-stage2-v1-payload").hexdigest()
        v2_sha = hashlib.sha256(b"aurora-stage2-v2-payload").hexdigest()

        # First install: backs up stock to both .pre-aurora and .old, writes v1
        sepvm.succeed("omarchnix-install-stage2 /tmp/mock-esp --stage2-dir /tmp/stage2-v1")
        assert sepvm.succeed("sha256sum /tmp/mock-esp/m1n1/boot.bin | cut -d' ' -f1").strip() == v1_sha
        assert sepvm.succeed("sha256sum /tmp/mock-esp/m1n1/boot.bin.pre-aurora | cut -d' ' -f1").strip() == stock_sha
        assert sepvm.succeed("sha256sum /tmp/mock-esp/m1n1/boot.bin.old | cut -d' ' -f1").strip() == stock_sha

        # Idempotent re-run of v1 does not overwrite .old
        sepvm.succeed("omarchnix-install-stage2 /tmp/mock-esp --stage2-dir /tmp/stage2-v1")
        assert sepvm.succeed("sha256sum /tmp/mock-esp/m1n1/boot.bin.old | cut -d' ' -f1").strip() == stock_sha

        # Second upgrade to v2: .pre-aurora stays stock_sha, .old becomes v1_sha, live becomes v2_sha
        sepvm.succeed("omarchnix-install-stage2 /tmp/mock-esp --stage2-dir /tmp/stage2-v2")
        assert sepvm.succeed("sha256sum /tmp/mock-esp/m1n1/boot.bin | cut -d' ' -f1").strip() == v2_sha
        assert sepvm.succeed("sha256sum /tmp/mock-esp/m1n1/boot.bin.old | cut -d' ' -f1").strip() == v1_sha
        assert sepvm.succeed("sha256sum /tmp/mock-esp/m1n1/boot.bin.pre-aurora | cut -d' ' -f1").strip() == stock_sha

        status_json = json.loads(sepvm.succeed("omarchnix-touchid-status --json").strip())
        assert status_json["iBootSystemContainer"] is True, f"expected iBootSystemContainer=True, got {status_json!r}"
        assert status_json["rearmSocket"] is True, f"expected rearmSocket=True, got {status_json!r}"
  '';
}
