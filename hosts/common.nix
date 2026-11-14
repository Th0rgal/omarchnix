# Shared configuration for every host in this flake.
# Keep this file hardware-agnostic: anything Apple-Silicon-specific
# belongs in m2air.nix / rehearsal.nix, anything QEMU-specific in vm.nix.
{ lib, ... }:
{
  # Default bootloaders and EFI NVRAM writes off across shared hosts so
  # m1n1/U-Boot/vendorfw and Apple NVRAM are never touched implicitly;
  # m2air.nix explicitly enables removable ARM64 UEFI GRUB on /boot
  # (with extraFiles cleared so m1n1/boot.bin stays untouched), and
  # vm.nix enables systemd-boot for QEMU.
  boot.loader.systemd-boot.enable = lib.mkDefault false;
  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;

  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  environment.variables.EDITOR = "hx";
  programs.zsh.enable = true;

  nix.settings = {
    # nixos-apple-silicon binary cache — skips multi-hour kernel builds.
    substituters = [ "https://nixos-apple-silicon.cachix.org" ];
    trusted-public-keys = [
      "nixos-apple-silicon.cachix.org-1:8psDu5SA5dAD7qA0zMy5UT292TxeEPzIz8VVEr2Js20="
    ];
    auto-optimise-store = true;
  };

  system.stateVersion = "25.05";

  # Users are declared per-host: the rehearsal box is disposable, the
  # Air is not. Never put secrets or personal data in this file.
}
