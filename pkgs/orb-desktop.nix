{
  lib,
  stdenv,
  nodejs,
  pnpm,
  pnpmConfigHook,
  fetchPnpmDeps,
  python3,
  pkg-config,
  gtk4,
  webkitgtk_6_0,
  wrapGAppsHook4,
  makeWrapper,
  git,
  openssh,
  openssl,
  libnotify,
  xdg-utils,
  cacert,
  clang,
  gst_all_1,
  pipewire,
  murmure,
  sandboxed-sh,
  orbSrc,
  autoPatchelfHook,
  glibc,
}:
let
  version = "0.13.0";

  # Upstream `orb` (`nix/package.nix`) stages `lean-sys` offline and compiles
  # all Lean 4 modules once via `turbo-lean` + `clang`/`lld`; add `autoPatchelfHook`
  # + `glibc` so linked ELF binaries carry the Nixpkgs dynamic loader. Linux GGUF
  # Speech-to-Text now ships upstream in `Rpc.lean`.
  sandboxedShOffline = sandboxed-sh.overrideAttrs (old: {
    nativeBuildInputs =
      (old.nativeBuildInputs or [ ])
      ++ [ python3 ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        autoPatchelfHook
      ];
    buildInputs =
      (old.buildInputs or [ ])
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        glibc
      ];
  });

  pnpmDeps = fetchPnpmDeps {
    pname = "orb-desktop";
    inherit version;
    src = "${orbSrc}/orb";
    fetcherVersion = 5;
    hash = "sha256-Dd/+Hxbe0bef8hp/37aIfpVgqYuf0XXPspotz8rW5fw=";
  };

  orb-ui = stdenv.mkDerivation {
    pname = "orb-ui";
    inherit version pnpmDeps;
    src = "${orbSrc}/orb";

    nativeBuildInputs = [
      nodejs
      pnpm
      pnpmConfigHook
      python3
    ];

    postPatch = ''
      python3 - <<'PY'
      import pathlib

      theme_ts = pathlib.Path("src/theme.ts")
      theme_txt = theme_ts.read_text()
      if "dataset.platform" not in theme_txt:
          helper = (
              'function detectPlatform(): string {\n'
              '  const ua = typeof navigator === "undefined" ? "" : navigator.userAgent || "";\n'
              '  const raw = typeof navigator === "undefined" ? "" : navigator.platform || ua;\n'
              '  if (/mac|iphone|ipad|ipod/i.test(raw)) return "macos";\n'
              '  if (/linux/i.test(raw) && !/android/i.test(ua)) return "linux";\n'
              '  return "other";\n'
              '}\n\n'
              'function apply(pref: ThemePref) {\n'
              '  if (!document.documentElement.dataset.platform) {\n'
              '    document.documentElement.dataset.platform = detectPlatform();\n'
              '  }'
          )
          assert "function apply(pref: ThemePref) {" in theme_txt
          theme_ts.write_text(theme_txt.replace("function apply(pref: ThemePref) {", helper, 1))

      styles_css = pathlib.Path("src/styles.css")
      css_txt = styles_css.read_text()
      if 'data-platform="linux"' not in css_txt:
          css_txt = css_txt.replace(
              ".settings-view .sidebar { background: var(--bg-sidebar); }\n",
              "",
          ).replace(
              "linear-gradient(90deg, var(--bg-code), var(--bg-active), var(--bg-code))",
              "linear-gradient(90deg, var(--bg-code), var(--hover-1), var(--bg-code))",
          )
          css_txt += (
              '\n:root[data-platform="linux"] {\n'
              '  --sidebar-opacity: 78%;\n'
              '  --surface-opacity: 92%;\n'
              '  --bg-hover: color-mix(in srgb, var(--fg) 4.5%, transparent);\n'
              '  --bg-active: color-mix(in srgb, var(--fg) 7.5%, transparent);\n'
              '}\n'
              ':root[data-platform="linux"][data-theme="light"] {\n'
              '  --sidebar-opacity: 72%;\n'
              '  --surface-opacity: 94%;\n'
              '  --bg-hover: color-mix(in srgb, var(--fg) 4%, transparent);\n'
              '  --bg-active: color-mix(in srgb, var(--fg) 6.5%, transparent);\n'
              '}\n'
          )
      if "--tb-traffic-left" not in css_txt:
          css_txt += (
              '\n:root[data-platform="linux"] .app:not(.sb-hidden) .tb-left { left: 8px; width: calc(var(--sb-w) - 16px); }\n'
              ':root[data-platform="linux"] .app.sb-hidden .tb-left,\n'
              ':root[data-platform="linux"] .app[data-files-split="true"] .tb-left { margin-left: 0; }\n'
              '@media (max-width: 720px) { :root[data-platform="linux"] .app:not(.sb-hidden) .titlebar .tb-left { padding-left: 0; } }\n'
              ':root[data-platform="linux"] .app.sb-hidden .file-panel.maximized .file-header { padding-left: 10px; }\n'
              '@media (max-width: 720px) { :root[data-platform="linux"] .file-panel.maximized .file-header { padding-left: 10px; } }\n'
              ':root[data-platform="linux"] .dlg-fullscreen > .dlg-head { padding-left: 14px; }\n'
          )
      styles_css.write_text(css_txt)

      vb_tsx = pathlib.Path("src/VoiceButton.tsx")
      if vb_tsx.exists():
          vb_txt = vb_tsx.read_text()
          old_mm = 'return "Speech model not downloaded — run orb/voice/install.sh --download-model.";'
          new_mm = 'return (typeof navigator !== "undefined" && /linux/i.test(navigator.platform || navigator.userAgent)) ? "Speech model not downloaded — run murmure download-model." : "Speech model not downloaded — run orb/voice/install.sh --download-model.";'
          if old_mm in vb_txt:
              vb_tsx.write_text(vb_txt.replace(old_mm, new_mm, 1))
      PY
    '';

    buildPhase = ''
      runHook preBuild
      pnpm build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r dist/. "$out/"
      runHook postInstall
    '';
  };

  linuxSigner = ''
    import base64, getpass, json, os, shutil, subprocess, sys, time, uuid

    OPENSSL = "${openssl}/bin/openssl"
    NOTIFY = "${libnotify}/bin/notify-send"

    def emit(obj):
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    def fail(msg, code=1):
        sys.stderr.write(msg + "\n")
        sys.stderr.flush()
        sys.exit(code)

    args = sys.argv[1:]
    if not args:
        fail("usage: orb-signer create|public|sign|auth|status|serve --key PATH")
    cmd = args[0]

    def opt(name):
        for i, a in enumerate(args):
            if a == name and i + 1 < len(args):
                return args[i + 1]
        return None

    def fprintd_enrolled():
        fplist = shutil.which("fprintd-list") or "/run/current-system/sw/bin/fprintd-list"
        fpverify = shutil.which("fprintd-verify") or "/run/current-system/sw/bin/fprintd-verify"
        if not (os.path.exists(fplist) and os.path.exists(fpverify)):
            return False, None
        try:
            r = subprocess.run([fplist, getpass.getuser()], capture_output=True, text=True, timeout=5)
            ok = r.returncode == 0 and (" - #" in r.stdout or "Fingerprints for user" in r.stdout and "has no fingers" not in r.stdout)
            return ok, fpverify
        except Exception:
            return False, None

    def verify_touchid(reason):
        ok, fpverify = fprintd_enrolled()
        if not ok or not fpverify:
            return False, 3, "Touch ID sensor or enrolled fingerprint is not available"
        prompt_text = reason or "Touch sensor to authenticate"
        proc = None
        try:
            proc = subprocess.Popen(
                [fpverify],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            overlay_shown = False
            omarchy_shell = shutil.which("omarchy-shell") or "/etc/profiles/per-user/" + getpass.getuser() + "/bin/omarchy-shell"
            if os.path.exists(omarchy_shell):
                try:
                    ipc_payload = json.dumps({
                        "app": "Orb",
                        "subtitle": prompt_text,
                        "pid": proc.pid,
                    })
                    clean_env = {k: v for k, v in os.environ.items() if k != "OMARCHY_PATH"}
                    ipc = subprocess.run(
                        [omarchy_shell, "touchid", "begin", ipc_payload],
                        capture_output=True,
                        text=True,
                        timeout=0.6,
                        env=clean_env,
                    )
                    overlay_shown = ipc.returncode == 0 and "ok" in (ipc.stdout or "")
                except Exception:
                    overlay_shown = False
            if not overlay_shown and os.path.exists(NOTIFY):
                try:
                    subprocess.Popen(
                        [NOTIFY, "-a", "Orb", "-t", "8000", "Orb — Touch ID", prompt_text],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                except Exception:
                    pass
            out_s, err_s = proc.communicate(timeout=35)
            out = (out_s or "") + "\n" + (err_s or "")
            if proc.returncode == 0 and "verify-match" in out:
                return True, 0, ""
            if "verify-no-match" in out:
                return False, 1, "Touch ID: fingerprint did not match"
            return False, 2, "Touch ID: authentication cancelled"
        except subprocess.TimeoutExpired:
            if proc is not None and proc.poll() is None:
                proc.kill()
            return False, 2, "Touch ID: timed out"
        except Exception as exc:
            if proc is not None and proc.poll() is None:
                proc.kill()
            return False, 1, f"Touch ID: {exc}"

    if cmd == "status":
        ok, _ = fprintd_enrolled()
        if ok:
            emit({"available": "true", "kind": "touch_id", "label": "Touch ID"})
        else:
            emit({"available": "false", "kind": "none", "label": "Unavailable"})
        sys.exit(0)

    if cmd == "auth":
        reason = (opt("--reason") or "Authenticate").strip() or "Authenticate"
        ok, code, msg = verify_touchid(reason)
        if not ok:
            fail(msg, code)
        emit({"authenticated": "true"})
        sys.exit(0)

    key_path = opt("--key")
    if not key_path:
        fail("--key is required")

    def pubkey_spki_b64(pem_path):
        r = subprocess.run(
            [OPENSSL, "pkey", "-in", pem_path, "-pubout", "-outform", "DER"],
            capture_output=True,
            check=True,
        )
        return base64.b64encode(r.stdout).decode("ascii")

    def grace_eligible(payload_bytes):
        try:
            lines = payload_bytes.decode("utf-8").split("\n")
            if len(lines) < 6:
                return False
            route = lines[2].split(" ")
            if len(route) != 2 or route[0] != "POST":
                return False
            parts = [p for p in route[1].split("/") if p]
            if len(parts) != 5 or parts[:3] != ["api", "bitwarden", "requests"]:
                return False
            uuid.UUID(parts[3])
            return parts[4] in ("approve", "reject")
        except Exception:
            return False

    def sign_payload(payload_bytes, skip_prompt=False):
        try:
            text = payload_bytes.decode("utf-8")
            lines = text.split("\n")
            summary = lines[-1] if lines else ""
            if not text.startswith("paloma-approval-v1\n") or not summary:
                return None, 1, "Not a Paloma approval payload"
        except Exception:
            return None, 1, "Not a Paloma approval payload"
        if not os.path.isfile(key_path):
            return None, 4, f"No approval key at {key_path}"
        if not skip_prompt:
            ok, code, msg = verify_touchid(summary)
            if not ok:
                return None, code, msg
        try:
            r = subprocess.run(
                [OPENSSL, "dgst", "-sha256", "-sign", key_path, "-binary"],
                input=payload_bytes,
                capture_output=True,
                check=True,
            )
            return base64.b64encode(r.stdout).decode("ascii"), 0, ""
        except Exception as exc:
            return None, 1, f"Signing failed: {exc}"

    if cmd == "create":
        ok, _ = fprintd_enrolled()
        if not ok:
            fail("Touch ID is not enrolled on this machine (run fprintd-enroll first)", 3)
        os.makedirs(os.path.dirname(os.path.abspath(key_path)), exist_ok=True)
        gen = subprocess.run(
            [OPENSSL, "ecparam", "-name", "prime256v1", "-genkey", "-noout"],
            capture_output=True,
            check=True,
        )
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, gen.stdout)
            os.fsync(fd)
        finally:
            os.close(fd)
        emit({"public_key": pubkey_spki_b64(key_path)})
    elif cmd == "public":
        if not os.path.isfile(key_path):
            fail(f"No approval key at {key_path}", 4)
        emit({"public_key": pubkey_spki_b64(key_path)})
    elif cmd == "sign":
        payload = sys.stdin.buffer.read()
        sig, code, msg = sign_payload(payload, skip_prompt=False)
        if sig is None:
            fail(msg, code)
        emit({"signature": sig})
    elif cmd == "serve":
        try:
            grace = min(max(int(opt("--grace") or "300"), 0), 3600)
        except ValueError:
            grace = 300
        held_at = None
        for raw_line in sys.stdin:
            now = time.time()
            if held_at is not None and (now - held_at) > grace:
                held_at = None
            try:
                payload = base64.b64decode(raw_line.strip(), validate=True)
            except Exception:
                emit({"error": "Invalid request", "code": "1"})
                continue
            elig = grace_eligible(payload)
            sig, code, msg = sign_payload(payload, skip_prompt=(elig and held_at is not None))
            if sig is not None:
                if elig and held_at is None and grace > 0:
                    held_at = time.time()
                reply = {"signature": sig}
                if held_at is not None:
                    reply["grace_until"] = str(int(held_at + grace))
                emit(reply)
            else:
                held_at = None
                emit({"error": msg, "code": str(code)})
    else:
        fail(f"unknown command {cmd}")
  '';
in
stdenv.mkDerivation {
  pname = "orb-desktop";
  inherit version;
  src = "${orbSrc}/linux_shell";

  nativeBuildInputs = [
    clang
    pkg-config
    wrapGAppsHook4
    makeWrapper
  ];

  buildInputs = [
    gtk4
    webkitgtk_6_0
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    pipewire
  ];

  dontWrapGApps = true;

  # Support both locked GTK3 orbSrc revisions and the new GTK4 + WebKitGTK 6.0 shell (`tauri://localhost/`).
  postPatch = ''
    if ! grep -q '<webkit/webkit.h>' main.c; then
      cp ${./orb-shell-gtk4.c} main.c
      substituteInPlace Makefile \
        --replace-fail 'gtk+-3.0 webkit2gtk-4.1' 'gtk4 webkitgtk-6.0'
      # The GTK4 shell is the single file above. Upstream keeps adding GTK3
      # companion sources (gtk_chrome.c, gtk_icons.c, gtk_menu.c, ...) to the
      # rule, so drop whatever the rule lists instead of matching exact names.
      sed -i -E \
        -e 's|^orb-desktop:.*$|orb-desktop: main.c|' \
        -e 's|-o \$@ main\.c .*\$\(LDFLAGS\)|-o $@ main.c $(LDFLAGS)|' Makefile
      grep -q -- '-o $@ main.c $(LDFLAGS)' Makefile
    fi
  '';

  buildPhase = ''
    runHook preBuild
    make CC="${clang}/bin/clang" HAS_WEBKIT=1 orb-desktop
    ./orb-desktop --self-test
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/orb" "$out/share/applications" "$out/share/pixmaps"
    install -m 0755 orb-desktop "$out/bin/.orb-desktop-unwrapped"
    cp -r ${orb-ui}/. "$out/share/orb/"
    if [ -f "${orbSrc}/macos_shell/icons/icon.png" ]; then
      install -m 0644 "${orbSrc}/macos_shell/icons/icon.png" "$out/share/pixmaps/orb.png"
    fi
    cat > "$out/share/applications/orb.desktop" <<EOF
    [Desktop Entry]
    Name=Orb
    Comment=All your AI providers, machines, and agent harnesses in one place
    Exec=$out/bin/orb
    Icon=orb
    Terminal=false
    Type=Application
    Categories=Development;Utility;
    StartupWMClass=orb-desktop
    EOF
    cat > "$out/bin/.orb-signer" <<'PY'
    #!${python3}/bin/python3
    ${linuxSigner}
    PY
    chmod 0755 "$out/bin/.orb-signer"
    runHook postInstall
  '';

  postFixup = ''
    makeWrapper "$out/bin/.orb-desktop-unwrapped" "$out/bin/orb" \
      "''${gappsWrapperArgs[@]}" \
      --set-default GTK_USE_PORTAL 1 \
      --prefix PATH : "/run/current-system/sw/bin:${
        lib.makeBinPath [
          sandboxedShOffline
          git
          openssh
          openssl
          libnotify
          python3
          xdg-utils
        ]
      }" \
      --set ORB_LOCALD_BIN "${sandboxedShOffline}/bin/orb-locald" \
      --set ORB_SIGNER_BIN "$out/bin/.orb-signer" \
      --set-default ORB_VOICE_PYTHON "${python3}/bin/python3" \
      --set-default ORB_VOICE_WORKER "${murmure}/libexec/murmure/voiced/orb_voice_bridge.py" \
      --set-default VOICED_COHERE_LIB "${murmure.crispasr-cohere}/lib/libcohere_asr.so" \
      --set-default SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt" \
      --set-default NIX_SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt" \
      --set ORB_UI_ROOT "$out/share/orb" \
      --run ${lib.escapeShellArg ''
        if [ -d /run/opengl-driver/share ]; then
          export XDG_DATA_DIRS="/run/opengl-driver/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
        fi
        if [ -d /run/opengl-driver/lib ]; then
          export LD_LIBRARY_PATH="/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
        if [ -d /run/opengl-driver/lib/dri ]; then
          export LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri"
        fi
        if [ -d /run/opengl-driver/lib/gbm ]; then
          export GBM_BACKENDS_PATH="/run/opengl-driver/lib/gbm"
        fi
        if [ -d /run/opengl-driver/share/glvnd/egl_vendor.d ]; then
          export __EGL_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/egl_vendor.d"
        fi
      ''}
  '';

  passthru = {
    sandboxed-sh = sandboxedShOffline;
    inherit orb-ui;
  };

  meta = {
    description = "Orb desktop client (GTK4 + WebKitGTK 6.0 shell + orb-locald)";
    mainProgram = "orb";
    platforms = lib.platforms.linux;
  };
}
