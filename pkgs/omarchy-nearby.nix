{
  lib,
  pkgs,
  omarchyNearbySrc,
  buildPlugin ? null,
}:
let
  pluginVersion = "1.2.14";
  helperVersion = "1.2.9";

  scriptRuntimePath = lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.file
    pkgs.glib
    pkgs.imagemagick
    pkgs.jq
    pkgs.wl-clipboard
    pkgs.xdg-utils
  ];

  helper = pkgs.rustPlatform.buildRustPackage {
    pname = "omarchy-nearby-helper";
    version = helperVersion;
    src = omarchyNearbySrc;
    sourceRoot = "${omarchyNearbySrc.name or "source"}/backend";
    cargoLock.lockFile = "${omarchyNearbySrc}/backend/Cargo.lock";

    doCheck = false;

    passthru = {
      inherit plugin;
    };

    meta = {
      description = "LocalSend v2 LAN sharing helper and Omarchy bar plugin (omarchy-nearby)";
      homepage = "https://github.com/jfg96/omarchy-nearby";
      license = lib.licenses.mit;
      mainProgram = "omarchy-nearby-helper";
      platforms = lib.platforms.linux;
    };
  };

  patchPluginScript = ''
        rm -rf "$out/backend" "$out/.github" "$out/.gitignore" "$out/build.sh" "$out/packaging"

        # Materialize the Nix-built Rust helper as a regular file (zero symlinks!)
        # alongside `.nearby-local-helper` so `nearby-helper-launcher` runs offline
        # without fetching external GitHub release tarballs at runtime.
        cp --no-preserve=mode,ownership "${helper}/bin/omarchy-nearby-helper" "$out/bin/omarchy-nearby-helper"
        chmod 0755 "$out/bin/omarchy-nearby-helper"
        : > "$out/bin/.nearby-local-helper"
        chmod 0644 "$out/bin/.nearby-local-helper"

        for script in "$out/bin/nearby-"*; do
          chmod 0755 "$script"
          sed -i "1s|^#!/usr/bin/env bash$|#!${pkgs.bash}/bin/bash|" "$script"
          sed -i 's|^set -uo pipefail$|set -uo pipefail\nexport PATH="${scriptRuntimePath}:/run/current-system/sw/bin:''${PATH:-}"|' "$script"
          sed -i 's|^set -euo pipefail$|set -euo pipefail\nexport PATH="${scriptRuntimePath}:/run/current-system/sw/bin:''${PATH:-}"|' "$script"
        done

        # Make `--prefetch` succeed offline when the Nix-built local helper is present.
        substituteInPlace "$out/bin/nearby-helper-launcher" \
          --replace-fail 'if ! $prefetch \' 'if [[ -f $local_helper && ! -L $local_helper && -x $local_helper && -f $local_marker && ! -L $local_marker ]]; then
      if $prefetch; then
        "$local_helper" --version
        exit 0
      fi
      exec "$local_helper" "$@"
    fi
    if false \'
  '';

  plugin =
    if buildPlugin != null then
      buildPlugin {
        src = omarchyNearbySrc;
        postInstall = patchPluginScript;
      }
    else
      pkgs.runCommand "omarchy-nearby-plugin-${pluginVersion}" { } ''
        mkdir -p "$out"
        cp -r --no-preserve=mode,ownership "${omarchyNearbySrc}/." "$out/"
        chmod -R u+w "$out"
        rm -rf "$out/.git"
        ${patchPluginScript}
      '';
in
helper
