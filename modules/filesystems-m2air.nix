# Declarative filesystem mounts and LUKS2 root mapping for MacBook Air M2.
# Intentionally uses pure NixOS `fileSystems` + `boot.initrd.luks.devices`
# (no `disko` GPT/partition declarations) so NixOS has zero capability to
# create, modify, or wipe Apple Silicon GPT partition tables.
{ ... }:
{
  boot.initrd.luks.devices.cryptroot = {
    device = "/dev/disk/by-uuid/aa0403dd-9917-49e1-85b1-46b21b39f2d9";
    allowDiscards = true;
  };

  fileSystems."/" = {
    device = "/dev/mapper/cryptroot";
    fsType = "ext4";
    options = [ "defaults" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/C650-1003";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };
}
