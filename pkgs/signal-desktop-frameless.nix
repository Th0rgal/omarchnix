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
    const fs = require("node:fs");
    const os = require("node:os");
    const path = require("node:path");
    const Module = require("node:module");
    const origLoad = Module._load;
    let WrappedBrowserWindow;
    let themeSyncInstalled = false;

    function readOmarchyThemeMode() {
      const stateDir = path.join(os.homedir(), ".local", "state", "omarchy", "current");
      const colorsPath = path.join(stateDir, "theme", "colors.toml");
      try {
        const text = fs.readFileSync(colorsPath, "utf8");
        const modeMatch = text.match(/^\s*mode\s*=\s*["'](light|dark)["']/m);
        if (modeMatch) return modeMatch[1];
        const bgMatch = text.match(/^\s*background\s*=\s*["']#?([0-9a-fA-F]{6})["']/m);
        if (bgMatch) {
          const hex = bgMatch[1];
          const r = parseInt(hex.slice(0, 2), 16) / 255;
          const g = parseInt(hex.slice(2, 4), 16) / 255;
          const b = parseInt(hex.slice(4, 6), 16) / 255;
          const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
          return lum >= 0.5 ? "light" : "dark";
        }
      } catch (_) {}
      return null;
    }

    function installOmarchyThemeSync(nativeTheme) {
      if (themeSyncInstalled || !nativeTheme) return;
      themeSyncInstalled = true;
      let lastMode = null;

      const applyMode = () => {
        const mode = readOmarchyThemeMode();
        if (mode && (mode !== lastMode || nativeTheme.themeSource !== mode)) {
          lastMode = mode;
          try {
            nativeTheme.themeSource = mode;
          } catch (_) {}
        }
      };

      applyMode();

      const currentDir = path.join(os.homedir(), ".local", "state", "omarchy", "current");
      const themeDir = path.join(currentDir, "theme");
      for (const dir of [currentDir, themeDir]) {
        try {
          const w = fs.watch(dir, { persistent: false }, () => applyMode());
          w.on("error", () => {});
        } catch (_) {}
      }
      // Fallback poll handles atomic directory/symlink replacement when switching themes.
      const timer = setInterval(applyMode, 1500);
      if (typeof timer.unref === "function") timer.unref();
    }

    Module._load = function (request, parent, isMain) {
      const loaded = origLoad.apply(this, arguments);
      if (request === "electron" && loaded && typeof loaded === "object") {
        installOmarchyThemeSync(loaded.nativeTheme);
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
