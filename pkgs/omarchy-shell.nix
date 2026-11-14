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
    pkgs.gtk3
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gum
    pkgs.hyprland
    pkgs.hyprpicker
    pkgs.hyprsunset
    pkgs.imagemagick
    pkgs.imv
    pkgs.inotify-tools
    pkgs.iproute2
    pkgs.iw
    pkgs.jq
    pkgs.libnotify
    pkgs.libxkbcommon
    pkgs.mpv-unwrapped
    pkgs.networkmanager
    pkgs.openssh
    pkgs.power-profiles-daemon
    pkgs.procps
    pkgs.psmisc
    pkgs.pulseaudio
    omarchyPython
    pkgs.qrencode
    pkgs.quickshell
    pkgs.ripgrep
    pkgs.satty
    pkgs.slurp
    pkgs.socat
    pkgs.systemd
    omarchyTesseract
    pkgs.upower
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
        old_prov = '  readonly property var providers: dragProviders !== null ? dragProviders : usage.panelProviders'
        new_prov = "\n".join([
            '  readonly property bool minimalHud: (settings && settings.minimalHud !== undefined) ? settings.minimalHud === true : providers.some(function(p) { return p.orbManaged === true })',
            '  readonly property var providers: dragProviders !== null ? dragProviders : usage.panelProviders',
        ])
        assert old_prov in qml, "Panel.qml providers property not found"
        qml = qml.replace(old_prov, new_prov, 1)

        old_acct_keys = "\n".join([
            '        for (var a = 0; a < accounts.length; a++, entry++) {',
            '          var row = []',
            '          if (needsSignIn(accounts[a])) row.push({ kind: "signin", index: entry })',
            '          if (!accounts[a].active) {',
            '            row.push({ kind: "autoswitch", index: entry })',
            '            row.push({ kind: "account", index: entry })',
            '          }',
            '          if (row.length > 0) rows.push(row)',
            '        }',
        ])
        new_acct_keys = "\n".join([
            '        for (var a = 0; a < accounts.length; a++, entry++) {',
            '          var row = []',
            '          var lapsed = authLapsed(accounts[a])',
            '          if (lapsed && supportsSignIn(providers[p])) row.push({ kind: "signin", index: entry })',
            '          if (!accounts[a].active && !lapsed) {',
            '            if (usableAccountsCount(providers[p]) >= 2) row.push({ kind: "autoswitch", index: entry })',
            '            row.push({ kind: "account", index: entry })',
            '          }',
            '          if (row.length > 0) rows.push(row)',
            '        }',
        ])
        assert old_acct_keys in qml, "Panel.qml account keyRows block not found"
        qml = qml.replace(old_acct_keys, new_acct_keys, 1)

        old_starter_keys = "\n".join([
            '      if (!blankSlate) {',
            '        var tiles = []',
        ])
        new_starter_keys = "\n".join([
            '      if (!blankSlate && !minimalHud) {',
            '        var tiles = []',
        ])
        assert old_starter_keys in qml, "Panel.qml starter keyRows block not found"
        qml = qml.replace(old_starter_keys, new_starter_keys, 1)

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

        old_use_fn = "\n".join([
            '  function useAccount(p, account) {',
            '    if (!p || !account || account.active) return',
            '    Util.execArgv(["omarchy-agent-account-use", p.providerId, String(account.id)])',
            '  }',
        ])
        new_use_fn = "\n".join([
            '  function usableAccountsCount(p) {',
            '    var list = providerAccounts(p)',
            '    var n = 0',
            '    for (var i = 0; i < list.length; i++)',
            '      if (!authLapsed(list[i])) n++',
            '    return n',
            '  }',
            "",
            '  function useAccount(p, account) {',
            '    if (!p || !account || account.active || authLapsed(account)) return',
            '    Util.execArgv(["omarchy-agent-account-use", p.providerId, String(account.id)])',
            '  }',
        ])
        assert old_use_fn in qml, "Panel.qml useAccount block not found"
        qml = qml.replace(old_use_fn, new_use_fn, 1)

        old_sw_fn = "\n".join([
            '  function setSwitchMode(p, mode) {',
            '    if (!p || providerAccounts(p).length < 2 || mode === (autoSwitchFor(p) ? "auto" : "manual")) return',
        ])
        new_sw_fn = "\n".join([
            '  function setSwitchMode(p, mode) {',
            '    if (!p || providerAccounts(p).length < 2 || (mode === "auto" && usableAccountsCount(p) < 2) || mode === (autoSwitchFor(p) ? "auto" : "manual")) return',
        ])
        assert old_sw_fn in qml, "Panel.qml setSwitchMode block not found"
        qml = qml.replace(old_sw_fn, new_sw_fn, 1)

        old_sup = "\n".join([
            '  function supportsSignIn(p) {',
            '    for (var i = 0; i < addProviders.length; i++)',
            '      if (p && addProviders[i].providerId === p.providerId) return true',
            '    return false',
            '  }',
            "",
            '  // A lapsed or missing sign-in is something you can fix from here; any other',
            '  // trouble is only reported.',
            '  function needsSignIn(item) {',
            '    if (item && item.providerId && !supportsSignIn(item)) return false',
            '    var status = String(item && item.usageStatusText || "")',
            '    return status === "Sign-in expired" || status === "Waiting for auth"',
            '  }',
            "",
            '  // Whatever keeps the numbers from being current, said beside the last ones',
            '  // known: they stay on show until a check succeeds again. A failed refresh',
            '  // with numbers kept may leave the status empty and say why only in its help.',
            '  function usageNote(item) {',
            '    if (!item || needsSignIn(item)) return ""',
        ])
        new_sup = "\n".join([
            '  function supportsSignIn(p) {',
            '    if (p && p.orbSignIn === true) return true',
            '    if (root.minimalHud) return false',
            '    for (var i = 0; i < addProviders.length; i++)',
            '      if (p && addProviders[i].providerId === p.providerId) return true',
            '    return false',
            '  }',
            "",
            '  function authLapsed(item) {',
            '    var status = String(item && item.usageStatusText || "")',
            '    return status === "Sign-in expired" || status === "Waiting for auth"',
            '  }',
            "",
            '  // A lapsed or missing sign-in is something you can fix from here; any other',
            '  // trouble is only reported.',
            '  function needsSignIn(item, owner) {',
            '    if (!authLapsed(item)) return false',
            '    return supportsSignIn(owner || item)',
            '  }',
            "",
            '  // Whatever keeps the numbers from being current, said beside the last ones',
            '  // known: they stay on show until a check succeeds again. A failed refresh',
            '  // with numbers kept may leave the status empty and say why only in its help.',
            '  function usageNote(item) {',
            '    if (!item || needsSignIn(item)) return ""',
        ])
        assert old_sup in qml, "Panel.qml supportsSignIn/needsSignIn block not found"
        qml = qml.replace(old_sup, new_sup, 1)

        old_harness = "\n".join([
            '  function harnessFor(provider) {',
            '    return provider && harnesses[provider.providerId] ? harnesses[provider.providerId] : ""',
            '  }',
        ])
        new_harness = "\n".join([
            '  function harnessFor(provider) {',
            '    if (root.minimalHud) return ""',
            '    return provider && harnesses[provider.providerId] ? harnesses[provider.providerId] : ""',
            '  }',
        ])
        assert old_harness in qml, "Panel.qml harnessFor block not found"
        qml = qml.replace(old_harness, new_harness, 1)

        old_hero_phrase = "\n".join([
            '  readonly property string heroPhrase: addStage !== "" || blankSlate',
            '    ? addHeading',
            '    : (shownPhrase !== "" ? shownPhrase : Commons.I18n.t("agents.subscriptions"))',
        ])
        new_hero_phrase = "\n".join([
            '  readonly property string heroPhrase: (addStage !== "" && (!minimalHud || addStage !== "pick")) || (!minimalHud && blankSlate)',
            '    ? addHeading',
            '    : (blankSlate ? "Connect providers in Orb Desktop" : (shownPhrase !== "" ? shownPhrase : Commons.I18n.t("agents.subscriptions")))',
        ])
        assert old_hero_phrase in qml, "Panel.qml heroPhrase block not found"
        qml = qml.replace(old_hero_phrase, new_hero_phrase, 1)

        old_picking = "\n".join([
            '  readonly property bool picking: addStage === "pick" || (blankSlate && addStage === "")',
            '  // The + in the hero turns into the X that leaves adding. A first setup has',
            '  // nothing to go back to until an agent is chosen.',
            '  readonly property bool addButtonShown: !blankSlate || !picking',
        ])
        new_picking = "\n".join([
            '  readonly property bool picking: !minimalHud && (addStage === "pick" || (blankSlate && addStage === ""))',
            '  // The + in the hero turns into the X that leaves adding. A first setup has',
            '  // nothing to go back to until an agent is chosen.',
            '  readonly property bool addButtonShown: minimalHud ? addStage !== "" : (!blankSlate || !picking)',
        ])
        assert old_picking in qml, "Panel.qml picking/addButtonShown block not found"
        qml = qml.replace(old_picking, new_picking, 1)

        old_open_chk = '    if (usage.enabledProviders.length === 0 && !checkProcess.running) checkProcess.running = true'
        new_open_chk = '    if (!minimalHud && usage.enabledProviders.length === 0 && !checkProcess.running) checkProcess.running = true'
        assert old_open_chk in qml, "Panel.qml checkProcess open trigger not found"
        qml = qml.replace(old_open_chk, new_open_chk, 1)

        old_rclick = '      if (buttonCode === Qt.RightButton) root.launchAgent()'
        new_rclick = '      if (buttonCode === Qt.RightButton) { if (root.minimalHud) root.refreshNow(); else root.launchAgent() }'
        assert old_rclick in qml, "Panel.qml right-click launch not found"
        qml = qml.replace(old_rclick, new_rclick, 1)

        old_add_view = "\n".join([
            '          AddView {',
            '            visible: root.addStage !== "" || root.blankSlate',
        ])
        new_add_view = "\n".join([
            '          AddView {',
            '            visible: (root.addStage !== "" && (!root.minimalHud || root.addStage !== "pick")) || (!root.minimalHud && root.blankSlate)',
        ])
        assert old_add_view in qml, "Panel.qml AddView block not found"
        qml = qml.replace(old_add_view, new_add_view, 1)

        old_make = "\n".join([
            '          // ---------- Make something ----------',
            '          PanelSeparator {',
            '            visible: root.addStage === "" && !root.blankSlate',
            '            foreground: root.foreground',
            '          }',
            "",
            '          Column {',
            '            visible: root.addStage === "" && !root.blankSlate',
        ])
        new_make = "\n".join([
            '          // ---------- Make something ----------',
            '          PanelSeparator {',
            '            visible: !root.minimalHud && root.addStage === "" && !root.blankSlate',
            '            foreground: root.foreground',
            '          }',
            "",
            '          Column {',
            '            visible: !root.minimalHud && root.addStage === "" && !root.blankSlate',
        ])
        assert old_make in qml, "Panel.qml Make something block not found"
        qml = qml.replace(old_make, new_make, 1)

        old_acct_head = "\n".join([
            '    readonly property bool isActive: account.active === true',
            '    readonly property bool autoOn: root.autoSwitchFor(owner)',
            "    // Which of the row's links the keyboard is on, when it's on this row.",
            '    readonly property string pickedKind: picked && root.keyTarget ? root.keyTarget.kind : ""',
            '    readonly property string label: renamedTo !== "" ? renamedTo : String(account.label || account.id || "")',
            "",
            '    onAccountChanged: renamedTo = ""',
            '    onEditingChanged: root.renaming = editing',
            '    onPickedChanged: if (picked) root.revealItem(head)',
            "",
            "    // Anywhere on the line counts, so Use can show up when it's hidden.",
            '    HoverHandler { id: useHover }',
            '    implicitHeight: Math.max(headText.implicitHeight, headAction.implicitHeight)',
            "",
            '    function startRename() {',
            '      editing = true',
            '      nameField.text = label',
            '      nameField.forceActiveFocus()',
            '      nameField.selectAll()',
            '    }',
            "",
            '    function finishRename(save) {',
            '      if (!editing) return',
            '      var value = nameField.text.trim()',
            '      editing = false',
            '      root.focusKeys()',
            '      if (save && value !== "" && value !== label) {',
            '        renamedTo = value',
            '        root.renameAccount(owner, account, value)',
            '      }',
            '    }',
            "",
            '    // One line: the name, then its plan and any caveats, quieter. The',
            "    // email is the name's tooltip.",
            '    Item {',
            '      id: headText',
            '      anchors.left: parent.left',
            '      anchors.right: headAction.left',
            '      anchors.rightMargin: Style.spacing.sm',
            '      implicitHeight: head.editing ? nameField.implicitHeight : nameText.implicitHeight',
            "",
            '      Text {',
            '        id: nameText',
            '        textFormat: Text.PlainText',
            '        visible: !head.editing',
            '        anchors.left: parent.left',
            '        anchors.verticalCenter: parent.verticalCenter',
            '        width: Math.min(implicitWidth, parent.width * 0.6)',
            '        text: head.label',
            '        color: head.picked ? Commons.Color.accent : root.foreground',
            '        font.family: root.fontFamily',
            '        font.pixelSize: Style.font.body',
            '        font.bold: head.isActive',
            '        font.underline: nameMouse.containsMouse',
            '        elide: Text.ElideRight',
            "",
            '        MouseArea {',
            '          id: nameMouse',
            '          anchors.fill: parent',
            '          hoverEnabled: true',
            '          cursorShape: Qt.IBeamCursor',
            '          onClicked: head.startRename()',
            '        }',
            "",
            '        PanelToolTip {',
            '          visible: nameMouse.containsMouse && String(head.account.email || "") !== ""',
            '          text: String(head.account.email || "")',
            '        }',
            '      }',
            "",
            '      // Bounded by the actions on the right: the plan shortens first, and the',
            '      // Sign-in required link keeps its whole width.',
            '      Row {',
            '        id: detailRow',
            '        visible: !head.editing',
            '        anchors.left: nameText.right',
            '        anchors.leftMargin: Style.space(8)',
            '        anchors.verticalCenter: nameText.verticalCenter',
            '        width: Math.max(0, parent.width - nameText.width - Style.space(8))',
            '        spacing: Style.space(8)',
            "",
            '        Text {',
            '          textFormat: Text.PlainText',
            '          visible: text !== ""',
            '          width: Math.max(0, Math.min(implicitWidth, detailRow.width',
            '            - (accountNote.visible ? accountNote.implicitWidth + detailRow.spacing : 0)',
            '            - (signInDot.visible ? signInDot.implicitWidth + detailRow.spacing : 0)',
            '            - (signInLink.visible ? signInLink.implicitWidth + detailRow.spacing : 0)))',
            '          elide: Text.ElideRight',
            '          text: {',
            '            var detail = root.accountDetail(head.account)',
            '            return detail !== "" ? "· " + detail : ""',
            '          }',
            '          color: root.dim',
            '          font.family: root.fontFamily',
            '          font.pixelSize: Style.font.caption',
            '        }',
            "",
            '        UsageNote {',
            '          id: accountNote',
            '          record: head.account',
            '        }',
            "",
            '        // The dot is punctuation, not part of the link.',
            '        Text {',
            '          id: signInDot',
            '          visible: root.needsSignIn(head.account)',
            '          text: "·"',
            '          color: root.dim',
            '          font.family: root.fontFamily',
            '          font.pixelSize: Style.font.caption',
            '        }',
            "",
            '        TextLink {',
            '          id: signInLink',
            '          visible: root.needsSignIn(head.account)',
            '          picked: head.pickedKind === "signin"',
            '          text: Commons.I18n.t("agents.signInRequired")',
            '          idleColor: root.urgent',
            '          tooltip: Commons.I18n.t("agents.signInAgainAccount")',
            '          onClicked: root.signInAgain(head.owner, head.account)',
            '        }',
            '      }',
            "",
            '      TextField {',
            '        id: nameField',
            '        visible: head.editing',
            '        anchors.left: parent.left',
            '        anchors.right: parent.right',
            '        anchors.verticalCenter: parent.verticalCenter',
            '        foreground: root.foreground',
            '        font.family: root.fontFamily',
            '        font.pixelSize: Style.font.body',
            '        horizontalPadding: Style.space(4)',
            '        verticalPadding: Style.space(1)',
            '        onAccepted: head.finishRename(true)',
            '        onActiveFocusChanged: if (!activeFocus) head.finishRename(false)',
            '        Keys.onEscapePressed: function(event) {',
            '          head.finishRename(false)',
            '          event.accepted = true',
            '        }',
            '      }',
            '    }',
            "",
            '    Item {',
            '      id: headAction',
            '      anchors.right: parent.right',
            '      anchors.top: parent.top',
            '      implicitWidth: head.isActive ? headActive.implicitWidth : useRow.implicitWidth',
            '      implicitHeight: head.isActive ? headActive.implicitHeight : useRow.implicitHeight',
            "",
            '      Text {',
            '        id: headActive',
            '        visible: head.isActive',
            '        anchors.right: parent.right',
            '        text: Commons.I18n.t("agents.active")',
            '        textFormat: Text.PlainText',
            '        color: Commons.Color.accent',
            '        font.family: root.fontFamily',
            '        font.pixelSize: Style.font.caption',
            '        font.bold: true',
            '      }',
            "",
            '      // Switching now is Use. Hovering it also offers Autoswitch: move new',
            '      // sessions over by themselves once the active account reaches the',
            "      // threshold. While that's on it stays in view in place of Use, and",
            '      // clicking it again goes back to only being notified.',
            '      Row {',
            '        id: useRow',
            '        visible: !head.isActive',
            '        anchors.right: parent.right',
            '        spacing: Style.space(12)',
            "",
            '        TextLink {',
            '          visible: head.autoOn || useHover.hovered || head.picked',
            '          text: Commons.I18n.t("agents.autoswitch") + (head.pickedKind === "autoswitch" ? " ⏎" : "")',
            '          picked: head.pickedKind === "autoswitch"',
            '          current: head.autoOn',
            '          tooltip: head.autoOn',
            '            ? Commons.I18n.t("agents.stopAutoSwitch")',
            '            : Commons.I18n.t("agents.switchAutoAt").arg(Commons.I18n.formatNumber(root.switchThreshold(head.owner)))',
            '          onClicked: root.setSwitchMode(head.owner, head.autoOn ? "manual" : "auto")',
            '        }',
            "",
            '        // With Autoswitch on, Use waits until the line is hovered or picked.',
            '        TextLink {',
            '          visible: !head.autoOn || useHover.hovered || head.picked',
            '          text: Commons.I18n.t("agents.use") + (head.pickedKind === "account" ? " ⏎" : "")',
            '          picked: head.pickedKind === "account"',
            '          onClicked: root.useAccount(head.owner, head.account)',
            '        }',
            '      }',
            '    }',
        ])
        new_acct_head = "\n".join([
            '    readonly property bool isActive: account.active === true',
            '    readonly property bool lapsed: root.authLapsed(account)',
            '    readonly property bool canSignIn: lapsed && root.supportsSignIn(owner)',
            '    readonly property bool canSwitchTo: !isActive && !lapsed',
            '    readonly property bool hasFailoverPeer: root.usableAccountsCount(owner) >= 2',
            '    readonly property bool autoOn: root.autoSwitchFor(owner) && hasFailoverPeer',
            "    // Which of the row's links the keyboard is on, when it's on this row.",
            '    readonly property string pickedKind: picked && root.keyTarget ? root.keyTarget.kind : ""',
            '    readonly property string label: renamedTo !== "" ? renamedTo : String(account.label || account.id || "")',
            "",
            '    onAccountChanged: renamedTo = ""',
            '    onEditingChanged: root.renaming = editing',
            '    onPickedChanged: if (picked) root.revealItem(head)',
            "",
            "    // Anywhere on a switchable line counts, so Use/Autoswitch can show up on hover.",
            '    HoverHandler { id: useHover; enabled: head.canSwitchTo }',
            '    implicitHeight: Math.max(headText.implicitHeight, headAction.visible ? headAction.implicitHeight : 0)',
            "",
            '    function startRename() {',
            '      if (root.minimalHud) return',
            '      editing = true',
            '      nameField.text = label',
            '      nameField.forceActiveFocus()',
            '      nameField.selectAll()',
            '    }',
            "",
            '    function finishRename(save) {',
            '      if (!editing) return',
            '      var value = nameField.text.trim()',
            '      editing = false',
            '      root.focusKeys()',
            '      if (save && value !== "" && value !== label) {',
            '        renamedTo = value',
            '        root.renameAccount(owner, account, value)',
            '      }',
            '    }',
            "",
            '    // One line: the name, then its plan and any caveats, quieter. The',
            "    // email is the name's tooltip.",
            '    Item {',
            '      id: headText',
            '      anchors.left: parent.left',
            '      anchors.right: headAction.visible ? headAction.left : parent.right',
            '      anchors.rightMargin: headAction.visible ? Style.spacing.sm : 0',
            '      clip: true',
            '      implicitHeight: head.editing ? nameField.implicitHeight : nameText.implicitHeight',
            '      readonly property string detailStr: {',
            '        var detail = root.accountDetail(head.account)',
            '        return detail !== "" ? "· " + detail : ""',
            '      }',
            '      readonly property real fixedBadgesWidth:',
            '        (accountNote.visible ? accountNote.implicitWidth + detailRow.spacing : 0)',
            '        + (signInDot.visible ? signInDot.implicitWidth + detailRow.spacing : 0)',
            '        + (signInLink.visible ? signInLink.implicitWidth : 0)',
            '        + (signInStatic.visible ? signInStatic.implicitWidth : 0)',
            '      readonly property real maxNameWidth: {',
            '        if (fixedBadgesWidth > 0) {',
            '          var avail = Math.max(Style.space(48), width - fixedBadgesWidth - Style.space(10))',
            '          return detailStr !== "" ? Math.min(avail, width * 0.6) : avail',
            '        }',
            '        return detailStr !== "" ? width * 0.6 : width',
            '      }',
            "",
            '      Text {',
            '        id: nameText',
            '        textFormat: Text.PlainText',
            '        visible: !head.editing',
            '        anchors.left: parent.left',
            '        anchors.verticalCenter: parent.verticalCenter',
            '        width: Math.min(implicitWidth, Math.max(0, headText.maxNameWidth))',
            '        text: head.label',
            '        color: head.picked ? Commons.Color.accent : root.foreground',
            '        font.family: root.fontFamily',
            '        font.pixelSize: Style.font.body',
            '        font.bold: head.isActive',
            '        font.underline: !root.minimalHud && nameMouse.containsMouse',
            '        elide: Text.ElideRight',
            "",
            '        MouseArea {',
            '          id: nameMouse',
            '          anchors.fill: parent',
            '          hoverEnabled: true',
            '          cursorShape: root.minimalHud ? Qt.ArrowCursor : Qt.IBeamCursor',
            '          onClicked: head.startRename()',
            '        }',
            "",
            '        PanelToolTip {',
            '          visible: nameMouse.containsMouse && String(head.account.email || "") !== ""',
            '          text: String(head.account.email || "")',
            '        }',
            '      }',
            "",
            '      // Bounded by the actions on the right: the plan shortens first, and',
            '      // Sign-in required never overflows onto Autoswitch/Use/ACTIVE.',
            '      Row {',
            '        id: detailRow',
            '        visible: !head.editing && (planText.visible || accountNote.visible || head.lapsed)',
            '        anchors.left: nameText.right',
            '        anchors.leftMargin: Style.space(8)',
            '        anchors.verticalCenter: nameText.verticalCenter',
            '        width: Math.max(0, parent.width - nameText.width - Style.space(8))',
            '        spacing: Style.space(8)',
            "",
            '        Text {',
            '          id: planText',
            '          textFormat: Text.PlainText',
            '          visible: text !== ""',
            '          width: Math.max(0, Math.min(implicitWidth, detailRow.width',
            '            - headText.fixedBadgesWidth',
            '            - (headText.fixedBadgesWidth > 0 ? detailRow.spacing : 0)))',
            '          elide: Text.ElideRight',
            '          text: headText.detailStr',
            '          color: root.dim',
            '          font.family: root.fontFamily',
            '          font.pixelSize: Style.font.caption',
            '        }',
            "",
            '        UsageNote {',
            '          id: accountNote',
            '          visible: !head.lapsed && message !== ""',
            '          record: head.account',
            '        }',
            "",
            '        // The dot is punctuation, not part of the link.',
            '        Text {',
            '          id: signInDot',
            '          visible: head.lapsed',
            '          text: "·"',
            '          color: root.dim',
            '          font.family: root.fontFamily',
            '          font.pixelSize: Style.font.caption',
            '        }',
            "",
            '        TextLink {',
            '          id: signInLink',
            '          visible: head.canSignIn',
            '          width: Math.min(implicitWidth, Math.max(0, detailRow.width - (signInDot.visible ? signInDot.implicitWidth + detailRow.spacing : 0)))',
            '          elide: Text.ElideRight',
            '          picked: head.pickedKind === "signin"',
            '          text: Commons.I18n.t("agents.signInRequired")',
            '          idleColor: root.urgent',
            '          tooltip: (String(head.account.authHelpText || "") !== "" ? String(head.account.authHelpText) + " — " : "") + Commons.I18n.t("agents.signInAgainAccount")',
            '          onClicked: root.signInAgain(head.owner, head.account)',
            '        }',
            "",
            '        Text {',
            '          id: signInStatic',
            '          visible: head.lapsed && !head.canSignIn',
            '          width: Math.min(implicitWidth, Math.max(0, detailRow.width - (signInDot.visible ? signInDot.implicitWidth + detailRow.spacing : 0)))',
            '          elide: Text.ElideRight',
            '          textFormat: Text.PlainText',
            '          text: Commons.I18n.t("agents.signInRequired")',
            '          color: root.urgent',
            '          font.family: root.fontFamily',
            '          font.pixelSize: Style.font.caption',
            '          HoverHandler { id: staticSignInHover }',
            '          PanelToolTip {',
            '            visible: staticSignInHover.hovered && String(head.account.authHelpText || "") !== ""',
            '            text: String(head.account.authHelpText || "")',
            '          }',
            '        }',
            '      }',
            "",
            '      TextField {',
            '        id: nameField',
            '        visible: head.editing',
            '        anchors.left: parent.left',
            '        anchors.right: parent.right',
            '        anchors.verticalCenter: parent.verticalCenter',
            '        foreground: root.foreground',
            '        font.family: root.fontFamily',
            '        font.pixelSize: Style.font.body',
            '        horizontalPadding: Style.space(4)',
            '        verticalPadding: Style.space(1)',
            '        onAccepted: head.finishRename(true)',
            '        onActiveFocusChanged: if (!activeFocus) head.finishRename(false)',
            '        Keys.onEscapePressed: function(event) {',
            '          head.finishRename(false)',
            '          event.accepted = true',
            '        }',
            '      }',
            '    }',
            "",
            '    Item {',
            '      id: headAction',
            '      visible: head.isActive || head.canSwitchTo',
            '      anchors.right: parent.right',
            '      anchors.verticalCenter: parent.verticalCenter',
            '      implicitWidth: head.isActive ? headActive.implicitWidth : (head.canSwitchTo ? useRow.implicitWidth : 0)',
            '      implicitHeight: head.isActive ? headActive.implicitHeight : (head.canSwitchTo ? useRow.implicitHeight : 0)',
            "",
            '      Text {',
            '        id: headActive',
            '        visible: head.isActive',
            '        anchors.right: parent.right',
            '        text: Commons.I18n.t("agents.active")',
            '        textFormat: Text.PlainText',
            '        color: Commons.Color.accent',
            '        font.family: root.fontFamily',
            '        font.pixelSize: Style.font.caption',
            '        font.bold: true',
            '      }',
            "",
            '      // Switching now is Use. Hovering it also offers Autoswitch when at least',
            '      // two healthy accounts exist; unauthenticated accounts never show Use or Autoswitch.',
            '      Row {',
            '        id: useRow',
            '        visible: head.canSwitchTo',
            '        anchors.right: parent.right',
            '        spacing: Style.space(12)',
            "",
            '        TextLink {',
            '          visible: head.hasFailoverPeer && (head.autoOn || useHover.hovered || head.picked)',
            '          text: Commons.I18n.t("agents.autoswitch") + (head.pickedKind === "autoswitch" ? " ⏎" : "")',
            '          picked: head.pickedKind === "autoswitch"',
            '          current: head.autoOn',
            '          tooltip: head.autoOn',
            '            ? Commons.I18n.t("agents.stopAutoSwitch")',
            '            : Commons.I18n.t("agents.switchAutoAt").arg(Commons.I18n.formatNumber(root.switchThreshold(head.owner)))',
            '          onClicked: root.setSwitchMode(head.owner, head.autoOn ? "manual" : "auto")',
            '        }',
            "",
            '        // With Autoswitch on, Use waits until the line is hovered or picked.',
            '        TextLink {',
            '          visible: head.canSwitchTo && (!head.autoOn || useHover.hovered || head.picked)',
            '          text: Commons.I18n.t("agents.use") + (head.pickedKind === "account" ? " ⏎" : "")',
            '          picked: head.pickedKind === "account"',
            '          onClicked: root.useAccount(head.owner, head.account)',
            '        }',
            '      }',
            '    }',
        ])
        assert old_acct_head in qml, "Panel.qml AccountHeader block not found"
        qml = qml.replace(old_acct_head, new_acct_head, 1)

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
        new_dp = '      ready: record.ready === true || synced,\n      orbManaged: record.orbManaged === true,\n      orbSignIn: record.orbSignIn === true,'
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

    # Unify builtin Omarchy Shell surfaces (Clipboard, Menu, Emojis, Bar Popups,
    # Notifications, Polkit, Tooltips, Lock) on Balanced Readable Glass:
    # - ~0.45–0.48 card translucency over Hyprland's `omarchy-glass` blur
    # - `scrim-alpha = 0.0` (< `ignore_alpha = 0.05`) so fullscreen OverlayWindows
    #   only blur the card rect rather than running Kawase blur fullscreen
    # - 1px neutral pre-mixed border (`border-alpha >= 0.55 > ignore_alpha`) so
    #   Qt Quick's `Rectangle.border` never punches an unblurred halo around cards
    shell_tpl = out / "default" / "themed" / "shell.toml.tpl"
    if shell_tpl.is_file():
        stpl = shell_tpl.read_text(encoding="utf-8")
        old_surfaces = "\n".join([
            '[popups]',
            '# Shared by every bar flyout (dropdowns, OSD, popup cards).',
            '# Border accepts either a solid color or a Hyprland-style gradient. Border',
            '# widths accept one CSS-style scalar/list: N, "Y X", "T X B", or "T R B L";',
            '# individual border-width-top/right/bottom/left keys override the list.',
            'background       = "{{ background }}"',
            'background-alpha = 1.0',
            'text             = "{{ foreground }}"',
            'border           = "hyprland.active-border"',
            'border-alpha     = 1.0',
            '# border-width     = 2',
            "",
            '[tooltip]',
            '# Hover tooltips across the bar, panels, and buttons. background-alpha of',
            '# 0.97 mirrors the legacy hard-coded tooltip opacity.',
            'background       = "{{ background }}"',
            'background-alpha = 0.97',
            'text             = "{{ foreground }}"',
            'border           = "hyprland.active-border-foreground"',
            'border-alpha     = 1.0',
            "",
            '[notifications]',
            'background       = "{{ background }}"',
            'background-alpha = 1.0',
            'text             = "{{ foreground }}"',
            '# Conventionally matches the Hyprland active-window border. Border accepts',
            '# either a solid color or the full active-border gradient.',
            'border           = "hyprland.active-border"',
            'border-alpha     = 1.0',
            '# border-width     = 2',
            'countdown        = "{{ accent }}"',
            "",
            '[launcher]',
            '# Same six tokens as [menu], applied to the launcher overlay. Alpha',
            '# companions go from 0 (invisible) to 1 (opaque). scrim is the full-screen',
            '# dim layer behind the card; background is the card itself. Defaults',
            '# mirror [menu] with the card at 0.95 to preserve the legacy translucency.',
            'background                = "{{ background }}"',
            'background-alpha          = 0.95',
            'text                      = "{{ foreground }}"',
            'border                    = "hyprland.active-border-foreground"',
            'border-alpha              = 1.0',
            'scrim                     = "{{ background }}"',
            'scrim-alpha               = 0.5',
            'selected-background       = "{{ foreground }}"',
            'selected-background-alpha = 0.08',
            'selected-text             = "{{ accent }}"',
            'selected-border           = "hyprland.active-border-foreground"',
            'selected-border-alpha     = 0.25',
            "",
            '[menu]',
            '# Cards, rows, and selected-row treatment. Alpha companions (where present)',
            '# go from 0 (invisible) to 1 (opaque). scrim is the full-screen dim layer',
            '# behind the card. Clipboard and emojis inherit these tokens.',
            'background                = "{{ background }}"',
            'background-alpha          = 1.0',
            'text                      = "{{ foreground }}"',
            'border                    = "hyprland.active-border-foreground"',
            'border-alpha              = 1.0',
            'scrim                     = "{{ background }}"',
            'scrim-alpha               = 0.5',
            'selected-background       = "{{ foreground }}"',
            'selected-background-alpha = 0.08',
            'selected-text             = "{{ accent }}"',
            'selected-border           = "hyprland.active-border-foreground"',
            'selected-border-alpha     = 0.25',
            "",
            '[polkit]',
            '# Polkit authentication prompt (sudo/password dialogs). scrim is the',
            '# darkening layer behind the card; background is the card itself.',
            '# text-error tints the lock icon, password text, and placeholder when',
            '# authentication fails. border-alpha applies to both border and',
            '# border-error (the two states are mutually exclusive in time).',
            'background       = "{{ background }}"',
            'background-alpha = 1.0',
            'text             = "{{ foreground }}"',
            'text-error       = "{{ red }}"',
            'border           = "hyprland.active-border"',
            'border-error     = "{{ red }}"',
            'border-alpha     = 1.0',
            'scrim            = "{{ background }}"',
            'scrim-alpha      = 0.5',
            '# accent is the lock-icon glyph color + text-selection tint.',
            'accent           = "{{ accent }}"',
            "",
            '[lock]',
            '# Lock screen password input. background/background-alpha control the',
            '# centered input field card; border/border-active/border-error cycle',
            '# through idle, typing/authenticating, and wrong-password states.',
            '# border-alpha applies to all three border states (they are mutually',
            '# exclusive in time).',
            'background       = "{{ background }}"',
            'background-alpha = 0.8',
            'text             = "{{ foreground }}"',
            'placeholder      = "{{ mix foreground background 34% }}"',
            'text-error       = "{{ red }}"',
            'border           = "hyprland.active-border"',
            'border-active    = "hyprland.active-border"',
            'border-error     = "{{ red }}"',
            'border-alpha     = 1.0',
            '# selection is the text-selection tint inside the input field.',
            'selection        = "{{ accent }}"',
            'selection-alpha  = 0.45',
        ])
        new_surfaces = "\n".join([
            '[popups]',
            'background       = "{{ background }}"',
            'background-alpha = 0.45',
            'text             = "{{ foreground }}"',
            'border           = "{{ mix background foreground 18% }}"',
            'border-alpha     = 0.55',
            'border-width     = 1',
            "",
            '[tooltip]',
            'background       = "{{ background }}"',
            'background-alpha = 0.58',
            'text             = "{{ foreground }}"',
            'border           = "{{ mix background foreground 18% }}"',
            'border-alpha     = 0.55',
            'border-width     = 1',
            "",
            '[notifications]',
            'background       = "{{ background }}"',
            'background-alpha = 0.48',
            'text             = "{{ foreground }}"',
            'border           = "{{ mix background foreground 18% }}"',
            'border-alpha     = 0.55',
            'border-width     = 1',
            'countdown        = "{{ accent }}"',
            "",
            '[launcher]',
            'background                = "{{ background }}"',
            'background-alpha          = 0.45',
            'text                      = "{{ foreground }}"',
            'border                    = "{{ mix background foreground 18% }}"',
            'border-alpha              = 0.55',
            'border-width              = 1',
            'scrim                     = "{{ background }}"',
            'scrim-alpha               = 0.0',
            'selected-background       = "{{ foreground }}"',
            'selected-background-alpha = 0.12',
            'selected-text             = "{{ accent }}"',
            'selected-border           = "{{ foreground }}"',
            'selected-border-alpha     = 0.12',
            "",
            '[menu]',
            'background                = "{{ background }}"',
            'background-alpha          = 0.45',
            'text                      = "{{ foreground }}"',
            'border                    = "{{ mix background foreground 18% }}"',
            'border-alpha              = 0.55',
            'border-width              = 1',
            'scrim                     = "{{ background }}"',
            'scrim-alpha               = 0.0',
            'selected-background       = "{{ foreground }}"',
            'selected-background-alpha = 0.12',
            'selected-text             = "{{ accent }}"',
            'selected-border           = "{{ foreground }}"',
            'selected-border-alpha     = 0.12',
            "",
            '[polkit]',
            'background       = "{{ background }}"',
            'background-alpha = 0.48',
            'text             = "{{ foreground }}"',
            'text-error       = "{{ red }}"',
            'border           = "{{ mix background foreground 18% }}"',
            'border-error     = "{{ red }}"',
            'border-alpha     = 0.65',
            'border-width     = 1',
            'scrim            = "{{ background }}"',
            'scrim-alpha      = 0.0',
            'accent           = "{{ accent }}"',
            "",
            '[lock]',
            'background       = "{{ background }}"',
            'background-alpha = 0.48',
            'text             = "{{ foreground }}"',
            'placeholder      = "{{ mix foreground background 34% }}"',
            'text-error       = "{{ red }}"',
            'border           = "{{ mix background foreground 18% }}"',
            'border-active    = "{{ accent }}"',
            'border-error     = "{{ red }}"',
            'border-alpha     = 0.65',
            'border-width     = 1',
            'selection        = "{{ accent }}"',
            'selection-alpha  = 0.45',
            "",
            '[flea]',
            'background-alpha = 0.45',
        ])
        assert old_surfaces in stpl, "shell.toml.tpl surface sections block not found"
        shell_tpl.write_text(stpl.replace(old_surfaces, new_surfaces, 1), encoding="utf-8")

    confirm_qml = out / "shell" / "Ui" / "ConfirmDialog.qml"
    if confirm_qml.is_file():
        cqml = confirm_qml.read_text(encoding="utf-8")
        old_confirm = "\n".join([
            "  Rectangle {",
            "    anchors.fill: parent",
            "    color: root.scrim",
            "",
            "    MouseArea { anchors.fill: parent; onClicked: root.canceled() }",
            "",
            "    BorderSurface {",
            "      id: card",
            "      width: Math.min(parent.width - Style.space(32), Style.space(370))",
            "      // Grows with the wrapped message so narrow hosts (like the menu card)",
            "      // don't squeeze the text into the buttons.",
            "      height: card.contentTopInset + card.contentBottomInset + messageText.implicitHeight + Style.space(20) + Style.space(34)",
            "      anchors.centerIn: parent",
            "      color: root.background",
        ])
        new_confirm = "\n".join([
            "  Rectangle {",
            "    anchors.fill: parent",
            "    color: root.scrim.a > 0.01 ? root.scrim : Qt.rgba(root.background.r, root.background.g, root.background.b, 0.62)",
            "",
            "    MouseArea { anchors.fill: parent; onClicked: root.canceled() }",
            "",
            "    BorderSurface {",
            "      id: card",
            "      width: Math.min(parent.width - Style.space(32), Style.space(370))",
            "      // Grows with the wrapped message so narrow hosts (like the menu card)",
            "      // don't squeeze the text into the buttons.",
            "      height: card.contentTopInset + card.contentBottomInset + messageText.implicitHeight + Style.space(20) + Style.space(34)",
            "      anchors.centerIn: parent",
            "      color: Qt.rgba(root.background.r, root.background.g, root.background.b, Math.max(root.background.a, 0.90))",
        ])
        assert old_confirm in cqml, "ConfirmDialog.qml card block not found"
        confirm_qml.write_text(cqml.replace(old_confirm, new_confirm, 1), encoding="utf-8")
    # Configure `[flea]` frosted-glass surface opacity in `shell.toml.tpl` across all bundled themes.
    shell_tpl = out / "default" / "themed" / "shell.toml.tpl"
    if shell_tpl.is_file():
        stpl = shell_tpl.read_text(encoding="utf-8")
        if "[flea]" not in stpl:
            shell_tpl.write_text(
                stpl.rstrip() + "\n\n[flea]\nbackground-alpha = 0.45\n",
                encoding="utf-8",
            )

    # Fast-path Apple Silicon Asahi speaker-safety voicing sinks (`sgv2.voicing.*`,
    # `effect_output.j*`) and Bluetooth sinks (`bluez_output.*`) directly in
    # Quickshell's media service & audio panel so Mac volume keys respond in <0.2ms
    # with zero subprocess forks, never unwrap into internal speaker-protection
    # nodes, and send semantic speaker/headphone/mute/zero states to the frosted OSD.
    media_model = out / "shell" / "plugins" / "services" / "media" / "MediaModel.js"
    if media_model.is_file():
        mmjs = media_model.read_text(encoding="utf-8")
        old_vol_icon = "\n".join([
            "function volumeOsdIcon(percent, muted) {",
            '  return muted || percent === 0 ? "volume-muted" : "volume-high"',
            "}",
        ])
        new_vol_icon = "\n".join([
            "function volumeOsdIcon(percent, muted, headphones) {",
            '  if (headphones) return muted ? "headphones-muted" : "headphones"',
            '  if (muted) return "volume-muted"',
            '  if (percent <= 0) return "volume-zero"',
            '  return "volume"',
            "}",
        ])
        assert old_vol_icon in mmjs, "MediaModel.js volumeOsdIcon block not found"
        media_model.write_text(mmjs.replace(old_vol_icon, new_vol_icon, 1), encoding="utf-8")

    media_svc = out / "shell" / "plugins" / "services" / "media" / "Service.qml"
    if media_svc.is_file():
        msqml = media_svc.read_text(encoding="utf-8")
        old_vsink = '  readonly property var volumeSink: defaultSink && String(defaultSink.name).indexOf("alsa_output.") === 0 ? defaultSink : null'
        new_vsink = "\n".join([
            '  readonly property var volumeSink: defaultSink && /^(alsa_output\\.|bluez_output\\.|sgv2\\.voicing\\.|effect_output\\.j)/.test(String(defaultSink.name)) ? defaultSink : null',
            '  readonly property bool volumeSinkHeadphones: {',
            '    if (!volumeSink) return false',
            '    var blob = String([volumeSink.name || "", volumeSink.description || "", volumeSink.nickname || ""].join(" ")).toLowerCase()',
            '    return /headphone|headset|earbud|earphone|airpod/.test(blob)',
            '  }',
        ])
        assert old_vsink in msqml, "media/Service.qml volumeSink line not found"
        msqml = msqml.replace(old_vsink, new_vsink, 1)

        old_osd_call = "      icon: MediaModel.volumeOsdIcon(step.percent, step.muted),"
        new_osd_call = "      icon: MediaModel.volumeOsdIcon(step.percent, step.muted, root.volumeSinkHeadphones),"
        assert old_osd_call in msqml, "media/Service.qml volumeOsdIcon call not found"
        msqml = msqml.replace(old_osd_call, new_osd_call, 1)
        media_svc.write_text(msqml, encoding="utf-8")

    audio_panel = out / "shell" / "plugins" / "panels" / "audio" / "Panel.qml"
    if audio_panel.is_file():
        apqml = audio_panel.read_text(encoding="utf-8")
        old_ap_fast = '    if (sink && String(sink.name).indexOf("alsa_output.") === 0) {'
        new_ap_fast = '    if (sink && /^(alsa_output\\.|bluez_output\\.|sgv2\\.voicing\\.|effect_output\\.j)/.test(String(sink.name))) {'
        assert old_ap_fast in apqml, "audio/Panel.qml resolveVolumeSink fast path not found"
        audio_panel.write_text(apqml.replace(old_ap_fast, new_ap_fast, 1), encoding="utf-8")

    sink_script = out / "bin" / "omarchy-audio-output-sink"
    if sink_script.is_file():
        stxt = sink_script.read_text(encoding="utf-8")
        old_sink_fast = "if [[ -z $sink || $sink == alsa_output.* ]]; then"
        new_sink_fast = "if [[ -z $sink || $sink == alsa_output.* || $sink == bluez_output.* || $sink == sgv2.voicing.* || $sink == effect_output.j* ]]; then"
        assert old_sink_fast in stxt, "omarchy-audio-output-sink fast path not found"
        sink_script.write_text(stxt.replace(old_sink_fast, new_sink_fast, 1), encoding="utf-8")

    vol_script = out / "bin" / "omarchy-audio-output-volume"
    if vol_script.is_file():
        vtxt = vol_script.read_text(encoding="utf-8")
        old_vol_tail = "\n".join([
            "percent=$(volume_percent)",
            "if volume_muted || ((''${percent:-0} == 0)); then",
            '  icon="volume-muted"',
            "else",
            '  icon="volume-high"',
            "fi",
            "",
            'omarchy-osd -i "$icon" -p "''${percent:-0}"',
        ])
        new_vol_tail = "\n".join([
            "percent=$(volume_percent)",
            'sink_lc="''${sink,,}"',
            "is_hp=0",
            'if [[ $sink_lc == *headphone* || $sink_lc == *headset* || $sink_lc == *earbud* || $sink_lc == *airpod* ]]; then',
            "  is_hp=1",
            "fi",
            "if volume_muted; then",
            '  icon=$( (( is_hp )) && echo "headphones-muted" || echo "volume-muted" )',
            "elif (( ''${percent:-0} <= 0 )); then",
            '  icon=$( (( is_hp )) && echo "headphones" || echo "volume-zero" )',
            "else",
            '  icon=$( (( is_hp )) && echo "headphones" || echo "volume" )',
            "fi",
            "",
            'omarchy-osd -i "$icon" -p "''${percent:-0}"',
        ])
        assert old_vol_tail in vtxt, "omarchy-audio-output-volume OSD tail not found"
        vol_script.write_text(vtxt.replace(old_vol_tail, new_vol_tail, 1), encoding="utf-8")

    # macOS-style 0% screen-off luminosity:
    # 1. Step brightness down to 0% (instead of clamping at 1%).
    # 2. On Apple Silicon (`apple-panel-bl`), `appledrm`'s `calculate_dac(0)` still
    #    leaves the panel backlight at `min_nits` (`actual_brightness = 2`) unless
    #    CRTC DPMS is disabled. At 0%, power off the internal panel via DPMS while
    #    holding `key_press_enables_dpms` / `mouse_move_enables_dpms` false so mouse
    #    movement or volume keys keep the screen completely off until Brightness Up
    #    (`F2`), slider raise, Power key, or system/lock wake restores >0%.
    bmodel_js = out / "shell" / "services" / "BrightnessModel.js"
    if bmodel_js.is_file():
        bmtxt = bmodel_js.read_text(encoding="utf-8")
        old_bm = "  return Math.max(current <= 5 ? current - 1 : current - 5, 1)"
        new_bm = "  return Math.max(current <= 5 ? current - 1 : current - 5, 0)"
        assert old_bm in bmtxt, "BrightnessModel.js lower clamp not found"
        bmodel_js.write_text(bmtxt.replace(old_bm, new_bm, 1), encoding="utf-8")

    bkeys_qml = out / "shell" / "services" / "BrightnessKeys.qml"
    if bkeys_qml.is_file():
        bktxt = bkeys_qml.read_text(encoding="utf-8")
        old_bk = "\n".join([
            "  property string device: \"\"",
            "  readonly property string devicePath: device ? \"/sys/class/backlight/\" + device : \"\"",
        ])
        new_bk = old_bk + "\n  property bool panelBlanked: false"
        assert old_bk in bktxt, "BrightnessKeys.qml device property block not found"
        bktxt = bktxt.replace(old_bk, new_bk, 1)

        old_bk_handle = "\n".join([
            "    var current = Math.round(100 * readNumber(brightnessFile) / max)",
            "",
            '    setProc.command = ["brightnessctl", "-q", "-d", device, "set", BrightnessModel.brightnessKeyTarget(action, current) + "%"]',
            "    setProc.running = true",
            "    return true",
        ])
        new_bk_handle = "\n".join([
            "    var current = Math.round(100 * readNumber(brightnessFile) / max)",
            "    var target = BrightnessModel.brightnessKeyTarget(action, current)",
            "",
            '    if (action === "lower" && current <= 0 && root.panelBlanked) return true',
            "    if (target <= 0) {",
            "      root.panelBlanked = true",
            '      setProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", name, "0%"]',
            "    } else if (current <= 0 || root.panelBlanked) {",
            "      root.panelBlanked = false",
            '      setProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", name, target + "%"]',
            "    } else {",
            '      setProc.command = ["brightnessctl", "-q", "-d", device, "set", target + "%"]',
            "    }",
            "    setProc.running = true",
            "    return true",
        ])
        assert old_bk_handle in bktxt, "BrightnessKeys.qml handle block not found"
        bktxt = bktxt.replace(old_bk_handle, new_bk_handle, 1)

        old_bk_exit = "\n".join([
            "    onExited: {",
            "      root.showOsd()",
            "      if (!deviceProc.running) deviceProc.running = true",
            "    }",
        ])
        new_bk_exit = "\n".join([
            "    onExited: {",
            "      if (!root.panelBlanked) root.showOsd()",
            "      if (!deviceProc.running) deviceProc.running = true",
            "    }",
        ])
        assert old_bk_exit in bktxt, "BrightnessKeys.qml onExited block not found"
        bkeys_qml.write_text(bktxt.replace(old_bk_exit, new_bk_exit, 1), encoding="utf-8")

    bdisp_bin = out / "bin" / "omarchy-brightness-display"
    if bdisp_bin.is_file():
        bdtxt = bdisp_bin.read_text(encoding="utf-8")
        old_bd_on = "\n".join([
            'elif [[ $step == "on" ]]; then',
            "  # Skip the dispatch when every active display is already lit: a redundant",
            "  # DPMS enable right after system resume forces another modeset, which blanks",
            "  # the panel for a beat (visible flash at the unlock screen).",
            "  hyprctl monitors -j 2>/dev/null | jq -e '[.[] | select(.disabled == false)] | length > 0 and all(.dpmsStatus)' >/dev/null 2>&1 && exit 0",
            "  hyprctl dispatch 'hl.dsp.dpms({ action = \"enable\" })' >/dev/null 2>&1",
            "  exit 0",
            "fi",
        ])
        new_bd_on = "\n".join([
            'elif [[ $step == "on" ]]; then',
            '  rm -f "''${XDG_RUNTIME_DIR:-/tmp}/omarchy-brightness-zero"',
            "  hyprctl eval 'hl.config({ misc = { key_press_enables_dpms = true, mouse_move_enables_dpms = true } })' >/dev/null 2>&1 || true",
            '  wake_dev="$(omarchy-hw-display 2>/dev/null || true)"',
            '  if [[ -n $wake_dev ]]; then',
            '    wake_pct="$(backlight_brightness "$wake_dev" 2>/dev/null || echo 5)"',
            '    if (( ''${wake_pct:-5} <= 0 )); then',
            '      brightnessctl -q -d "$wake_dev" set 5% >/dev/null 2>&1 || true',
            "    fi",
            "  fi",
            "  hyprctl monitors -j 2>/dev/null | jq -e '[.[] | select(.disabled == false)] | length > 0 and all(.dpmsStatus)' >/dev/null 2>&1 && exit 0",
            "  hyprctl dispatch 'hl.dsp.dpms({ action = \"enable\" })' >/dev/null 2>&1",
            "  exit 0",
            "fi",
        ])
        assert old_bd_on in bdtxt, "omarchy-brightness-display 'on' block not found"
        bdtxt = bdtxt.replace(old_bd_on, new_bd_on, 1)

        old_bd_tail = "\n".join([
            "    (( target < 1 )) && target=1",
            '    step="$target%"',
            "  fi",
            "",
            "  # Set brightness of the display device.",
            '  brightnessctl -d "$device" set "$step" >/dev/null',
            "",
            "  # Show the new brightness in OSD",
            '  (( no_osd )) || omarchy-osd -i brightness -p "$(backlight_brightness "$device")"',
        ])
        new_bd_tail = "\n".join([
            "    (( target < 0 )) && target=0",
            '    step="$target%"',
            "  fi",
            "",
            "  # Set brightness of the display device.",
            '  brightnessctl -d "$device" set "$step" >/dev/null',
            '  new_pct="$(backlight_brightness "$device")"',
            '  target_mon="''${monitor:-$(omarchy-hyprland-monitor-laptop 2>/dev/null || true)}"',
            '  if (( ''${new_pct:-1} <= 0 )); then',
            '    printf \'%s\\n\' "$target_mon" > "''${XDG_RUNTIME_DIR:-/tmp}/omarchy-brightness-zero"',
            "    hyprctl eval 'hl.config({ misc = { key_press_enables_dpms = false, mouse_move_enables_dpms = false } })' >/dev/null 2>&1 || true",
            '    [[ -n $target_mon ]] && hyprctl dispatch "hl.dsp.dpms({ action = \\"disable\\", monitor = \\"$target_mon\\" })" >/dev/null 2>&1 || true',
            "  else",
            '    if [[ -f "''${XDG_RUNTIME_DIR:-/tmp}/omarchy-brightness-zero" ]]; then',
            '      rm -f "''${XDG_RUNTIME_DIR:-/tmp}/omarchy-brightness-zero"',
            '      [[ -n $target_mon ]] && hyprctl dispatch "hl.dsp.dpms({ action = \\"enable\\", monitor = \\"$target_mon\\" })" >/dev/null 2>&1 || true',
            "      hyprctl eval 'hl.config({ misc = { key_press_enables_dpms = true, mouse_move_enables_dpms = true } })' >/dev/null 2>&1 || true",
            '    elif [[ -n $target_mon ]]; then',
            '      hyprctl monitors -j 2>/dev/null | jq -e --arg m "$target_mon" \'.[] | select(.name == $m) | .dpmsStatus == true\' >/dev/null 2>&1 \\',
            '        || hyprctl dispatch "hl.dsp.dpms({ action = \\"enable\\", monitor = \\"$target_mon\\" })" >/dev/null 2>&1 || true',
            "    fi",
            "    (( no_osd )) || omarchy-osd -i brightness -p \"$new_pct\"",
            "  fi",
        ])
        assert old_bd_tail in bdtxt, "omarchy-brightness-display tail block not found"
        bdisp_bin.write_text(bdtxt.replace(old_bd_tail, new_bd_tail, 1), encoding="utf-8")

    mon_model_js = out / "shell" / "plugins" / "panels" / "monitor" / "Model.js"
    if mon_model_js.is_file():
        mm_txt = mon_model_js.read_text(encoding="utf-8")
        old_clamp = "\n".join([
            "function clampBrightness(value) {",
            "  var n = Number(value)",
            "  if (!isFinite(n)) return 1",
            "  return Math.max(1, Math.min(100, Math.round(n)))",
            "}",
        ])
        new_clamp = "\n".join([
            "function clampBrightness(value) {",
            "  var n = Number(value)",
            "  if (!isFinite(n)) return 0",
            "  return Math.max(0, Math.min(100, Math.round(n)))",
            "}",
        ])
        assert old_clamp in mm_txt, "monitor/Model.js clampBrightness not found"
        mm_txt = mm_txt.replace(old_clamp, new_clamp, 1)

        old_bname = '  return t("monitor.level.nightOwl", "Night owl")'
        new_bname = '  if (p <= 0) return t("monitor.level.screenOff", "Screen off")\n  return t("monitor.level.nightOwl", "Night owl")'
        assert old_bname in mm_txt, "monitor/Model.js nightOwl line not found"
        mon_model_js.write_text(mm_txt.replace(old_bname, new_bname, 1), encoding="utf-8")

    mon_panel_qml = out / "shell" / "plugins" / "panels" / "monitor" / "Panel.qml"
    if mon_panel_qml.is_file():
        mp_txt = mon_panel_qml.read_text(encoding="utf-8")
        old_bslider = "\n".join([
            "                minimum: 1",
            "                maximum: 100",
            "                step: 1",
            "                value: Math.max(1, root.currentBrightness)",
        ])
        new_bslider = "\n".join([
            "                minimum: 0",
            "                maximum: 100",
            "                step: 1",
            "                value: Math.max(0, root.currentBrightness)",
        ])
        assert old_bslider in mp_txt, "monitor/Panel.qml brightnessSlider minimum block not found"
        mon_panel_qml.write_text(mp_txt.replace(old_bslider, new_bslider, 1), encoding="utf-8")

    # Fix battery charge-limit & charging-bolt detection on Apple Silicon (`macsmc-battery`)
    # and laptops where UPower's hwdb presets `ChargeStartThreshold=75`/`ChargeEndThreshold=80`
    # even when `ChargeThresholdEnabled=false` or sysfs `charge_control_end_threshold == 100`:
    # 1. `bin/omarchy-battery-status`: prefer authoritative sysfs `charge_control_*_threshold`
    #    over UPower hwdb presets, require `charge-threshold-enabled: yes` before falling back
    #    to `upower -i`, and treat `threshold_end >= 100` as uncapped (no active charge limit).
    # 2. `shell/plugins/panels/power/Model.js`: gate `chargeThresholdActive` on `batteryInfo`
    #    reporting an actual sub-100% threshold so `FullyCharged` at ~97% energy nominal or
    #    low initial `changeRate` on AC never strips the charging bolt icon (`󰢜`..`󰂅`).
    # 3. `shell/plugins/panels/power/Panel.qml`: default `showPercentage` fallback to `true`
    #    and run a lightweight one-shot `omarchy-battery-status --shell` refresh on startup and
    #    UPower AC/state transitions so the status bar icon is accurate before opening the panel.
    batt_status = out / "bin" / "omarchy-battery-status"
    if batt_status.is_file():
        btxt = batt_status.read_text(encoding="utf-8")
        old_pct = 'percentage=$(awk \'/percentage/ { print int($2); exit }\' <<<"$battery_info")'
        new_pct = 'percentage=$(awk \'/percentage/ { print int($2 + 0.5); exit }\' <<<"$battery_info")'
        assert old_pct in btxt, "omarchy-battery-status percentage awk line not found"
        btxt = btxt.replace(old_pct, new_pct, 1)

        old_thresh = "\n".join([
            'threshold_start=$(awk \'/charge-start-threshold:/ { gsub(/%/, "", $2); print int($2); exit }\' <<<"$battery_info")',
            'threshold_end=$(awk \'/charge-end-threshold:/ { gsub(/%/, "", $2); print int($2); exit }\' <<<"$battery_info")',
            "",
            "# Read the thresholds from the battery UPower resolved rather than a BAT* glob,",
            "# which misses every battery with another name.",
            '[[ -n $threshold_end || ! -r $battery_path/charge_control_end_threshold ]] || threshold_end=$(<"$battery_path/charge_control_end_threshold")',
            '[[ -n $threshold_start || ! -r $battery_path/charge_control_start_threshold ]] || threshold_start=$(<"$battery_path/charge_control_start_threshold")',
            "# The time to full counts to this battery's own limit, never another one's.",
            "charge_limit=''${threshold_end:-100}",
            '[[ -n $threshold_end ]] || threshold_end=$(cat "$power_supply_path"/BAT*/charge_control_end_threshold 2>/dev/null | head -1)',
            '[[ -n $threshold_start ]] || threshold_start=$(cat "$power_supply_path"/BAT*/charge_control_start_threshold 2>/dev/null | head -1)',
        ])
        new_thresh = "\n".join([
            "sysfs_status=\"\"",
            "[[ ! -r \"$battery_path/status\" ]] || sysfs_status=$(<\"$battery_path/status\")",
            "case \"$sysfs_status\" in",
            "  Charging) state=\"charging\" ;;",
            "  Discharging) state=\"discharging\" ;;",
            "  \"Not charging\") state=\"pending-charge\" ;;",
            "  Full) state=\"fully-charged\" ;;",
            "esac",
            "threshold_start=\"\"",
            "threshold_end=\"\"",
            "limit_file=\"\"",
            "# Prefer kernel sysfs thresholds on the resolved battery: UPower's hwdb",
            "# (`60-upower-battery.hwdb`) populates preset 75/80% thresholds even when",
            "# ChargeThresholdEnabled is false or sysfs charge_control_end_threshold is 100.",
            "if [[ -e \"$battery_path/charge_control_end_threshold\" ]]; then",
            "  limit_file=\"$battery_path/charge_control_end_threshold\"",
            "  threshold_end=$(read_sysfs_number \"$limit_file\" || true)",
            "  threshold_start=$(read_sysfs_number \"$battery_path/charge_control_start_threshold\" || true)",
            "fi",
            "if [[ -z $threshold_end ]]; then",
            '  for bat_cand in "$power_supply_path"/BAT*; do',
            '    if threshold_end=$(read_sysfs_number "$bat_cand/charge_control_end_threshold"); then',
            '      limit_file="$bat_cand/charge_control_end_threshold"',
            '      threshold_start=$(read_sysfs_number "$bat_cand/charge_control_start_threshold" || true)',
            "      break",
            "    fi",
            "  done",
            "fi",
            "raw_limit_end=\"$threshold_end\"",
            "if [[ -z $threshold_end ]] && grep -qE '^\\s*charge-threshold-enabled:\\s+(yes|true)' <<<\"$battery_info\"; then",
            '  threshold_start=$(awk \'/charge-start-threshold:/ { gsub(/%/, "", $2); print int($2); exit }\' <<<"$battery_info")',
            '  threshold_end=$(awk \'/charge-end-threshold:/ { gsub(/%/, "", $2); print int($2); exit }\' <<<"$battery_info")',
            "fi",
            "if [[ -n $threshold_end ]] && (( threshold_end >= 100 )); then",
            "  threshold_end=\"\"",
            "  threshold_start=\"\"",
            "fi",
            "# The time to full counts to this battery's own limit, never another one's.",
            "charge_limit=''${threshold_end:-100}",
        ])
        assert old_thresh in btxt, "omarchy-battery-status threshold block not found"
        btxt = btxt.replace(old_thresh, new_thresh, 1)

        old_holding = "\n".join([
            "charge_holding=false",
            'if [[ $ac_online == "true" && -n $threshold_end ]]; then',
            '  if [[ $state == "pending-charge" ]]; then',
            "    charge_holding=true",
            '  elif [[ $state == "fully-charged" ]] && (( percentage < 99 )); then',
            "    charge_holding=true",
            '  elif [[ $state == "charging" && $charge_idle == "true" ]] && (( threshold_end < 99 && percentage >= threshold_end )); then',
            "    charge_holding=true",
            "  fi",
            "fi",
        ])
        new_holding = "\n".join([
            "charge_holding=false",
            'if [[ $ac_online == "true" && -n $threshold_end ]] && (( threshold_end < 100 )); then',
            '  if [[ $state == "pending-charge" ]]; then',
            "    charge_holding=true",
            '  elif [[ $state == "fully-charged" ]] && (( percentage < 99 && percentage >= threshold_end - 2 )); then',
            "    charge_holding=true",
            '  elif [[ $state == "charging" && $charge_idle == "true" ]] && (( threshold_end < 99 && percentage >= threshold_end - 1 )); then',
            "    charge_holding=true",
            "  fi",
            "fi",
        ])
        assert old_holding in btxt, "omarchy-battery-status charge_holding block not found"
        btxt = btxt.replace(old_holding, new_holding, 1)

        old_shell_tail = "\n".join([
            "  if [[ -n $threshold_end ]]; then",
            "    if [[ -n $threshold_start && $threshold_start != $threshold_end ]]; then",
            "      printf 'threshold\\t%s-%s%%\\n' \"$threshold_start\" \"$threshold_end\"",
            "    else",
            "      printf 'threshold\\t%s%%\\n' \"$threshold_end\"",
            "    fi",
            "  fi",
            "",
            "  exit 0",
        ])
        new_shell_tail = "\n".join([
            "  if [[ -n $threshold_end ]]; then",
            "    if [[ -n $threshold_start && $threshold_start != $threshold_end ]]; then",
            "      printf 'threshold\\t%s-%s%%\\n' \"$threshold_start\" \"$threshold_end\"",
            "    else",
            "      printf 'threshold\\t%s%%\\n' \"$threshold_end\"",
            "    fi",
            "  fi",
            "",
            "  if e_full=$(read_sysfs_number \"$battery_path/energy_full\") && e_design=$(read_sysfs_number \"$battery_path/energy_full_design\") && (( e_design > 0 )); then",
            "    printf 'health\\t%d%%\\n' \"$(( (e_full * 100 + e_design / 2) / e_design ))\"",
            "  fi",
            "  if raw_temp=$(read_sysfs_number \"$battery_path/temp\"); then",
            "    printf 'temp\\t%s\\n' \"$(awk -v t=\"$raw_temp\" 'BEGIN { printf \"%.1f°C\", t / 10 }')\"",
            "  fi",
            "  for hw in /sys/class/hwmon/hwmon*; do",
            "    [[ -r \"$hw/name\" && $(<\"$hw/name\") == \"macsmc_hwmon\" ]] || continue",
            "    if sys_uw=$(read_sysfs_number \"$hw/power1_input\"); then",
            "      printf 'sys_power\\t%s\\n' \"$(awk -v uw=\"$sys_uw\" 'BEGIN { if (uw < 0) uw = -uw; r = sprintf(\"%.1f\", uw / 1000000); sub(/\\.0$/, \"\", r); print r \"W\" }')\"",
            "    fi",
            "    break",
            "  done",
            "  if [[ -n $limit_file && -w $limit_file ]]; then",
            "    printf 'limit_supported\\t1\\n'",
            "    printf 'limit_end\\t%s\\n' \"''${raw_limit_end:-100}\"",
            "    daily_lim=90",
            "    for df in \"''${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/daily-charge-limit\" /etc/omarchnix/daily-charge-limit; do",
            "      [[ -r $df ]] || continue",
            "      dv=$(tr -d '[:space:]%' <\"$df\" 2>/dev/null || true)",
            "      if [[ $dv =~ ^[0-9]+$ ]] && (( dv >= 50 && dv < 100 )); then daily_lim=\"$dv\"; break; fi",
            "    done",
            "    printf 'limit_daily\\t%s\\n' \"$daily_lim\"",
            "  fi",
            "",
            "  exit 0",
        ])
        assert old_shell_tail in btxt, "omarchy-battery-status shell tail block not found"
        btxt = btxt.replace(old_shell_tail, new_shell_tail, 1)
        batt_status.write_text(btxt, encoding="utf-8")

    batt_model_js = out / "shell" / "plugins" / "services" / "battery" / "BatteryModel.js"
    if batt_model_js.is_file():
        bm_txt = batt_model_js.read_text(encoding="utf-8")
        old_bm = "\n".join([
            "function parseActiveProfile(text) {",
            '  // busctl --json=short prints {"type":"s","data":"balanced"}; an empty or',
            "  // malformed reply (daemon not running) reads as no active profile.",
            "  try {",
            '    return String(JSON.parse(text).data || "").trim()',
            "  } catch (e) {",
            '    return ""',
            "  }",
            "}",
        ])
        new_bm = "\n".join([
            "function parseActiveProfile(text) {",
            '  var raw = String(text || "").trim()',
            '  if (!raw) return ""',
            '  if (raw.charAt(0) === "{") {',
            "    try {",
            '      return String(JSON.parse(raw).data || "").trim()',
            "    } catch (e) {",
            '      return ""',
            "    }",
            "  }",
            '  var lines = raw.split("\\n")',
            "  for (var i = 0; i < lines.length; i++) {",
            '    var parts = lines[i].trim().split("\\t")',
            '    if (parts[1] === "1") return parts[0]',
            "  }",
            '  return ""',
            "}",
        ])
        assert old_bm in bm_txt, "services/battery/BatteryModel.js parseActiveProfile not found"
        batt_model_js.write_text(bm_txt.replace(old_bm, new_bm, 1), encoding="utf-8")

    batt_service_qml = out / "shell" / "plugins" / "services" / "battery" / "Service.qml"
    if batt_service_qml.is_file():
        bs_txt = batt_service_qml.read_text(encoding="utf-8")
        old_bs_cmd = '    command: ["busctl", "--json=short", "get-property", "net.hadess.PowerProfiles", "/net/hadess/PowerProfiles", "net.hadess.PowerProfiles", "ActiveProfile"]'
        new_bs_cmd = '    command: ["omarchy-powerprofiles-list", "--active-state"]'
        assert old_bs_cmd in bs_txt, "services/battery/Service.qml busctl command not found"
        bs_txt = bs_txt.replace(old_bs_cmd, new_bs_cmd, 1)

        old_bs_sig = "\n".join([
            "  Connections {",
            "    target: PowerProfiles",
            "    function onProfileChanged() {",
            "      root.powerProfileSignals++",
            "      root.activePowerProfile = root.profileName(PowerProfiles.profile)",
            "    }",
            "  }",
        ])
        new_bs_sig = "\n".join([
            "  Connections {",
            "    target: PowerProfiles",
            "    function onProfileChanged() {",
            "      root.refreshPowerProfile()",
            "    }",
            "  }",
        ])
        assert old_bs_sig in bs_txt, "services/battery/Service.qml PowerProfiles Connections not found"
        batt_service_qml.write_text(bs_txt.replace(old_bs_sig, new_bs_sig, 1), encoding="utf-8")

    menu_qml_p = out / "shell" / "plugins" / "menu" / "Menu.qml"
    if menu_qml_p.is_file():
        mq_txt = menu_qml_p.read_text(encoding="utf-8")
        old_mq = '      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf \'%s\\\\t%s\\\\t%s\\\\n\' \\"$p\\" \\"$p\\" \\"$current\\"; done",'
        new_mq = "\n".join([
            '      script: "current=$(omarchy-powerprofiles-list --active-state 2>/dev/null | awk -F\'\\\\t\' \'$2 == \\"1\\" { print $1; exit }\'); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf \'%s\\\\t%s\\\\t%s\\\\n\' \\"$p\\" \\"$p\\" \\"$current\\"; done",',
            "      volatile: true,",
        ])
        assert old_mq in mq_txt, "menu/Menu.qml power-profiles script not found"
        menu_qml_p.write_text(mq_txt.replace(old_mq, new_mq, 1), encoding="utf-8")

    power_model_js = out / "shell" / "plugins" / "panels" / "power" / "Model.js"
    if power_model_js.is_file():
        pm_txt = power_model_js.read_text(encoding="utf-8")
        old_pm = "\n".join([
            "function chargeThresholdActive(device, onBattery, states) {",
            "  var d = device || {}",
            "  var s = states || {}",
            "  if (!(d && d.isPresent && !onBattery)) return false",
            "",
            "  var fraction = batteryFraction(d)",
            "  if (d.state === s.Discharging) return false",
            "  if (d.state === s.PendingCharge) return true",
            "  if (d.state === s.FullyCharged && fraction < 0.99) return true",
            "  if (d.state !== s.Charging || fraction >= 0.99) return false",
            "",
            "  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60",
            "}",
            "",
            "function batteryIcon(device, onBattery, states) {",
            "  var d = device || {}",
            '  if (!d.isPresent) return ""',
            "",
            '  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]',
            '  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]',
            "  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))",
            "  var threshold = chargeThresholdActive(d, onBattery, states)",
            "",
            "  if (threshold) return defaultIcons[index]",
            '  if (d.state === states.FullyCharged) return "󰂅"',
            "  if (!onBattery) return chargingIcons[index]",
            "  return defaultIcons[index]",
            "}",
            "",
            "function modeLabel(device, onBattery, states, tr) {",
            '  var t = typeof tr === "function" ? tr : function(key, english) { return english }',
            "  var d = device || {}",
            '  if (!d.isPresent) return ""',
            "",
            "  var percentage = d.isPresent ? d.percentage : 0",
            '  if (chargeThresholdActive(d, onBattery, states)) return t("power.threshold", "Threshold")',
            '  if (onBattery) return t("power.onBattery", "On battery")',
            '  if (!onBattery && percentage >= 1) return t("power.fullyCharged", "Fully charged")',
            '  return t("power.charging", "Charging")',
            "}",
        ])
        new_pm = "\n".join([
            "function parseConsumers(raw) {",
            '  var lines = String(raw || "").split("\\n")',
            "  var out = []",
            "  for (var i = 0; i < lines.length; i++) {",
            "    var line = lines[i].trim()",
            "    if (!line) continue",
            '    var parts = line.split("\\t")',
            "    if (parts.length < 2) continue",
            '    out.push({ name: parts[0], cpu: parts[1], memory: parts[2] || "—" })',
            "  }",
            "  return out",
            "}",
            "",
            "function parseThresholdEndPercent(rawThreshold) {",
            '  var m = String(rawThreshold || "").match(/(\\d+)\\s*%\\s*$/)',
            "  if (!m) return 0",
            "  var n = parseInt(m[1], 10)",
            "  return isFinite(n) && n > 0 && n < 100 ? n : 0",
            "}",
            "",
            "function chargeThresholdActive(device, onBattery, states, batteryInfo) {",
            "  var d = device || {}",
            "  var s = states || {}",
            "  if (!(d && d.isPresent && !onBattery)) return false",
            "  if (d.state === s.Discharging) return false",
            "",
            "  var info = batteryInfo || null",
            "  if (info && info.state !== undefined) {",
            '    if (info.state === "holding") return true',
            "    var endPct = parseThresholdEndPercent(info.threshold)",
            "    if (!endPct) return false",
            "    var limitFrac = endPct / 100",
            "    var fraction = batteryFraction(d)",
            "    if (d.state === s.PendingCharge) return true",
            "    if (d.state === s.FullyCharged && fraction < 0.99 && fraction >= limitFrac - 0.02) return true",
            "    if (d.state !== s.Charging || fraction < limitFrac - 0.01 || fraction >= 0.99) return false",
            "    return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60",
            "  }",
            "",
            "  return d.state === s.PendingCharge",
            "}",
            "",
            "function batteryIcon(device, onBattery, states, batteryInfo) {",
            "  var d = device || {}",
            "  var s = states || {}",
            '  if (!d.isPresent) return ""',
            "",
            '  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]',
            '  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]',
            "  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))",
            "  var threshold = chargeThresholdActive(d, onBattery, s, batteryInfo)",
            '  var infoState = batteryInfo && batteryInfo.state ? String(batteryInfo.state) : ""',
            "",
            "  if (threshold) return defaultIcons[index]",
            '  if ((infoState === "fully-charged" || (infoState === "" && d.state === s.FullyCharged)) && !onBattery) return "󰂅"',
            '  if (!onBattery || infoState === "charging" || d.state === s.Charging) return chargingIcons[index]',
            "  return defaultIcons[index]",
            "}",
            "",
            "function modeLabel(device, onBattery, states, tr, batteryInfo) {",
            '  var t = typeof tr === "function" ? tr : function(key, english) { return english }',
            "  var d = device || {}",
            "  var s = states || {}",
            '  if (!d.isPresent) return ""',
            "",
            "  var percentage = d.isPresent ? d.percentage : 0",
            '  var infoState = batteryInfo && batteryInfo.state ? String(batteryInfo.state) : ""',
            '  if (chargeThresholdActive(d, onBattery, s, batteryInfo)) return t("power.threshold", "Threshold")',
            '  if (onBattery) return t("power.onBattery", "On battery")',
            '  if (!onBattery && (infoState === "fully-charged" || (infoState === "" && d.state === s.FullyCharged) || percentage >= 1)) return t("power.fullyCharged", "Fully charged")',
            '  return t("power.charging", "Charging")',
            "}",
        ])
        assert old_pm in pm_txt, "power/Model.js chargeThresholdActive/batteryIcon/modeLabel block not found"
        pm_txt = pm_txt.replace(old_pm, new_pm, 1)
        old_pm_exp = "    parseProfiles: parseProfiles,"
        new_pm_exp = "    parseProfiles: parseProfiles,\n    parseConsumers: parseConsumers,"
        assert old_pm_exp in pm_txt, "power/Model.js exports not found"
        power_model_js.write_text(pm_txt.replace(old_pm_exp, new_pm_exp, 1), encoding="utf-8")

    power_panel_qml = out / "shell" / "plugins" / "panels" / "power" / "Panel.qml"
    if power_panel_qml.is_file():
        pp_txt = power_panel_qml.read_text(encoding="utf-8")

        old_show_pct = "\n".join([
            "  property var systemInfo: ({})",
            "  property var profiles: []",
            '  property string activeProfile: ""',
            "  property int profileIndex: 0",
            "  property bool cursorActive: false",
            '  readonly property bool showPercentage: setting("showPercentage", false) === true',
        ])
        new_show_pct = "\n".join([
            "  property var systemInfo: ({})",
            "  property var topConsumers: []",
            "  property var profiles: []",
            '  property string activeProfile: ""',
            "  property int profileIndex: 0",
            "  property bool cursorActive: false",
            '  readonly property bool showPercentage: setting("showPercentage", true) !== false',
            '  readonly property bool chargeLimitSupported: root.batteryInfo.limit_supported === "1"',
            "  readonly property int chargeLimitEnd: Number(root.batteryInfo.limit_end || 100)",
            '  readonly property string chargeLimitDaily: String(root.batteryInfo.limit_daily || "90")',
        ])
        assert old_show_pct in pp_txt, "power/Panel.qml showPercentage property not found"
        pp_txt = pp_txt.replace(old_show_pct, new_show_pct, 1)

        old_calls = "\n".join([
            "  function batteryIcon() {",
            "    var device = UPower.displayDevice",
            "    return Model.batteryIcon(device, root.discharging, upowerStates())",
            "  }",
            "",
            "  function modeLabel() {",
            "    var device = UPower.displayDevice",
            "    return Model.modeLabel(device, root.discharging, upowerStates(), Commons.I18n.t)",
            "  }",
        ])
        new_calls = "\n".join([
            "  function refreshBatteryStatus() {",
            "    if (batteryPresent && !batteryProc.running) batteryProc.running = true",
            "  }",
            "",
            "  function batteryIcon() {",
            "    var device = UPower.displayDevice",
            "    return Model.batteryIcon(device, root.discharging, upowerStates(), root.batteryInfo)",
            "  }",
            "",
            "  function modeLabel() {",
            "    var device = UPower.displayDevice",
            "    return Model.modeLabel(device, root.discharging, upowerStates(), Commons.I18n.t, root.batteryInfo)",
            "  }",
        ])
        assert old_calls in pp_txt, "power/Panel.qml batteryIcon/modeLabel block not found"
        pp_txt = pp_txt.replace(old_calls, new_calls, 1)

        old_thresh_prop = "\n".join([
            "  readonly property bool fullyCharged: {",
            "    var device = UPower.displayDevice",
            "    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive",
            "  }",
            "  readonly property bool discharging: {",
            "    var device = UPower.displayDevice",
            "    return !!(device && device.isPresent && UPower.onBattery)",
            "  }",
            "  readonly property bool chargeThresholdActive: {",
            "    var device = UPower.displayDevice",
            "    return Model.chargeThresholdActive(device, root.discharging, upowerStates())",
            "  }",
        ])
        new_thresh_prop = "\n".join([
            "  readonly property bool fullyCharged: {",
            "    var device = UPower.displayDevice",
            '    var infoState = root.batteryInfo && root.batteryInfo.state ? String(root.batteryInfo.state) : ""',
            "    if (!device || !device.isPresent || root.chargeThresholdActive) return false",
            '    if (infoState !== "") return infoState === "fully-charged"',
            "    return device.state === UPowerDeviceState.FullyCharged",
            "  }",
            "  readonly property bool discharging: {",
            "    var device = UPower.displayDevice",
            "    return !!(device && device.isPresent && UPower.onBattery)",
            "  }",
            "  readonly property bool chargeThresholdActive: {",
            "    var device = UPower.displayDevice",
            "    return Model.chargeThresholdActive(device, root.discharging, upowerStates(), root.batteryInfo)",
            "  }",
        ])
        assert old_thresh_prop in pp_txt, "power/Panel.qml chargeThresholdActive block not found"
        pp_txt = pp_txt.replace(old_thresh_prop, new_thresh_prop, 1)

        old_refresh = "\n".join([
            "  function refresh() {",
            "    if (!batteryPresent) return",
            "",
            "    if (!batteryProc.running) batteryProc.running = true",
            "    if (!profilesProc.running) profilesProc.running = true",
            "    if (!systemProc.running) systemProc.running = true",
            "  }",
        ])
        new_refresh = "\n".join([
            "  function refresh() {",
            "    if (!batteryPresent) return",
            "",
            "    if (!batteryProc.running) batteryProc.running = true",
            "    if (!profilesProc.running) profilesProc.running = true",
            "    if (!systemProc.running) systemProc.running = true",
            "    if (opened && !consumersProc.running) consumersProc.running = true",
            "  }",
        ])
        assert old_refresh in pp_txt, "power/Panel.qml refresh() block not found"
        pp_txt = pp_txt.replace(old_refresh, new_refresh, 1)

        old_set_prof = "\n".join([
            "  function setProfile(profile) {",
            "    if (!profile || actionProc.running) return",
            '    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]',
            "    actionProc.running = true",
            "  }",
        ])
        new_set_prof = "\n".join([
            "  function setProfile(profile) {",
            "    if (!profile || actionProc.running) return",
            '    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]',
            "    actionProc.running = true",
            "  }",
            "",
            "  function setChargeLimit(mode) {",
            "    if (!mode || actionProc.running) return",
            '    actionProc.command = ["omarchy-battery-charge-limit", mode]',
            "    actionProc.running = true",
            "  }",
        ])
        assert old_set_prof in pp_txt, "power/Panel.qml setProfile() block not found"
        pp_txt = pp_txt.replace(old_set_prof, new_set_prof, 1)

        old_ipc = '    function togglePercentage() { root.togglePercentage() }'
        new_ipc = "\n".join([
            '    function togglePercentage() { root.togglePercentage() }',
            '    function refresh() { if (root.opened) root.refresh(); else root.refreshBatteryStatus() }',
        ])
        assert old_ipc in pp_txt, "power/Panel.qml ShellIpc togglePercentage not found"
        pp_txt = pp_txt.replace(old_ipc, new_ipc, 1)

        old_present = "  onBatteryPresentChanged: if (!batteryPresent) close()"
        new_present = "\n".join([
            "  Component.onCompleted: refreshBatteryStatus()",
            "  onBatteryPresentChanged: {",
            "    if (!batteryPresent) close()",
            "    else refreshBatteryStatus()",
            "  }",
            "",
            "  Connections {",
            "    target: UPower",
            "    function onOnBatteryChanged() { root.refreshBatteryStatus() }",
            "  }",
            "",
            "  Connections {",
            "    target: UPower.displayDevice",
            "    function onStateChanged() { root.refreshBatteryStatus() }",
            "  }",
        ])
        assert old_present in pp_txt, "power/Panel.qml onBatteryPresentChanged line not found"
        pp_txt = pp_txt.replace(old_present, new_present, 1)

        old_sys_proc = "\n".join([
            "  Process {",
            "    id: systemProc",
            '    command: ["omarchy-system-stats"]',
            '    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }',
            "  }",
        ])
        new_sys_proc = "\n".join([
            "  Process {",
            "    id: systemProc",
            '    command: ["omarchy-system-stats"]',
            '    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }',
            "  }",
            "",
            "  Process {",
            "    id: consumersProc",
            '    command: ["omarchy-power-consumers", "3"]',
            "    stdout: StdioCollector {",
            "      waitForEnd: true",
            "      onStreamFinished: {",
            "        var next = Model.parseConsumers(text)",
            "        if (next.length > 0) root.topConsumers = next",
            "      }",
            "    }",
            "  }",
            "",
            "  Timer {",
            "    id: settleTimer",
            "    interval: 2200",
            "    repeat: false",
            "    onTriggered: { if (root.opened) root.refresh(); else root.refreshBatteryStatus() }",
            "  }",
        ])
        assert old_sys_proc in pp_txt, "power/Panel.qml systemProc block not found"
        pp_txt = pp_txt.replace(old_sys_proc, new_sys_proc, 1)

        old_action_proc = "\n".join([
            "  Process {",
            "    id: actionProc",
            "    onExited: root.refresh()",
            "  }",
        ])
        new_action_proc = "\n".join([
            "  Process {",
            "    id: actionProc",
            "    onExited: {",
            "      root.refresh()",
            "      settleTimer.restart()",
            "    }",
            "  }",
        ])
        assert old_action_proc in pp_txt, "power/Panel.qml actionProc block not found"
        pp_txt = pp_txt.replace(old_action_proc, new_action_proc, 1)

        old_slot = "    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)"
        new_slot = "    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? (Math.round(root.batteryFraction * 100) >= 100 ? 2.2 : 2) : 1)"
        assert old_slot in pp_txt, "power/Panel.qml slotSize line not found"
        pp_txt = pp_txt.replace(old_slot, new_slot, 1)

        old_stats = "\n".join([
            "          Column {",
            "            width: (parent.width - parent.spacing) / 2",
            "            spacing: Style.spacing.labelGap",
            '            InfoPair { label: Commons.I18n.t("power.batterySize"); value: root.reading(root.batteryInfo.size) }',
            '            InfoPair { label: Commons.I18n.t("power.chargeCycles"); value: root.reading(root.batteryInfo.cycles) || "—" }',
            "          }",
            "",
            "          Column {",
            "            width: (parent.width - parent.spacing) / 2",
            "            spacing: Style.spacing.labelGap",
            "            InfoPair {",
            '              label: root.chargeThresholdActive ? Commons.I18n.t("power.chargeLimit") : (root.discharging ? Commons.I18n.t("power.timeLeft") : Commons.I18n.t("power.timeToFull"))',
            '              value: root.chargeThresholdActive ? (root.reading(root.batteryInfo.threshold) || "-") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))',
            "            }",
            "            InfoPair {",
            '              label: root.chargeThresholdActive ? Commons.I18n.t("power.batteryState") : (root.discharging ? Commons.I18n.t("power.discharging") : Commons.I18n.t("power.charging"))',
            '              value: root.chargeThresholdActive ? Commons.I18n.t("power.holding") : (root.batteryFull ? "-" : root.reading(root.batteryInfo.rate))',
            "            }",
            "          }",
        ])
        new_stats = "\n".join([
            "          Column {",
            "            width: (parent.width - parent.spacing) / 2",
            "            spacing: Style.spacing.labelGap",
            "            InfoPair {",
            '              label: Commons.I18n.t("power.batterySize")',
            '              value: root.reading(root.batteryInfo.size) + (root.batteryInfo.health ? " · " + root.reading(root.batteryInfo.health) : "")',
            "            }",
            "            InfoPair {",
            '              label: Commons.I18n.t("power.chargeCycles")',
            '              value: (root.reading(root.batteryInfo.cycles) || "—") + (root.batteryInfo.temp ? " · " + root.reading(root.batteryInfo.temp) : "")',
            "            }",
            "          }",
            "",
            "          Column {",
            "            width: (parent.width - parent.spacing) / 2",
            "            spacing: Style.spacing.labelGap",
            "            InfoPair {",
            "              readonly property bool armedCap: !root.discharging && root.batteryFull && root.chargeLimitEnd < 100",
            '              label: (root.chargeThresholdActive || armedCap) ? Commons.I18n.t("power.chargeLimit") : (root.discharging ? Commons.I18n.t("power.timeLeft") : Commons.I18n.t("power.timeToFull"))',
            '              value: root.chargeThresholdActive ? (root.reading(root.batteryInfo.threshold) || "-") : (armedCap ? root.reading(String(root.chargeLimitEnd) + "%") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—")))',
            "            }",
            "            InfoPair {",
            '              readonly property string sysWatts: root.reading(root.batteryInfo.sys_power)',
            '              label: root.chargeThresholdActive ? Commons.I18n.t("power.batteryState") : (root.batteryFull && sysWatts !== "" ? "System power" : (root.discharging ? Commons.I18n.t("power.discharging") : Commons.I18n.t("power.charging")))',
            '              value: root.chargeThresholdActive ? (sysWatts !== "" ? Commons.I18n.t("power.holding") + " · " + sysWatts : Commons.I18n.t("power.holding")) : (root.batteryFull ? (sysWatts !== "" ? sysWatts : "-") : root.reading(root.batteryInfo.rate))',
            "            }",
            "          }",
        ])
        assert old_stats in pp_txt, "power/Panel.qml Stats block not found"
        pp_txt = pp_txt.replace(old_stats, new_stats, 1)

        old_prof_sec = "\n".join([
            "        // ---------- Power profile picker ----------",
            "        PanelSeparator {",
            "          foreground: root.bar.foreground",
            "        }",
        ])
        new_prof_sec = "\n".join([
            "        // ---------- Charge limit toggle ----------",
            "        PanelSeparator {",
            "          visible: root.chargeLimitSupported",
            "          foreground: root.bar.foreground",
            "        }",
            "",
            "        Column {",
            "          visible: root.chargeLimitSupported",
            "          width: parent.width",
            "          spacing: Style.space(10)",
            "",
            "          PanelSectionHeader {",
            '            text: Commons.I18n.t("power.chargeLimit").toUpperCase()',
            "            foreground: root.bar.foreground",
            "            fontFamily: root.bar.fontFamily",
            "          }",
            "",
            "          Row {",
            "            id: chargeLimitRow",
            "            width: parent.width",
            "            spacing: Style.space(6)",
            "            readonly property real cellWidth: (width - spacing) / 2",
            "",
            "            Button {",
            "              width: chargeLimitRow.cellWidth",
            '              iconText: "󰂄"',
            "              iconSize: Style.font.title",
            '              text: root.reading(root.chargeLimitDaily + "%") + " Daily"',
            "              fontSize: Style.font.bodySmall",
            "              foreground: root.bar.foreground",
            "              fontFamily: root.bar.fontFamily",
            "              horizontalPadding: Style.spacing.controlPaddingX",
            "              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)",
            "              bordered: true",
            "              active: root.chargeLimitEnd < 100",
            '              onClicked: root.setChargeLimit("daily")',
            "            }",
            "",
            "            Button {",
            "              width: chargeLimitRow.cellWidth",
            '              iconText: "󰂅"',
            "              iconSize: Style.font.title",
            '              text: root.reading("100%") + " Full"',
            "              fontSize: Style.font.bodySmall",
            "              foreground: root.bar.foreground",
            "              fontFamily: root.bar.fontFamily",
            "              horizontalPadding: Style.spacing.controlPaddingX",
            "              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)",
            "              bordered: true",
            "              active: root.chargeLimitEnd >= 100",
            '              onClicked: root.setChargeLimit("full")',
            "            }",
            "          }",
            "        }",
            "",
            "        // ---------- Power profile picker ----------",
            "        PanelSeparator {",
            "          foreground: root.bar.foreground",
            "        }",
        ])
        assert old_prof_sec in pp_txt, "power/Panel.qml Power profile separator not found"
        pp_txt = pp_txt.replace(old_prof_sec, new_prof_sec, 1)

        old_prof_end = "\n".join([
            "              }",
            "            }",
            "          }",
            "        }",
            "      }",
            "    }",
            "  }",
        ])
        new_prof_end = "\n".join([
            "              }",
            "            }",
            "          }",
            "        }",
            "",
            "        // ---------- Using significant energy ----------",
            "        PanelSeparator {",
            "          visible: root.topConsumers.length > 0",
            "          foreground: root.bar.foreground",
            "        }",
            "",
            "        Column {",
            "          visible: root.topConsumers.length > 0",
            "          width: parent.width",
            "          spacing: Style.space(8)",
            "",
            "          Item {",
            "            width: parent.width",
            "            implicitHeight: Math.max(consumersTitle.implicitHeight, consumersMeta.implicitHeight)",
            "",
            "            PanelSectionHeader {",
            "              id: consumersTitle",
            "              anchors.left: parent.left",
            "              anchors.verticalCenter: parent.verticalCenter",
            '              text: "SIGNIFICANT ENERGY"',
            "              foreground: root.bar.foreground",
            "              fontFamily: root.bar.fontFamily",
            "            }",
            "",
            "            Text {",
            "              id: consumersMeta",
            "              anchors.right: parent.right",
            "              anchors.verticalCenter: parent.verticalCenter",
            "              textFormat: Text.PlainText",
            "              color: Qt.darker(root.bar.foreground, 1.4)",
            "              font.family: root.bar.fontFamily",
            "              font.pixelSize: Style.font.caption",
            "              text: {",
            "                var parts = []",
            '                if (root.systemInfo.cpu) parts.push("CPU " + root.reading(root.systemInfo.cpu))',
            "                if (root.batteryInfo.sys_power) parts.push(root.reading(root.batteryInfo.sys_power))",
            '                return parts.join(" · ")',
            "              }",
            "            }",
            "          }",
            "",
            "          Column {",
            "            width: parent.width",
            "            spacing: Style.spacing.labelGap",
            "",
            "            Repeater {",
            "              model: root.topConsumers",
            "              InfoPair {",
            "                required property var modelData",
            '                label: String(modelData.name || "")',
            '                value: root.reading(modelData.cpu) + " · " + root.reading(modelData.memory)',
            "              }",
            "            }",
            "          }",
            "        }",
            "      }",
            "    }",
            "  }",
        ])
        assert old_prof_end in pp_txt, "power/Panel.qml profile end block not found"
        pp_txt = pp_txt.replace(old_prof_end, new_prof_end, 1)

        power_panel_qml.write_text(pp_txt, encoding="utf-8")
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

        chmod -R u+w "$out/shell/plugins/osd"
        cp --remove-destination --no-preserve=mode "${./osd/OsdModel.js}" "$out/shell/plugins/osd/OsdModel.js"
        cp --remove-destination --no-preserve=mode "${./osd/Osd.qml}" "$out/shell/plugins/osd/Osd.qml"

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

        cp --remove-destination --no-preserve=mode "${./omarchy-power}"/* "$out/bin/"
        chmod 0755 \
          "$out/bin/omarchy-powerprofiles-list" \
          "$out/bin/omarchy-powerprofiles-set" \
          "$out/bin/omarchy-battery-charge-limit" \
          "$out/bin/omarchy-power-consumers"

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
      case "$script_name" in
        omarchy-shell-config|omarchy-sudo-keepalive|omarchy-branding-about-animation|omarchy-restart-gum)
          ln -s "$script" "$out/bin/$script_name"
          continue
          ;;
      esac
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
