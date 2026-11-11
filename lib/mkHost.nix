{
  inputs,
  omarchnixOverlay,
  omarchnixModule,
}:
{
  platform ? "workstation",
  system ? (if platform == "workstation" then "x86_64-linux" else "aarch64-linux"),
  extraSpecialArgs ? { },
  includeOmarchnixModule ? true,
  includeHomeManager ? true,
  includeSops ? true,
  modules ? [ ],
}:
let
  inherit (inputs)
    nixpkgs
    apple-silicon-support
    nixos-aurora
    home-manager
    sops-nix
    orb
    ;
  inherit (nixpkgs) lib;

  withAuroraOverlay = platform == "m2air-aurora";
  withAsahiOverlay = platform == "m2air-asahi";

  mergedInputs = inputs // (extraSpecialArgs.inputs or { });
  mergedSpecialArgs = {
    modulesPath = nixpkgs + "/nixos/modules";
  }
  // extraSpecialArgs
  // {
    inputs = mergedInputs;
  };
in
lib.nixosSystem {
  inherit system;
  specialArgs = mergedSpecialArgs;
  modules = [
    {
      nixpkgs.overlays =
        lib.optionals withAuroraOverlay [
          nixos-aurora.inputs.apple-silicon.overlays.default
          nixos-aurora.overlays.default
        ]
        ++ lib.optionals withAsahiOverlay [
          apple-silicon-support.overlays.default
        ]
        ++ [
          orb.overlays.default
          omarchnixOverlay
        ];
      nix.registry.nixpkgs.flake = nixpkgs;
    }
  ]
  ++ lib.optional withAuroraOverlay nixos-aurora.inputs.apple-silicon.nixosModules.default
  ++ lib.optional withAsahiOverlay apple-silicon-support.nixosModules.apple-silicon-support
  ++ lib.optional includeOmarchnixModule omarchnixModule
  ++ lib.optional includeHomeManager home-manager.nixosModules.home-manager
  ++ lib.optional includeSops sops-nix.nixosModules.sops
  ++ modules;
}
