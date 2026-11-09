# `omarchnix` — Vision & Architecture

**`omarchnix`** combines two properties that rarely coexist in one Linux workstation operating system:

1. **Omarchy's instant aesthetic, QML shell, and keyboard-centric ergonomics** (`omacom/omarchy` themes, `quickshell` + `omarchy-shell` QML runtime, and `plugins.omarchy.org` ecosystem).
2. **Pure, rollback-safe NixOS + Home Manager declarativity and defense-in-depth hardening** across both **`aarch64-linux`** (Apple Silicon M-series via Asahi Linux, NVIDIA Grace / DGX Spark) and **`x86_64-linux`** workstations and cloud/QEMU VMs.

---

## 1. Cross-Architecture Hardware Targets

`omarchnix` exports reusable modules (`nixosModules.omarchnix`, `homeManagerModules.omarchnix`) and reference host configurations across architectures without duplicating desktop or security logic:

| Profile / Host | Architecture | Target Class | Boot & Hardware Model |
| --- | --- | --- | --- |
| `m2air` / `m2air-aurora` | `aarch64-linux` | Apple Silicon MacBook Air M2 (`J413`/`J415`) | Preserved `alx.sh` `m1n1` + U-Boot + `vendorfw` chain -> removable ARM64 UEFI GRUB (`EFI/BOOT/BOOTAA64.EFI`, `configurationLimit = 2`, DR-5 / DR-19), pure `fileSystems` + `initrd.luks` UUID mounts (`C650-1003` + `aa0403dd-9917-49e1-85b1-46b21b39f2d9`, no `disko` GPT management, DR-18), PipeWire `asahi-audio` DSP + `speakersafetyd`, 1.6x HiDPI + notch geometry, staged Aurora SEP/Touch ID (`m2air-aurora`) |
| `spark` | `aarch64-linux` | NVIDIA Grace / DGX Spark ARM64 server & workstation | UEFI `systemd-boot`, hardened headless or desktop profile |
| `workstation` | `x86_64-linux` | AMD / Intel Linux desktop & cloud workstation | UEFI `systemd-boot`, KVM + `nixos-container` sandboxing, full Hyprland + `omarchy-shell` desktop |
| `rehearsal` / `vm` | `aarch64-linux` | Scaleway `M2-L-ASAHI` Mac mini & QEMU guests | Disposable BootROM dress rehearsal with poweroff->reboot guard (DR-3 / DR-12) and CI/QEMU iteration |

---

## 2. The Omarchy Compatibility Contract (DR-8)

Instead of forking Omarchy's themes or rewriting its QML shell, `omarchnix` treats upstream `omacom/omarchy` as a declarative data and QML source:

- **`lib.omarchy.importTheme` & Live Switching:** Imports all 23+ bundled Omarchy `colors.toml` palettes (`tokyo-night`, `catppuccin`, `catppuccin-latte`, `ethereal`, `everforest`, `flexoki-light`, `gruvbox`, `hackerman`, `jade-horse`, `kanagawa`, `last-horizon`, `lumon`, `lupine`, `matte-black`, `miasma`, `nord`, `retro-82`, `ristretto`, `rose-pine`, `solitude`, `starship`, `vantablack`, `white`) or any custom `colors.toml` directory into a canonical Nix theme attrset, while staging `~/.local/state/omarchy/current/theme` so `omarchnix theme set <theme>` (`omarchy-theme-set`) switches themes live at runtime in milliseconds.
- **`quickshell` + `omarchy-shell` QML Runtime:** Runs stock `quickshell` (`Qt 6.12`) over Nix-packaged `omarchy-shell` (`qs.Commons`, `qs.Ui`, and 26+ first-party QML plugins) with NixOS FHS path shims (`python3`, `tzdata`, `omarchy.ttf` icon font, `socat` ~5 ms Unix-socket IPC, and `/usr/share/omarchy-platform/display-cutouts.json`).
- **Declarative + Runtime `plugins.omarchy.org` Loader:** Supports both Nix-locked plugins (`programs.omarchnix.plugins.locked`, enforcing `schemaVersion == 1`, non-`omarchy.*` IDs, relative entrypoints, and symlink-free trees inside Nix derivations and `~/.config/omarchy/plugins/<id>`) and user-installed plugins validated by `omarchnix plugin`.
- **Agent-First Ergonomics:** Ships pre-wired configuration and a shared `omarchnix` system skill for `opencode`, `claude`, `codex`, and `hermes`, instructing agents to validate module edits via `omarchnix check` (`nix fmt`, flake evaluation, and KVM VM checks) before running `nixos-rebuild`.

---

## 3. Defense-in-Depth Hardening & Sandboxing (DR-6 / DR-7 / DR-14)

Security invariants are enforced directly through declarative NixOS and Home Manager primitives rather than auxiliary build-receipt daemons:

- **Secrets Outside the Nix Store (DR-6):** `sops-nix` decrypts host secrets into `tmpfs` (`/run/secrets`) at activation using an owner-held `age` root key; zero plaintext secrets live in Git or `/nix/store`.
- **Kernel, Firewall & AppArmor (`modules/hardening.nix`):** Enforces strict sysctl hardening, default-drop nftables firewalling, `doas` without root SSH/passwords, and mandatory AppArmor confinement on browsers and exposed network clients.
- **Declarative Container & `bwrap` Isolation (`modules/containers.nix`, DR-7):** Isolates untrusted workloads inside networkless `nixos-container` (`systemd-nspawn`) sandboxes with explicit workspace bind-mounts and `devbox` (`bubblewrap`) wrappers.
- **Pure-Nix Plugin Validation (`lib.omarchy.buildPlugin`, DR-10):** Rejects symlinks, path traversal (`..` / absolute paths), and malformed `manifest.json` payloads at Nix evaluation and derivation build time.
