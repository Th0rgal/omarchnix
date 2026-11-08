# Printed Runbook — MacBook Air M2 Cutover (Gate G6)

> **Rule (`docs/decisions.md` DR-3 / DR-5 / DR-12):** Complete the Scaleway `M2-L-ASAHI` dress rehearsal (`docs/runbook-scaleway.md`, Gates G4 & G5) before touching internal partitions, or verify the `m1n1` -> U-Boot -> UEFI standalone stages below cleanly before writing the NixOS partition. Never enable `boot.loader.*` in NixOS on Apple Silicon; boot objects (`m1n1`, `U-Boot`, `vendorfw/firmware.cpio`) are owned exclusively by the Asahi installer on the Apple EFI System Partition.

---

## 0. Pre-Cutover Checklist (in macOS)

- [ ] **CI Artifacts Verified:** `main` CI run green across all jobs; download `installer-iso` artifact and verify SHA-256 checksum matches `docs/logs/g2-2026-11-06.md` (or latest `main` run).
- [ ] **Verified Time Machine Backup:** Complete APFS snapshot + external Time Machine backup verified readable on another volume.
- [ ] **macOS Firmware Baseline:** Update macOS to latest point release so `iBoot` and `vendorfw` match `linux-asahi` (`7.2.15`) expectations.
- [ ] **APFS Resize (DR-4, 1 TB NVMe):**
  ```console
  # Shrink macOS APFS container leaving ~880 GB free for shared exFAT + NixOS LUKS2
  diskutil apfs resizeContainer disk0s2 120G
  ```
- [ ] **Prepare USB Installer Stick:** Flash `nixos-*-aarch64-linux.iso` to a USB-C drive (`/dev/diskN` external ONLY — double-check `diskutil list external`):
  ```console
  diskutil unmountDisk /dev/diskN
  sudo dd if=nixos-26.11.20261103.1d06008-aarch64-linux.iso of=/dev/rdiskN bs=4m status=progress
  sync
  ```

---

## 1. Asahi UEFI Standalone Bootstrap (in macOS)

1. Run the upstream Asahi installer to extract vendor firmware and install the signed `m1n1` + U-Boot UEFI stub without installing Fedora/Arch:
   ```console
   curl https://alx.sh | sh
   ```
2. Choose **UEFI environment only (m1n1 + U-Boot + ESP)** in the free space after `disk0s2` (`macOS`), naming the boot entry `omarchnix`.
3. Follow the prompt to shut down, **press and hold Touch ID / Power** until *"Loading startup options..."* appears, select `omarchnix` under Startup Options, and complete `bputil` 1TR step when prompted.
4. Plug in the USB-C NixOS installer drive; U-Boot (`2026.07-2-asahi`) auto-boots GRUB EFI from USB into the live NixOS `aarch64-linux` installer with `/boot/vendorfw/firmware.cpio` available on the Asahi ESP.

*(Fallback DR-1 Path B: if standalone UEFI stalls, run the Omarchy Mac installer for dual-boot and revisit NixOS cutover without touching macOS).*

---

## 2. Partitioning Free Space & Installing `m2air` (in Live NixOS ISO)

> **Safety Note:** `modules/disko-m2air.nix` carries a `preCreateHook` refusing whole-disk GPT destruction whenever Apple Silicon `iBootSystemContainer` / `RecoveryOSContainer` (`AF0A`) partitions exist on `/dev/nvme0n1`. On live dual-boot Apple Silicon hardware, create the two Linux partitions (`shared` + `cryptroot`) only in the unallocated free space after the Asahi UEFI ESP (`nvme0n1p4`), never wiping `nvme0n1` GPT!

1. Connect to Wi-Fi in the live environment (`impala` or `iwctl` / `nmcli device wifi connect <SSID> --ask`).
2. Inspect exact partition numbers (`lsblk -o NAME,PARTLABEL,FSTYPE,SIZE /dev/nvme0n1`):
   - Confirm `iBootSystemContainer`, `macOS` APFS (~120 GB), Asahi `EFI` (`ESP`, ~512 MB, FAT32 containing `m1n1/`, `efi/`, and `vendorfw/firmware.cpio`), and `RecoveryOSContainer`.
3. Create the `shared` exFAT shelf (`150G`, label `shared`) and `cryptroot` (`LUKS2` + `ext4`, label `nixos`) in the free space using `gdisk /dev/nvme0n1` (`n` -> `+150G` type `0700` name `shared`; `n` -> remaining space type `8309` name `cryptroot`), then format and mount matching `modules/disko-m2air.nix` labels:
   ```console
   # Replace p5 / p6 / p4 with exact partition numbers verified in lsblk!
   mkfs.exfat -n shared /dev/nvme0n1p5
   cryptsetup luksFormat --type luks2 --pbkdf argon2id --label cryptroot-luks /dev/nvme0n1p6
   cryptsetup open --allow-discards /dev/nvme0n1p6 cryptroot
   mkfs.ext4 -L nixos /dev/mapper/cryptroot

   mount /dev/mapper/cryptroot /mnt
   mkdir -p /mnt/boot /mnt/mnt/shared /mnt/var/lib/sops-nix
   mount -o umask=0077 /dev/nvme0n1p4 /mnt/boot
   mount /dev/nvme0n1p5 /mnt/mnt/shared
   ```
4. Verify `/mnt/boot/vendorfw/firmware.cpio` is intact (`ls -lh /mnt/boot/vendorfw/firmware.cpio`).
5. Copy the owner `sops-nix` age secret key (`0600`) to `/mnt/var/lib/sops-nix/key.txt` and provision `thomas`'s SSH authorized key.
6. Install the `m2air` system closure and stage the verified Aurora Stage 2 (`aura` `1.0.0b8` + `linux-aurora` `7.3.0` DTBs + `uboot-aurora`, preserving `/mnt/boot/m1n1/boot.bin.pre-aurora`):
   ```console
   nixos-install --flake github:Th0rgal/omarchnix#m2air --no-root-passwd
   nixos-enter --root /mnt -c 'passwd thomas'
   nixos-enter --root /mnt -c '/run/current-system/sw/bin/omarchnix-install-stage2 /boot'
   umount -R /mnt
   cryptsetup close cryptroot
   reboot
   ```

---

## 3. First-Boot Hardware Polish Verification (`m2air`)

Record all outputs verbatim into `docs/logs/g6-<YYYY-MM-DD>.md`:

- [ ] **Dual-Boot Picker & Startup Disk:** Hold power button -> both `Macintosh HD` and `omarchnix` boot cleanly; `sudo asahi-bless --list-volumes` enumerates both volumes from Linux.
- [ ] **LUKS2 Initrd Unlock & Mounts:** Unlock `cryptroot` at boot; verify `findmnt / /boot /mnt/shared` and read/write test on `/mnt/shared` from both NixOS and macOS.
- [ ] **Display, HiDPI (1.6x) & Notch Geometry:**
  - `hyprctl monitors -j` shows `eDP-1` at `2560x1664@60Hz`, scale `1.60` (`1600x1040` logical), `xwayland.force_zero_scaling = true`.
  - `/usr/share/omarchy-platform/display-cutouts.json` present (`300x64` notch reserve for `omarchy-shell` / top bar).
  - `brightnessctl` adjusts Apple DCP backlight (`XF86MonBrightnessUp/Down`) and keyboard backlight (`*::kbd_backlight`).
- [ ] **Audio DSP & Speaker Protection (`asahi-audio` 4.1 + `speakersafetyd` 3.0):**
  - `systemctl status speakersafetyd` is **active (running)** (never bypass thermal protection).
  - `wpctl status` shows `MacBook Air J413` / `J415` DSP graph (`bankstown-lv2`, `lsp-plugins`, `triforce-lv2` via PipeWire filter-chain) + internal mic array.
- [ ] **Power, Battery Thresholds & `s2idle` Sleep:**
  - `systemctl status upower power-profiles-daemon macsmc-battery-thresholds` active; `cat /sys/class/power_supply/macsmc-battery/charge_control_end_threshold` returns `80`.
  - Close lid for 60s -> `journalctl -b -u systemd-suspend` confirms clean `s2idle` entry/resume, `hyprlock` locked before sleep, DPMS restored on wake, Wi-Fi (`brcmfmac` firmware supplicant) reconnects automatically.
- [ ] **Omarchnix Shell & System Health:**
  - `omarchnix status --json` and `omarchnix check --json` report `omarchy-shell` active, current theme staged cleanly, and all 4 coding-agent skill directories provisioned.
- [ ] **Secure Enclave, Touch ID & FIDO2 Passkeys (`modules/aurora-sep.nix`):**
  - Wait ~45s after boot for initial SEP keybag bring-up, then run `omarchnix-touchid-status` (verifies `linux-aurora` `7.3.0`, `/dev/disk/by-partlabel/iBootSystemContainer`, `/dev/sep-bio`, `aurora-sep-ready.service`, `fprintd.service`, and `aurora-fido.service`).
  - Enroll fingerprint: `sudo fprintd-enroll thomas` and test `fprintd-verify`.
  - Verify Touch ID prompts on `sudo -k true`, Polkit GUI dialogs, `omarchy-system-lock`, and `hyprlock` (`SUPER + ESCAPE`), plus WebAuthn passkeys in Brave/Firefox (`aurora-fido status`).
  - *(Rollback note: if ever needed from macOS or live USB, copying `/boot/m1n1/boot.bin.pre-aurora` back to `/boot/m1n1/boot.bin` restores the original stock `alx.sh` Stage 2).*

---

## 4. Ongoing Firmware Maintenance (DR-5)

1. Boot macOS after Apple point updates and install macOS Software Update.
2. In macOS Terminal, run `curl https://alx.sh | sh` and select **Rebuild vendor firmware package** so `/boot/vendorfw/firmware.cpio` stays synchronized with system firmware.
