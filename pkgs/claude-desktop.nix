{
  lib,
  stdenvNoCC,
  fetchurl,
  buildFHSEnv,
  dpkg,
  python3,
  autoPatchelfHook,
  makeWrapper,
  adwaita-icon-theme,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  gcc-unwrapped,
  git,
  glib,
  gsettings-desktop-schemas,
  gtk3,
  libayatana-appindicator,
  libcap_ng,
  libdrm,
  libgbm,
  libglvnd,
  libnotify,
  libpulseaudio,
  libseccomp,
  libsecret,
  libX11,
  libxcb,
  libXcomposite,
  libXcursor,
  libXdamage,
  libXext,
  libXfixes,
  libxkbcommon,
  libXrandr,
  mesa,
  nodejs,
  nspr,
  nss,
  openssh,
  OVMF,
  pango,
  pipewire,
  procps,
  qemu_kvm,
  socat,
  systemdLibs,
  systemdMinimal,
  vulkan-loader,
  wayland,
  xdg-utils,
  withCoworkVm ? true,
  commandLineArgs ? [ ],
}:
let
  pname = "claude-desktop";
  version = "5.1231.2";

  fwPrefix = if stdenvNoCC.hostPlatform.isAarch64 then "AAVMF" else "OVMF";
  ovmfCode = "${OVMF.fd}/FV/${fwPrefix}_CODE.fd";
  ovmfVars = "${OVMF.fd}/FV/${fwPrefix}_VARS.fd";

  srcs = {
    x86_64-linux = fetchurl {
      url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${version}_amd64.deb";
      hash = "sha256-600Wya/wppY2bYhyj3T6VRNr58/ePB/jWvQGK0WVW28=";
    };
    aarch64-linux = fetchurl {
      url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${version}_arm64.deb";
      hash = "sha256-16AUTmlGl15sXzOkjbCMvgi8zaBL2xnPIlSqaQvOJcE=";
    };
  };

  meta = {
    description = "Anthropic's official Claude AI desktop application";
    homepage = "https://claude.ai/download";
    license = lib.licenses.unfree;
    mainProgram = "claude-desktop";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };

  unwrapped = stdenvNoCC.mkDerivation {
    inherit pname version meta;

    src =
      srcs.${stdenvNoCC.hostPlatform.system}
        or (throw "claude-desktop: unsupported system ${stdenvNoCC.hostPlatform.system}");

    nativeBuildInputs = [
      dpkg
      python3
      autoPatchelfHook
      makeWrapper
    ];

    buildInputs = [
      alsa-lib
      at-spi2-atk
      at-spi2-core
      atk
      cairo
      cups
      dbus
      expat
      gcc-unwrapped.lib
      glib
      gtk3
      libcap_ng
      libdrm
      libgbm
      libseccomp
      libsecret
      libX11
      libxcb
      libXcomposite
      libXcursor
      libXdamage
      libXext
      libXfixes
      libxkbcommon
      libXrandr
      nspr
      nss
      pango
      pipewire
      systemdLibs
    ];

    # Loaded via dlopen() at runtime by Electron, Chromium, and @ant/claude-native.
    runtimeDependencies = [
      libayatana-appindicator
      libglvnd
      libnotify
      libpulseaudio
      libsecret
      pipewire
      wayland
    ];

    strictDeps = true;

    unpackPhase = ''
      runHook preUnpack
      dpkg-deb --fsys-tarfile "$src" | tar -x --no-same-owner --no-same-permissions
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin" "$out/lib" "$out/share"
      cp -a usr/lib/claude-desktop "$out/lib/claude-desktop"
      cp -a usr/share/applications "$out/share/applications"
      cp -a usr/share/icons "$out/share/icons"
      cp -a usr/share/doc "$out/share/doc"

      # NixOS uses unprivileged user namespaces instead of a setuid chrome-sandbox.
      rm -f "$out/lib/claude-desktop/chrome-sandbox"

      # 1. Prevent Google OAuth deep-link callback eviction when `claude://` is
      #    handed off from the browser while the login page is at `/` or cold-starting.
      # 2. Read `~/.local/state/omarchy/current/theme/colors.toml` synchronously on
      #    Linux so dark/light startup chrome matches Omarchnix without flashing white.
      python3 - "$out/lib/claude-desktop/resources/app.asar" <<'PY'
      import hashlib, json, re, struct, sys

      asar_path = sys.argv[1]
      with open(asar_path, "rb") as f:
          magic, pickle1, pickle2, str_size = struct.unpack("<IIII", f.read(16))
          assert magic == 4, f"unexpected ASAR pickle header: {magic}"
          header = json.loads(f.read(str_size).decode("utf-8"))
          f.seek(8 + pickle1)
          payload = f.read()

      appended = bytearray()
      block_size = 4194304

      def update_asar_entry(meta, new_bytes):
          blocks = [
              hashlib.sha256(new_bytes[i : i + block_size]).hexdigest()
              for i in range(0, len(new_bytes), block_size)
          ]
          meta["offset"] = str(len(payload) + len(appended))
          meta["size"] = len(new_bytes)
          meta["integrity"] = {
              "algorithm": "SHA256",
              "hash": hashlib.sha256(new_bytes).hexdigest(),
              "blockSize": block_size,
              "blocks": blocks,
          }
          appended.extend(new_bytes)

      build_files = header["files"][".vite"]["files"]["build"]["files"]
      target_meta = None
      target_src = None
      for fn, meta in build_files.items():
          if not (fn.startswith("index.chunk-") and fn.endswith(".js")):
              continue
          off, sz = int(meta["offset"]), int(meta["size"])
          raw = payload[off : off + sz]
          if b"desktop_login_callback_evicted" in raw:
              target_meta = meta
              target_src = raw.decode("utf-8")
              break

      assert target_meta is not None and target_src is not None, "main chunk not found in app.asar"
      patched = target_src

      # Allow OAuth callback delivery when the main view is at `/` or cold-started.
      patched, n1 = re.subn(
          r'new Set\(\["/login","/gift/redeem"\]\)',
          'new Set(["/login","/gift/redeem","/",""])',
          patched,
          count=1,
      )
      assert n1 == 1, "expected OAuth allowed-paths Set in main chunk"

      patched, n2 = re.subn(
          r'!\(([A-Za-z0-9_$]+)!=null&&!([A-Za-z0-9_$]+)&&([A-Za-z0-9_$]+)\(\1\.getURL\(\)\)\)',
          r'!(\1!=null&&\3(\1.getURL()))',
          patched,
          count=1,
      )
      assert n2 == 1, "expected OAuth cold-start guard in main chunk"

      # Sync boot-placeholder window color with Omarchnix's active theme file before portal init.
      omarchy_dark_expr = (
          '(()=>{try{const fs=require("node:fs"),p=require("node:path"),'
          'h=process.env.HOME||"";if(h){const c=fs.readFileSync('
          'p.join(h,".local/state/omarchy/current/theme/colors.toml"),"utf8");'
          'const m=c.match(/^\\s*mode\\s*=\\s*["\x27]?(light|dark)["\x27]?/m);'
          'if(m)return m[1]!=="light"?"dark":"light"}}catch{}})()'
      )
      patched, n3 = re.subn(
          r'=(\(\)=>([A-Za-z0-9_$]+)\.nativeTheme\.shouldUseDarkColors\?"dark":"light")',
          lambda m: f"=()=>({omarchy_dark_expr}??({m.group(2)}.nativeTheme.shouldUseDarkColors?\"dark\":\"light\"))",
          patched,
          count=1,
      )
      assert n3 == 1, "expected bootPlaceholderColors dark/light helper in main chunk"

      update_asar_entry(target_meta, patched.encode("utf-8"))

      header_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8")
      new_str_size = len(header_bytes)
      aligned_size = ((new_str_size + 3) // 4) * 4
      new_pickle2 = 4 + aligned_size
      new_pickle1 = 4 + new_pickle2

      with open(asar_path + ".tmp", "wb") as out:
          out.write(struct.pack("<IIII", 4, new_pickle1, new_pickle2, new_str_size))
          out.write(header_bytes)
          out.write(b"\x00" * (aligned_size - new_str_size))
          out.write(payload)
          out.write(appended)
      import os
      os.replace(asar_path + ".tmp", asar_path)
      PY

      substituteInPlace "$out/share/applications/com.anthropic.Claude.desktop" \
        --replace-quiet "Exec=claude-desktop" "Exec=$out/bin/claude-desktop"

      makeWrapper "$out/lib/claude-desktop/claude-desktop" "$out/bin/claude-desktop" \
        --prefix LD_LIBRARY_PATH : "$out/lib/claude-desktop" \
        --prefix XDG_DATA_DIRS : "${adwaita-icon-theme}/share:${gsettings-desktop-schemas}/share:$out/share" \
        --suffix PATH : "${
          lib.makeBinPath [
            xdg-utils
            socat
          ]
        }" \
        --set DISABLE_AUTOUPDATER "1" \
        --set-default GTK_USE_PORTAL "1" \
        --set CHROME_DESKTOP "com.anthropic.Claude.desktop" \
        --add-flags "--password-store=gnome-libsecret" \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=GlobalShortcutsPortal,WaylandWindowDecorations --enable-wayland-ime=true --wayland-text-input-version=3}}" \
        --add-flags "\''${CLAUDE_USE_X11:+--ozone-platform=x11}" \
        ${lib.optionalString (
          commandLineArgs != [ ]
        ) "--add-flags ${lib.escapeShellArg (lib.escapeShellArgs commandLineArgs)}"}

      runHook postInstall
    '';
  };

  fhsEnv = buildFHSEnv {
    inherit pname version meta;

    targetPkgs =
      pkgs:
      [
        unwrapped
        pkgs.glibc
        pkgs.gcc-unwrapped.lib
        pkgs.libglvnd
        pkgs.mesa
        pkgs.libgbm
        pkgs.vulkan-loader
        pkgs.systemdMinimal
        pkgs.git
        pkgs.nodejs
        pkgs.openssh
        pkgs.procps
        pkgs.python3
        pkgs.socat
        pkgs.xdg-utils
      ]
      ++ lib.optionals withCoworkVm [
        pkgs.qemu_kvm
      ];

    extraBuildCommands = ''
      # Expose UEFI firmware & Anthropic's bundled virtiofsd at the exact paths
      # probed by Claude Desktop's Cowork VM helper (`cowork-linux-helper`).
      mkdir -p "$out/usr/share/${fwPrefix}" "$out/usr/libexec" "$out/usr/bin"
      ln -sf "${ovmfCode}" "$out/usr/share/${fwPrefix}/${fwPrefix}_CODE.fd"
      ln -sf "${ovmfCode}" "$out/usr/share/${fwPrefix}/${fwPrefix}_CODE_4M.fd"
      ln -sf "${ovmfVars}" "$out/usr/share/${fwPrefix}/${fwPrefix}_VARS.fd"
      ln -sf "${ovmfVars}" "$out/usr/share/${fwPrefix}/${fwPrefix}_VARS_4M.fd"
      ln -sf "${unwrapped}/lib/claude-desktop/resources/virtiofsd" "$out/usr/libexec/virtiofsd"

      ln -sf "${lib.getExe git}" "$out/usr/bin/git"
      ln -sf "${openssh}/bin/ssh" "$out/usr/bin/ssh"
      ln -sf "${procps}/bin/pgrep" "$out/usr/bin/pgrep"
    '';

    # Expose host `/etc` entries (gitconfig, ssh, xdg, ssl, hosts, ...) inside bwrap.
    extraPreBwrapCmds = ''
      host_etc_args() {
        local i
        for i in /etc/*; do
          case " /etc/ld.so.conf /etc/ld.so.cache ''${etc_ignored[*]} ''${symlinks[*]} " in
            *" $i "* | *" $i/"*) ;;
            *) echo --symlink "/.host-etc/''${i#/etc/}" "$i" ;;
          esac
        done
      }
    '';
    extraBwrapArgs = [ "$(host_etc_args)" ];

    extraInstallCommands = ''
      mkdir -p "$out/share"
      cp -r "${unwrapped}/share/"* "$out/share/"
      chmod -R u+w "$out/share"
      substituteInPlace "$out/share/applications/com.anthropic.Claude.desktop" \
        --replace-quiet "${unwrapped}/bin/claude-desktop" "$out/bin/claude-desktop"
    '';

    runScript = "${unwrapped}/bin/claude-desktop";
    dieWithParent = true;
  };
in
stdenvNoCC.mkDerivation {
  inherit pname version meta;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share"
    ln -s "${fhsEnv}/bin/${pname}" "$out/bin/${pname}"
    ln -s "${fhsEnv}/share/"* "$out/share/"
    runHook postInstall
  '';

  passthru = {
    inherit unwrapped fhsEnv;
  };
}
