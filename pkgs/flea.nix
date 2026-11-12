{
  lib,
  rustPlatform,
  fetchurl,
  pkg-config,
  makeWrapper,
  patchelf,
  omarchySrc ? null,
  python3,
  expect,
  bash,
  coreutils,
  diffutils,
  util-linux,
  bubblewrap,
  bat,
  jq,
  ripgrep,
  wl-clipboard,
  xdg-utils,
  xdg-terminal-exec,
  shared-mime-info,
  morewaita-icon-theme,
  adwaita-icon-theme,
  hicolor-icon-theme,
  fontconfig,
  freetype,
  glib,
  cairo,
  gdk-pixbuf,
  libheif,
  wayland,
  libxkbcommon,
  libxcb,
  libX11,
  libglvnd,
  vulkan-loader,
  poppler,
  poppler-utils,
  mpv-unwrapped,
  ffmpeg,
  ffmpegthumbnailer,
  _7zz,
  libarchive,
  imagemagick,
  quickjs-ng,
  gvfs,
  udisks2,
  zoxide,
  rclone,
  tailscale,
}:
let
  pythonWithGi = python3.withPackages (ps: [ ps.pygobject3 ]);
  giTypelibPath = lib.makeSearchPath "lib/girepository-1.0" [ glib.out ];

  runtimeLibs = [
    vulkan-loader
    wayland
    libglvnd
    libxkbcommon
    libxcb
    libX11
    poppler
    cairo
    mpv-unwrapped
    ffmpegthumbnailer
    libheif
    gdk-pixbuf
    glib.out
    fontconfig.lib
    freetype
  ];

  runtimeBinPath = lib.makeBinPath [
    bash
    coreutils
    diffutils
    util-linux
    bubblewrap
    bat
    jq
    ripgrep
    wl-clipboard
    xdg-utils
    xdg-terminal-exec
    ffmpeg
    ffmpegthumbnailer
    _7zz
    libarchive
    imagemagick
    poppler-utils
    quickjs-ng
    glib
    udisks2
    zoxide
    rclone
    tailscale
  ];

  runtimeDataDirs = lib.makeSearchPath "share" [
    shared-mime-info
    morewaita-icon-theme
    adwaita-icon-theme
    hicolor-icon-theme
  ];
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "flea";
  version = "0.4.2";

  src = fetchurl {
    url = "https://github.com/thisisgm/flea/releases/download/v${finalAttrs.version}/flea-v${finalAttrs.version}.tar.gz";
    hash = "sha256-5Ouf8oMS+vtPkMbpsX5kL0hWwW/2lX4cEGtOcgmFuEM=";
  };

  cargoHash = "sha256-z64BjWipyFhkrgtown7VTg3G1pcs5NV4adCPXLMrR0Q=";

  cargoBuildFlags = [
    "--workspace"
    "--bins"
  ];

  # Parallelize LTO across all CPU cores (upstream Cargo.toml defaults to single-CGU fat LTO,
  # which takes ~10 minutes to link `flea` + `flea-gui` on M2 Air vs ~90s with thin LTO).
  env = {
    CARGO_PROFILE_RELEASE_LTO = "thin";
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
  };

  # Upstream PKGBUILD runs GUI/QML/namespace integration tests that require a live Wayland display and FHS.
  doCheck = false;

  nativeBuildInputs = [
    pkg-config
    makeWrapper
    patchelf
  ];

  buildInputs = [
    fontconfig
    freetype
    glib
    gdk-pixbuf
    libheif
    wayland
    libxkbcommon
    libxcb
    libX11
    libglvnd
    vulkan-loader
  ];

  postPatch = ''
    # 1. Allow bubblewrap sandboxes (`flea` backend + `flea-gui` media preview) to resolve `/nix/store`
    #    binaries, libraries, MIME data, and GPU drivers on NixOS.
    substituteInPlace src/backend/sandbox.rs \
      --replace-fail '"--ro-bind",' '"--ro-bind-try", "/nix", "/nix", "--ro-bind-try", "/run/current-system", "/run/current-system", "--ro-bind-try", "/run/opengl-driver", "/run/opengl-driver", "--ro-bind-try",'

    substituteInPlace crates/flea-gui/src/g2/media_preview/sandbox.rs \
      --replace-fail '"--ro-bind",' '"--ro-bind-try", "/nix", "/nix", "--ro-bind-try", "/run/current-system", "/run/current-system", "--ro-bind-try", "/run/opengl-driver", "/run/opengl-driver", "--ro-bind-try",'

    substituteInPlace src/backend/thumbbind.rs \
      --replace-fail 'const JAIL_ROOTS: [&str; 6] = ["/usr", "/etc", "/bin", "/sbin", "/lib", "/lib64"];' 'const JAIL_ROOTS: [&str; 8] = ["/nix", "/run/current-system", "/usr", "/etc", "/bin", "/sbin", "/lib", "/lib64"];' \
      --replace-fail 'const MOUNTED: [&str; 2] = ["/usr", "/etc"];' 'const MOUNTED: [&str; 4] = ["/nix", "/run/current-system", "/usr", "/etc"];'

    substituteInPlace src/backend/pluginpreview_sandbox.rs \
      --replace-fail '"--setenv", "PATH", "/usr/bin"' '"--setenv", "PATH", "${runtimeBinPath}:/run/current-system/sw/bin:/usr/bin"'

    # 2. Point MIME database lookups to Nixpkgs `shared-mime-info`.
    for f in src/backend/mime.rs src/backend/icons.rs src/backend/aliases.rs src/backend/kind.rs; do
      substituteInPlace "$f" \
        --replace-quiet "/usr/share/mime" "${shared-mime-info}/share/mime"
    done

    # 3. Allow syntax highlighting (`bat`), office previews (`soffice`), plugin PNG validation (`python3`),
    #    and Markdown figure rendering (`qjs`) to resolve executables inside `/nix/store`.
    substituteInPlace src/backend/codereq.rs \
      --replace-fail 'bat_under(path, Path::new("/usr"))' 'bat_under(path, Path::new("/nix/store")).or_else(|| bat_under(path, Path::new("/usr")))'

    substituteInPlace src/backend/officepdf.rs \
      --replace-fail 'real.starts_with("/usr")' '(real.starts_with("/nix/store") || real.starts_with("/usr"))'

    substituteInPlace src/backend/pluginpreview_png.rs \
      --replace-fail 'const PYTHON: &str = "/usr/bin/python3";' 'const PYTHON: &str = "${python3}/bin/python3";' \
      --replace-fail 'Path::new("/usr"),' 'Path::new("/nix"),'

    substituteInPlace src/figurehelper.rs \
      --replace-fail 'const SYSTEM_QJS: &str = "/usr/bin/qjs";' 'const SYSTEM_QJS: &str = "${quickjs-ng}/bin/qjs";' \
      --replace-fail 'path.starts_with("/usr/")' 'path.starts_with("/nix/store/") || path.starts_with("/usr/")'

    # 4. Include `/run/opengl-driver/share` in Vulkan ICD discovery so Asahi/Mesa/NVIDIA ICD manifests
    #    are visible even when launched from clean systemd/D-Bus environments, and allow non-conformant
    #    Vulkan drivers (such as Apple Silicon Asahi Mesa Borealis/Honeykrisp `conformanceVersion = 0.0.0.0`)
    #    in `gpui-pre-wgpu` instead of silently hiding the Vulkan adapter and falling back to OpenGL.
    substituteInPlace src/icdexclude.rs \
      --replace-fail '["/usr/local/share", "/usr/share"]' '["/run/opengl-driver/share", "/run/current-system/sw/share", "/usr/local/share", "/usr/share"]'

    for wgpu_file in \
      "$cargoDepsCopy"/source-git-*/gpui-pre-wgpu-*/src/wgpu_context.rs \
      "$cargoDepsCopy"/source-git-*/gpui-pre-wgpu-*/src/wgpu_atlas.rs
    do
      chmod u+w "$wgpu_file"
      substituteInPlace "$wgpu_file" \
        --replace-fail 'flags: wgpu::InstanceFlags::default(),' 'flags: wgpu::InstanceFlags::from_env_or_default() | wgpu::InstanceFlags::ALLOW_UNDERLYING_NONCOMPLIANT_ADAPTER,'
    done

    # 5. Substitute packaged FHS paths (`/usr/share/flea`, `/usr/lib/flea`, `/usr/share/omarchy`, tool paths).
    for f in \
      src/paths.rs \
      src/shelfplugin.rs \
      src/defaults.rs \
      src/i18n/mod.rs \
      src/gui/legacy_identity.rs \
      src/backend/flashhelper.rs \
      src/backend/pluginshelf.rs \
      crates/flea-gui/src/theme_gate.rs \
      crates/flea-gui/src/g2/media_preview/mpris.rs \
      crates/flea-gui/src/g2/network_shares/mount_process.rs \
      tools/flea-portal \
      tools/flea-filemanager1 \
      packaging/org.freedesktop.impl.portal.desktop.flea.service \
      packaging/com.thisisgm.flea.FileManager1.service
    do
      substituteInPlace "$f" \
        --replace-quiet "/usr/share/flea" "$out/share/flea" \
        --replace-quiet "/usr/lib/flea" "$out/lib/flea" \
        --replace-quiet "/usr/bin/flea" "$out/bin/flea" \
        ${lib.optionalString (
          omarchySrc != null
        ) ''--replace-quiet "/usr/share/omarchy" "${omarchySrc}"''}
    done

    substituteInPlace src/ui_logic_network_shares/bridge.rs \
      --replace-fail '"/usr/lib/gvfsd-fuse"' '"${gvfs}/libexec/gvfsd-fuse"'

    substituteInPlace src/backend/compare.rs \
      --replace-fail 'const DIFF: &str = "/usr/bin/diff";' 'const DIFF: &str = "${diffutils}/bin/diff";'

    substituteInPlace src/backend/appicon.rs \
      --replace-fail 'pub(crate) const TOOL: &str = "/usr/bin/7z";' 'pub(crate) const TOOL: &str = "${_7zz}/bin/7zz";' \
      --replace-fail '"/usr/bin/sh"' '"${bash}/bin/sh"'

    substituteInPlace src/tui/graphics.rs \
      --replace-fail 'pub const POSTER: &str = "/usr/bin/ffmpegthumbnailer";' 'pub const POSTER: &str = "${ffmpegthumbnailer}/bin/ffmpegthumbnailer";' \
      --replace-fail '"/usr/bin/magick"' '"${imagemagick}/bin/magick"'

    for f in src/tui/pdf.rs src/tui/convert/replies.rs src/tui/combine/source.rs src/tui/job.rs; do
      substituteInPlace "$f" \
        --replace-quiet "/usr/bin/pdftoppm" "${poppler-utils}/bin/pdftoppm" \
        --replace-quiet "/usr/bin/pdfinfo" "${poppler-utils}/bin/pdfinfo" \
        --replace-quiet "/usr/bin/magick" "${imagemagick}/bin/magick" \
        --replace-quiet "/usr/bin/bash" "${bash}/bin/bash"
    done
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 target/*/release/flea "$out/bin/flea"
    install -Dm755 target/*/release/flea-gui "$out/bin/flea-gui"

    install -Dm755 tools/flea-gio-auth "$out/lib/flea/flea-gio-auth"
    substituteInPlace "$out/lib/flea/flea-gio-auth" \
      --replace-fail "#!/usr/bin/expect -f" "#!${expect}/bin/expect -f" \
      --replace-fail "spawn -noecho gio mount" "spawn -noecho ${glib}/bin/gio mount"

    for helper in flea-udisks flea-portal flea-filemanager1 flea-mpris; do
      install -Dm755 "tools/$helper" "$out/lib/flea/.$helper-real"
      substituteInPlace "$out/lib/flea/.$helper-real" \
        --replace-fail "#!/usr/bin/python3" "#!${pythonWithGi}/bin/python3"
      makeWrapper "${pythonWithGi}/bin/python3" "$out/lib/flea/$helper" \
        --add-flags "$out/lib/flea/.$helper-real" \
        --prefix GI_TYPELIB_PATH : "${giTypelibPath}" \
        --prefix PATH : "$out/bin:${runtimeBinPath}:/run/current-system/sw/bin"
    done

    install -Dm644 packaging/flea.portal -t "$out/share/xdg-desktop-portal/portals"
    install -Dm644 packaging/org.freedesktop.impl.portal.desktop.flea.service -t "$out/share/dbus-1/services"
    install -Dm644 packaging/com.thisisgm.flea.FileManager1.service -t "$out/share/dbus-1/services"

    install -Dm644 packaging/com.thisisgm.flea.desktop "$out/share/applications/com.thisisgm.flea.desktop"
    substituteInPlace "$out/share/applications/com.thisisgm.flea.desktop" \
      --replace-fail "Exec=flea --gui %f" "Exec=$out/bin/flea --gui %f" \
      --replace-fail "Keywords=files;folder;manager;browser;flea;" "Keywords=file explorer;file manager;files;folders;finder;explorer;manager;browser;flea;directory;downloads;browse;"

    install -Dm644 packaging/com.thisisgm.flea.svg -t "$out/share/icons/hicolor/scalable/apps"
    install -Dm644 LICENSE THIRD-PARTY-LICENSES.txt -t "$out/share/licenses/flea"

    install -Dm644 ui/qmldir ui/*.qml ui/*.js -t "$out/share/flea/ui"
    install -Dm644 ui/js/*.js ui/js/*.mjs -t "$out/share/flea/ui/js"
    install -Dm644 ui/vendor/*.mjs -t "$out/share/flea/ui/vendor"
    install -Dm644 ui/vendor/LICENSES/* -t "$out/share/flea/ui/vendor/LICENSES"
    install -Dm644 ui/boot/shell.qml ui/boot/picker.qml ui/boot/fleatab.qml ui/boot/tabtearoff.qml -t "$out/share/flea/ui/boot"

    install -Dm644 shelf/manifest.json shelf/README.md shelf/*.qml shelf/*.js -t "$out/share/flea/shelf"
    sed -i 's/^  "version": "[^"]*",$/  "version": "${finalAttrs.version}-1",/' "$out/share/flea/shelf/manifest.json"

    for catalog in i18n/*/flea.json; do
      install -Dm644 "$catalog" "$out/share/flea/$catalog"
    done

    ${lib.optionalString (omarchySrc != null) ''
      ln -sfn "${omarchySrc}/shell/Commons" "$out/share/flea/ui/Commons"
      ln -sfn "${omarchySrc}/shell/Ui" "$out/share/flea/ui/Ui"
      ln -sfn "${omarchySrc}/shell/Commons" "$out/share/flea/ui/boot/Commons"
      ln -sfn "${omarchySrc}/shell/Ui" "$out/share/flea/ui/boot/Ui"
    ''}

    runHook postInstall
  '';

  # Bake dlopen runtime libraries directly into ELF DT_RUNPATH *after* `fixupPhase` (`shrinkRpath`)
  # so both normal GUI windows and `bwrap --clearenv --ro-bind <exe> /flea-media` sandboxes resolve
  # libvulkan, libwayland-client, libEGL, libxkbcommon, libmpv, libpoppler-glib, libffmpegthumbnailer,
  # and libheif without needing LD_LIBRARY_PATH.
  postFixup = ''
    rpath="${lib.makeLibraryPath runtimeLibs}:/run/opengl-driver/lib"
    for bin in "$out/bin/flea" "$out/bin/flea-gui"; do
      existing="$(patchelf --print-rpath "$bin")"
      patchelf --set-rpath "$existing:$rpath" "$bin"
      wrapProgram "$bin" \
        --prefix PATH : "$out/bin:${runtimeBinPath}" \
        --suffix PATH : "/run/current-system/sw/bin" \
        --prefix XDG_DATA_DIRS : "$out/share:${runtimeDataDirs}:/run/opengl-driver/share" \
        ${lib.optionalString (omarchySrc != null) ''--set-default OMARCHY_PATH "${omarchySrc}"''}
    done
  '';

  meta = {
    description = "Fast, keyboard-first GPUI/Vulkan file manager for Omarchy";
    homepage = "https://github.com/thisisgm/flea";
    license = with lib.licenses; [
      mit
      asl20
      bsd2
      bsd3
      cc0
      isc
      mpl20
      unicode-30
      zlib
    ];
    mainProgram = "flea";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
})
