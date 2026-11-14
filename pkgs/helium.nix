{
  lib,
  stdenvNoCC,
  fetchurl,
  dpkg,
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
  dconf,
  expat,
  fontconfig,
  freetype,
  gcc-unwrapped,
  gdk-pixbuf,
  glib,
  gsettings-desktop-schemas,
  gtk3,
  gtk4,
  krb5,
  libdrm,
  libgbm,
  libglvnd,
  libnotify,
  libpulseaudio,
  librsvg,
  libsecret,
  libva,
  libX11,
  libxcb,
  libXcomposite,
  libXcursor,
  libXdamage,
  libXext,
  libXfixes,
  libXi,
  libxkbcommon,
  libXrandr,
  libXrender,
  libXScrnSaver,
  libxshmfence,
  libXtst,
  mesa,
  nspr,
  nss,
  pango,
  pciutils,
  pipewire,
  qt6,
  snappy,
  speechd-minimal,
  systemdLibs,
  util-linuxMinimal,
  vulkan-loader,
  wayland,
  widevineCdm ? null,
  xdg-utils,
  zlib,
  commandLineArgs ? [ ],
}:
let
  pname = "helium";
  version = "0.21.2.1";

  srcs = {
    aarch64-linux = fetchurl {
      url = "https://github.com/imputnet/helium-linux/releases/download/${version}/helium-bin_${version}-1_arm64.deb";
      hash = "sha256-YIKHq0dPl1tRHDj69MBiidwOfSxnOHKGosEVHkPNTr0=";
    };
    x86_64-linux = fetchurl {
      url = "https://github.com/imputnet/helium-linux/releases/download/${version}/helium-bin_${version}-1_amd64.deb";
      hash = "sha256-Q5YhKlIi257oO+dESKUJp+BOZNEI41llXUokGBZf6XU=";
    };
  };

  runtimeLibs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig.lib
    freetype
    gcc-unwrapped.lib
    gdk-pixbuf
    glib
    gtk3
    gtk4
    krb5.lib
    libdrm
    libgbm
    libglvnd
    libnotify
    libpulseaudio
    libsecret
    libva
    libX11
    libxcb
    libXcomposite
    libXcursor
    libXdamage
    libXext
    libXfixes
    libXi
    libxkbcommon
    libXrandr
    libXrender
    libXScrnSaver
    libxshmfence
    libXtst
    mesa
    nspr
    nss
    pango
    pciutils
    pipewire
    qt6.qtbase
    snappy
    speechd-minimal
    systemdLibs
    util-linuxMinimal
    vulkan-loader
    wayland
    zlib
  ];

  schemaDirs = lib.makeSearchPath "share" [
    adwaita-icon-theme
    gsettings-desktop-schemas
    gtk3
    gtk4
  ];

  widevineBootstrap =
    lib.optionalString (widevineCdm != null) ''
      wv_dir="${widevineCdm}/share/google/chrome/WidevineCdm"
      wv_ver="${widevineCdm.version or ""}"
      cfg_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/net.imput.helium"
      mkdir -p "$cfg_dir/WidevineCdm"
      hint_file="$cfg_dir/WidevineCdm/latest-component-updated-widevine-cdm"
      if [ -n "$wv_ver" ]; then
        desired_hint="{\"Path\":\"$wv_dir\",\"LastBundledVersion\":\"$wv_ver\"}"
      else
        desired_hint="{\"Path\":\"$wv_dir\"}"
      fi
      if [ ! -f "$hint_file" ] || [ "$(cat "$hint_file" 2>/dev/null || true)" != "$desired_hint" ]; then
        tmp_hint="$(mktemp "$hint_file.XXXXXX")"
        printf '%s\n' "$desired_hint" > "$tmp_hint"
        chmod 0600 "$tmp_hint"
        mv "$tmp_hint" "$hint_file"
      fi
    '';
in
stdenvNoCC.mkDerivation {
  inherit pname version;

  src =
    srcs.${stdenvNoCC.hostPlatform.system}
      or (throw "helium: unsupported system ${stdenvNoCC.hostPlatform.system}");

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = runtimeLibs;

  # Skip optional Qt5 theme shim (`libqt5_shim.so`); Qt6 (`libqt6_shim.so`) + GTK3/4 are wired.
  autoPatchelfIgnoreMissingDeps = [
    "libQt5Core.so.5"
    "libQt5Gui.so.5"
    "libQt5Widgets.so.5"
  ];

  strictDeps = true;
  dontWrapQtApps = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile "$src" | tar -x --no-same-owner --no-same-permissions
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/lib" "$out/share"
    cp -a opt/helium "$out/lib/helium"
    cp -a usr/share/applications "$out/share/applications"
    cp -a usr/share/icons "$out/share/icons"
    cp -a usr/share/metainfo "$out/share/metainfo"

    # Drop unused Qt5 shim and Debian AppArmor profile; NixOS uses unprivileged userns sandboxing.
    rm -f "$out/lib/helium/libqt5_shim.so" "$out/lib/helium/apparmor.cfg"

    substituteInPlace "$out/share/applications/helium.desktop" \
      --replace-quiet "Exec=helium" "Exec=$out/bin/helium"
    if ! grep -q '^StartupWMClass=' "$out/share/applications/helium.desktop"; then
      sed -i '/^Type=Application/a StartupWMClass=helium' "$out/share/applications/helium.desktop"
    fi

    makeWrapper "$out/lib/helium/helium" "$out/bin/helium" \
      --set CHROME_WRAPPER "$out/bin/helium" \
      --set CHROME_VERSION_EXTRA "nixos" \
      --set-default GTK_USE_PORTAL "1" \
      --prefix GIO_EXTRA_MODULES : "${dconf.lib}/lib/gio/modules" \
      --set-default GDK_PIXBUF_MODULE_FILE "${librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" \
      --prefix XDG_DATA_DIRS : "${schemaDirs}:$out/share" \
      --prefix LD_LIBRARY_PATH : "$out/lib/helium:${lib.makeLibraryPath runtimeLibs}:/run/opengl-driver/lib" \
      --suffix PATH : "${lib.makeBinPath [ xdg-utils ]}" \
      ${lib.optionalString (widevineCdm != null) "--run ${lib.escapeShellArg widevineBootstrap}"} \
      --add-flags "--password-store=gnome-libsecret" \
      --add-flags "--enable-zero-copy" \
      --add-flags "--enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder,TouchpadOverscrollHistoryNavigation,OverlayScrollbar" \
      --add-flags "--disable-features=OutdatedBuildDetector,UseChromeOSDirectVideoDecoder" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-wayland-ime=true --wayland-text-input-version=3}}" \
      ${lib.optionalString (
        commandLineArgs != [ ]
      ) "--add-flags ${lib.escapeShellArg (lib.escapeShellArgs commandLineArgs)}"}

    ln -s "$out/bin/helium" "$out/bin/helium-browser"

    runHook postInstall
  '';

  meta = {
    description = "Private, fast, minimalist Chromium-based web browser";
    homepage = "https://github.com/imputnet/helium-linux";
    license = lib.licenses.gpl3Only;
    mainProgram = "helium";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
