{
  lib,
  pkgs,
  omarchySrc,
  marketplaceSrc ? null,
}:
let
  omarchyRuntimePath = lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.curl
    pkgs.findutils
    pkgs.gawk
    pkgs.git
    pkgs.glib
    pkgs.gsettings-desktop-schemas
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gum
    pkgs.hyprland
    pkgs.imagemagick
    pkgs.inotify-tools
    pkgs.jq
    pkgs.libnotify
    pkgs.openssh
    pkgs.procps
    pkgs.psmisc
    pkgs.python3
    pkgs.quickshell
    pkgs.ripgrep
    pkgs.socat
    pkgs.systemd
    pkgs.util-linux
    pkgs.vips
    pkgs.wl-clipboard
  ];

  omarchyShare =
    pkgs.runCommand "omarchy-share"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.python3
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
          --replace-fail '"/usr/bin/python3"' '"${pkgs.python3}/bin/python3"'

        substituteInPlace "$out/shell/plugins/panels/elsewhen/Panel.qml" \
          --replace-fail '"/usr/share/zoneinfo/zone1970.tab"' '"${pkgs.tzdata}/share/zoneinfo/zone1970.tab"'

        substituteInPlace "$out/bin/omarchy-shell" \
          --replace-fail 'socat -t 86400 - "UNIX-CONNECT:$socket"' 'socat -t 86400 STDIO,shut-none "UNIX-CONNECT:$socket"'

        substituteInPlace "$out/shell/plugins/bar/widgets/Workspaces.qml" \
          --replace-fail 'var target = ids[Util.clamp(index - wheel.steps, 0, ids.length - 1)]' 'var target = ids[Util.clamp(index + wheel.steps, 0, ids.length - 1)]'

        substituteInPlace "$out/bin/omarchy-theme-set-browser" \
          --replace-fail 'omarchy-theme-set-browser-policy "''${THEME_HEX_COLOR#\#}" <&0 &' 'if [ "''${saw_any}" = "true" ]; then omarchy-theme-set-browser-policy "''${THEME_HEX_COLOR#\#}" <&0 & policy_pid=$!; else policy_pid=""; fi' \
          --replace-fail 'policy_pid=$!' ':' \
          --replace-fail 'wait "$policy_pid" || failed=1' 'if [ -n "$policy_pid" ]; then wait "$policy_pid" || failed=1; fi'

        chmod -R u+w "$out"
        for f in "$out"/bin/* "$out/default/input-methods/typing_setup.py"; do
          [ -f "$f" ] || continue
          sed -i 's|/usr/bin/python3|${pkgs.python3}/bin/python3|g' "$f"
        done
        find "$out/shell" -type f -name '*.sh' -exec chmod +x {} +
        find "$out/bin" -type f -exec chmod +x {} +
        patchShebangs "$out/shell" "$out/bin"
      '';
in
pkgs.runCommand "omarchy-shell"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
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

    # glib's gsettings only honours GSETTINGS_SCHEMA_DIR here, so point it at the
    # gsettings-desktop-schemas store layout that omarchy-theme-set-gnome needs.
    gsettings_schema_dir="$(echo "${pkgs.gsettings-desktop-schemas}"/share/gsettings-schemas/*/glib-2.0/schemas)"
    for script in "$out/share/omarchy/bin"/*; do
      [ -f "$script" ] || continue
      script_name="$(basename "$script")"
      makeWrapper "$script" "$out/bin/$script_name" \
        --set-default OMARCHY_PATH "${omarchyShare}" \
        --prefix PATH : "$out/bin:${omarchyRuntimePath}" \
        --set-default GSETTINGS_SCHEMA_DIR "$gsettings_schema_dir" \
        --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share"
    done

    ln -s "${pkgs.quickshell}/bin/quickshell" "$out/bin/quickshell"
    if [ -x "${pkgs.quickshell}/bin/qs" ]; then
      ln -s "${pkgs.quickshell}/bin/qs" "$out/bin/qs"
    else
      ln -s "${pkgs.quickshell}/bin/quickshell" "$out/bin/qs"
    fi
  ''
