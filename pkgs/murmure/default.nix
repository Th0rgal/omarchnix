{
  lib,
  stdenv,
  runCommand,
  python3,
  python3Packages,
  gtk3,
  gobject-introspection,
  wrapGAppsHook3,
  makeWrapper,
  pipewire,
  wl-clipboard,
  xdg-utils,
  systemd,
  crispasr-cohere,
  buildPlugin ? null,
}:
let
  pyPlain = python3;
  pyGtk = python3.withPackages (ps: [ ps.pygobject3 ]);

  runtimePath = lib.makeBinPath [
    pipewire
    wl-clipboard
    xdg-utils
    systemd
  ];

  murmurePkg = stdenv.mkDerivation {
    pname = "murmure";
    version = "0.2.0";

    src = lib.cleanSourceWith {
      src = ./.;
      filter = path: _type: baseNameOf path != "default.nix";
    };

    nativeBuildInputs = [
      wrapGAppsHook3
      makeWrapper
      gobject-introspection
    ];

    buildInputs = [
      gtk3
    ];

    dontWrapGApps = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/libexec/murmure/voiced" "$out/libexec/murmure/app" \
               "$out/bin" "$out/share/applications" "$out/share/icons/hicolor/scalable/apps"

      cp -r voiced/. "$out/libexec/murmure/voiced/"
      cp -r app/. "$out/libexec/murmure/app/"

      substituteInPlace "$out/libexec/murmure/voiced/worker.py" \
        --replace-fail "@CRISPASR_LIB@" "${crispasr-cohere}/lib/libcohere_asr.so"

      chmod 0755 \
        "$out/libexec/murmure/voiced/worker.py" \
        "$out/libexec/murmure/voiced/voiced.py" \
        "$out/libexec/murmure/voiced/orb_voice_bridge.py" \
        "$out/libexec/murmure/voiced/learn.py" \
        "$out/libexec/murmure/app/murmured.py" \
        "$out/libexec/murmure/app/murmure_cli.py" \
        "$out/libexec/murmure/app/murmure_settings.py"

      makeWrapper "${pyPlain}/bin/python3" "$out/bin/voiced" \
        --add-flags "$out/libexec/murmure/voiced/voiced.py" \
        --set-default VOICED_COHERE_LIB "${crispasr-cohere}/lib/libcohere_asr.so"

      makeWrapper "${pyPlain}/bin/python3" "$out/bin/orb-voice-bridge" \
        --add-flags "$out/libexec/murmure/voiced/orb_voice_bridge.py" \
        --set-default VOICED_COHERE_LIB "${crispasr-cohere}/lib/libcohere_asr.so"

      makeWrapper "${pyPlain}/bin/python3" "$out/bin/murmured" \
        --add-flags "$out/libexec/murmure/app/murmured.py" \
        --prefix PATH : "/run/current-system/sw/bin:${runtimePath}" \
        --set MURMURE_CLI_BIN "$out/bin/murmure" \
        --set MURMURE_SETTINGS_BIN "$out/bin/murmure-settings" \
        --set-default VOICED_COHERE_LIB "${crispasr-cohere}/lib/libcohere_asr.so"

      makeWrapper "${pyPlain}/bin/python3" "$out/bin/murmure" \
        --add-flags "$out/libexec/murmure/app/murmure_cli.py" \
        --prefix PATH : "/run/current-system/sw/bin:${runtimePath}" \
        --set MURMURE_CLI_BIN "$out/bin/murmure" \
        --set MURMURE_SETTINGS_BIN "$out/bin/murmure-settings" \
        --set-default VOICED_COHERE_LIB "${crispasr-cohere}/lib/libcohere_asr.so"

      cat > "$out/share/icons/hicolor/scalable/apps/murmure.svg" <<'SVG'
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
        <rect x="4" y="4" width="56" height="56" rx="14" fill="#161616" stroke="#3d3d3d" stroke-width="2"/>
        <g fill="#ffffff">
          <rect x="15" y="26" width="4" height="12" rx="2"/>
          <rect x="23" y="19" width="4" height="26" rx="2"/>
          <rect x="31" y="13" width="4" height="38" rx="2"/>
          <rect x="39" y="21" width="4" height="22" rx="2"/>
          <rect x="47" y="27" width="4" height="10" rx="2"/>
        </g>
      </svg>
      SVG

      cat > "$out/share/applications/murmure.desktop" <<EOF
      [Desktop Entry]
      Name=Murmure
      Comment=Private, on-device voice dictation
      Exec=$out/bin/murmure-settings
      Icon=murmure
      Terminal=false
      Type=Application
      Categories=Utility;AudioVideo;
      StartupWMClass=murmure-settings
      EOF

      runHook postInstall
    '';

    postFixup = ''
      makeWrapper "${pyGtk}/bin/python3" "$out/bin/murmure-settings" \
        "''${gappsWrapperArgs[@]}" \
        --prefix GI_TYPELIB_PATH : "$GI_TYPELIB_PATH" \
        --add-flags "$out/libexec/murmure/app/murmure_settings.py" \
        --prefix PATH : "/run/current-system/sw/bin:${runtimePath}" \
        --set MURMURE_CLI_BIN "$out/bin/murmure" \
        --set-default VOICED_COHERE_LIB "${crispasr-cohere}/lib/libcohere_asr.so"
    '';

    passthru = {
      inherit crispasr-cohere;
      pluginSrc = runCommand "murmure-plugin-src" { } ''
        mkdir -p "$out"
        cp -r --no-preserve=mode,ownership "${./plugin}/." "$out/"
        substituteInPlace "$out/Murmure.qml" "$out/BarWidget.qml" \
          --replace-fail "@MURMURE_BIN@" "${murmurePkg}/bin/murmure"
      '';
      plugin =
        if buildPlugin != null then
          buildPlugin {
            src = ./plugin;
            postInstall = ''
              substituteInPlace "$out/Murmure.qml" "$out/BarWidget.qml" \
                --replace-fail "@MURMURE_BIN@" "${murmurePkg}/bin/murmure"
            '';
          }
        else
          null;
    };

    meta = {
      description = "Private, on-device Wayland dictation backed by shared Cohere Transcribe (`voiced`)";
      homepage = "https://github.com/Th0rgal/murmure";
      license = lib.licenses.mit;
      mainProgram = "murmure";
      platforms = lib.platforms.linux;
    };
  };
in
murmurePkg
