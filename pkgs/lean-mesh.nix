{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  autoPatchelfHook,
  binutils,
  callPackage,
  clang,
  git,
  gnutar,
  lld,
  openssl,
  patchelf,
  python3,
  sqlite,
  zstd,
  orbSrc,
  turbo-lean ? null,
}:
let
  orbPackageJson = lib.importJSON "${orbSrc}/orb/package.json";
  coreLakeManifest = lib.importJSON "${orbSrc}/lean/OrbCore/lake-manifest.json";
  leanSysPkg = lib.findFirst (
    p: p.name == "«lean-sys»" || p.name == "lean-sys"
  ) (throw "lean-sys entry missing from lean/OrbCore/lake-manifest.json") coreLakeManifest.packages;

  leanVersion = "4.35.0";
  leanArchiveSpec =
    {
      x86_64-linux = {
        artifact = "lean-${leanVersion}-linux.tar.zst";
        sha256 = "7289597a44543246c9227b8cae501767e095ce17f6d448b95fc4a8dc97268f6d";
      };
      aarch64-linux = {
        artifact = "lean-${leanVersion}-linux_aarch64.tar.zst";
        sha256 = "c8f0f8a3920e839718b1343e6781fd80a3e9b1024fbcd7078eb30f54e806b028";
      };
    }
    .${stdenv.hostPlatform.system}
      or (throw "Unsupported system for Lean ${leanVersion}: ${stdenv.hostPlatform.system}");

  leanToolchain = stdenv.mkDerivation {
    pname = "lean4-bin";
    version = leanVersion;
    src = fetchurl {
      url = "https://github.com/leanprover/lean4/releases/download/v${leanVersion}/${leanArchiveSpec.artifact}";
      inherit (leanArchiveSpec) sha256;
    };
    nativeBuildInputs = [
      gnutar
      zstd
      autoPatchelfHook
    ];
    buildInputs = [ stdenv.cc.cc.lib ];
    dontConfigure = true;
    dontBuild = true;
    unpackPhase = ''
      runHook preUnpack
      mkdir -p "$out"
      tar --zstd -xf "$src" --strip-components=1 -C "$out"
      runHook postUnpack
    '';
    installPhase = ''
      runHook preInstall
      test -x "$out/bin/lean"
      test -x "$out/bin/lake"
      runHook postInstall
    '';
  };

  pinnedLeanSys = fetchFromGitHub {
    owner = "Th0rgal";
    repo = "lean-sys";
    inherit (leanSysPkg) rev;
    hash = "sha256-TKE6Zhx4mWHFkJJbZEOQLwPQomAAYU5L3fYAiDMGwi8=";
  };

  resolvedTurboLean =
    if turbo-lean != null then
      turbo-lean
    else
      callPackage "${orbSrc}/nix/turbo-lean.nix" { inherit leanToolchain; };

  filteredOrbSrc = lib.cleanSourceWith {
    src = orbSrc;
    filter =
      path: _type:
      let
        base = baseNameOf (toString path);
        rel = lib.removePrefix (toString orbSrc + "/") (toString path);
        topDir = builtins.head (lib.splitString "/" rel);
      in
      base != ".lake"
      && base != "target"
      && base != "node_modules"
      && base != ".git"
      && builtins.elem topDir [
        "lean"
        "scripts"
        "shared"
        "catalog"
      ];
  };
in
stdenv.mkDerivation {
  pname = "lean-mesh";
  inherit (orbPackageJson) version;
  src = filteredOrbSrc;

  nativeBuildInputs = [
    leanToolchain
    resolvedTurboLean
    clang
    lld
    binutils
    git
    python3
    zstd
    patchelf
    autoPatchelfHook
  ];

  buildInputs = [
    stdenv.cc.cc.lib
    openssl
    sqlite
  ];

  LD_LIBRARY_PATH = lib.makeLibraryPath [
    openssl
    sqlite
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export PATH="${clang}/bin:${lld}/bin:${binutils}/bin:${leanToolchain}/bin:$PATH"
    export LEAN_BIN_DIR="${leanToolchain}/bin"
    export CC="${clang}/bin/clang"
    export LEAN_CC="${clang}/bin/clang"
    export TURBO_LEAN_BIN="${leanToolchain}/bin/lean"
    export TURBO_LEAN_HOME="$TMPDIR/turbo-lean-state"
    export TURBO_LEAN_STATE_DIR="$TMPDIR/turbo-lean-state"
    export TURBO_LEAN_EMIT_C=1
    export TURBO_LEAN_NO_DAEMON=1
    export TURBO_LEAN_TELEMETRY=off
    export ORB_TURBO_LEAN_JOBS=1
    export ORB_TURBO_LEAN_MAX_MB=6144
    export CPATH="${
      lib.makeSearchPathOutput "dev" "include" [
        openssl
        sqlite
      ]
    }''${CPATH:+:$CPATH}"
    export LIBRARY_PATH="${
      lib.makeLibraryPath [
        openssl
        sqlite
      ]
    }''${LIBRARY_PATH:+:$LIBRARY_PATH}"

    if [ ! -d "lean/lean-sys" ]; then
      cp -R "${pinnedLeanSys}" lean/lean-sys
      chmod -R u+w lean/lean-sys
      python3 - <<'PY'
    import glob, json, pathlib, re

    lf = pathlib.Path("lean/OrbNetLeaf/lakefile.lean")
    lf.write_text(
        re.sub(
            r'require\s+«lean-sys»\s+from\s+git\s+"[^"]+"\s*@\s*"[^"]+"',
            'require «lean-sys» from "../lean-sys"',
            lf.read_text(),
        )
    )

    for path in glob.glob("lean/*/lake-manifest.json"):
        p = pathlib.Path(path)
        data = json.loads(p.read_text())
        new_pkgs = []
        for entry in data.get("packages", []):
            if entry.get("name") in ("«lean-sys»", "lean-sys"):
                new_pkgs.append({
                    "type": "path",
                    "scope": entry.get("scope", ""),
                    "name": entry["name"],
                    "manifestFile": entry.get("manifestFile", "lake-manifest.json"),
                    "inherited": entry.get("inherited", False),
                    "dir": "../lean-sys",
                    "copy": False,
                    "configFile": entry.get("configFile", "lakefile.lean"),
                })
            else:
                new_pkgs.append(entry)
        data["packages"] = new_pkgs
        p.write_text(json.dumps(data, indent=1) + "\n")
    PY
    fi

    patchShebangs scripts/build_orb_bins.sh
    mkdir -p "$TMPDIR/orb-bins"
    ./scripts/build_orb_bins.sh --only lean-mesh --out-dir "$TMPDIR/orb-bins"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    install -m 0755 "$TMPDIR/orb-bins/lean-mesh" "$out/bin/lean-mesh"
    patchelf --add-rpath "${
      lib.makeLibraryPath [
        openssl
        sqlite
      ]
    }" "$out/bin/lean-mesh"
    runHook postInstall
  '';

  meta = {
    description = "Lean 4 verified WireGuard & nftables mesh engine (lean-mesh)";
    mainProgram = "lean-mesh";
    platforms = lib.platforms.linux;
  };
}
