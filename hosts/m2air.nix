# MacBook Air M2 — the primary Apple Silicon daily driver.
{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.home-manager
    inputs.sops-nix.nixosModules.sops
    ../modules/omarchnix.nix
    ../modules/disko-m2air.nix
  ];

  networking.hostName = "m2air";

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

  environment.systemPackages = with pkgs; [
    brave
    firefox
    bitwarden-desktop
    bitwarden-cli
    telegram-desktop
    age
    restic
    rclone
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
