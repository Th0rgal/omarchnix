{
  lib,
  stdenvNoCC,
  brave,
  makeWrapper,
}:
stdenvNoCC.mkDerivation {
  pname = "notion-calendar";
  version = "1.0.0";
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    mkdir -p \
      "$out/bin" \
      "$out/share/applications" \
      "$out/share/icons/hicolor/scalable/apps"

    cat > "$out/share/icons/hicolor/scalable/apps/notion-calendar.svg" <<'SVG'
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
      <rect x="16" y="16" width="224" height="224" rx="52" fill="#ffffff"/>
      <rect x="20" y="20" width="216" height="216" rx="48" fill="none" stroke="#e5e5e3" stroke-width="6"/>
      <rect x="52" y="48" width="152" height="160" rx="22" fill="#ffffff" stroke="#191919" stroke-width="14"/>
      <path d="M52 92h152" stroke="#191919" stroke-width="14"/>
      <path d="M92 34v28M164 34v28" stroke="#191919" stroke-width="14" stroke-linecap="round"/>
      <text x="128" y="176" text-anchor="middle" font-family="Inter, -apple-system, sans-serif" font-size="76" font-weight="800" fill="#191919">31</text>
    </svg>
    SVG

    makeWrapper ${brave}/bin/brave "$out/bin/notion-calendar" \
      --add-flags "--ozone-platform=wayland" \
      --add-flags "--enable-features=UseOzonePlatform,WaylandWindowDecorations,WebRTCPipeWireCapturer,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder" \
      --add-flags "--enable-wayland-ime=true --wayland-text-input-version=3" \
      --add-flags "--app=https://calendar.notion.so"

    cat > "$out/share/applications/notion-calendar.desktop" <<EOF
    [Desktop Entry]
    Name=Notion Calendar
    GenericName=Calendar
    Comment=Notion Calendar
    Exec=$out/bin/notion-calendar %U
    Icon=notion-calendar
    Terminal=false
    Type=Application
    Categories=Office;Calendar;
    StartupWMClass=brave-calendar.notion.so__-Default
    EOF
    runHook postInstall
  '';
  meta = {
    description = "Notion Calendar Wayland desktop app";
    mainProgram = "notion-calendar";
    platforms = lib.platforms.linux;
  };
}
