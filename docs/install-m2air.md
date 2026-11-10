# Printed Runbook — MacBook Air M2 Cutover (Gate G6)

> **Rule (`docs/decisions.md` DR-3 / DR-5 / DR-12 / DR-19):** Complete the Scaleway `M2-L-ASAHI` dress rehearsal (`docs/runbook-scaleway.md`, Gates G4 & G5) before touching internal partitions, or verify the `m1n1` -> U-Boot -> UEFI standalone stages below cleanly before writing the NixOS partition. Apple BootROM/iBoot, Stage 1 `m1n1`, `/boot/m1n1/boot.bin` (Stage 2 `m1n1` + DTBs + `U-Boot`), and `/boot/vendorfw/firmware.cpio` on the Asahi ESP (`UUID=C650-1003`) are owned by `alx.sh` (and later explicit `omarchnix-install-stage2`), while `hosts/m2air.nix` installs removable ARM64 UEFI GRUB to `/boot/EFI/BOOT/BOOTAA64.EFI` (`device = "nodev"`, `efiSupport = true`, `efiInstallAsRemovable = true`, `enableCryptodisk = false`, `configurationLimit = 2`, `canTouchEfiVariables = false`, `extraFiles = lib.mkForce { }`) so U-Boot boots NixOS persistently without touching Apple NVRAM, `m1n1/boot.bin`, `vendorfw`, or Argon2id LUKS2 in GRUB.

---

## 0. Pre-Cutover Checklist (in macOS)

- [ ] **CI Artifacts Verified:** `main` CI run green across all jobs; download `installer-iso` artifact and verify SHA-256 checksum matches `docs/logs/g2-2026-11-06.md` (or latest `main` run).
- [ ] **Verified Time Machine Backup:** Complete APFS snapshot + external Time Machine backup verified readable on another volume.
- [ ] **macOS Firmware Baseline:** Update macOS to latest point release so `iBoot` and `vendorfw` match `linux-asahi` (`7.2.15`) expectations.
- [ ] **APFS Resize (1 TB NVMe):**
  ```console
  # Shrink macOS APFS container leaving free space for NixOS LUKS2
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

> **Safety Note:** `modules/filesystems-m2air.nix` declares **only** existing NixOS `fileSystems` and `boot.initrd.luks.devices.cryptroot` by UUID — `disko` has been removed completely (`DR-18`) so NixOS carries zero GPT/partition creation or disk-formatting scripts for `/dev/nvme0n1`. On Apple Silicon, `nvme0n1p1` (`iBootSystemContainer`), `nvme0n1p2` (`macOS` APFS), `nvme0n1p3` (Asahi stub APFS), `nvme0n1p4` (Asahi EFI System Partition, FAT32 UUID `C650-1003`), and `nvme0n1p5` (`RecoveryOSContainer` — **macOS Recovery, NEVER touch or format `p5`!**) are owned by macOS and `alx.sh`. Unlock and mount only the existing NixOS LUKS2 root (`UUID=aa0403dd-9917-49e1-85b1-46b21b39f2d9`) and EFI (`UUID=C650-1003`) by UUID so boot remains completely independent of GPT partition labels or numbering (even if GPT entries are later sorted with `gdisk` `s` under a verified backup; see §5).

1. Connect to Wi-Fi in the live environment (`impala` or `iwctl` / `nmcli device wifi connect <SSID> --ask`).
2. Inspect exact partition UUIDs and types (`lsblk -o NAME,FSTYPE,UUID,PARTTYPE,PARTLABEL,SIZE /dev/nvme0n1`):
   - `nvme0n1p1`: `iBootSystemContainer`
   - `nvme0n1p2`: `macOS` APFS
   - `nvme0n1p3`: Asahi stub APFS (`2.5G`)
   - `nvme0n1p4`: Asahi EFI System Partition (`vfat`, UUID `C650-1003`, containing `m1n1/`, `efi/`, and `vendorfw/firmware.cpio`)
   - `nvme0n1p5`: `RecoveryOSContainer` (**macOS Recovery — do not modify!**)
   - `nvme0n1p6`: NixOS `crypto_LUKS` (`UUID=aa0403dd-9917-49e1-85b1-46b21b39f2d9`, unnamed GPT partition -> `/dev/mapper/cryptroot` `ext4`)
3. If `cryptroot` is not already formatted, create a single Linux LUKS partition in unallocated free space (`gdisk /dev/nvme0n1` -> `n` -> remaining space, type `8309`), format LUKS2 + `ext4`, or if already prepared simply unlock and mount by UUID:
   ```console
   # Only if nvme0n1p6 has NOT been formatted yet:
   # cryptsetup luksFormat --type luks2 --pbkdf argon2id --uuid aa0403dd-9917-49e1-85b1-46b21b39f2d9 /dev/nvme0n1p6
   # cryptsetup open --allow-discards /dev/disk/by-uuid/aa0403dd-9917-49e1-85b1-46b21b39f2d9 cryptroot
   # mkfs.ext4 -L nixos /dev/mapper/cryptroot

   # If LUKS2 + ext4 are already created, unlock and mount directly by UUID:
   cryptsetup open --allow-discards /dev/disk/by-uuid/aa0403dd-9917-49e1-85b1-46b21b39f2d9 cryptroot
   mount /dev/mapper/cryptroot /mnt
   mkdir -p /mnt/boot /mnt/var/lib/sops-nix
   mount -o fmask=0077,dmask=0077 /dev/disk/by-uuid/C650-1003 /mnt/boot
   ```
4. Verify `/mnt/boot/vendorfw/firmware.cpio` and `/mnt/boot/m1n1/boot.bin` are intact (`ls -lh /mnt/boot/vendorfw/firmware.cpio /mnt/boot/m1n1/boot.bin`).
5. Copy the owner `sops-nix` age secret key (`0600`) to `/mnt/var/lib/sops-nix/key.txt` and provision `thomas`'s SSH authorized key.
6. Install the baseline `m2air` system closure and removable ARM64 UEFI GRUB (`EFI/BOOT/BOOTAA64.EFI`, `grub/grub.cfg`, `kernels/*`, capped at `configurationLimit = 2` to fit within the ~353 MiB free ESP budget while leaving `/boot/m1n1/boot.bin` and `/boot/vendorfw/firmware.cpio` untouched; Aurora Stage 2 stays deferred until §4):
   ```console
   nixos-install --flake github:Th0rgal/omarchnix#m2air --no-root-passwd --option tarball-ttl 0
   # Set thomas's password on initial install (skip if already set in /mnt/etc/shadow):
   nixos-enter --root /mnt -c 'passwd thomas'
   ```
7. Verify ESP bootloader artifacts, kernel/initrd copies, untouched `m1n1/boot.bin` + `vendorfw/firmware.cpio`, and free ESP space **before** unmounting and rebooting:
   ```console
   ls -lh /mnt/boot/EFI/BOOT/BOOTAA64.EFI /mnt/boot/grub/grub.cfg /mnt/boot/kernels/
   ls -lh /mnt/boot/m1n1/boot.bin /mnt/boot/vendorfw/firmware.cpio
   grep -E 'C650-1003|menuentry|linux |initrd ' /mnt/boot/grub/grub.cfg
   df -h /mnt/boot
   sync
   umount -R /mnt
   cryptsetup close cryptroot
   reboot
   ```
   *(If `/mnt` and `/mnt/boot` are already mounted from an earlier install with `thomas`'s password and `/mnt/var/lib/sops-nix/key.txt` already configured, simply re-run `nixos-install --flake github:Th0rgal/omarchnix#m2air --no-root-passwd --option tarball-ttl 0` without reformatting or touching partitions, then run the step 7 checks above).*

---

## 3. First-Boot Hardware Polish Verification (`m2air`)

Record all outputs verbatim into `docs/logs/g6-<YYYY-MM-DD>.md`:

- [ ] **Dual-Boot Picker & Startup Disk:** Hold power button -> both `Macintosh HD` and `omarchnix` boot cleanly; `sudo asahi-bless --list-volumes` enumerates both volumes from Linux.
- [ ] **LUKS2 Initrd Unlock & Mounts:** Unlock `cryptroot` (`UUID=aa0403dd-9917-49e1-85b1-46b21b39f2d9`) at boot; verify `findmnt / /boot` shows `/dev/mapper/cryptroot` (`ext4`) on `/` and `/dev/nvme0n1p4` (`vfat`, `UUID=C650-1003`) on `/boot` (no `/mnt/shared`).
- [ ] **Display, HiDPI (1.6x) & Notch Geometry:**
  - `hyprctl monitors -j` shows `eDP-1` at the DCP-advertised mode (`2560x1600@60Hz` on Linux Asahi 7.2.15, which reports only that mode on `J413`), scale `1.60` (`1600x1000` logical), `xwayland.force_zero_scaling = true`. The Hyprland rule uses `mode = "preferred"` on purpose: pinning `2560x1664@60` does not exist in the DRM mode list and breaks the atomic commit.
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

---

## 4. Stage-2 Opt-In: Aurora SEP, Touch ID & FIDO2 (`m2air-aurora`)

Only after ordinary `m2air` NixOS boot, LUKS unlock, Wi-Fi, audio, and `s2idle` are verified above, switch to `m2air-aurora` and atomically stage the checked Aurora Stage 2 (`aura` `1.0.0b8` + `linux-aurora` `7.3.0` DTBs + `uboot-aurora`, preserving `/boot/m1n1/boot.bin.pre-aurora`):

```console
sudo nixos-rebuild boot --flake github:Th0rgal/omarchnix#m2air-aurora
sudo /nix/var/nix/profiles/system/sw/bin/omarchnix-install-stage2 /boot
sudo reboot
```

- [ ] **Secure Enclave, Touch ID & FIDO2 Passkeys (`modules/aurora-sep.nix`):**
  - Wait ~45s after boot for initial SEP keybag bring-up, then run `omarchnix-touchid-status` (verifies `linux-aurora` `7.3.0`, `/dev/disk/by-partlabel/iBootSystemContainer`, `/dev/sep-bio`, `aurora-sep-ready.service`, `fprintd.service`, and `aurora-fido.service`).
  - Enroll fingerprint: `sudo fprintd-enroll thomas` and test `fprintd-verify`.
  - Verify Touch ID prompts on `sudo -k true`, Polkit GUI dialogs, `omarchy-system-lock`, and `hyprlock` (`SUPER + ESCAPE`), plus WebAuthn passkeys in Brave/Firefox (`aurora-fido status`).
  - *(Rollback note: if ever needed from macOS or live USB, copying `/boot/m1n1/boot.bin.pre-aurora` back to `/boot/m1n1/boot.bin` and selecting the previous NixOS generation restores the stock `alx.sh` Stage 2 + `m2air` boot chain).*

---

## 5. Ongoing Firmware & GPT Maintenance (DR-5 / DR-18)

1. Boot macOS after Apple point updates and install macOS Software Update.
2. In macOS Terminal, run `curl https://alx.sh | sh` and select **Rebuild vendor firmware package** so `/boot/vendorfw/firmware.cpio` stays synchronized with system firmware.
3. **Deferred GPT Entry Sorting (`p6` physically before `p5`):** Inserting the Linux partition in free space between `nvme0n1p4` (Asahi ESP) and `nvme0n1p5` (`RecoveryOSContainer` at the end of the disk) leaves GPT table entries out of physical sector order (`p6` physically precedes `p5`), which some Apple `diskutil` / macOS upgrade checks dislike. Do **not** sort GPT entries during initial `nixos-install`. Handle GPT sorting (`gdisk /dev/nvme0n1` -> `s` -> `w`) as a separate maintenance step later only after a verified full backup; because `modules/filesystems-m2air.nix` mounts strictly by LUKS/FAT UUID (`aa0403dd-9917-49e1-85b1-46b21b39f2d9` and `C650-1003`), partition renumbering (`p5` <-> `p6`) requires zero NixOS configuration changes.
