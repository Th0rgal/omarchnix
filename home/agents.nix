{
  config,
  lib,
  pkgs,
  theme,
  ...
}:
let
  cfg = config.programs.omarchnix;

  skillFiles = {
    "SKILL.md" = ''
      ---
      name: omarchnix
      description: >
        Governed customization and verification skill for omarchnix — the declarative
        Omarchy-compatible NixOS & Home Manager workstation stack across aarch64-linux
        (Apple Silicon Asahi, NVIDIA Grace / DGX Spark) and x86_64-linux.
        Use when changing themes, Hyprland Lua config, omarchy-shell QML/plugins, coding
        agent skins, or NixOS / Home Manager modules.
      ---

      # `omarchnix` System Skill

      `omarchnix` combines upstream [Omarchy](https://omarchy.org) themes, `quickshell` + `omarchy-shell`, and the `plugins.omarchy.org` ecosystem with pure NixOS + Home Manager declarativity and defense-in-depth hardening.

      ## Topic Guides

      Read the relevant guide next to this file before making changes:

      - [`nixos-declarative.md`](nixos-declarative.md) — NixOS (`omarchnix.*`) & Home Manager (`programs.omarchnix.*`) options, host profiles (`asahi`, `spark`, `workstation`, `vm`), and safe `omarchnix check` validation before `nixos-rebuild`.
      - [`themes.md`](themes.md) — Declarative `lib.omarchy.importTheme` (all 23+ bundled palettes + custom `colors.toml` directories) and instant runtime switching via `omarchnix theme set <name>`.
      - [`shell-and-plugins.md`](shell-and-plugins.md) — `omarchy-shell` QML runtime, bar layout (`~/.config/omarchy/shell.json`), declarative `programs.omarchnix.plugins.locked` (`lib.omarchy.buildPlugin`), and runtime `plugins.omarchy.org` discovery/installation.

      ## Golden Rules for Agents

      1. **Never edit `/nix/store` or `$OMARCHY_PATH` directly.** Read `$OMARCHY_PATH` freely (`$OMARCHY_PATH/shell`, `$OMARCHY_PATH/themes`, `$OMARCHY_PATH/default/themed`) for reference.
      2. **Respect Asahi BootROM & ESP safety (DR-5 / DR-19).** Never enable `boot.loader.systemd-boot`, `boot.loader.efi.canTouchEfiVariables`, `boot.loader.grub.enableCryptodisk`, or `disko` on Apple Silicon hosts; `m2air` uses removable ARM64 UEFI GRUB (`device = "nodev"`, `efiInstallAsRemovable = true`, `configurationLimit = 2`, `extraFiles = lib.mkForce { }`) to preserve `m1n1/boot.bin`, `vendorfw`, and Apple partitions, while `rehearsal` keeps `boot.loader.*` disabled.
      3. **Validate before switching.** Run `omarchnix check` (and `nix fmt` + `nix flake check` when modifying a system flake) before running `sudo nixos-rebuild switch`.
      4. **Zero symlinks inside `~/.config/omarchy/plugins/<id>`.** Both `omarchy-plugin-validate` and `PluginRegistry.qml` reject symlinks inside plugin directories; use `lib.omarchy.buildPlugin` + `programs.omarchnix.plugins.locked` or `omarchnix plugin install <id> --yes`.
    '';

    "nixos-declarative.md" = ''
      # Declarative NixOS & Home Manager Configuration

      ## Reusable Flake Outputs

      - `nixosModules.omarchnix` (`nixosModules.default`): Cross-architecture NixOS module (`aarch64-linux` and `x86_64-linux`).
      - `homeManagerModules.omarchnix` (`homeManagerModules.default`): Home Manager desktop, theme, shell, plugin, and agent-ergonomics module.
      - `overlays.default`: Adds `pkgs.omarchnix.{omarchy-shell, cli, buildPlugin, importTheme, themes, ...}`.
      - `lib.omarchy`: Pure Nix theme importer (`importTheme`, `allBundledThemes`, `themeNames`) and plugin builder (`buildPlugin`, `validatePluginManifest`).

      ## Key Options

      ```nix
      omarchnix = {
        enable = true;
        profile = "workstation"; # "asahi" | "spark" | "workstation" | "vm"
        hardening.enable = true;
        containers.enable = true;
        desktop = {
          enable = true;
          user = "alice";
          theme = "tokyo-night";
          shellBackend = "omarchy-shell"; # or "waybar"
        };
      };
      ```

      ## Safe Rebuild Workflow

      ```bash
      omarchnix status --json
      omarchnix check --flake /path/to/flake --json
      nix fmt
      sudo nixos-rebuild test --flake /path/to/flake#<host>
      ```
    '';

    "themes.md" = ''
      # Themes & Live Switching

      `omarchnix` supports all 23+ bundled Omarchy themes (`catppuccin`, `catppuccin-latte`, `ethereal`, `everforest`, `flexoki-light`, `gruvbox`, `hackerman`, `jade-horse`, `kanagawa`, `last-horizon`, `lumon`, `lupine`, `matte-black`, `miasma`, `nord`, `retro-82`, `ristretto`, `rose-pine`, `solitude`, `starship`, `tokyo-night`, `vantablack`, `white`) plus custom `colors.toml` directories.

      ## Declarative Default Theme

      Set `omarchnix.desktop.theme = "catppuccin";` (NixOS) or `programs.omarchnix.theme.name = "catppuccin";` (Home Manager), or pass a custom directory via `lib.omarchy.importTheme { theme = ./my-theme; inherit pkgs; }`.

      ## Live Runtime Switching

      ```bash
      omarchnix theme list --json
      omarchnix theme current
      omarchnix theme palette gruvbox --json
      omarchnix theme set rose-pine
      omarchnix theme toggle
      ```

      Shortcuts: `SUPER + CTRL + T` / `CTRL + SUPER + SHIFT + T` opens the Omarchy theme picker; `SUPER + ALT + T` toggles dark/light mode (`omarchnix theme toggle`).

      `omarchnix theme set` renders `$OMARCHY_PATH/default/themed/*.tpl` into `~/.local/state/omarchy/current/theme/`, updates `omarchy-shell` over Unix-socket IPC, updates GNOME/GTK `color-scheme` via `gsettings` (`xdg-desktop-portal-gtk` `Settings` portal), retints running `foot` terminals via OSC sequences, reloads Hyprland borders, and updates `opencode` (`SIGUSR2`), `claude` (`~/.claude/themes/omarchy.json`), and `hermes` (`~/.hermes` skin).
    '';

    "shell-and-plugins.md" = ''
      # `omarchy-shell` Runtime & `plugins.omarchy.org` Loader

      ## Shell Runtime & IPC

      - Config file: `~/.config/omarchy/shell.json` (hot-reloaded by `omarchy-shell`; must remain a regular writable file with `"version": 1`).
      - Fast IPC (`~5 ms` via `socat`):
        - `omarchy-shell shell ping`
        - `omarchy-shell shell listPlugins`
        - `omarchy-shell shell rescanPlugins`
        - `omarchnix plugin enable <id> --section right`
        - `omarchnix plugin disable <id>`

      ## Declarative Nix-Locked Plugins

      ```nix
      programs.omarchnix.plugins.locked."dizziee.opencode-model-usage" = {
        package = inputs.omarchnix.lib.omarchy.buildPlugin {
          inherit pkgs;
          src = opencodeModelUsageSrc;
        };
        enable = true;
        section = "right";
      };
      ```

      `lib.omarchy.buildPlugin` enforces `schemaVersion == 1`, rejects reserved `omarchy.*` IDs, verifies relative entryPoints exist, and rejects symlinks at Nix build time. Home Manager copies locked plugins as real files into `~/.config/omarchy/plugins/<id>`.

      ## Runtime Marketplace Discovery (`plugins.omarchy.org`)

      ```bash
      omarchnix plugin registry --json
      omarchnix plugin registry opencode
      omarchnix plugin install dizziee.opencode-model-usage --enable --yes
      omarchnix plugin validate ~/.config/omarchy/plugins/<id>
      ```
    '';
  };

  mkSkillFilesFor =
    prefix:
    lib.mapAttrs' (fileName: text: {
      name = "${prefix}/${fileName}";
      value = {
        inherit text;
      };
    }) skillFiles;

  orbAgentSyncPkg =
    if pkgs ? orb-agent-sync then
      pkgs.orb-agent-sync
    else if (pkgs ? omarchnix) && (pkgs.omarchnix ? orb-agent-sync) then
      pkgs.omarchnix.orb-agent-sync
    else
      pkgs.callPackage ../pkgs/orb-agent-sync.nix { };

  mkAgentOverride = subcmd: {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      exec "${orbAgentSyncPkg}/bin/omarchy-orb-agent" ${subcmd} "$@"
    '';
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.agents.enable) {
    home.packages = lib.optionals cfg.agents.orbSync.enable [
      orbAgentSyncPkg
    ];

    home.file =
      (mkSkillFilesFor ".agents/skills/omarchnix")
      // lib.optionalAttrs (builtins.elem "claude" cfg.agents.targets) (
        mkSkillFilesFor ".claude/skills/omarchnix"
      )
      // lib.optionalAttrs (builtins.elem "codex" cfg.agents.targets) (
        mkSkillFilesFor ".codex/skills/omarchnix"
      )
      // lib.optionalAttrs (builtins.elem "hermes" cfg.agents.targets) (
        mkSkillFilesFor ".hermes/skills/omarchnix"
      )
      // lib.optionalAttrs (builtins.elem "opencode" cfg.agents.targets) (
        mkSkillFilesFor ".config/opencode/skills/omarchnix"
      );

    xdg.configFile = lib.mkMerge [
      (lib.mkIf (builtins.elem "opencode" cfg.agents.targets) {
        "opencode/opencode.json".text =
          builtins.toJSON {
            "$schema" = "https://opencode.ai/config.json";
            update = "disable";
          }
          + "\n";
        "opencode/cli.json".text =
          builtins.toJSON {
            "$schema" = "https://opencode.ai/v2/cli.json";
            theme = {
              name = "system";
            };
          }
          + "\n";
      })
      (lib.mkIf cfg.agents.orbSync.enable (
        {
          "omarchy/agent-overrides/omarchy-agent-usage-update" = mkAgentOverride "usage-update";
          "omarchy/agent-overrides/omarchy-agent-account-use" = mkAgentOverride "account-use";
          "omarchy/agent-overrides/omarchy-agent-account-mode" = mkAgentOverride "account-mode";
          "omarchy/agent-overrides/omarchy-agent-account-rename" = mkAgentOverride "account-rename";
          "omarchy/agent-overrides/omarchy-agent-account-add" = mkAgentOverride "account-add";
        }
        // lib.optionalAttrs cfg.agents.orbSync.launchInOrb {
          "omarchy/agent-overrides/omarchy-agent" = mkAgentOverride "launch";
          "omarchy/agent-overrides/omarchy-agent-prompt" = mkAgentOverride "prompt";
        }
      ))
    ];

    systemd.user.services.omarchy-orb-agent-sync = lib.mkIf cfg.agents.orbSync.enable {
      Unit = {
        Description = "Sync Omarchy agent usage bar with Orb Core";
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${orbAgentSyncPkg}/bin/omarchy-orb-agent usage-update";
      };
    };

    systemd.user.timers.omarchy-orb-agent-sync = lib.mkIf cfg.agents.orbSync.enable {
      Unit = {
        Description = "Periodic Orb Core usage sync for Omarchy agent bar";
      };
      Timer = {
        OnBootSec = "15s";
        OnUnitActiveSec = cfg.agents.orbSync.pollInterval;
        Persistent = false;
      };
      Install = {
        WantedBy = [ "timers.target" ];
      };
    };
  };
}
