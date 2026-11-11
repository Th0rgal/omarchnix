{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
  cacert,
  coreutils,
  libnotify,
  xdg-utils,
}:
stdenvNoCC.mkDerivation {
  pname = "orb-agent-sync";
  version = "0.1.0";

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  buildPhase = ''
    runHook preBuild
    mkdir -p "$out/libexec" "$out/bin"
    cp ${./orb-agent-sync.py} "$out/libexec/omarchy-orb-agent.py"
    chmod +x "$out/libexec/omarchy-orb-agent.py"
    patchShebangs "$out/libexec/omarchy-orb-agent.py"

    makeWrapper "${python3}/bin/python3" "$out/bin/omarchy-orb-agent" \
      --add-flags "$out/libexec/omarchy-orb-agent.py" \
      --set-default SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt" \
      --set-default NIX_SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt" \
      --suffix PATH : "${
        lib.makeBinPath [
          coreutils
          libnotify
          xdg-utils
        ]
      }:/run/current-system/sw/bin"
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    HOME="$TMPDIR/home" mkdir -p "$TMPDIR/home"
    HOME="$TMPDIR/home" "$out/bin/omarchy-orb-agent" --self-test
    runHook postCheck
  '';

  dontInstall = true;

  meta = {
    description = "Bidirectional sync and control bridge between Omarchy's agents bar plugin and Orb Core / Orb Desktop";
    mainProgram = "omarchy-orb-agent";
    platforms = lib.platforms.linux;
  };
}
