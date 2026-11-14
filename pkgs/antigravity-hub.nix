{
  lib,
  stdenv,
  symlinkJoin,
  makeShellWrapper,
  python3,
  antigravity-hub,
}:
# Enable Wayland text-input-v3 IME (fcitx5 dead-key preedit & XCompose), hide
# Electron's non-macOS WCO caption overlay (`titleBarOverlay`) on tiling Wayland/Hyprland,
# and read `~/.local/state/omarchy/current/theme/colors.toml` synchronously at startup
# so dark/light window chrome never flashes white before the async XDG portal responds.
if stdenv.hostPlatform.isLinux then
  symlinkJoin {
    inherit (antigravity-hub)
      pname
      version
      meta
      passthru
      ;
    paths = [ antigravity-hub ];
    nativeBuildInputs = [
      makeShellWrapper
      python3
    ];
    postBuild = ''
      rm -rf "$out/share/antigravity"
      mkdir -p "$out/share/antigravity/resources"
      for item in "${antigravity-hub}/share/antigravity"/*; do
        base="$(basename "$item")"
        case "$base" in
          antigravity)
            cp "$item" "$out/share/antigravity/antigravity"
            chmod 0555 "$out/share/antigravity/antigravity"
            ;;
          resources)
            for res in "$item"/*; do
              res_base="$(basename "$res")"
              if [ "$res_base" != "app.asar" ]; then
                ln -s "$res" "$out/share/antigravity/resources/$res_base"
              fi
            done
            ;;
          *)
            ln -s "$item" "$out/share/antigravity/$base"
            ;;
        esac
      done

      python3 - "${antigravity-hub}/share/antigravity/resources/app.asar" \
        "$out/share/antigravity/resources/app.asar" <<'PY'
      import hashlib, json, struct, sys

      src_path, dst_path = sys.argv[1], sys.argv[2]
      with open(src_path, "rb") as f:
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

      dist_files = header["files"]["dist"]["files"]
      utils_meta = dist_files["utils.js"]
      old_off = int(utils_meta["offset"])
      old_size = int(utils_meta["size"])
      utils_src = payload[old_off : old_off + old_size].decode("utf-8")

      needle_overlay = "titleBarOverlay: isMacOS()"
      assert needle_overlay in utils_src, "expected titleBarOverlay: isMacOS() in dist/utils.js"
      patched_utils = utils_src.replace(
          needle_overlay,
          "titleBarOverlay: (isMacOS() || process.platform === 'linux')",
          1,
      )

      needle_get_theme = "function getThemeMode() {"
      assert needle_get_theme in patched_utils, "expected getThemeMode() in dist/utils.js"
      linux_dark_helper = """function shouldUseSystemDarkColors() {
          if (process.platform === 'linux') {
              try {
                  const home = process.env.HOME || electron_1.app.getPath('home');
                  const colorsToml = fs.readFileSync(path_1.default.join(home, '.local/state/omarchy/current/theme/colors.toml'), 'utf-8');
                  const m = colorsToml.match(/^\\s*mode\\s*=\\s*["']?(light|dark)["']?/m);
                  if (m) {
                      return m[1] !== 'light';
                  }
              }
              catch (_) {
              }
          }
          return electron_1.nativeTheme.shouldUseDarkColors;
      }
      function getThemeMode() {"""
      patched_utils = patched_utils.replace(needle_get_theme, linux_dark_helper, 1)

      needle_inherit = "return electron_1.nativeTheme.shouldUseDarkColors ? 'DARK' : 'LIGHT';"
      assert needle_inherit in patched_utils, "expected nativeTheme.shouldUseDarkColors in dist/utils.js"
      patched_utils = patched_utils.replace(
          needle_inherit,
          "return shouldUseSystemDarkColors() ? 'DARK' : 'LIGHT';",
          1,
      )

      needle_loading = "(0, loadingOverlay_1.attachLoadingOverlay)(win, foregroundColor, backgroundColor);"
      assert needle_loading in patched_utils, "expected attachLoadingOverlay in dist/utils.js"
      patched_utils = patched_utils.replace(
          needle_loading,
          needle_loading + """
          let lastLoadedUrl = url;
          win.webContents.on('did-navigate', (_e, navUrl) => {
              if (navUrl && navUrl.startsWith('https://127.0.0.1:')) {
                  lastLoadedUrl = navUrl;
              }
          });
          const lowerRendererOomScore = () => {
              if (process.platform !== 'linux' || win.isDestroyed()) {
                  return;
              }
              try {
                  const osPid = win.webContents.getOSProcessId();
                  if (osPid > 0) {
                      fs.writeFileSync('/proc/' + osPid + '/oom_score_adj', '100\\n');
                  }
              }
              catch (_) {
              }
          };
          win.webContents.on('did-finish-load', lowerRendererOomScore);
          let lastRendererRecoveryMs = 0;
          win.webContents.on('render-process-gone', (_event, details) => {
              const reason = details && details.reason;
              if (!reason || reason === 'clean-exit' || win.isDestroyed()) {
                  return;
              }
              const now = Date.now();
              const delayMs = now - lastRendererRecoveryMs < 5000 ? 1500 : 250;
              lastRendererRecoveryMs = now;
              console.warn('[OOM-Guard] Renderer process gone (' + reason + ', exitCode=' + details.exitCode + '); reloading ' + lastLoadedUrl + ' in ' + delayMs + 'ms');
              setTimeout(() => {
                  if (!win.isDestroyed()) {
                      void win.loadURL(lastLoadedUrl);
                  }
              }, delayMs);
          });
          const syncWindowBackground = () => {
              if (win.isDestroyed()) {
                  return;
              }
              const nextIsLight = getThemeMode().toUpperCase().includes('LIGHT');
              win.setBackgroundColor(nextIsLight ? '#FAFAFA' : '#131313');
          };
          electron_1.nativeTheme.on('updated', syncWindowBackground);
          win.on('closed', () => {
              electron_1.nativeTheme.removeListener('updated', syncWindowBackground);
          });""",
          1,
      )
      update_asar_entry(utils_meta, patched_utils.encode("utf-8"))

      main_meta = dist_files.get("main.js")
      assert main_meta is not None, "expected dist/main.js in app.asar"
      main_off = int(main_meta["offset"])
      main_size = int(main_meta["size"])
      main_src = payload[main_off : main_off + main_size].decode("utf-8")
      needle_main_lock = "const gotTheLock = electron_1.app.requestSingleInstanceLock();"
      assert needle_main_lock in main_src, "expected requestSingleInstanceLock in dist/main.js"
      patched_main = main_src.replace(
          needle_main_lock,
          """if (process.platform === 'linux') {
          try {
              require('fs').writeFileSync('/proc/self/oom_score_adj', '100\\n');
          }
          catch (_) {
          }
      }
      """ + needle_main_lock,
          1,
      )
      needle_gpu_oom = "electron_1.app\n    .whenReady()"
      assert needle_gpu_oom in patched_main, "expected app.whenReady() in dist/main.js"
      patched_main = patched_main.replace(
          needle_gpu_oom,
          """if (process.platform === 'linux') {
          electron_1.app.on('child-process-launched', (_event, details) => {
              if (details && details.pid > 0 && (details.type === 'GPU' || details.type === 'Utility')) {
                  try {
                      fs.writeFileSync('/proc/' + details.pid + '/oom_score_adj', '100\\n');
                  }
                  catch (_) {
                  }
              }
          });
      }
      """ + needle_gpu_oom,
          1,
      )
      update_asar_entry(main_meta, patched_main.encode("utf-8"))

      ls_meta = dist_files.get("languageServer.js")
      assert ls_meta is not None, "expected dist/languageServer.js in app.asar"
      ls_off = int(ls_meta["offset"])
      ls_size = int(ls_meta["size"])
      ls_src = payload[ls_off : ls_off + ls_size].decode("utf-8")
      needle_ls_spawn = "_lsStdinIsLiveness = !!wsl;"
      assert needle_ls_spawn in ls_src, "expected _lsStdinIsLiveness in dist/languageServer.js"
      patched_ls = ls_src.replace(
          needle_ls_spawn,
          """if (process.platform === 'linux' && _lsProcess && _lsProcess.pid) {
            try {
                fs.writeFileSync('/proc/' + _lsProcess.pid + '/oom_score_adj', '200\\n');
            }
            catch (_) {
            }
        }
        """ + needle_ls_spawn,
          1,
      )
      update_asar_entry(ls_meta, patched_ls.encode("utf-8"))

      splash_meta = dist_files.get("provisionSplash.js")
      if splash_meta:
          sp_off = int(splash_meta["offset"])
          sp_size = int(splash_meta["size"])
          sp_src = payload[sp_off : sp_off + sp_size].decode("utf-8")
          sp_needle = "const dark = electron_1.nativeTheme.shouldUseDarkColors;"
          if sp_needle in sp_src:
              sp_patched = sp_src.replace(
                  sp_needle,
                  """const dark = (() => {
          if (process.platform === 'linux') {
              try {
                  const fs = require('fs');
                  const path = require('path');
                  const home = process.env.HOME || electron_1.app.getPath('home');
                  const colorsToml = fs.readFileSync(path.join(home, '.local/state/omarchy/current/theme/colors.toml'), 'utf-8');
                  const m = colorsToml.match(/^\\s*mode\\s*=\\s*["']?(light|dark)["']?/m);
                  if (m) return m[1] !== 'light';
              } catch (_) {}
          }
          return electron_1.nativeTheme.shouldUseDarkColors;
      })();""",
                  1,
              )
              update_asar_entry(splash_meta, sp_patched.encode("utf-8"))

      header_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8")
      new_str_size = len(header_bytes)
      aligned_size = ((new_str_size + 3) // 4) * 4
      new_pickle2 = 4 + aligned_size
      new_pickle1 = 4 + new_pickle2

      with open(dst_path, "wb") as out:
          out.write(struct.pack("<IIII", 4, new_pickle1, new_pickle2, new_str_size))
          out.write(header_bytes)
          out.write(b"\x00" * (aligned_size - new_str_size))
          out.write(payload)
          out.write(appended)
      PY

      rm "$out/bin/antigravity"
      cp "${antigravity-hub}/bin/antigravity" "$out/bin/.antigravity-orig"
      chmod 0755 "$out/bin/.antigravity-orig"
      substituteInPlace "$out/bin/.antigravity-orig" \
        --replace-fail "${antigravity-hub}" "$out"
      makeShellWrapper "$out/bin/.antigravity-orig" "$out/bin/antigravity" \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--enable-wayland-ime=true --wayland-text-input-version=3}}"
    '';
  }
else
  antigravity-hub
