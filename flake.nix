{
  description = "omarchnix — Declarative Omarchy-compatible NixOS & Home Manager workstation stack for Apple Silicon (Asahi), DGX Spark (aarch64-linux), and x86_64-linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-toolchains.url = "github:NixOS/nixpkgs/nixos-unstable";

    apple-silicon-support = {
      url = "github:nix-community/nixos-apple-silicon";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-aurora = {
      url = "github:aurora-silicon/nixos-aurora/4b025a0cfd35bede6bc87a50fcce6e2a95170f39";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    omarchy = {
      url = "github:omacom/omarchy/6194f4606c585da8b839b87df9120b7d796afedf";
      flake = false;
    };

    omarchy-plugin-marketplace = {
      url = "github:omacom/omarchy-plugin-marketplace/d2a854554c778b06911f6c878d9ea0d4522c4a14";
      flake = false;
    };

    omarchy-plugin-opencode-usage = {
      url = "github:JJDizz1L/dizziee.opencode-model-usage/95a0f856d704e12915888dca7ec093e5df3009d9";
      flake = false;
    };

    orb = {
      url = "github:Th0rgal/orb";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    turbo-lean = {
      url = "github:Th0rgal/turbo-lean/f240450af444a302a0e02d5a5f8af00351089386";
      flake = false;
    };

    omdrop-awdl = {
      url = "github:netmojo-systems/omdrop-awdl/09752e5f95aa11db041b7ca071b6d673254d0dfe";
      flake = false;
    };

    omdrop-plugin = {
      url = "github:netmojo-systems/omdrop-plugin/517afeba331188de6d199a47810b58836019363a";
      flake = false;
    };

    omarchy-quickshare = {
      url = "github:PuroDelphi/omarchy-quickshare/d124909620a37699f081e7415e8c6644ec22657c";
      flake = false;
    };

    omarchy-nearby = {
      url = "github:jfg96/omarchy-nearby/b26b5dc22a5c5f1d1c26edb80a7676c932f6afaa";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      apple-silicon-support,
      nixos-aurora,
      orb,
      ...
    }@inputs:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      omarchyLib = import ./lib/omarchy.nix {
        inherit (nixpkgs) lib;
        omarchySrc = inputs.omarchy;
      };

      omarchnixOverlay =
        final: prev:
        let
          omarchyShell = import ./pkgs/omarchy-shell.nix {
            inherit (final) lib;
            pkgs = final;
            omarchySrc = inputs.omarchy;
            marketplaceSrc = inputs.omarchy-plugin-marketplace;
          };
          cli = import ./pkgs/omarchnix-cli.nix {
            pkgs = final;
            inherit omarchyShell;
            marketplaceSrc = inputs.omarchy-plugin-marketplace;
          };
        in
        {
          omarchnix = {
            inherit cli;
            omarchy-shell = omarchyShell;
            omarchySrc = inputs.omarchy;
            marketplaceSrc = inputs.omarchy-plugin-marketplace;
            importTheme =
              arg:
              omarchyLib.importTheme (
                if builtins.isAttrs arg && !(arg ? outPath) then
                  { pkgs = final; } // arg
                else
                  {
                    theme = arg;
                    pkgs = final;
                  }
              );
            themes = omarchyLib.allBundledThemes final;
            buildTheme = args: omarchyLib.buildThemePkg ({ pkgs = final; } // args);
            buildPlugin = args: omarchyLib.buildPlugin ({ pkgs = final; } // args);
            michelangelus-font = final.michelangelus-font;
            omdrop = final.omdrop;
            omarchy-quickshare = final.omarchy-quickshare;
            omarchy-nearby = final.omarchy-nearby;
          };
          michelangelus-font = final.callPackage ./pkgs/michelangelus-font.nix { };
          turbo-lean = final.callPackage ./pkgs/turbo-lean.nix {
            turboLeanSrc = inputs.turbo-lean;
          };
          crispasr-cohere = final.callPackage ./pkgs/crispasr-cohere.nix { };
          murmure = final.callPackage ./pkgs/murmure {
            buildPlugin = final.omarchnix.buildPlugin;
          };
          omdrop = final.callPackage ./pkgs/omdrop.nix {
            omdropAwdlSrc = inputs.omdrop-awdl;
            omdropPluginSrc = inputs.omdrop-plugin;
            buildPlugin = final.omarchnix.buildPlugin;
            inherit omarchyShell;
          };
          omarchy-quickshare = final.callPackage ./pkgs/omarchy-quickshare.nix {
            omarchyQuickshareSrc = inputs.omarchy-quickshare;
            buildPlugin = final.omarchnix.buildPlugin;
            inherit omarchyShell;
          };
          omarchy-nearby = final.callPackage ./pkgs/omarchy-nearby.nix {
            omarchyNearbySrc = inputs.omarchy-nearby;
            buildPlugin = final.omarchnix.buildPlugin;
          };
          orb-desktop = final.callPackage ./pkgs/orb-desktop.nix {
            orbSrc = inputs.orb;
            sandboxed-sh = final.callPackage "${inputs.orb}/nix/package.nix" {
              inherit (final) turbo-lean;
            };
          };
          sandboxed-sh = final.orb-desktop.passthru.sandboxed-sh;
          notion-calendar = final.callPackage ./pkgs/notion-calendar.nix { };
          # Enable Wayland text-input-v3 IME (fcitx5 dead-key preedit & XCompose) in Antigravity,
          # matching NixOS's Brave and Bitwarden Electron wrappers without re-running autoPatchelf.
          antigravity-hub =
            if prev.stdenv.hostPlatform.isLinux && (prev ? antigravity-hub) then
              final.symlinkJoin {
                pname = prev.antigravity-hub.pname;
                version = prev.antigravity-hub.version;
                paths = [ prev.antigravity-hub ];
                nativeBuildInputs = [ final.makeShellWrapper ];
                postBuild = ''
                  rm "$out/bin/antigravity"
                  makeShellWrapper "${prev.antigravity-hub}/bin/antigravity" "$out/bin/antigravity" \
                    --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--enable-wayland-ime=true --wayland-text-input-version=3}}"
                '';
                inherit (prev.antigravity-hub) meta passthru;
              }
            else
              prev.antigravity-hub;
        }
        // prev.lib.optionalAttrs (prev ? aurora-sep) {
          # nixos-aurora already runs Aurora's SEP contract tests (test_interface.py,
          # test_lockout_reason.py) in postPatch; upstream libfprint's 131 simulated USB
          # umockdev tests (egis_etu905, aes2550, etc.) fail/timeout under parallel builds.
          libfprint = prev.libfprint.overrideAttrs {
            doInstallCheck = false;
          };
        };

      mkNixos =
        {
          system ? "aarch64-linux",
          withAsahiOverlay ? true,
          withAuroraOverlay ? false,
          modules,
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit inputs;
            modulesPath = nixpkgs + "/nixos/modules";
          };
          modules = modules ++ [
            {
              nixpkgs.overlays =
                nixpkgs.lib.optionals withAuroraOverlay [
                  nixos-aurora.inputs.apple-silicon.overlays.default
                  nixos-aurora.overlays.default
                ]
                ++ nixpkgs.lib.optionals (withAsahiOverlay && !withAuroraOverlay) [
                  apple-silicon-support.overlays.default
                ]
                ++ [
                  orb.overlays.default
                  omarchnixOverlay
                ];
              nix.registry.nixpkgs.flake = nixpkgs;
            }
          ];
        };
    in
    {
      lib = {
        omarchy = omarchyLib;
      };

      overlays = {
        omarchnix = omarchnixOverlay;
        default = omarchnixOverlay;
      };

      nixosModules = {
        omarchnix = import ./modules/omarchnix.nix;
        default = self.nixosModules.omarchnix;
      };

      homeManagerModules = {
        omarchnix = import ./home;
        default = self.homeManagerModules.omarchnix;
      };

      nixosConfigurations = {
        # Target machine: MacBook Air M2 (daily driver after cutover).
        # Initial cutover boots on stock nixos-apple-silicon + alx.sh Stage 2;
        # use m2air-aurora once ordinary NixOS boot is verified.
        m2air = mkNixos {
          modules = [
            apple-silicon-support.nixosModules.apple-silicon-support
            ./hosts/common.nix
            ./hosts/m2air.nix
          ];
        };

        # Stage-2 Aurora SEP / Touch ID / FIDO2 configuration for MacBook Air M2
        # (apply after validating ordinary m2air NixOS boot).
        m2air-aurora = mkNixos {
          withAuroraOverlay = true;
          modules = [
            nixos-aurora.inputs.apple-silicon.nixosModules.default
            ./hosts/common.nix
            ./hosts/m2air.nix
            {
              omarchnix.hardware.m2air.touchId = {
                enable = true;
                requirePasswordAfterBoot = true;
                fido.enable = true;
              };
            }
          ];
        };

        # ARM64 UEFI server/workstation: NVIDIA Grace / DGX Spark.
        spark = mkNixos {
          system = "aarch64-linux";
          withAsahiOverlay = false;
          modules = [
            ./hosts/spark.nix
          ];
        };

        # Generic x86_64-linux UEFI workstation/VM.
        workstation = mkNixos {
          system = "x86_64-linux";
          withAsahiOverlay = false;
          modules = [
            ./hosts/workstation.nix
          ];
        };

        # Rehearsal machine: rented Mac mini M2 (Scaleway). Same hardware
        # module, deliberately minimal — it exists to validate the boot
        # chain, install flow, and nixos-rebuild path on real BootROM
        # before touching the Air. No user data, no secrets.
        rehearsal = mkNixos {
          modules = [
            apple-silicon-support.nixosModules.apple-silicon-support
            ./hosts/common.nix
            ./hosts/rehearsal.nix
          ];
        };

        # Pure-software test target: plain aarch64 QEMU guest, no Asahi
        # bits. Used to iterate on hosts/common.nix and the installer
        # flow without hardware.
        vm = mkNixos {
          modules = [
            ./hosts/common.nix
            ./hosts/vm.nix
          ];
        };
      };

      # Asahi/NixOS installer ISO (via nixos-apple-silicon's
      # mkInstallerBootstrapCustom; built natively on ubuntu-24.04-arm in CI
      # using the nixos-apple-silicon binary cache) + Omarchy compatibility packages.
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              orb.overlays.default
              omarchnixOverlay
            ];
          };
        in
        rec {
          omarchy-shell = pkgs.omarchnix.omarchy-shell;
          omarchnix = pkgs.omarchnix.cli;
          turbo-lean = pkgs.turbo-lean;
          crispasr-cohere = pkgs.crispasr-cohere;
          murmure = pkgs.murmure;
          omdrop = pkgs.omdrop;
          omarchy-quickshare = pkgs.omarchy-quickshare;
          omarchy-nearby = pkgs.omarchy-nearby;
          orb-desktop = pkgs.orb-desktop;
          notion-calendar = pkgs.notion-calendar;
          plugin-opencode-model-usage = pkgs.omarchnix.buildPlugin {
            src = inputs.omarchy-plugin-opencode-usage;
          };
          installer-bootstrap = apple-silicon-support.lib.mkInstallerBootstrapCustom { inherit system; };
          default = installer-bootstrap;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              orb.overlays.default
              omarchnixOverlay
            ];
          };
        in
        {
          security = import ./tests/security.nix {
            inherit pkgs inputs;
            inherit (nixpkgs) lib;
            m2airConfig = self.nixosConfigurations.m2air.config;
            m2airAuroraConfig = self.nixosConfigurations.m2air-aurora.config;
            rehearsalConfig = self.nixosConfigurations.rehearsal.config;
          };

          desktop = import ./tests/desktop.nix {
            inherit pkgs inputs;
            inherit (nixpkgs) lib;
            m2airConfig = self.nixosConfigurations.m2air.config;
            rehearsalConfig = self.nixosConfigurations.rehearsal.config;
            vmConfig = self.nixosConfigurations.vm.config;
          };

          omarchy-compat = import ./tests/omarchy-compat.nix {
            inherit pkgs inputs omarchyLib;
            inherit (nixpkgs) lib;
            self = self;
          };

          aurora-sep = import ./tests/aurora-sep.nix {
            inherit pkgs inputs self;
            inherit (nixpkgs) lib;
            m2airConfig = self.nixosConfigurations.m2air.config;
            m2airAuroraConfig = self.nixosConfigurations.m2air-aurora.config;
          };

          modules-eval =
            let
              standaloneNixos = nixpkgs.lib.nixosSystem {
                inherit system;
                specialArgs = { inherit inputs; };
                modules = [
                  { nixpkgs.overlays = [ omarchnixOverlay ]; }
                  self.nixosModules.omarchnix
                  inputs.home-manager.nixosModules.home-manager
                  {
                    networking.hostName = "standalone-consumer";
                    omarchnix = {
                      enable = true;
                      profile = if system == "aarch64-linux" then "spark" else "workstation";
                      desktop = {
                        enable = true;
                        user = "alice";
                        theme = "catppuccin";
                        shellBackend = "omarchy-shell";
                        murmure.enable = true;
                      };
                      services.sharing = {
                        airdrop.enable = true;
                        quickshare.enable = true;
                        nearby.enable = true;
                      };
                    };
                    home-manager.users.alice = {
                      programs.omarchnix.plugins.locked."dizziee.opencode-model-usage" = {
                        package = pkgs.omarchnix.buildPlugin {
                          src = inputs.omarchy-plugin-opencode-usage;
                        };
                        enable = true;
                        section = "right";
                      };
                    };
                    fileSystems."/" = {
                      device = "/dev/vda1";
                      fsType = "ext4";
                    };
                    fileSystems."/boot" = {
                      device = "/dev/vda2";
                      fsType = "vfat";
                    };
                    users.users.alice = {
                      isNormalUser = true;
                      uid = 1000;
                      extraGroups = [ "wheel" ];
                    };
                  }
                ];
              };
            in
            assert standaloneNixos.config.programs.hyprland.enable == true;
            assert standaloneNixos.config.boot.loader.systemd-boot.enable == true;
            assert
              standaloneNixos.config.home-manager.users.alice.wayland.windowManager.hyprland.enable == true;
            assert standaloneNixos.config.home-manager.users.alice.programs.waybar.enable == false;
            assert standaloneNixos.config.home-manager.users.alice.systemd.user.services ? omarchy-shell;
            assert standaloneNixos.config.systemd.services ? awdl0;
            assert standaloneNixos.config.systemd.services ? omdrop-awdl-sleep;
            assert standaloneNixos.config.home-manager.users.alice.systemd.user.services ? omarchy-quickshare;
            assert standaloneNixos.config.home-manager.users.alice.systemd.user.services ? murmure;
            assert
              standaloneNixos.config.home-manager.users.alice.programs.omarchnix.plugins.locked
                ? "omarchnix.sharing";
            assert
              standaloneNixos.config.home-manager.users.alice.programs.omarchnix.plugins.locked
                ? "th0rgal.murmure";
            assert self.nixosConfigurations.spark.pkgs.stdenv.hostPlatform.system == "aarch64-linux";
            assert self.nixosConfigurations.workstation.pkgs.stdenv.hostPlatform.system == "x86_64-linux";
            pkgs.runCommand "omarchnix-modules-eval" { } ''
              echo "${builtins.unsafeDiscardStringContext standaloneNixos.config.system.build.toplevel.drvPath}" > "$out"
            '';
        }
      );

      # Wrapper: recent nixfmt chokes when 'nix fmt' invokes it with no
      # positional args, so collect the .nix files ourselves.
      formatter = forAllSystems (
        system:
        nixpkgs.legacyPackages.${system}.writeShellScriptBin "nix-fmt" ''
          exec ${nixpkgs.legacyPackages.${system}.nixfmt}/bin/nixfmt \
            $(git ls-files '*.nix' 2>/dev/null || find . -name '*.nix' -not -path './.git/*')
        ''
      );
    };
}
