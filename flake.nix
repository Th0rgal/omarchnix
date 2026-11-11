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

    folio = {
      url = "github:Th0rgal/folio";
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

      omarchnixOverlay = import ./overlays/default.nix {
        inherit inputs omarchyLib;
      };

      omarchnixModule = import ./modules/omarchnix.nix;

      mkHost = import ./lib/mkHost.nix {
        inherit inputs omarchnixOverlay omarchnixModule;
      };

      mkInternalHost =
        args:
        mkHost (
          {
            includeOmarchnixModule = false;
            includeHomeManager = false;
            includeSops = false;
          }
          // args
        );
    in
    {
      lib = {
        omarchy = omarchyLib;
        inherit mkHost;
      };

      overlays = {
        omarchnix = omarchnixOverlay;
        default = omarchnixOverlay;
      };

      nixosModules = {
        omarchnix = omarchnixModule;
        default = self.nixosModules.omarchnix;
      };

      homeManagerModules = {
        omarchnix = import ./home;
        default = self.homeManagerModules.omarchnix;
      };

      nixosConfigurations = {
        m2air = mkInternalHost {
          platform = "m2air-asahi";
          modules = [
            ./hosts/common.nix
            ./hosts/m2air.nix
          ];
        };

        m2air-aurora = mkInternalHost {
          platform = "m2air-aurora";
          modules = [
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

        spark = mkInternalHost {
          platform = "spark";
          modules = [
            ./hosts/spark.nix
          ];
        };

        workstation = mkInternalHost {
          platform = "workstation";
          modules = [
            ./hosts/workstation.nix
          ];
        };

        rehearsal = mkInternalHost {
          platform = "m2air-asahi";
          modules = [
            ./hosts/common.nix
            ./hosts/rehearsal.nix
          ];
        };

        vm = mkInternalHost {
          platform = "vm";
          modules = [
            ./hosts/common.nix
            ./hosts/vm.nix
          ];
        };
      };

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
          crispasr-cohere = pkgs.crispasr-cohere;
          murmure = pkgs.murmure;
          omdrop = pkgs.omdrop;
          omarchy-quickshare = pkgs.omarchy-quickshare;
          omarchy-nearby = pkgs.omarchy-nearby;
          orb-agent-sync = pkgs.orb-agent-sync;
          turbo-lean = pkgs.turbo-lean;
          orb-desktop = pkgs.orb-desktop;
          folio-desktop = pkgs.folio-desktop;
          notion-calendar = pkgs.notion-calendar;
          michelangelus-font = pkgs.michelangelus-font;
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
            inherit self;
          };

          aurora-sep = import ./tests/aurora-sep.nix {
            inherit pkgs inputs self;
            inherit (nixpkgs) lib;
            m2airConfig = self.nixosConfigurations.m2air.config;
            m2airAuroraConfig = self.nixosConfigurations.m2air-aurora.config;
          };

          modules-eval =
            let
              standaloneNixos = mkHost {
                platform = if system == "aarch64-linux" then "spark" else "workstation";
                modules = [
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
                        macos = {
                          enable = true;
                          touchIdHud = true;
                          wallpapers = {
                            default = "/tmp/default.webp";
                            workspaces."1" = "/tmp/ws1.webp";
                          };
                        };
                      };
                      services.sharing = {
                        airdrop.enable = true;
                        quickshare.enable = true;
                        nearby.enable = true;
                        kdeconnect.enable = true;
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
              aliceHm = standaloneNixos.config.home-manager.users.alice;
            in
            assert standaloneNixos.config.programs.hyprland.enable == true;
            assert standaloneNixos.config.boot.loader.systemd-boot.enable == true;
            assert aliceHm.wayland.windowManager.hyprland.enable == true;
            assert aliceHm.programs.waybar.enable == false;
            assert aliceHm.systemd.user.services ? omarchy-shell;
            assert aliceHm.systemd.user.services ? omarchy-orb-agent-sync;
            assert aliceHm.systemd.user.services ? murmure;
            assert standaloneNixos.config.systemd.services ? awdl0;
            assert standaloneNixos.config.systemd.services ? omdrop-awdl-sleep;
            assert aliceHm.systemd.user.services ? omarchy-quickshare;
            assert aliceHm.systemd.user.services ? kdeconnect;
            assert aliceHm.programs.omarchnix.plugins.locked ? "omarchnix.sharing";
            assert aliceHm.programs.omarchnix.plugins.locked ? "th0rgal.murmure";
            assert aliceHm.programs.omarchnix.plugins.locked ? "io.github.joaovitor2763.mission-control";
            assert aliceHm.programs.omarchnix.plugins.locked ? "th0rgal.macos-dock";
            assert aliceHm.programs.omarchnix.plugins.locked ? "th0rgal.spotlight";
            assert aliceHm.programs.omarchnix.plugins.locked ? "th0rgal.touchid";
            assert aliceHm.programs.omarchnix.plugins.locked ? "th0rgal.workspaces";
            assert aliceHm.programs.omarchnix.plugins.locked ? "th0rgal.workspace-wallpapers";
            assert aliceHm.services.hyprpaper.enable == false;
            assert self.nixosConfigurations.spark.pkgs.stdenv.hostPlatform.system == "aarch64-linux";
            assert self.nixosConfigurations.workstation.pkgs.stdenv.hostPlatform.system == "x86_64-linux";
            pkgs.runCommand "omarchnix-modules-eval" { } ''
              echo "${builtins.unsafeDiscardStringContext standaloneNixos.config.system.build.toplevel.drvPath}" > "$out"
            '';
        }
      );

      formatter = forAllSystems (
        system:
        nixpkgs.legacyPackages.${system}.writeShellScriptBin "nix-fmt" ''
          exec ${nixpkgs.legacyPackages.${system}.nixfmt}/bin/nixfmt \
            $(git ls-files '*.nix' 2>/dev/null || find . -name '*.nix' -not -path './.git/*')
        ''
      );
    };
}
