# `omarchnix`

Declarative Omarchy-compatible NixOS & Home Manager workstation stack across **`aarch64-linux`** (Apple Silicon M-series via Asahi Linux, NVIDIA Grace / DGX Spark) and **`x86_64-linux`** workstations and VMs.

See [`docs/VISION.md`](docs/VISION.md) for the full architecture and [`docs/decisions.md`](docs/decisions.md) (`DR-1`..`DR-19`) for recorded design decisions.

---

## Reusable Flake Outputs

`omarchnix` is designed to be consumed as a reusable flake input by your own personal NixOS & Home Manager configuration repo (for example, see [`Th0rgal/nixos-config`](https://github.com/Th0rgal/nixos-config) for a full personal MacBook Air M2 + DGX Spark setup):

```nix
{
  inputs = {
    omarchnix.url = "github:Th0rgal/omarchnix";
    nixpkgs.follows = "omarchnix/nixpkgs";
    apple-silicon-support.follows = "omarchnix/apple-silicon-support";
    home-manager.follows = "omarchnix/home-manager";
  };

  outputs = { nixpkgs, apple-silicon-support, home-manager, omarchnix, ... }: {
    nixosConfigurations.my-m2air = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        apple-silicon-support.nixosModules.apple-silicon-support
        {
          nixpkgs.overlays = [
            apple-silicon-support.overlays.default
            omarchnix.overlays.default
          ];
        }
        omarchnix.nixosModules.omarchnix
        home-manager.nixosModules.home-manager
        {
          omarchnix = {
            enable = true;
            profile = "asahi"; # "asahi" | "spark" | "workstation" | "vm"
            desktop = {
              enable = true;
              user = "alice";
              theme = "tokyo-night"; # any of the 23+ Omarchy themes
              shellBackend = "omarchy-shell"; # "omarchy-shell" (Quickshell QML) or "waybar"
              autostartTty.enable = true;
            };
            hardware.m2air = {
              enable = true;
              bootloader.enable = true; # removable ARM64 UEFI GRUB on /boot
              fileSystems = {
                enable = true;
                luksUuid = "YOUR-LUKS2-UUID";
                espUuid = "YOUR-ESP-UUID";
              };
            };
          };
        }
      ];
    };
  };
}
```

### Omarchy Ecosystem Compatibility (`lib.omarchy`, `omarchy-shell`, `plugins.omarchy.org`)

- **23+ Themes & Live Switching:** `omarchnix.lib.omarchy.importTheme` imports all bundled Omarchy `colors.toml` palettes (or custom directories) at Nix evaluation time; `omarchnix theme set <name>` switches themes live across `omarchy-shell`, `foot`, Hyprland, `opencode`, `claude`, and `hermes`.
- **Quickshell QML Runtime & Plugins:** `pkgs.omarchnix.omarchy-shell` runs upstream `omarchy-shell` (`Qt 6.12` / `quickshell`) with NixOS FHS shims, while `programs.omarchnix.plugins.locked` + `omarchnix plugin install <id>` load validated `plugins.omarchy.org` plugins without symlinks.
- **Agent-First Ergonomics:** Automatically provisions the governed `omarchnix` system skill and live theme hooks for `opencode`, `claude`, `codex`, and `hermes`, backed by `omarchnix status` and `omarchnix check`.

### Reference `nixosConfigurations`

| Host | Architecture | Target | Purpose |
| --- | --- | --- | --- |
| `m2air` | `aarch64-linux` | MacBook Air M2 (Asahi) | Primary Apple Silicon daily driver on stock `nixos-apple-silicon` + `alx.sh` Stage 2 + removable ARM64 UEFI GRUB (`EFI/BOOT/BOOTAA64.EFI`, `configurationLimit = 2`, UUID-mounted ESP + LUKS2 `cryptroot`, `asahi-audio` DSP, 1.6x HiDPI, dual-boot macOS). |
| `m2air-aurora` | `aarch64-linux` | MacBook Air M2 (Aurora SEP) | Stage-2 opt-in `m2air` variant adding `aurora-silicon/nixos-aurora` Secure Enclave, Touch ID (`fprintd`), and FIDO2 (`aurora-fido`) after baseline boot validation (`docs/install-m2air.md` §4). |
| `spark` | `aarch64-linux` | NVIDIA Grace / DGX Spark | ARM64 UEFI server & workstation (`systemd-boot`, hardened + Hyprland desktop). |
| `workstation` | `x86_64-linux` | AMD / Intel desktop & cloud | Generic `x86_64-linux` UEFI workstation (`systemd-boot`, hardened + Hyprland desktop). |
| `rehearsal` | `aarch64-linux` | Scaleway Mac mini M2 Pro (`M2-L-ASAHI`) | Disposable BootROM dress rehearsal target with poweroff->reboot guard (`docs/runbook-scaleway.md`). |
| `vm` | `aarch64-linux` | Plain QEMU guest | Software iteration target without Apple hardware dependencies. |

Build the Asahi/NixOS installer ISO:

```console
$ nix build .#installer-bootstrap
```

### Adopting an existing machine

Home Manager activation never overwrites files you already have: the module sets
`home-manager.backupFileExtension = "hm-backup"`, so a hand-written
`~/.config/hypr/hyprland.lua` or `~/.zshrc` is renamed to `<file>.hm-backup`
instead of aborting activation.

### Deploying to another machine

`nix copy --to ssh-ng://host` requires the remote `nix.settings.trusted-users` to
contain your account (or a signature by a trusted key), which most hosts do not
allow. Use the bundled helper instead; it builds locally, transfers only the
missing store paths and switches the remote profile:

```console
$ scripts/remote-switch.sh m2air thomas@192.168.1.165
```

Known failure modes (crashed lock screen, repeated password prompts, clobbered
dotfiles, `gsettings` schema lookup) are collected in
[`docs/troubleshooting.md`](docs/troubleshooting.md).

---

## Status Matrix

Every cell is backed by a recorded gate (CI run or runbook log in `docs/logs/`). No cell is marked done without evidence.

| Gate | What proves it | Status |
| --- | --- | --- |
| G1 — flake evaluates | `nix eval` across all hosts + standalone module checks in CI | passed ([`g1-2026-11-06.md`](docs/logs/g1-2026-11-06.md)) |
| G2 — installer ISO builds | `nix build .#installer-bootstrap` in CI, artifact attached | passed ([`g2-2026-11-06.md`](docs/logs/g2-2026-11-06.md)) |
| G3 — VM boots shared config | QEMU boot log in `docs/logs/` | passed ([`g3-2026-11-06.md`](docs/logs/g3-2026-11-06.md)) |
| G4 — Asahi bootstrap on real BootROM | runbook log from the rehearsal box | `M2-L-ASAHI` cutover runbook + `rehearsal` power-guard ready; Orb Scaleway allowlist / `M2-M` `out_of_stock` logged ([`m5-m7-2026-11-06.md`](docs/logs/m5-m7-2026-11-06.md)) |
| G5 — NixOS install + rebuild on rehearsal | `nixos-rebuild switch` log on the mini | `M2-L-ASAHI` cutover runbook + `rehearsal` power-guard ready; Orb Scaleway allowlist / `M2-M` `out_of_stock` logged ([`m5-m7-2026-11-06.md`](docs/logs/m5-m7-2026-11-06.md)) |
| G6 — Air install, dual-boot macOS kept | runbook log from the Air | hardware polish + printed runbook ready ([`install-m2air.md`](docs/install-m2air.md), [`m5-m7-2026-11-06.md`](docs/logs/m5-m7-2026-11-06.md)) |
| G7 — security & container invariants | `checks.x86_64-linux.security` in CI + secret sweep | passed ([`g7-2026-11-06.md`](docs/logs/g7-2026-11-06.md)) |
| G8 — Hyprland desktop via Home Manager | `m2air` eval + `checks.x86_64-linux.desktop` screenshot in CI + `boat.dev` toplevel build | passed ([`g8-2026-11-06.md`](docs/logs/g8-2026-11-06.md), [`g3-2026-11-06.md`](docs/logs/g3-2026-11-06.md)) |

---

## Method

- **Runbooks, not memory.** Every operation on real hardware is written down in `docs/` before it is run, and produces a log in `docs/logs/`.
- **Gates with evidence.** A gate without a recorded artifact is not passed.
- **Pinned inputs.** `flake.lock` is committed; upgrades are deliberate commits, not surprises.
- **Rehearse before you cut.** Nothing reaches physical BootROM without rehearsal or explicit runbook verification.
- **One writer, no rebase.** Straight commits on `main`, or short-lived feature PRs merged cleanly. No force-push, no history rewriting.

## What Is Out of Scope on Apple Silicon

- Touch ID / Secure Enclave on the baseline `m2air` stock `nixos-apple-silicon` kernel (staged as `nixosConfigurations.m2air-aurora` via `aurora-silicon/nixos-aurora` + `omarchnix-install-stage2 /boot` once ordinary NixOS boot is verified on hardware; see `docs/install-m2air.md` §4 and `DR-17`)
- Metal (does not exist on Linux; Mesa Honeykrisp Vulkan 1.4 / OpenGL 4.6 is what Asahi ships)
- Apple's verified boot / SIP inside Linux (replaced by the Asahi `m1n1` + U-Boot boot chain + LUKS2 `cryptroot` + NixOS store reproducibility and AppArmor/container sandboxing)

## References

- [nix-community/nixos-apple-silicon](https://github.com/nix-community/nixos-apple-silicon) — Apple Silicon hardware module and installer bootstrap
- [Asahi Linux](https://asahilinux.org/) — kernel, `m1n1`, `asahi-audio`, Mesa Honeykrisp
- [Omarchy](https://omarchy.org/) — theme, shell, and plugin ecosystem compatible with `omarchnix`
