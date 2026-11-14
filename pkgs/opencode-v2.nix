# OpenCode v2 CLI built from the upstream flake sources on aarch64-linux (nixpkgs lags
# behind there), with auto-update disabled and ripgrep on PATH. Other systems use
# nixpkgs' `opencode`.
{
  lib,
  stdenv,
  callPackage,
  fetchFromGitHub,
  opencode,
  ripgrep,
  wayland,
}:
if stdenv.hostPlatform.system == "aarch64-linux" then
  let
    opencodeVersion = "2.2.7";
    opencodeSrc = fetchFromGitHub {
      owner = "anomalyco";
      repo = "opencode";
      tag = "v${opencodeVersion}";
      hash = "sha256-JPCR867ZoMbYNrCvAa3OnilsxVcktD3mHCGpR6o/nlw=";
    };
    opencodeNodeModules = callPackage "${opencodeSrc}/nix/node_modules.nix" {
      rev = "v${opencodeVersion}";
      hash = "sha256-L0rDvr0j/+R8bSErWXO1xTPac5rVamUny4clIThzSUk=";
    };
  in
  (callPackage "${opencodeSrc}/nix/opencode.nix" {
    node_modules = opencodeNodeModules;
  }).overrideAttrs
    {
      version = opencodeVersion;
      __intentionallyOverridingVersion = true;
      installPhase = ''
        runHook preInstall

        install -Dm755 dist/cli-*/bin/opencode "$out/bin/opencode"

        wrapProgram "$out/bin/opencode" \
          --set OPENCODE_DISABLE_AUTOUPDATE true \
          --suffix PATH : ${lib.makeBinPath [ ripgrep ]} \
          --prefix LD_LIBRARY_PATH : ${
            lib.makeLibraryPath [
              stdenv.cc.cc
              wayland
            ]
          }

        ln -s opencode "$out/bin/opencode2"

        runHook postInstall
      '';
    }
else
  opencode
