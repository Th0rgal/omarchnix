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
