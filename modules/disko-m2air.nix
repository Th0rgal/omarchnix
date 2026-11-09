{
  disko.devices = {
    disk.nvme0n1 = {
      type = "disk";
      device = "/dev/nvme0n1";
      destroy = false;

      content = {
        type = "gpt";
        # Apple Silicon GPT layout on nvme0n1 is managed by macOS + alx.sh
        # (p1 iBootSystemContainer, p2 macOS APFS, p3 Asahi stub APFS,
        # p4 Asahi EFI FAT32 UUID C650-1003, p5 RecoveryOSContainer,
        # p6 NixOS LUKS2 UUID aa0403dd-9917-49e1-85b1-46b21b39f2d9).
        # Never run disko destroy/format against live Apple Silicon GPT.
        preCreateHook = ''
          if sgdisk -p "$device" 2>/dev/null | grep -Eq 'iBootSystemContainer|RecoveryOSContainer|AF0A'; then
            echo "Refusing full-disk disko format on live Apple Silicon GPT ($device): macOS/Asahi bootstrap partitions exist; mount existing UUIDs per docs/install-m2air.md." >&2
            exit 1
          fi
        '';

        partitions = {
          ESP = {
            priority = 100;
            size = "512M";
            type = "EF00";
            device = "/dev/disk/by-uuid/C650-1003";
            content = {
              type = "filesystem";
              format = "vfat";
              extraArgs = [
                "-F"
                "32"
                "-i"
                "C6501003"
              ];
              mountpoint = "/boot";
              mountOptions = [
                "fmask=0077"
                "dmask=0077"
              ];
            };
          };

          cryptroot = {
            priority = 200;
            size = "100%";
            type = "8309";
            device = "/dev/disk/by-uuid/aa0403dd-9917-49e1-85b1-46b21b39f2d9";
            content = {
              type = "luks";
              name = "cryptroot";
              extraFormatArgs = [
                "--type"
                "luks2"
                "--pbkdf"
                "argon2id"
                "--uuid"
                "aa0403dd-9917-49e1-85b1-46b21b39f2d9"
              ];
              settings = {
                allowDiscards = true;
              };
              content = {
                type = "filesystem";
                format = "ext4";
                extraArgs = [
                  "-L"
                  "nixos"
                ];
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
