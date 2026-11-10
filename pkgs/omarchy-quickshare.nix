{
  lib,
  pkgs,
  omarchyQuickshareSrc,
  buildPlugin ? null,
  omarchyShell ? null,
}:
let
  version = "0.3.7";

  runtimePath = lib.makeBinPath (
    [
      pkgs.bluez
      pkgs.coreutils
      pkgs.iw
      pkgs.jq
      pkgs.networkmanager
    ]
    ++ lib.optional (omarchyShell != null) omarchyShell
  );

  backend = pkgs.rustPlatform.buildRustPackage {
    pname = "omarchy-quickshare";
    inherit version;
    src = omarchyQuickshareSrc;
    cargoLock.lockFile = "${omarchyQuickshareSrc}/Cargo.lock";

    nativeBuildInputs = [
      pkgs.makeWrapper
      pkgs.pkg-config
      pkgs.protobuf
    ];

    buildInputs = [
      pkgs.dbus
    ];

    # Avoid environment-dependent D-Bus/network tests in the Nix build sandbox.
    doCheck = false;

    postInstall = ''
      wrapProgram "$out/bin/omarchy-quickshare" \
        --prefix PATH : "${runtimePath}:/run/current-system/sw/bin"
    '';

    passthru = {
      inherit plugin;
    };

    meta = {
      description = "Android & Chromebook Quick Share daemon, CLI, and Omarchy bar plugin";
      homepage = "https://github.com/PuroDelphi/omarchy-quickshare";
      license = lib.licenses.gpl3Plus;
      mainProgram = "omarchy-quickshare";
      platforms = lib.platforms.linux;
    };
  };

  patchPluginScript = ''
    rm -rf "$out/src" "$out/vendor" "$out/target" "$out/scripts/tests" "$out/.github" "$out/.gitignore" \
           "$out/Cargo.toml" "$out/Cargo.lock" "$out/PKGBUILD"

    chmod 0755 "$out/scripts/"*.sh

    substituteInPlace "$out/scripts/service-common.sh" \
      --replace-fail 'SYSTEM_BINARY=/usr/bin/omarchy-quickshare' \
                     'SYSTEM_BINARY=${backend}/bin/omarchy-quickshare' \
      --replace-fail 'command -v pacman >/dev/null && pacman -Qq omarchy-quickshare >/dev/null 2>&1 || fail \' \
                     '[[ -x "$SYSTEM_BINARY" ]] || ( command -v pacman >/dev/null && pacman -Qq omarchy-quickshare >/dev/null 2>&1 ) || fail \'

    substituteInPlace "$out/Service.qml" \
      --replace-fail '/usr/bin/omarchy-quickshare' '${backend}/bin/omarchy-quickshare' \
      --replace-fail 'command: ["bash", "-c", "' \
                     'command: ["${pkgs.bash}/bin/bash", "-c", "export PATH=${
                       lib.makeBinPath [
                         pkgs.coreutils
                         pkgs.jq
                       ]
                     }:/run/current-system/sw/bin:$PATH; '

    for qml in "$out/BarWidget.qml" "$out/Panel.qml" "$out/TransferEffectsArt.qml"; do
      substituteInPlace "$qml" \
        --replace-fail 'import qs.Commons' $'import qs.Commons\nimport qs.Commons as Commons' \
        --replace-fail 'Color.' 'Commons.Color.'
    done

    if [ -f "$out/nautilus/omarchy_quickshare.py" ]; then
      substituteInPlace "$out/nautilus/omarchy_quickshare.py" \
        --replace-fail '/usr/bin/omarchy-quickshare' '${backend}/bin/omarchy-quickshare'
    fi

    if [ -f "$out/packaging/system-binary.conf" ]; then
      substituteInPlace "$out/packaging/system-binary.conf" \
        --replace-fail '/usr/bin/omarchy-quickshare' '${backend}/bin/omarchy-quickshare'
    fi
  '';

  plugin =
    if buildPlugin != null then
      buildPlugin {
        src = omarchyQuickshareSrc;
        postInstall = patchPluginScript;
      }
    else
      pkgs.runCommand "omarchy-quickshare-plugin-${version}" { } ''
        mkdir -p "$out"
        cp -r --no-preserve=mode,ownership "${omarchyQuickshareSrc}/." "$out/"
        chmod -R u+w "$out"
        rm -rf "$out/.git"
        ${patchPluginScript}
      '';
in
backend
