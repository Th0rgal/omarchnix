# Signal Desktop on native Wayland without Electron's client-side titlebar or Linux
# menu bar, keeping fcitx5 dead-key IME and GNOME Keyring (libsecret) storage.
{
  signal-desktop,
  symlinkJoin,
  makeWrapper,
  writeText,
}:
let
  signalFramelessHook = writeText "signal-frameless-hook.cjs" ''
    const Module = require("node:module");
    const origLoad = Module._load;
    let WrappedBrowserWindow;

    Module._load = function (request, parent, isMain) {
      const loaded = origLoad.apply(this, arguments);
      if (request === "electron" && loaded && typeof loaded === "object") {
        return new Proxy(loaded, {
          get(target, prop) {
            if (prop === "BrowserWindow") {
              if (!WrappedBrowserWindow) {
                const OrigBrowserWindow = Reflect.get(target, prop, target);
                WrappedBrowserWindow = class FramelessBrowserWindow extends OrigBrowserWindow {
                  constructor(opts = {}) {
                    const nextOpts = { ...opts, frame: false, autoHideMenuBar: true };
                    delete nextOpts.titleBarStyle;
                    super(nextOpts);
                    super.setMenuBarVisibility(false);
                  }
                  setMenuBarVisibility(_visible) {
                    return super.setMenuBarVisibility(false);
                  }
                };
              }
              return WrappedBrowserWindow;
            }
            return Reflect.get(target, prop, target);
          },
        });
      }
      return loaded;
    };
  '';
in
symlinkJoin {
  name = "signal-desktop-${signal-desktop.version}";
  paths = [ signal-desktop ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    cp --remove-destination "$(readlink -f "$out/bin/signal-desktop")" "$out/bin/signal-desktop"
    chmod 755 "$out/bin/signal-desktop"
    substituteInPlace "$out/bin/signal-desktop" \
      --replace-fail "${signal-desktop}/share/signal-desktop/app.asar" \
      "-r ${signalFramelessHook} ${signal-desktop}/share/signal-desktop/app.asar"
    wrapProgram "$out/bin/signal-desktop" \
      --add-flags "--password-store=gnome-libsecret" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --disable-features=WaylandWindowDecorations --enable-wayland-ime=true --wayland-text-input-version=3}}"
    for desktop in "$out/share/applications/"*.desktop; do
      if [ -L "$desktop" ]; then
        cp --remove-destination "$(readlink -f "$desktop")" "$desktop"
        substituteInPlace "$desktop" --replace-quiet "Exec=signal-desktop" "Exec=$out/bin/signal-desktop"
      fi
    done
  '';
  inherit (signal-desktop) meta;
}
