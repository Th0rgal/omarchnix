{
  lib,
  pkgs,
  omarchySrc,
  marketplaceSrc ? null,
}:
let
  omarchyPython = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
  omarchyTesseract = pkgs.tesseract.override { enableLanguages = [ "eng" ]; };

  fcitxIndicatorBin =
    pkgs.runCommandCC "omarchy-fcitx-indicator"
      {
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [
          pkgs.glib
          pkgs.json-glib
        ];
      }
      ''
        mkdir -p "$out/bin"
        $CC -O2 -Wall -Wextra \
          "${./omarchy-shell-fast/fcitx-indicator.c}" \
          $(pkg-config --cflags --libs gio-2.0 gio-unix-2.0 json-glib-1.0) \
          -o "$out/bin/fcitx-indicator"
      '';

  omarchyRuntimePath = lib.makeBinPath [
    pkgs.bash
    pkgs.brightnessctl
    pkgs.coreutils
    pkgs.curl
    pkgs.dconf
    pkgs.ffmpeg
    pkgs.ffmpegthumbnailer
    pkgs.file
    pkgs.findutils
    pkgs.gawk
    pkgs.git
    pkgs.glib
    pkgs.glib.bin
    pkgs.grim
    pkgs.gsettings-desktop-schemas
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gum
    pkgs.hyprland
    pkgs.hyprpicker
    pkgs.hyprsunset
    pkgs.imagemagick
    pkgs.imv
    pkgs.inotify-tools
    pkgs.jq
    pkgs.libnotify
    pkgs.mpv-unwrapped
    pkgs.openssh
    pkgs.procps
    pkgs.psmisc
    pkgs.pulseaudio
    omarchyPython
    pkgs.quickshell
    pkgs.ripgrep
    pkgs.satty
    pkgs.slurp
    pkgs.socat
    pkgs.systemd
    omarchyTesseract
    pkgs.util-linux
    pkgs.uwsm
    pkgs.v4l-utils
    pkgs.vips
    pkgs.wf-recorder
    pkgs.wl-clipboard
    pkgs.xdg-terminal-exec
    pkgs.xdg-user-dirs
    pkgs.xdg-utils
    pkgs.zbar
  ];

  patchAgentsPy = pkgs.writeText "patch-omarchy-agents.py" ''
    import pathlib
    import sys

    out = pathlib.Path(sys.argv[1])
    hook = (
        '_omarchy_override="''${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/agent-overrides/$(basename "$0")"\n'
        'if [[ -z ''${_OMARCHY_SKIP_AGENT_OVERRIDE:-} && -x $_omarchy_override ]]; then\n'
        '  export OMARCHY_UPSTREAM_BIN_DIR="$(cd "$(dirname "$0")" && pwd)"\n'
        '  exec "$_omarchy_override" "$@"\n'
        'fi\n'
    )
    for name in (
        "omarchy-agent",
        "omarchy-agent-usage-update",
        "omarchy-agent-account-use",
        "omarchy-agent-account-mode",
        "omarchy-agent-account-rename",
        "omarchy-agent-account-add",
        "omarchy-agent-prompt",
    ):
        p = out / "bin" / name
        if not p.is_file():
            continue
        lines = p.read_text(encoding="utf-8").splitlines(keepends=True)
        if not lines or not lines[0].startswith("#!"):
            continue
        insert_at = 1
        while insert_at < len(lines) and (
            lines[insert_at].strip() == "" or lines[insert_at].startswith("#")
        ):
            insert_at += 1
        lines.insert(insert_at, "\n" + hook + "\n")
        p.write_text("".join(lines), encoding="utf-8")

    panel = out / "shell" / "plugins" / "agents" / "Panel.qml"
    if panel.is_file():
        qml = panel.read_text(encoding="utf-8")
        old_add = "\n".join([
            '  readonly property var addProviders: [',
            '    { providerId: "claude", providerName: "Claude Code" },',
            '    { providerId: "codex", providerName: "Codex" },',
            '    { providerId: "grok", providerName: "Grok" }',
            '  ].concat(localFits ? [{ providerId: "local", providerName: Commons.I18n.t("agents.localAi") }] : [])',
        ])
        new_add = "\n".join([
            '  readonly property var addProviders: [',
            '    { providerId: "claude", providerName: "Claude Code" },',
            '    { providerId: "codex", providerName: "Codex" },',
            '    { providerId: "grok", providerName: "Grok" }',
            '  ].concat(addChecks["agy"] ? [{ providerId: "agy", providerName: "Antigravity" }] : [])',
            '   .concat(addChecks["kimi"] ? [{ providerId: "kimi", providerName: "Kimi" }] : [])',
            '   .concat(addChecks["vibe"] ? [{ providerId: "vibe", providerName: "Mistral Vibe" }] : [])',
            '   .concat(localFits ? [{ providerId: "local", providerName: Commons.I18n.t("agents.localAi") }] : [])',
        ])
        assert old_add in qml, "Panel.qml addProviders block not found"
        qml = qml.replace(old_add, new_add, 1)

        old_sup = "\n".join([
            '  function supportsSignIn(p) {',
            '    for (var i = 0; i < addProviders.length; i++)',
            '      if (p && addProviders[i].providerId === p.providerId) return true',
            '    return false',
            '  }',
        ])
        new_sup = "\n".join([
            '  function supportsSignIn(p) {',
            '    if (p && p.orbSignIn === true) return true',
            '    for (var i = 0; i < addProviders.length; i++)',
            '      if (p && addProviders[i].providerId === p.providerId) return true',
            '    return false',
            '  }',
        ])
        assert old_sup in qml, "Panel.qml supportsSignIn block not found"
        qml = qml.replace(old_sup, new_sup, 1)

        old_row = "\n".join([
            '    Row {',
            '      id: choiceRow',
            '      visible: root.picking',
            '      width: parent.width',
            '      spacing: Style.space(10)',
        ])
        new_row = "\n".join([
            '    Flow {',
            '      id: choiceRow',
            '      readonly property int cols: Math.min(3, Math.max(1, root.addProviders.length))',
            '      visible: root.picking',
            '      width: parent.width',
            '      spacing: Style.space(10)',
        ])
        assert old_row in qml, "Panel.qml choiceRow header not found"
        qml = qml.replace(old_row, new_row, 1)

        old_w = "width: (choiceRow.width - choiceRow.spacing * (root.addProviders.length - 1)) / root.addProviders.length"
        new_w = "width: Math.floor((choiceRow.width - choiceRow.spacing * (choiceRow.cols - 1)) / choiceRow.cols)"
        assert old_w in qml, "Panel.qml choice width line not found"
        qml = qml.replace(old_w, new_w, 1)

        panel.write_text(qml, encoding="utf-8")

    main_qml = out / "shell" / "plugins" / "agents" / "Main.qml"
    if main_qml.is_file():
        mtxt = main_qml.read_text(encoding="utf-8")
        old_dp = '      ready: record.ready === true || synced,'
        new_dp = '      ready: record.ready === true || synced,\n      orbSignIn: record.orbSignIn === true,'
        assert old_dp in mtxt, "Main.qml displayProvider ready line not found"
        main_qml.write_text(mtxt.replace(old_dp, new_dp, 1), encoding="utf-8")

    mon_panel = out / "shell" / "plugins" / "panels" / "monitor" / "Panel.qml"
    if mon_panel.is_file():
        mqml = mon_panel.read_text(encoding="utf-8")

        old_slider_fn = "\n".join([
            '  // A lone slider, held at the -1 sentinel.',
            '  function isSliderSection(section) {',
            '    return section === "textsize" || section === "brightness"',
            '  }',
        ])
        new_slider_fn = "\n".join([
            '  property int kbdBrightness: -1',
            '  property int lastNonZeroKbdBrightness: 50',
            '  property int pendingKbdBrightness: 0',
            '  property bool kbdBrightnessSetQueued: false',
            "",
            '  // A lone slider, held at the -1 sentinel.',
            '  function isSliderSection(section) {',
            '    return section === "textsize" || section === "brightness" || section === "kbdbacklight"',
            '  }',
        ])
        assert old_slider_fn in mqml, "monitor/Panel.qml isSliderSection not found"
        mqml = mqml.replace(old_slider_fn, new_slider_fn, 1)

        old_vis = '    if (currentBrightness >= 0) list.push("brightness")'
        new_vis = '    if (currentBrightness >= 0) list.push("brightness")\n    if (kbdBrightness >= 0) list.push("kbdbacklight")'
        assert old_vis in mqml, "monitor/Panel.qml visibleSections brightness line not found"
        mqml = mqml.replace(old_vis, new_vis, 1)

        old_move_h = "\n".join([
            '    if (focusSection === "brightness") {',
            '      if (current) adjustBrightness(current.name, delta * 5)',
            '    } else if (focusSection === "textsize") {',
        ])
        new_move_h = "\n".join([
            '    if (focusSection === "brightness") {',
            '      if (current) adjustBrightness(current.name, delta * 5)',
            '    } else if (focusSection === "kbdbacklight") {',
            '      adjustKbdBrightness(delta * 5)',
            '    } else if (focusSection === "textsize") {',
        ])
        assert old_move_h in mqml, "monitor/Panel.qml moveCursorH block not found"
        mqml = mqml.replace(old_move_h, new_move_h, 1)

        old_refresh = "\n".join([
            '  function refresh() {',
            '    if (!stateProc.running) stateProc.running = true',
            '  }',
        ])
        new_refresh = "\n".join([
            '  function clampKbdBrightness(value) {',
            '    return Math.max(0, Math.min(100, Math.round(Number(value) || 0)))',
            '  }',
            "",
            '  function setKbdBrightness(value) {',
            '    var percent = clampKbdBrightness(value)',
            '    if (percent > 0) root.lastNonZeroKbdBrightness = percent',
            '    root.kbdBrightness = percent',
            '    root.pendingKbdBrightness = percent',
            '    if (setKbdBrightnessProc.running) {',
            '      root.kbdBrightnessSetQueued = true',
            '      return',
            '    }',
            '    root.kbdBrightnessSetQueued = false',
            '    setKbdBrightnessProc.command = ["omarchy-brightness-keyboard", "--no-osd", percent + "%"]',
            '    setKbdBrightnessProc.running = true',
            '  }',
            "",
            '  function previewKbdBrightness(value) {',
            '    var percent = clampKbdBrightness(value)',
            '    if (percent > 0) root.lastNonZeroKbdBrightness = percent',
            '    root.kbdBrightness = percent',
            '    root.pendingKbdBrightness = percent',
            '    kbdBrightnessDebounce.restart()',
            '  }',
            "",
            '  function adjustKbdBrightness(delta) {',
            '    if (root.kbdBrightness < 0) return',
            '    setKbdBrightness(root.kbdBrightness + delta)',
            '  }',
            "",
            '  function toggleKbdBrightness() {',
            '    if (root.kbdBrightness < 0) return',
            '    if (root.kbdBrightness > 0) setKbdBrightness(0)',
            '    else setKbdBrightness(root.lastNonZeroKbdBrightness > 0 ? root.lastNonZeroKbdBrightness : 50)',
            '  }',
            "",
            '  function refresh() {',
            '    if (!stateProc.running) stateProc.running = true',
            '    if (!kbdStateProc.running && !setKbdBrightnessProc.running && !kbdBrightnessDebounce.running)',
            '      kbdStateProc.running = true',
            '  }',
        ])
        assert old_refresh in mqml, "monitor/Panel.qml refresh block not found"
        mqml = mqml.replace(old_refresh, new_refresh, 1)

        old_set_proc = "\n".join([
            '    onRunningChanged: {',
            '      if (running) return',
            '      if (root.brightnessSetQueued) {',
            '        root.setDisplayBrightness(root.pendingBrightnessMonitor, root.pendingBrightnessPercent)',
            '      }',
            '    }',
            '  }',
        ])
        new_set_proc = old_set_proc + "\n\n" + "\n".join([
            '  Process {',
            '    id: kbdStateProc',
            '    command: ["omarchy-brightness-keyboard", "get"]',
            '    stdout: StdioCollector {',
            '      waitForEnd: true',
            '      onStreamFinished: {',
            '        var raw = String(text || "").trim()',
            '        if (raw === "" || isNaN(parseInt(raw, 10))) {',
            '          root.kbdBrightness = -1',
            '        } else {',
            '          var pct = Math.max(0, Math.min(100, parseInt(raw, 10)))',
            '          if (pct > 0) root.lastNonZeroKbdBrightness = pct',
            '          if (!setKbdBrightnessProc.running && !kbdBrightnessDebounce.running)',
            '            root.kbdBrightness = pct',
            '        }',
            '      }',
            '    }',
            '  }',
            "",
            '  Timer {',
            '    id: kbdBrightnessDebounce',
            '    interval: 120',
            '    repeat: false',
            '    onTriggered: root.setKbdBrightness(root.pendingKbdBrightness)',
            '  }',
            "",
            '  Process {',
            '    id: setKbdBrightnessProc',
            '    stdout: StdioCollector { waitForEnd: true }',
            '    onRunningChanged: {',
            '      if (running) return',
            '      if (root.kbdBrightnessSetQueued) {',
            '        root.setKbdBrightness(root.pendingKbdBrightness)',
            '      }',
            '    }',
            '  }',
        ])
        assert old_set_proc in mqml, "monitor/Panel.qml setBrightnessProc block not found"
        mqml = mqml.replace(old_set_proc, new_set_proc, 1)

        old_text_sep = "\n".join([
            '              HoverHandler {',
            '                onHoveredChanged: if (hovered) root.pointAt("brightness", -1)',
            '              }',
            '            }',
            '          }',
            "",
            '          // ---------- Text size ----------',
        ])
        new_text_sep = "\n".join([
            '              HoverHandler {',
            '                onHoveredChanged: if (hovered) root.pointAt("brightness", -1)',
            '              }',
            '            }',
            '          }',
            "",
            '          // ---------- Keyboard backlight ----------',
            '          PanelSeparator {',
            '            visible: root.kbdBrightness >= 0',
            '            foreground: root.bar.foreground',
            '          }',
            "",
            '          Column {',
            '            visible: root.kbdBrightness >= 0',
            '            width: parent.width',
            '            spacing: Style.space(6)',
            "",
            '            Item {',
            '              width: parent.width',
            '              implicitHeight: Math.max(kbdBrightnessHeader.implicitHeight, kbdBrightnessPercent.implicitHeight)',
            "",
            '              PanelSectionHeader {',
            '                id: kbdBrightnessHeader',
            '                text: "KEYBOARD BACKLIGHT"',
            '                foreground: root.bar.foreground',
            '                fontFamily: root.bar.fontFamily',
            '                anchors.left: parent.left',
            '                anchors.verticalCenter: parent.verticalCenter',
            '              }',
            "",
            '              Text {',
            '                id: kbdBrightnessPercent',
            '                textFormat: Text.PlainText',
            '                text: Commons.I18n.formatNumber(Math.round(kbdBrightnessSlider.dragging ? kbdBrightnessSlider.liveValue : Math.max(0, root.kbdBrightness))) + "%"',
            '                color: Qt.darker(root.bar.foreground, 1.4)',
            '                font.family: root.bar.fontFamily',
            '                font.pixelSize: Style.font.caption',
            '                font.bold: true',
            '                anchors.right: parent.right',
            '                anchors.rightMargin: Style.space(6)',
            '                anchors.verticalCenter: parent.verticalCenter',
            '              }',
            '            }',
            "",
            '            CursorSurface {',
            '              id: kbdBrightnessRow',
            '              width: parent.width',
            '              height: kbdBrightnessSlider.implicitHeight + Style.spacing.controlGap',
            '              hasCursor: root.cursorActive && root.focusSection === "kbdbacklight" && root.selectedIndex === -1',
            '              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(kbdBrightnessRow)',
            '              foreground: root.bar.foreground',
            '              outline: true',
            "",
            '              PanelSlider {',
            '                id: kbdBrightnessSlider',
            '                bar: root.bar',
            '                anchors.fill: parent',
            '                anchors.leftMargin: Style.space(6)',
            '                anchors.rightMargin: Style.space(6)',
            '                minimum: 0',
            '                maximum: 100',
            '                step: 1',
            '                value: Math.max(0, root.kbdBrightness)',
            '                integer: true',
            '                onMoved: function(v) { root.previewKbdBrightness(v) }',
            '                onReleased: function(v) {',
            '                  kbdBrightnessDebounce.stop()',
            '                  root.setKbdBrightness(v)',
            '                }',
            '                onRightClicked: root.toggleKbdBrightness()',
            '              }',
            "",
            '              HoverHandler {',
            '                onHoveredChanged: if (hovered) root.pointAt("kbdbacklight", -1)',
            '              }',
            '            }',
            '          }',
            "",
            '          // ---------- Text size ----------',
        ])
        assert old_text_sep in mqml, "monitor/Panel.qml Text size separator not found"
        mqml = mqml.replace(old_text_sep, new_text_sep, 1)

        mon_panel.write_text(mqml, encoding="utf-8")

    lock_svc = out / "shell" / "plugins" / "lock" / "Service.qml"
    if lock_svc.is_file():
        lqml = lock_svc.read_text(encoding="utf-8")

        old_blank = "\n".join([
            "  // A suspended PAM conversation may be orphaned by the daemon restart.",
            "  function restartFingerprintAfterSleep() {",
            "    noteFingerprintResumed()",
            "    if (fingerprintAuthenticating || fingerprintPam.active) {",
            "      if (fingerprintPam.active) fingerprintPam.abort()",
            "      settleFingerprintAttempt()",
            "      return",
            "    }",
            "    if (!fingerprintRetryTimer.running) return",
            "    armFingerprintRetry(FingerprintModel.MATCH_RETRY_MS)",
            "  }",
            "",
            "  function runBlank() {",
            "    pauseFingerprint()",
            "    if (!blankProcess.running) blankProcess.running = true",
            "  }",
        ])
        new_blank = "\n".join([
            "  // A suspended PAM conversation may be orphaned by the daemon restart.",
            "  function restartFingerprintAfterSleep() {",
            "    noteFingerprintResumed()",
            "    fingerprintPaused = false",
            "    armBlankTimer(idleBlankTimer.resumeMs)",
            "    if (fingerprintAuthenticating || fingerprintPam.active) {",
            "      if (fingerprintPam.active) fingerprintPam.abort()",
            "      settleFingerprintAttempt()",
            "      return",
            "    }",
            "    armFingerprintRetry(FingerprintModel.MATCH_RETRY_MS)",
            "  }",
            "",
            "  function runBlank() {",
            "    if (!blankProcess.running) blankProcess.running = true",
            "  }",
        ])
        assert old_blank in lqml, "lock/Service.qml restartFingerprintAfterSleep/runBlank block not found"
        lqml = lqml.replace(old_blank, new_blank, 1)

        old_settle = "\n".join([
            "    fingerprintLastSettleMs = now",
            "    armFingerprintRetry(FingerprintModel.retryDelayMs(fingerprintUnreachedStreak))",
            "  }",
        ])
        new_settle = "\n".join([
            "    fingerprintLastSettleMs = now",
            "    armFingerprintRetry(inGrace ? FingerprintModel.MATCH_RETRY_MS : FingerprintModel.retryDelayMs(fingerprintUnreachedStreak))",
            "  }",
        ])
        assert old_settle in lqml, "lock/Service.qml settleFingerprintAttempt retry block not found"
        lqml = lqml.replace(old_settle, new_settle, 1)

        old_pam = "\n".join([
            "  PamContext {",
            "    id: fingerprintPam",
            '    config: "omarchy-lock-fingerprint"',
            "    user: root.userName",
            "",
            "    onPamMessage: {",
            "      if (!messageIsError) root.noteFingerprintReachedDevice()",
            "    }",
        ])
        new_pam = "\n".join([
            "  PamContext {",
            "    id: fingerprintPam",
            '    config: "omarchy-lock-fingerprint"',
            "    user: root.userName",
            "",
            "    onPamMessage: {",
            "      var alreadyReached = root.fingerprintAttemptReachedDevice",
            "      if (!messageIsError) root.noteFingerprintReachedDevice()",
            '      if (alreadyReached && root.lockRequested && !/timed out/i.test(String(message || ""))) {',
            "        root.runWake()",
            "      }",
            "    }",
        ])
        assert old_pam in lqml, "lock/Service.qml fingerprintPam block not found"
        lqml = lqml.replace(old_pam, new_pam, 1)

        old_sleep_watch = "\n".join([
            "  // Detect resume both during an active attempt and during backoff.",
            "  Timer {",
            "    id: fingerprintSleepWatch",
            "    interval: 1000",
            "    repeat: true",
            "    running: root.lockRequested && root.fingerprintConfigured && (!root.fingerprintPaused || root.fingerprintAuthenticating)",
        ])
        new_sleep_watch = "\n".join([
            "  IdleMonitor {",
            "    id: lockActivityMonitor",
            "    enabled: root.lockRequested",
            "    timeout: 1",
            "    respectInhibitors: false",
            "    onIsIdleChanged: {",
            "      if (!isIdle && root.lockRequested) root.runWake()",
            "    }",
            "  }",
            "",
            "  // Detect resume both during an active attempt and during backoff.",
            "  Timer {",
            "    id: fingerprintSleepWatch",
            "    interval: 1000",
            "    repeat: true",
            "    running: root.lockRequested && root.fingerprintConfigured",
        ])
        assert old_sleep_watch in lqml, "lock/Service.qml fingerprintSleepWatch block not found"
        lqml = lqml.replace(old_sleep_watch, new_sleep_watch, 1)

        old_ipc = "\n".join([
            "  ShellIpc {",
            '    target: "lock"',
            "",
            "    function lock(): string {",
            '      if (!root.passwordPamConfigured) return "missing-pam"',
            "      // omarchy-system-sleep-lock asks for the lock before every suspend.",
            "      if (root.currentlyLocked()) root.noteSleepRequested()",
            '      if (!root.currentlyLocked() && !root.beginLock()) return "failed"',
            '      return "ok"',
            "    }",
        ])
        new_ipc = "\n".join([
            "  ShellIpc {",
            '    target: "lock"',
            "",
            "    function lock(): string {",
            '      if (!root.passwordPamConfigured) return "missing-pam"',
            "      // omarchy-system-sleep-lock asks for the lock before every suspend.",
            "      if (root.currentlyLocked()) root.noteSleepRequested()",
            '      if (!root.currentlyLocked() && !root.beginLock()) return "failed"',
            '      return "ok"',
            "    }",
            "",
            "    function wake(): string {",
            "      if (root.currentlyLocked()) root.runWake()",
            '      return "ok"',
            "    }",
            "",
            "    function resume(): string {",
            "      if (root.currentlyLocked()) {",
            "        root.restartFingerprintAfterSleep()",
            "        root.runWake()",
            "      }",
            '      return "ok"',
            "    }",
        ])
        assert old_ipc in lqml, "lock/Service.qml ShellIpc lock block not found"
        lqml = lqml.replace(old_ipc, new_ipc, 1)

        lock_svc.write_text(lqml, encoding="utf-8")
  '';

  omarchyShare =
    pkgs.runCommand "omarchy-share"
      {
        nativeBuildInputs = [
          pkgs.bash
          omarchyPython
        ];
      }
      ''
        mkdir -p "$out"

        cp -r --no-preserve=mode "${omarchySrc}/shell" "$out/shell"
        cp -r --no-preserve=mode "${omarchySrc}/config" "$out/config"
        cp -r --no-preserve=mode "${omarchySrc}/default" "$out/default"
        cp -r --no-preserve=mode "${omarchySrc}/bin" "$out/bin"
        if [ -d "${omarchySrc}/install/helpers" ]; then
          mkdir -p "$out/install"
          cp -r --no-preserve=mode "${omarchySrc}/install/helpers" "$out/install/helpers"
        fi

        mkdir -p "$out/themes"
        for theme_dir in "${omarchySrc}"/themes/*; do
          [ -d "$theme_dir" ] || continue
          name="$(basename "$theme_dir")"
          mkdir -p "$out/themes/$name"
          for entry in "$theme_dir"/*; do
            [ -e "$entry" ] || continue
            entry_name="$(basename "$entry")"
            if [ "$entry_name" = "backgrounds" ]; then
              continue
            fi
            cp -r --no-preserve=mode "$entry" "$out/themes/$name/$entry_name"
          done
        done

        ${lib.optionalString (marketplaceSrc != null) ''
          mkdir -p "$out/marketplace"
          cp --no-preserve=mode "${marketplaceSrc}/registry.json" "$out/marketplace/registry.json"
        ''}

        sed -i '1{/^\/\/@ pragma OmarchyLoadPatch$/d;}' "$out/shell/shell.qml"

        substituteInPlace "$out/shell/Commons/InputMethodState.qml" \
          --replace-fail 'command: ["/usr/bin/python3", Quickshell.env("OMARCHY_PATH") + "/default/input-methods/indicator.py"]' 'command: ["${fcitxIndicatorBin}/bin/fcitx-indicator"]'

        substituteInPlace "$out/shell/plugins/panels/elsewhen/Panel.qml" \
          --replace-fail '"/usr/share/zoneinfo/zone1970.tab"' '"${pkgs.tzdata}/share/zoneinfo/zone1970.tab"'

        substituteInPlace "$out/shell/plugins/panels/elsewhen/Model.js" \
          --replace-fail 'sudo -n timedatectl set-timezone "$1"' 'timedatectl --no-ask-password set-timezone "$1"'

        substituteInPlace "$out/bin/omarchy-menu-timezone" \
          --replace-fail 'sudo timedatectl set-timezone "$timezone"' 'timedatectl --no-ask-password set-timezone "$timezone"' \
          --replace-fail 'omarchy-shell -q omarchy.clock refresh' $'omarchy-shell -q omarchy.clock refresh\nomarchy-shell -q omarchy.elsewhen refresh || true'

        substituteInPlace "$out/shell/plugins/bar/widgets/Workspaces.qml" \
          --replace-fail 'var target = ids[Util.clamp(index - wheel.steps, 0, ids.length - 1)]' 'var target = ids[Util.clamp(index + wheel.steps, 0, ids.length - 1)]'

        substituteInPlace "$out/shell/plugins/menu/BarWidget.qml" \
          --replace-fail $'    text: "\\ue900"\n    fontFamily: "omarchy"' '    text: setting("icon", "\uf313")'

        substituteInPlace "$out/shell/Commons/Style.qml" \
          --replace-fail '    readonly property string menuFamily: root.menuFontFamily' $'    readonly property string menuFamily: root.menuFontFamily\n    readonly property int heroTitle: root.fontToken("hero-title", root.fontPx(1.5))'

        substituteInPlace "$out/shell/plugins/panels/clock/BarWidget.qml" \
          --replace-fail '    return date.toLocaleString(root.formatLocale, activeFormat.replace(/ww/g, week))' '    return date.toLocaleString(root.formatLocale, activeFormat.replace(/ww/g, week)).toLowerCase()'

        substituteInPlace "$out/shell/plugins/panels/clock/Panel.qml" \
          --replace-fail $'                font.family: root.contentFontFamily\n                font.pixelSize: 52\n                font.bold: true' $'                font.family: Style.font.menuFamily\n                font.pixelSize: 52\n                font.weight: Font.DemiBold'

        substituteInPlace "$out/shell/plugins/panels/elsewhen/HeroTitle.qml" \
          --replace-fail $'  component TitleWord: Text {\n    anchors.verticalCenter: parent.verticalCenter\n    textFormat: Text.PlainText\n    color: hero.foreground\n    font.family: hero.fontFamily\n    font.pixelSize: Style.font.title\n    font.weight: Font.DemiBold\n  }' $'  component TitleWord: Text {\n    anchors.verticalCenter: parent.verticalCenter\n    textFormat: Text.PlainText\n    color: hero.foreground\n    font.family: Style.font.menuFamily\n    font.pixelSize: Style.font.display\n    font.weight: Font.DemiBold\n  }'

        substituteInPlace "$out/shell/plugins/panels/weather/Panel.qml" \
          --replace-fail $'              font.family: root.bar.fontFamily\n              // Hero temperature read-out; deliberately oversized, outside\n              // the Style.font.* scale.\n              font.pixelSize: 56\n              font.bold: true' $'              font.family: Style.font.menuFamily\n              // Hero temperature read-out; deliberately oversized, outside\n              // the Style.font.* scale.\n              font.pixelSize: 56\n              font.weight: Font.DemiBold' \
          --replace-fail $'              text: root.current ? root.tempUnit : ""\n              color: root.bar.foreground\n              font.family: root.bar.fontFamily\n              font.pixelSize: Style.font.display' $'              text: root.current ? root.tempUnit : ""\n              color: root.bar.foreground\n              font.family: Style.font.menuFamily\n              font.pixelSize: Style.font.display'

        substituteInPlace "$out/shell/Ui/PanelHero.qml" \
          --replace-fail $'        color: root.foreground\n        font.family: root.fontFamily\n        font.pixelSize: Style.font.title\n        font.bold: true' $'        color: root.foreground\n        font.family: Style.font.menuFamily\n        font.pixelSize: Style.font.heroTitle\n        font.weight: Font.DemiBold'

        substituteInPlace "$out/shell/plugins/panels/audio/Panel.qml" \
          --replace-fail $'                text: Commons.I18n.t("audio.title")\n                textFormat: Text.PlainText\n                color: root.bar.foreground\n                font.family: root.bar.fontFamily\n                font.pixelSize: Style.font.title\n                font.bold: true' $'                text: Commons.I18n.t("audio.title")\n                textFormat: Text.PlainText\n                color: root.bar.foreground\n                font.family: Style.font.menuFamily\n                font.pixelSize: Style.font.heroTitle\n                font.weight: Font.DemiBold'

        substituteInPlace "$out/shell/plugins/panels/bluetooth/Panel.qml" \
          --replace-fail $'              text: Commons.I18n.t("bluetooth.title")\n              textFormat: Text.PlainText\n              color: root.bar.foreground\n              font.family: root.bar.fontFamily\n              font.pixelSize: Style.font.title\n              font.bold: true' $'              text: Commons.I18n.t("bluetooth.title")\n              textFormat: Text.PlainText\n              color: root.bar.foreground\n              font.family: Style.font.menuFamily\n              font.pixelSize: Style.font.heroTitle\n              font.weight: Font.DemiBold'

        substituteInPlace "$out/shell/plugins/panels/network/Panel.qml" \
          --replace-fail $'            text: heroSsid.detail !== "" ? heroSsid.title + " (" + heroSsid.detail + ")" : heroSsid.title\n            color: root.bar.foreground\n            font.family: root.bar.fontFamily\n            font.pixelSize: Style.font.title\n            font.bold: true' $'            text: heroSsid.detail !== "" ? heroSsid.title + " (" + heroSsid.detail + ")" : heroSsid.title\n            color: root.bar.foreground\n            font.family: Style.font.menuFamily\n            font.pixelSize: Style.font.heroTitle\n            font.weight: Font.DemiBold'

        substituteInPlace "$out/shell/plugins/panels/power/Panel.qml" \
          --replace-fail $'              text: Commons.I18n.t("power.battery")\n              textFormat: Text.PlainText\n              color: root.bar.foreground\n              font.family: root.bar.fontFamily\n              font.pixelSize: Style.font.title\n              font.bold: true' $'              text: Commons.I18n.t("power.battery")\n              textFormat: Text.PlainText\n              color: root.bar.foreground\n              font.family: Style.font.menuFamily\n              font.pixelSize: Style.font.heroTitle\n              font.weight: Font.DemiBold' \
          --replace-fail $'            id: heroPercent\n            textFormat: Text.PlainText\n            text: root.reading(root.batteryInfo.percentage) || "—"\n            color: root.bar.foreground\n            font.family: root.bar.fontFamily\n            font.pixelSize: Style.font.displayLarge\n            font.bold: true' $'            id: heroPercent\n            textFormat: Text.PlainText\n            text: root.reading(root.batteryInfo.percentage) || "—"\n            color: root.bar.foreground\n            font.family: Style.font.menuFamily\n            font.pixelSize: Style.font.displayLarge\n            font.weight: Font.DemiBold'

        substituteInPlace "$out/shell/plugins/panels/monitor/Panel.qml" \
          --replace-fail $'                text: root.current ? root.current.title : Commons.I18n.t("monitor.display")\n                textFormat: Text.PlainText\n                color: root.bar.foreground\n                font.family: root.bar.fontFamily\n                font.pixelSize: Style.font.title\n                font.bold: true' $'                text: root.current ? root.current.title : Commons.I18n.t("monitor.display")\n                textFormat: Text.PlainText\n                color: root.bar.foreground\n                font.family: Style.font.menuFamily\n                font.pixelSize: Style.font.heroTitle\n                font.weight: Font.DemiBold'

        substituteInPlace "$out/bin/omarchy-theme-set-browser" \
          --replace-fail 'omarchy-theme-set-browser-policy "''${THEME_HEX_COLOR#\#}" <&0 &' 'if [ "''${saw_any}" = "true" ]; then omarchy-theme-set-browser-policy "''${THEME_HEX_COLOR#\#}" <&0 & policy_pid=$!; else policy_pid=""; fi' \
          --replace-fail 'policy_pid=$!' ':' \
          --replace-fail 'wait "$policy_pid" || failed=1' 'if [ -n "$policy_pid" ]; then wait "$policy_pid" || failed=1; fi'

        substituteInPlace "$out/bin/omarchy-theme-set-gnome" \
          --replace-fail '"Adwaita-dark"' '"adw-gtk3-dark"' \
          --replace-fail '"Adwaita"' '"adw-gtk3"' \
          --replace-fail '"Yaru-blue"' '"MoreWaita"'

        substituteInPlace "$out/bin/omarchy-theme-set-foot" \
          --replace-fail '"$foot_ini" 2>/dev/null | tail -n 1)' '"$HOME/.config/foot/foot.ini" "$foot_ini" 2>/dev/null | tail -n 1)'

        substituteInPlace "$out/bin/omarchy-restart-terminal" \
          --replace-fail 'if pgrep -x ghostty >/dev/null; then' 'if pgrep -x "ghostty|\.ghostty-wrappe" >/dev/null 2>&1; then' \
          --replace-fail 'killall -SIGUSR2 ghostty' 'pkill -SIGUSR2 -x "ghostty|\.ghostty-wrappe" || true' \
          --replace-fail 'if pgrep -x kitty >/dev/null; then' 'if pgrep -x "kitty|\.kitty-wrapped" >/dev/null 2>&1; then' \
          --replace-fail 'killall -SIGUSR1 kitty >/dev/null' 'pkill -SIGUSR1 -x "kitty|\.kitty-wrapped" >/dev/null 2>&1 || true'

        substituteInPlace "$out/shell/plugins/services/nightlight/Service.qml" \
          --replace-fail 'uwsm-app -- hyprsunset' 'uwsm-app -- ${pkgs.hyprsunset}/bin/hyprsunset'

        substituteInPlace "$out/bin/omarchy-toggle-nightlight" \
          --replace-fail 'uwsm-app -- hyprsunset' 'uwsm-app -- ${pkgs.hyprsunset}/bin/hyprsunset'

        substituteInPlace "$out/bin/omarchy-capture-screenrecording" \
          --replace-fail 'if [[ $STATUS != "true" && ! -d $OUTPUT_DIR ]]; then' $'if [[ $STATUS != "true" && ! -d $OUTPUT_DIR && ( $OUTPUT_DIR == "$HOME" || $OUTPUT_DIR == "$HOME/"* ) ]]; then\n  mkdir -p "$OUTPUT_DIR" 2>/dev/null || true\nfi\nif [[ $STATUS != "true" && ! -d $OUTPUT_DIR ]]; then' \
          --replace-fail $'    local image_args=()\n    [[ -s $preview ]] && image_args=(--image "$preview")\n\n    omarchy-notification-send "$(omarchy-i18n capture.recordingSaved)" "$(recording_details "$filename")" \\\n      -t 10000 "''${image_args[@]}" \\\n      --action "$(omarchy-i18n capture.recordingOpen)" mpv -- \\\n      --action "$(omarchy-i18n capture.recordingCut)" omacut \\\n      --with "$filename"' $'    local image_args=() cut_args=()\n    [[ -s $preview ]] && image_args=(--image "$preview")\n    omarchy-cmd-present omacut && cut_args=(--action "$(omarchy-i18n capture.recordingCut)" omacut)\n\n    omarchy-notification-send "$(omarchy-i18n capture.recordingSaved)" "$(recording_details "$filename")" \\\n      -t 10000 "''${image_args[@]}" \\\n      --action "$(omarchy-i18n capture.recordingOpen)" mpv -- \\\n      "''${cut_args[@]}" \\\n      --with "$filename"'

        substituteInPlace "$out/bin/omarchy-menu-file" \
          --replace-fail $'for path in "''${paths[@]}"; do\n  [[ -e $path ]] || { echo "Path not found: $path" >&2; exit 1; }\ndone' $'existing_paths=()\nfor path in "''${paths[@]}"; do\n  [[ -e $path ]] && existing_paths+=("$path")\ndone\nif (( ''${#existing_paths[@]} == 0 )); then\n  echo "Path not found: ''${paths[0]}" >&2\n  exit 1\nfi\npaths=("''${existing_paths[@]}")'

        substituteInPlace "$out/bin/omarchy-clipboard-open" \
          --replace-fail '  exec omasnap --notify "$path"' $'  if command -v omasnap >/dev/null 2>&1; then\n    exec omasnap --notify "$path"\n  elif command -v satty >/dev/null 2>&1; then\n    exec satty --filename "$path" --copy-command wl-copy\n  else\n    exec imv -- "$path"\n  fi'

        chmod -R u+w "$out"
        cat > "$out/bin/omarchy-brightness-keyboard" <<'EOF'
        #!/usr/bin/env bash

        # omarchy:summary=Show or adjust keyboard backlight brightness.
        # omarchy:args=[--no-osd] <get|N%|up [step]|down [step]|cycle [step]|off|restore>

        no_osd=0
        if [[ ''${1:-} == "--no-osd" ]]; then
          no_osd=1
          shift
        fi

        direction="''${1:-up}"
        custom_step="''${2:-}"

        device=""
        for candidate in /sys/class/leds/*kbd_backlight*; do
          if [[ -e $candidate ]]; then
            device="$(basename "$candidate")"
            break
          fi
        done

        if [[ -z $device ]]; then
          [[ $direction == "get" || $direction == "--get" ]] && exit 1
          echo "No keyboard backlight device found" >&2
          exit 1
        fi

        max_brightness="$(brightnessctl -d "$device" max)"
        current_brightness="$(brightnessctl -d "$device" get)"
        (( max_brightness > 0 )) || exit 1
        current_pct=$(( (current_brightness * 100 + max_brightness / 2) / max_brightness ))
        (( current_pct > 100 )) && current_pct=100
        (( current_pct < 0 )) && current_pct=0

        if [[ $direction == "get" || $direction == "--get" ]]; then
          printf '%d\n' "$current_pct"
          exit 0
        fi

        saved="''${XDG_RUNTIME_DIR:-/tmp}/omarchy-brightness-keyboard-$device"

        if [[ $direction == "off" || $direction == "restore" ]]; then
          exec {lock_fd}>"$saved.lock" || exit 1
          flock "$lock_fd" || exit 1
        fi

        if [[ $direction == "off" ]]; then
          if [[ ! -s $saved ]]; then
            if [[ $current_brightness =~ ^[0-9]+$ ]] && ! echo "$current_brightness" >"$saved"; then
              rm -f "$saved"
            fi
          fi
          [[ -s $saved ]] && brightnessctl -d "$device" set 0 >/dev/null
          exit 0
        elif [[ $direction == "restore" ]]; then
          if [[ -f $saved ]]; then
            level="$(<"$saved")"
            if [[ ! $level =~ ^[0-9]+$ ]] || brightnessctl -d "$device" set "$level" >/dev/null; then
              rm -f "$saved"
            fi
          fi
          exit 0
        fi

        # Clear any stale idle-saved level when the user actively changes brightness.
        rm -f "$saved" 2>/dev/null || true

        step_pct=10
        if [[ $custom_step =~ ^[0-9]+%?$ ]]; then
          step_pct="''${custom_step%%%}"
          (( step_pct < 1 )) && step_pct=1
          (( step_pct > 100 )) && step_pct=100
        fi

        if [[ $direction =~ ^[0-9]+%?$ ]]; then
          target_pct="''${direction%%%}"
          (( target_pct > 100 )) && target_pct=100
          (( target_pct < 0 )) && target_pct=0
        elif [[ $direction == "cycle" ]]; then
          target_pct=$(( current_pct + step_pct ))
          (( target_pct > 100 )) && target_pct=0
        elif [[ $direction == "up" ]]; then
          target_pct=$(( current_pct + step_pct ))
          (( target_pct > 100 )) && target_pct=100
        else
          target_pct=$(( current_pct - step_pct ))
          (( target_pct < 0 )) && target_pct=0
        fi

        if (( max_brightness <= 10 )); then
          step_raw=$(( max_brightness * step_pct / 100 ))
          (( step_raw < 1 )) && step_raw=1
          if [[ $direction =~ ^[0-9]+%?$ ]]; then
            new_brightness=$(( (target_pct * max_brightness + 50) / 100 ))
          elif [[ $direction == "cycle" ]]; then
            new_brightness=$(( current_brightness + step_raw ))
            (( new_brightness > max_brightness )) && new_brightness=0
          elif [[ $direction == "up" ]]; then
            new_brightness=$(( current_brightness + step_raw ))
            (( new_brightness > max_brightness )) && new_brightness=$max_brightness
          else
            new_brightness=$(( current_brightness - step_raw ))
            (( new_brightness < 0 )) && new_brightness=0
          fi
          shown_pct=$(( (new_brightness * 100 + max_brightness / 2) / max_brightness ))
        else
          new_brightness=$(( (target_pct * max_brightness + 50) / 100 ))
          (( new_brightness > max_brightness )) && new_brightness=$max_brightness
          (( new_brightness < 0 )) && new_brightness=0
          shown_pct=$target_pct
        fi

        brightnessctl -d "$device" set "$new_brightness" >/dev/null
        (( no_osd )) || omarchy-osd -i keyboard -p "$shown_pct"
        EOF
        chmod 0755 "$out/bin/omarchy-brightness-keyboard"

        sed -i '/^exec omasnap /d' "$out/bin/omarchy-capture-screenshot"
        cat >> "$out/bin/omarchy-capture-screenshot" <<'EOF'
        if command -v omasnap >/dev/null 2>&1; then
          exec omasnap "''${omasnap_args[@]}"
        fi

        [[ -f ~/.config/user-dirs.dirs ]] && source ~/.config/user-dirs.dirs
        shot_dir="''${OMASNAP_SCREENSHOT_DIR:-''${OMARCHY_SCREENSHOT_DIR:-''${XDG_SCREENSHOTS_DIR:-''${XDG_PICTURES_DIR:-$HOME/Pictures}/Screenshots}}}"
        shot_mode="smart"
        shot_dest="both"
        shot_edit_first=0
        for arg in "$@"; do
          case "$arg" in
            smart|region|windows|fullscreen) shot_mode="$arg" ;;
            scroll) shot_mode="region" ;;
            copy) shot_dest="copy" ;;
            save) shot_dest="save" ;;
            --editor=*) shot_edit_first=1 ;;
          esac
        done

        raw_pick=$(omarchy-capture-region "$shot_mode" --keep-freeze) || exit 1
        freeze_pid="''${raw_pick%%$'\n'*}"
        selection="''${raw_pick#*$'\n'}"
        cleanup_shot_freeze() {
          [[ -n ''${freeze_pid:-} ]] && kill "$freeze_pid" 2>/dev/null || true
        }
        trap cleanup_shot_freeze EXIT
        [[ -n $selection ]] || exit 1

        tmp_png=$(mktemp "''${XDG_RUNTIME_DIR:-/tmp}/omarchy-screenshot-XXXXXX.png")
        grim -g "$selection" "$tmp_png" || { rm -f "$tmp_png"; exit 1; }
        cleanup_shot_freeze

        if (( shot_edit_first )) && command -v satty >/dev/null 2>&1; then
          mkdir -p "$shot_dir"
          out_file="$shot_dir/screenshot-$(date +'%Y-%m-%d_%H-%M-%S').png"
          satty --filename "$tmp_png" --output-filename "$out_file" --copy-command wl-copy
          rm -f "$tmp_png"
          exit 0
        fi

        if [[ $shot_dest == "copy" ]]; then
          wl-copy --type image/png < "$tmp_png"
          rm -f "$tmp_png"
          exit 0
        fi

        mkdir -p "$shot_dir"
        out_file="$shot_dir/screenshot-$(date +'%Y-%m-%d_%H-%M-%S').png"
        mv "$tmp_png" "$out_file"

        if [[ $shot_dest == "both" ]]; then
          wl-copy --type image/png < "$out_file"
          headline="$(omarchy-i18n capture.screenshotSavedCopied)"
        else
          headline="$(omarchy-i18n capture.screenshotSaved)"
        fi

        action_args=(--action "$(omarchy-i18n capture.screenshotOpen)" imv --)
        command -v satty >/dev/null 2>&1 && action_args+=(--action "$(omarchy-i18n capture.screenshotEdit)" satty --filename)
        omarchy-notification-send "$headline" "$out_file" \
          -t 10000 --image "$out_file" \
          "''${action_args[@]}" \
          --with "$out_file"
        EOF

        for f in "$out"/bin/* "$out/default/input-methods/typing_setup.py"; do
          [ -f "$f" ] || continue
          sed -i 's|/usr/bin/python3|${omarchyPython}/bin/python3|g' "$f"
        done

        # Allow declarative agent backends (e.g. `orb-agent-sync`) to intercept
        # `omarchy-agent*` calls inside Quickshell's wrapped PATH while keeping
        # `_OMARCHY_SKIP_AGENT_OVERRIDE=1` fallback to upstream scripts.
        ${omarchyPython}/bin/python3 "${patchAgentsPy}" "$out"

        find "$out/shell" -type f -name '*.sh' -exec chmod +x {} +
        find "$out/bin" -type f -exec chmod +x {} +
        patchShebangs "$out/shell" "$out/bin"
      '';
in
pkgs.runCommandCC "omarchy-shell"
  {
    nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
    passthru = {
      sharePath = omarchyShare;
    };
    meta = {
      description = "Omarchy Quickshell desktop runtime, theme engine, and plugin manager packaged for NixOS";
      mainProgram = "omarchy-shell";
      platforms = lib.platforms.linux;
    };
  }
  ''
    mkdir -p "$out/bin" "$out/share/fonts/truetype/omarchy"
    ln -s "${omarchyShare}" "$out/share/omarchy"

    if [ -f "${omarchySrc}/default/fonts/omarchy/omarchy.ttf" ]; then
      cp "${omarchySrc}/default/fonts/omarchy/omarchy.ttf" "$out/share/fonts/truetype/omarchy/omarchy.ttf"
    fi

    # Compile zero-fork native IPC client directly as `$out/bin/omarchy-shell`
    $CC -O2 -Wall -Wextra \
      -DDEFAULT_OMARCHY_PATH="\"${omarchyShare}\"" \
      -DDEFAULT_QS_BIN="\"$out/bin/qs\"" \
      "${./omarchy-shell-fast/omarchy-shell-ipc.c}" \
      -o "$out/bin/omarchy-shell"

    # glib's gsettings only honours GSETTINGS_SCHEMA_DIR here, so point it at the
    # gsettings-desktop-schemas store layout that omarchy-theme-set-gnome needs.
    gsettings_schema_dir="$(echo "${pkgs.gsettings-desktop-schemas}"/share/gsettings-schemas/*/glib-2.0/schemas)"
    for script in "$out/share/omarchy/bin"/*; do
      [ -f "$script" ] || continue
      script_name="$(basename "$script")"
      [ "$script_name" = "omarchy-shell" ] && continue
      makeWrapper "$script" "$out/bin/$script_name" \
        --set-default OMARCHY_PATH "${omarchyShare}" \
        --prefix PATH : "$out/bin:${omarchyRuntimePath}" \
        --prefix GI_TYPELIB_PATH : "${pkgs.glib.out}/lib/girepository-1.0" \
        --prefix QT_PLUGIN_PATH : "${pkgs.qt6.qtimageformats}/lib/qt-6/plugins" \
        --set-default GSETTINGS_SCHEMA_DIR "$gsettings_schema_dir" \
        --prefix GIO_EXTRA_MODULES : "${pkgs.dconf.lib}/lib/gio/modules" \
        --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share"
    done

    makeWrapper "${pkgs.quickshell}/bin/quickshell" "$out/bin/quickshell" \
      --prefix GI_TYPELIB_PATH : "${pkgs.glib.out}/lib/girepository-1.0" \
      --prefix QT_PLUGIN_PATH : "${pkgs.qt6.qtimageformats}/lib/qt-6/plugins"
    if [ -x "${pkgs.quickshell}/bin/qs" ]; then
      makeWrapper "${pkgs.quickshell}/bin/qs" "$out/bin/qs" \
        --prefix GI_TYPELIB_PATH : "${pkgs.glib.out}/lib/girepository-1.0" \
        --prefix QT_PLUGIN_PATH : "${pkgs.qt6.qtimageformats}/lib/qt-6/plugins"
    else
      ln -s "$out/bin/quickshell" "$out/bin/qs"
    fi
  ''
