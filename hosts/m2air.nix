# MacBook Air M2 — the primary Apple Silicon daily driver.
{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    inputs.sops-nix.nixosModules.sops
    ../modules/omarchnix.nix
    ../modules/filesystems-m2air.nix
  ];

  networking.hostName = "m2air";

  # Persistent ARM64 UEFI GRUB on the existing Asahi ESP (/boot, FAT32 UUID C650-1003).
  # Preserves Apple iBoot -> Stage 1 m1n1 -> Stage 2 /boot/m1n1/boot.bin -> U-Boot ->
  # /boot/EFI/BOOT/BOOTAA64.EFI -> Linux + initrd (initrd unlocks Argon2id LUKS2 by UUID;
  # GRUB never touches NVRAM, m1n1/boot.bin, vendorfw, or LUKS).
  boot.loader = {
    systemd-boot.enable = false;
    efi = {
      canTouchEfiVariables = false;
      efiSysMountPoint = "/boot";
    };
    grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      efiInstallAsRemovable = true;
      enableCryptodisk = false;
      configurationLimit = 2;
      extraFiles = lib.mkForce { };
    };
  };

  omarchnix = {
    enable = true;
    profile = "asahi";
    hardening.enable = true;
    containers.enable = true;
    secrets.enable = true;
    desktop = {
      enable = true;
      user = "thomas";
      shellBackend = "omarchy-shell";
      keyboard = {
        layout = "us";
        variant = "intl";
      };
      # The desktop is the console session: no display manager, Hyprland is
      # owned by a real systemd unit so `nixos-rebuild switch` cannot kill it.
      autostartTty.enable = true;
    };
    hardware.m2air = {
      enable = true;
      # Validate ordinary NixOS boot on stock nixos-apple-silicon + alx.sh
      # Stage 2 first; switch to .#m2air-aurora (or enable touchId with the
      # Aurora overlay) before running omarchnix-install-stage2 /boot.
      touchId = {
        enable = lib.mkDefault false;
        requirePasswordAfterBoot = true;
        fido.enable = true;
      };
    };
  };

  # Google Antigravity ships as a binary Electron app; allow only that unfree
  # package rather than the whole unfree set.
  nixpkgs.config.allowUnfreePackages = [ "antigravity-hub" ];

  environment.systemPackages = with pkgs; [
    brave
    firefox
    bitwarden-desktop
    bitwarden-cli
    telegram-desktop
    age
    restic
    rclone
    orb-desktop
    notion-calendar
    antigravity-hub
  ];

  users.users.thomas = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [
      "wheel"
      "video"
      "render"
      "audio"
      "networkmanager"
    ];
    shell = "/run/current-system/sw/bin/zsh";
    # Provision the real key at install time; never commit it.
    openssh.authorizedKeys.keys = [ ];
  };

  security.sudo.wheelNeedsPassword = true;
}
