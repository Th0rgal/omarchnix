{
  pkgs,
  lib,
  inputs,
  m2airConfig,
}:
let
  inherit (import "${inputs.nixpkgs}/nixos/tests/ssh-keys.nix" pkgs)
    snakeOilPrivateKey
    snakeOilPublicKey
    ;

  vmLuksKeyfile = pkgs.writeText "vm-luks-keyfile" "asahi-nixos-ci-test-luks-key";
in
assert m2airConfig.boot.initrd.luks.devices ? cryptroot;
assert m2airConfig.boot.initrd.luks.devices.cryptroot.device == "/dev/disk/by-partlabel/cryptroot";
assert m2airConfig.boot.initrd.luks.devices.cryptroot.allowDiscards == true;
assert m2airConfig.fileSystems."/".device == "/dev/mapper/cryptroot";
assert m2airConfig.fileSystems."/".fsType == "ext4";
assert m2airConfig.fileSystems."/boot".device == "/dev/disk/by-partlabel/ESP";
assert m2airConfig.fileSystems."/mnt/shared".device == "/dev/disk/by-partlabel/shared";
assert m2airConfig.fileSystems."/mnt/shared".fsType == "exfat";
assert m2airConfig.boot.loader.systemd-boot.enable == false;
assert m2airConfig.boot.loader.grub.enable == false;
assert m2airConfig.boot.loader.efi.canTouchEfiVariables == false;
pkgs.testers.runNixOSTest {
  name = "asahi-nixos-security";

  sshBackdoor.enable = false;

  node.specialArgs = { inherit inputs; };

  nodes = {
    host =
      { pkgs, ... }:
      {
        imports = [
          inputs.disko.nixosModules.disko
          inputs.sops-nix.nixosModules.sops
          ../hosts/common.nix
          ../modules/disko-m2air.nix
          ../modules/hardening.nix
          ../modules/containers.nix
          ../modules/secrets.nix
        ];

        networking.hostName = "host";

        virtualisation = {
          memorySize = 2048;
          emptyDiskImages = [ 512 ];
          useNixStoreImage = true;
          writableStore = false;
        };

        nix.enable = lib.mkVMOverride false;
        containers.dev-untrusted.config.nix.enable = lib.mkVMOverride false;

        boot.initrd = {
          systemd = {
            initrdBin = [
              pkgs.cryptsetup
              pkgs.gptfdisk
              pkgs.util-linux
            ];
            contents."/etc/vm-cryptroot.key".source = vmLuksKeyfile;
            services.prepare-vm-cryptroot = {
              description = "Format virtual GPT cryptroot partition for CI LUKS2 test";
              wantedBy = [ "initrd.target" ];
              before = [
                "systemd-cryptsetup@cryptroot.service"
                "cryptsetup.target"
              ];
              after = [
                "systemd-udevd.service"
                "systemd-modules-load.service"
              ];
              unitConfig.DefaultDependencies = false;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                udevadm settle
                for cand in /dev/vdb /dev/vdc; do
                  if [ -b "$cand" ] && ! blkid "$cand" >/dev/null 2>&1; then
                    sgdisk --zap-all "$cand"
                    sgdisk -n 1:1M:65M -t 1:EF00 -c 1:ESP "$cand"
                    sgdisk -n 2:66M:130M -t 2:0700 -c 2:shared "$cand"
                    sgdisk -n 3:131M:0 -t 3:8309 -c 3:cryptroot "$cand"
                    partprobe "$cand" 2>/dev/null || true
                    udevadm trigger --action=change "$cand"
                    udevadm settle
                    for _ in $(seq 1 50); do
                      [ -b /dev/disk/by-partlabel/cryptroot ] && break
                      sleep 0.1
                    done
                    cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
                      --key-file /etc/vm-cryptroot.key /dev/disk/by-partlabel/cryptroot
                    break
                  fi
                done
              '';
            };
          };

          luks.devices = lib.mkVMOverride {
            cryptroot = {
              device = "/dev/disk/by-partlabel/cryptroot";
              keyFile = "/etc/vm-cryptroot.key";
              allowDiscards = true;
            };
          };
        };

        users.users.thomas = {
          isNormalUser = true;
          uid = 1000;
          extraGroups = [ "wheel" ];
          initialPassword = "test-password-must-not-work-over-ssh";
          openssh.authorizedKeys.keys = [ snakeOilPublicKey ];
        };

        users.users.unpriv = {
          isNormalUser = true;
          uid = 1001;
        };

        environment.systemPackages = [
          pkgs.cpio
          pkgs.jq
          pkgs.netcat-openbsd
          pkgs.sshpass
          pkgs.zstd
        ];
      };

    attacker =
      { pkgs, ... }:
      {
        networking.firewall.enable = false;
        environment.systemPackages = [
          pkgs.netcat-openbsd
          pkgs.sshpass
        ];
      };
  };

  testScript = ''
    start_all()

    host.wait_for_unit("multi-user.target")
    host.wait_for_unit("apparmor.service")
    host.wait_for_unit("sshd.service")
    host.wait_for_unit("firewall.service")
    host.wait_for_unit("container@dev-untrusted.service")
    attacker.wait_for_unit("multi-user.target")

    with subtest("Firewall is default-deny with explicit TCP/22 exception only"):
        host.succeed("nc -lk 0.0.0.0 9999 >/tmp/unexposed.log 2>&1 &")
        host.wait_for_open_port(9999)
        attacker.succeed("nc -z -w 3 host 22")
        attacker.fail("nc -z -w 2 host 9999")
        attacker.fail("ping -4 -c 1 -W 2 host")
        attacker.fail("ping -6 -c 1 -W 2 host")
        attacker.fail("nc -z -w 2 host 18080")

    with subtest("SSH enforces key-only authentication and confines sshd with AppArmor"):
        sshd_cfg = host.succeed("sshd -T -f /etc/ssh/sshd_config").lower()
        assert "passwordauthentication no" in sshd_cfg, f"sshd_cfg: {sshd_cfg!r}"
        assert "kbdinteractiveauthentication no" in sshd_cfg, f"sshd_cfg: {sshd_cfg!r}"
        assert "permitrootlogin no" in sshd_cfg, f"sshd_cfg: {sshd_cfg!r}"

        host.succeed("aa-status --json | jq -e '.profiles[\"sshd\"] == \"enforce\"'")
        host.succeed(
            "aa-status --json | jq -e '(.processes | to_entries | map(.value[]) | map(select(.profile == \"sshd\" and .status == \"enforce\")) | length) >= 1'"
        )

        pw_err = attacker.fail(
            "sshpass -p 'test-password-must-not-work-over-ssh' ssh "
            "-n -F /dev/null "
            "-o LogLevel=ERROR "
            "-o PreferredAuthentications=password,keyboard-interactive "
            "-o PubkeyAuthentication=no "
            "-o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            "thomas@host true </dev/null 2>&1"
        )
        assert "Permission denied" in pw_err, f"unexpected ssh failure: {pw_err!r}"

        attacker.succeed("install -d -m 700 /root/.ssh")
        attacker.succeed("cat ${snakeOilPrivateKey} > /root/.ssh/id_key && chmod 600 /root/.ssh/id_key")
        out = attacker.succeed(
            "ssh -n -F /dev/null -i /root/.ssh/id_key "
            "-o BatchMode=yes "
            "-o LogLevel=ERROR "
            "-o IdentitiesOnly=yes "
            "-o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            "thomas@host id -un </dev/null"
        ).strip()
        assert out == "thomas", f"expected thomas, got {out!r}"

    with subtest("sudo execWheelOnly and supported kernel hardening sysctls"):
        sudo_err = host.fail("su -l unpriv -s /bin/sh -c '/run/wrappers/bin/sudo -n true' 2>&1")
        assert "Permission denied" in sudo_err, f"expected Permission denied from execWheelOnly, got {sudo_err!r}"
        host.succeed("test -x /run/wrappers/bin/sudo")
        assert host.succeed("stat -c '%U:%G:%a' /run/wrappers/bin/sudo").strip() == "root:wheel:4510"
        host.succeed("systemctl is-active systemd-sysctl.service")
        assert host.succeed("sysctl -n kernel.kptr_restrict").strip() == "2"
        assert host.succeed("sysctl -n kernel.dmesg_restrict").strip() == "1"
        assert host.succeed("sysctl -n kernel.unprivileged_bpf_disabled").strip() == "1"
        assert host.succeed("sysctl -n kernel.yama.ptrace_scope").strip() == "1"
        assert host.succeed("sysctl -n fs.suid_dumpable").strip() == "0"
        assert host.succeed("sysctl -n net.ipv4.ip_forward").strip() == "0"

    with subtest("LUKS2 cryptroot device is wired into initrd and unlocked at boot"):
        host.succeed("test -b /dev/mapper/cryptroot")
        status = host.succeed("cryptsetup status cryptroot")
        assert "LUKS2" in status, f"expected LUKS2 status, got {status!r}"
        initrd_listing = host.succeed("zstd -dc < /run/booted-system/initrd | cpio -t 2>/dev/null")
        assert "etc/crypttab" in initrd_listing
        assert "systemd-cryptsetup" in initrd_listing
        assert "dm-crypt" in initrd_listing or "dm_crypt" in initrd_listing

    with subtest("Declarative dev-untrusted container starts, shifts UIDs, and cannot reach host or WAN"):
        state = host.succeed("nixos-container status dev-untrusted").strip()
        assert state == "up", f"expected container up, got {state!r}"

        leader_pid = host.succeed("machinectl show dev-untrusted -p Leader --value").strip()
        leader_uid = int(host.succeed(f"stat -c '%u' /proc/{leader_pid}").strip())
        assert leader_uid >= 65536, f"expected user-namespaced leader UID >= 65536, got {leader_uid}"

        host.succeed(
            "nixos-container run dev-untrusted -- su -s /bin/sh dev -c "
            "'echo isolated-ok > /workspace/from-container'"
        )
        assert host.succeed("cat /var/lib/containers-workdir/dev-untrusted/from-container").strip() == "isolated-ok"
        assert host.succeed("stat -c '%u:%g' /var/lib/containers-workdir/dev-untrusted/from-container").strip() == "1000:100"

        host.fail(
            "nixos-container run dev-untrusted -- "
            "nc -z -w 2 10.233.1.1 22"
        )
        host.fail(
            "nixos-container run dev-untrusted -- "
            "nc -z -w 2 10.233.1.1 9999"
        )
        attacker_ip = attacker.succeed("hostname -I | awk '{print $1}'").strip()
        host.fail(
            f"nixos-container run dev-untrusted -- nc -z -w 2 {attacker_ip} 22"
        )

        host.succeed(
            "nixos-container run dev-untrusted -- "
            "su -s /bin/sh dev -c "
            "'nohup nc -lk 0.0.0.0 8080 >/tmp/nc.log 2>&1 </dev/null &'"
        )
        host.wait_until_succeeds("nc -z -w 2 10.233.1.2 8080")
        host.wait_until_succeeds("nc -z -w 2 127.0.0.1 18080")
  '';
}
