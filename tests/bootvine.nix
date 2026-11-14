# omarchnix.boot.bootvine end to end, in a VM with a systemd initrd:
#   1. bootvine draws in the initrd and answers the LUKS passphrase prompt;
#   2. systemd-cryptsetup still caches that passphrase in the kernel keyring, which
#      `autostartTty.unlockKeyringFromLuks` reads to unlock GNOME Keyring;
#   3. a tty1 session unit (standing in for `hyprland-tty1`) is aliased as
#      display-manager.service, switches to tty1 during boot and keeps it: bootvine
#      hands over instead of pulling the console back to tty12.
{
  pkgs,
  inputs,
  self,
}:
let
  secretDisk = import "${inputs.bootvine}/vm-tests/encrypted-volume/secret-disk.nix" {
    inherit pkgs;
  };
in
pkgs.testers.runNixOSTest {
  name = "omarchnix-bootvine";

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [ self.nixosModules.omarchnix ];

      system.stateVersion = "26.05";
      testing.initrdBackdoor = true;
      # The bundled omarchnix module enforces these hardening invariants.
      services.openssh.settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };

      omarchnix.boot.bootvine = {
        enable = true;
        sessionUnit = "fake-session";
      };

      boot.initrd.luks.devices = lib.mkVMOverride {
        secret.device = "/dev/disk/by-uuid/${secretDisk.uuid}";
      };
      virtualisation.qemu.drives = [ secretDisk.qemuDrive ];

      environment.systemPackages = [ pkgs.keyutils ];

      # Same shape as omarchnix's hyprland-<tty> unit: a session that owns tty1,
      # part of multi-user.target, switching the console to its terminal.
      systemd.services.fake-session = {
        description = "Stand-in graphical session on /dev/tty1";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-user-sessions.service" ];
        conflicts = [ "autovt@tty1.service" ];
        serviceConfig = {
          Type = "exec";
          TTYPath = "/dev/tty1";
          TTYReset = true;
          StandardInput = "tty";
          StandardOutput = "tty";
          ExecStartPre = "${pkgs.kbd}/bin/chvt 1";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      };
    };

  testScript = ''
    PASSPHRASE = "${secretDisk.passphrase}"

    # In the initrd bootvine logs as `@bootvine` rather than under its unit.
    ENTRIES = "_SYSTEMD_UNIT=bootvine.service + SYSLOG_IDENTIFIER=bootvine + SYSLOG_IDENTIFIER=@bootvine"

    def bootvine_journal():
        return machine.execute(f"journalctl -b --no-pager -o cat {ENTRIES}")[1]

    def wait_for_bootvine(text, timeout=120):
        # The initrd has no grep, so match on this side.
        retry(lambda _: text in bootvine_journal(), timeout_seconds=timeout)

    machine.start()

    with subtest("bootvine answers the LUKS prompt in the initrd"):
        wait_for_bootvine("asking for a password")
        machine.send_chars(f"{PASSPHRASE}\n")
        machine.wait_for_unit("systemd-cryptsetup@secret.service")
        machine.switch_root()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("test -e /dev/mapper/secret")
        assert "answered a password prompt" in bootvine_journal(), "bootvine did not answer the prompt itself"

    with subtest("the passphrase is cached in the kernel keyring for the keyring unlock"):
        # Read it the way omarchnix-stage-luks-keyring-<tty> does: a unit with
        # KeyringMode=shared (the backdoor shell has a private session keyring).
        # systemd keeps the cached passphrase for about 150 s after the unlock.
        machine.succeed(
            "systemd-run --wait --pipe --quiet -p KeyringMode=shared "
            "${pkgs.keyutils}/bin/keyctl request user cryptsetup"
        )

    with subtest("the tty1 session keeps the console after boot"):
        machine.succeed("test \"$(systemctl show -p Id --value display-manager.service)\" = fake-session.service")
        machine.wait_for_unit("fake-session.service")
        machine.wait_until_succeeds("! systemctl is-active --quiet bootvine.service", timeout=120)
        machine.sleep(3)
        active = machine.succeed("cat /sys/class/tty/tty0/active").strip()
        assert active == "tty1", f"console is on {active}, expected the session's tty1"
        print(bootvine_journal())
  '';
}
