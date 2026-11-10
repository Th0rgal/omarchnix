{
  lib,
  stdenv,
  nodejs,
  pnpm,
  pnpmConfigHook,
  fetchPnpmDeps,
  fetchFromGitHub,
  python3,
  pkg-config,
  gtk3,
  webkitgtk_4_1,
  wrapGAppsHook3,
  makeWrapper,
  git,
  openssh,
  openssl,
  libnotify,
  xdg-utils,
  cacert,
  sandboxed-sh,
  orbSrc,
  autoPatchelfHook,
  glibc,
}:
let
  version = "0.13.0";

  coreLakeManifest = lib.importJSON "${orbSrc}/lean/OrbCore/lake-manifest.json";
  leanSysPkg = lib.findFirst (
    p: p.name == "«lean-sys»" || p.name == "lean-sys"
  ) (throw "lean-sys entry missing from lean/OrbCore/lake-manifest.json") coreLakeManifest.packages;

  pinnedLeanSys = fetchFromGitHub {
    owner = "Th0rgal";
    repo = "lean-sys";
    inherit (leanSysPkg) rev;
    hash = "sha256-TKE6Zhx4mWHFkJJbZEOQLwPQomAAYU5L3fYAiDMGwi8=";
  };

  # Upstream sandboxed-sh copies lean-sys into .lake/packages without .git,
  # which causes Lake 4.35 to re-fetch from GitHub and fail in the offline Nix
  # sandbox. Stage lean-sys as a sibling path package instead.
  sandboxedShOffline = sandboxed-sh.overrideAttrs (old: {
    # Lean's bundled clang links every binary against the generic Linux loader
    # (/lib/ld-linux-*.so.1). That works on Ubuntu and fails on NixOS.
    nativeBuildInputs =
      (old.nativeBuildInputs or [ ])
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        autoPatchelfHook
      ];
    buildInputs =
      (old.buildInputs or [ ])
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        glibc
      ];
    postPatch = (old.postPatch or "") + ''
      rm -rf lean/lean-sys
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

      rpc = pathlib.Path("lean/OrbLocald/OrbLocald/Rpc.lean")
      rpc_txt = rpc.read_text()
      for old_s, new_s in [
          (
              'if st.hostOs == "macos" && (← System.FilePath.pathExists bin) then',
              'if (st.hostOs == "macos" || st.hostOs == "linux") && (← System.FilePath.pathExists bin) then',
          ),
          (
              '  | "approval_key_create" =>\n    match st.signerBin? with\n    | some bin =>\n      if st.hostOs == "macos" then',
              '  | "approval_key_create" =>\n    match st.signerBin? with\n    | some bin =>\n      if st.hostOs == "macos" || st.hostOs == "linux" then',
          ),
          (
              '  | "approval_sign" =>\n    let payload := (args.fieldStr? "payload").getD ""\n    match st.signerBin? with\n    | some bin =>\n      if st.hostOs == "macos" then',
              '  | "approval_sign" =>\n    let payload := (args.fieldStr? "payload").getD ""\n    match st.signerBin? with\n    | some bin =>\n      if st.hostOs == "macos" || st.hostOs == "linux" then',
          ),
          (
              '  | "biometric_status" =>\n    if st.hostOs != "macos" then',
              '  | "biometric_status" =>\n    if st.hostOs != "macos" && (st.hostOs != "linux" || st.signerBin?.isNone) then',
          ),
          (
              '        | .error _ =>\n          return .ok (.obj #[\n            ("available", .bool true),\n            ("kind", .str "touch_id"),\n            ("label", .str "Touch ID"),\n            ("biometry_type", .str "touch_id")\n          ])',
              '        | .error _ =>\n          let fallbackAvail := st.hostOs == "macos"\n          return .ok (.obj #[\n            ("available", .bool fallbackAvail),\n            ("kind", .str (if fallbackAvail then "touch_id" else "none")),\n            ("label", .str (if fallbackAvail then "Touch ID" else "")),\n            ("biometry_type", .str (if fallbackAvail then "touch_id" else "none"))\n          ])',
          ),
          (
              '  | "biometric_authenticate" =>\n    if st.hostOs != "macos" then',
              '  | "biometric_authenticate" =>\n    if st.hostOs != "macos" && st.hostOs != "linux" then',
          ),
      ]:
          assert old_s in rpc_txt, f"missing Rpc.lean snippet: {old_s!r}"
          rpc_txt = rpc_txt.replace(old_s, new_s, 1)
      rpc.write_text(rpc_txt)
      PY
    '';
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
    ];

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

  staticServer = ''
    import os, sys
    from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

    ROOT = sys.argv[1]
    os.chdir(ROOT)

    MIME = {
        ".html": "text/html; charset=utf-8",
        ".js": "text/javascript; charset=utf-8",
        ".mjs": "text/javascript; charset=utf-8",
        ".css": "text/css; charset=utf-8",
        ".wasm": "application/wasm",
        ".json": "application/json; charset=utf-8",
        ".svg": "image/svg+xml",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webp": "image/webp",
        ".ico": "image/x-icon",
        ".woff2": "font/woff2",
        ".woff": "font/woff",
        ".ttf": "font/ttf",
        ".map": "application/json; charset=utf-8",
    }

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def end_headers(self):
            origin = self.headers.get("Origin") or ""
            if not origin.startswith("http://127.0.0.1") and not origin.startswith("http://localhost"):
                host = self.headers.get("Host", "127.0.0.1")
                origin = "http://" + host
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            self.send_header("Cache-Control", "no-cache")
            super().end_headers()

        def guess_type(self, path):
            ext = os.path.splitext(path)[1].lower()
            return MIME.get(ext, "application/octet-stream")

        def translate_path(self, path):
            rel = path.split("?", 1)[0].split("#", 1)[0]
            while rel.startswith("/"):
                rel = rel[1:]
            if rel == "":
                rel = "index.html"
            candidate = os.path.normpath(os.path.join(ROOT, rel))
            if not (candidate == ROOT or candidate.startswith(ROOT + os.sep)):
                return os.path.join(ROOT, "__missing__")
            if os.path.isfile(candidate):
                return candidate
            if os.path.splitext(rel)[1] == "":
                return os.path.join(ROOT, "index.html")
            return os.path.join(ROOT, "__missing__")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    sys.stdout.write(str(port) + "\n")
    sys.stdout.flush()
    server.serve_forever()
  '';

  linuxSigner = ''
    import base64, getpass, json, os, shutil, subprocess, sys, tempfile, time, uuid

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
        try:
            if os.path.exists(NOTIFY):
                subprocess.Popen(
                    [NOTIFY, "-a", "Orb", "-t", "8000", "Orb — Touch ID", reason or "Touch sensor to authenticate"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
        except Exception:
            pass
        try:
            r = subprocess.run([fpverify], capture_output=True, text=True, timeout=35)
            out = (r.stdout or "") + "\n" + (r.stderr or "")
            if r.returncode == 0 and "verify-match" in out:
                return True, 0, ""
            if "verify-no-match" in out:
                return False, 1, "Touch ID: fingerprint did not match"
            return False, 2, "Touch ID: authentication cancelled"
        except subprocess.TimeoutExpired:
            return False, 2, "Touch ID: timed out"
        except Exception as exc:
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
    pkg-config
    wrapGAppsHook3
    makeWrapper
  ];

  buildInputs = [
    gtk3
    webkitgtk_4_1
  ];

  dontWrapGApps = true;

  # "http://127.0.0.1/*" already matches any port: WTF::URL::host() has no
  # port, and a colon in the host makes UserContentURLPattern::parse drop
  # the pattern. NULL allow_list injects on every top frame; navigation
  # policy still confines the top frame to loopback and file://.
  # GTK3 on Wayland leaves gtk-xft-dpi at -1 when settings.ini does not set
  # it. WebKitGTK then does gdk_screen_get_resolution() * wl_output scale /
  # 96, which is -1 * 2 / 96 = -0.0208333 and collapses the whole CSS tree.
  postPatch = ''
    substituteInPlace main.c \
      --replace-fail \
      'static const char *const keep[] = { "HOME", "PATH", "TMPDIR", "USER", "LANG", "ORB_STATE_DIR", "ORB_SIGNER_BIN", "ORB_APPROVAL_KEY_PATH" };' \
      'static const char *const keep[] = { "HOME", "PATH", "TMPDIR", "USER", "LANG", "ORB_STATE_DIR", "ORB_SIGNER_BIN", "ORB_APPROVAL_KEY_PATH", "SSL_CERT_FILE", "SSL_CERT_DIR", "NIX_SSL_CERT_FILE" };' \
      --replace-fail \
      'char pkv[40], tkv[4200], kv[8][1024], *envp[11];' \
      'char pkv[40], tkv[4200], kv[11][1024], *envp[14];' \
      --replace-fail \
      'for (size_t i = 0; i < 8; ++i) {' \
      'for (size_t i = 0; i < 11; ++i) {'
    substituteInPlace main.c \
      --replace-fail \
      'static const gchar *const allow_list[] = { "http://127.0.0.1/*", "http://localhost/*", "file:///*", NULL };' \
      'static const gchar *const allow_list[] = { NULL };'
    substituteInPlace main.c \
      --replace-fail \
      'gtk_init(&argc, &argv);' \
      '    g_set_prgname("orb-desktop");
    gtk_init(&argc, &argv);
    {
        GtkSettings *gs = gtk_settings_get_default();
        gint xft_dpi = -1;
        if (gs) {
            g_object_get(gs, "gtk-xft-dpi", &xft_dpi, NULL);
            if (xft_dpi <= 0) g_object_set(gs, "gtk-xft-dpi", 96 * 1024, NULL);
        }
        GdkScreen *def = gdk_screen_get_default();
        if (def && gdk_screen_get_resolution(def) <= 0.0)
            gdk_screen_set_resolution(def, 96.0);
        GtkCssProvider *glass = gtk_css_provider_new();
        gtk_css_provider_load_from_data(glass,
            "window, window.background { background-color: rgba(0,0,0,0); background-image: none; backdrop-filter: blur(20px); }",
            -1, NULL);
        gtk_style_context_add_provider_for_screen(gdk_screen_get_default(),
            GTK_STYLE_PROVIDER(glass), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        g_object_unref(glass);
    }'
    substituteInPlace main.c \
      --replace-fail \
      'gtk_window_set_title(GTK_WINDOW(win), "Orb");' \
      'gtk_window_set_title(GTK_WINDOW(win), "Orb");
    {
        GdkScreen *screen = gtk_widget_get_screen(win);
        GdkVisual *rgba = gdk_screen_get_rgba_visual(screen);
        if (rgba) gtk_widget_set_visual(win, rgba);
        gtk_widget_set_app_paintable(win, TRUE);
    }'
    substituteInPlace main.c \
      --replace-fail \
      'WebKitUserContentManager *ucm = webkit_user_content_manager_new();' \
      'WebKitSettings *wks = webkit_settings_new();
    webkit_settings_set_hardware_acceleration_policy(wks, WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS);
    WebKitUserContentManager *ucm = webkit_user_content_manager_new();'
    substituteInPlace main.c \
      --replace-fail \
      'GtkWidget *wv = webkit_web_view_new_with_user_content_manager(ucm);' \
      'GtkWidget *wv = g_object_new(WEBKIT_TYPE_WEB_VIEW, "settings", wks, "user-content-manager", ucm, "is-ephemeral", FALSE, NULL);
    {
        GdkRGBA clear = { 0, 0, 0, 0 };
        webkit_web_view_set_background_color(WEBKIT_WEB_VIEW(wv), &clear);
    }'
  '';

  buildPhase = ''
    runHook preBuild
    make HAS_WEBKIT=1 orb-desktop
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
    cat > "$out/bin/.orb-static-server" <<'PY'
    ${staticServer}
    PY
    chmod 0755 "$out/bin/.orb-static-server"
    cat > "$out/bin/.orb-signer" <<'PY'
    #!${python3}/bin/python3
    ${linuxSigner}
    PY
    chmod 0755 "$out/bin/.orb-signer"
    makeWrapper "$out/bin/.orb-desktop-unwrapped" "$out/bin/orb" \
      "''${gappsWrapperArgs[@]}" \
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
      --set-default SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt" \
      --set-default NIX_SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt" \
      --set ORB_UNWRAPPED "$out/bin/.orb-desktop-unwrapped" \
      --set ORB_STATIC_SERVER "$out/bin/.orb-static-server" \
      --set ORB_UI_ROOT "$out/share/orb" \
      --run ${lib.escapeShellArg ''
        case " $* " in
          *" --self-test "*) ;;
          *)
            if [ -z "''${ORB_DEV_URL:-}" ]; then
              fifo=$(mktemp -u)
              mkfifo "$fifo"
              ${python3}/bin/python3 "$ORB_STATIC_SERVER" "$ORB_UI_ROOT" >"$fifo" &
              server_pid=$!
              IFS= read -r port <"$fifo" || true
              rm -f "$fifo"
              if [ -z "$port" ]; then
                echo "orb: static UI server failed to start" >&2
                kill "$server_pid" 2>/dev/null || true
                exit 1
              fi
              export ORB_DEV_URL="http://127.0.0.1:$port/"
              if [ -z "''${ORB_LOCALD_PORT:-}" ]; then
                export ORB_LOCALD_PORT=$(${python3}/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
              fi
              trap 'kill "$server_pid" 2>/dev/null || true' EXIT HUP INT TERM
              "$ORB_UNWRAPPED" "$@"
              exit $?
            fi
            ;;
        esac
      ''}
    runHook postInstall
  '';

  passthru = {
    sandboxed-sh = sandboxedShOffline;
    inherit orb-ui;
  };

  meta = {
    description = "Orb desktop client (GTK3 + WebKitGTK shell + orb-locald)";
    mainProgram = "orb";
    platforms = lib.platforms.linux;
  };
}
