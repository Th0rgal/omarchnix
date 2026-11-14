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

  patchAgentsPy = pkgs.writeText "patch-omarchy-agents.py" (
    builtins.readFile ./omarchy-shell/patch-agents.py
  );

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
