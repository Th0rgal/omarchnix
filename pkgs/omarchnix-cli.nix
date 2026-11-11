{
  pkgs,
  omarchyShell,
  marketplaceSrc ? null,
}:
let
  registryPath = if marketplaceSrc != null then "${marketplaceSrc}/registry.json" else "";
in
pkgs.writeShellApplication {
  name = "omarchnix";
  runtimeInputs = [
    omarchyShell
    pkgs.bash
    pkgs.brightnessctl
    pkgs.coreutils
    pkgs.curl
    pkgs.dbus
    pkgs.dconf
    pkgs.findutils
    pkgs.gawk
    pkgs.git
    pkgs.glib
    pkgs.glib.bin
    pkgs.gsettings-desktop-schemas
    pkgs.gnugrep
    pkgs.gnused
    pkgs.hyprland
    pkgs.jq
    pkgs.nix
    pkgs.procps
    pkgs.python3
    pkgs.systemd
    pkgs.wayland-utils
  ];
  text = ''
    set -euo pipefail

    if [[ -z "''${XDG_RUNTIME_DIR:-}" ]]; then
      uid_runtime_dir="/run/user/$(id -u)"
      if [[ -d "$uid_runtime_dir" ]]; then
        XDG_RUNTIME_DIR="$uid_runtime_dir"
        export XDG_RUNTIME_DIR
      fi
    fi
    if [[ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" && -n "''${XDG_RUNTIME_DIR:-}" && -S "$XDG_RUNTIME_DIR/bus" ]]; then
      DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
      export DBUS_SESSION_BUS_ADDRESS
    fi

    export OMARCHY_PATH="''${OMARCHY_PATH:-${omarchyShell.sharePath}}"
    export OMARCHY_SHELL_IPC_TIMEOUT="''${OMARCHY_SHELL_IPC_TIMEOUT:-10s}"
    export GIO_EXTRA_MODULES="${pkgs.dconf.lib}/lib/gio/modules''${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"
    if [[ -z "''${GSETTINGS_SCHEMA_DIR:-}" ]]; then
      for schema_candidate in "${pkgs.gsettings-desktop-schemas}"/share/gsettings-schemas/*/glib-2.0/schemas; do
        if [[ -d "$schema_candidate" ]]; then
          export GSETTINGS_SCHEMA_DIR="$schema_candidate"
          break
        fi
      done
    fi
    MARKETPLACE_REGISTRY_DEFAULT="${registryPath}"
    MARKETPLACE_REGISTRY_URL="https://raw.githubusercontent.com/omacom/omarchy-plugin-marketplace/main/registry.json"

    usage() {
      cat <<'EOF'
    Usage: omarchnix <command> [args...]

    Agent-first declarative NixOS & Omarchy workstation CLI.

    Commands:
      status [--json]                     Inspect current theme, shell backend, plugins, and agent skills
      check [--flake <dir>] [--json]      Validate runtime state and optional flake metadata
      theme list [--json]                 List all available Omarchy themes (bundled + user)
      theme current                       Print the active Omarchy theme
      theme set <name> [--offline]        Live-switch the active Omarchy theme across shell, foot, Hyprland, and agents
      theme toggle [--dark <t>] [--light <t>]  Toggle between dark (default: tokyo-night) and light (default: white) themes
      theme palette <name> [--json]       Resolve semantic & ANSI palette for any Omarchy theme
      plugin registry [query] [--json]    Search the plugins.omarchy.org marketplace registry
      plugin install <id|url> [--enable]  Install a plugin from plugins.omarchy.org or git URL (non-interactive --yes supported)
      plugin list [--json]                List discovered first-party and third-party Omarchy shell plugins
      plugin enable <id> [placement...]   Enable an installed Omarchy shell plugin
      plugin disable <id>                 Disable an Omarchy shell plugin
      plugin validate <dir>               Validate a plugin folder against Omarchy manifest schema v1
      kbd-backlight [get|<N>%|up|down|cycle|off]  Inspect or adjust keyboard backlight brightness
    EOF
    }

    resolve_registry_file() {
      local cache_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/omarchnix"
      local cached="$cache_dir/plugins-registry.json"
      if [[ -f "$cached" ]]; then
        printf '%s\n' "$cached"
        return 0
      fi
      if [[ -n "$MARKETPLACE_REGISTRY_DEFAULT" && -f "$MARKETPLACE_REGISTRY_DEFAULT" ]]; then
        printf '%s\n' "$MARKETPLACE_REGISTRY_DEFAULT"
        return 0
      fi
      if [[ -f "$OMARCHY_PATH/marketplace/registry.json" ]]; then
        printf '%s\n' "$OMARCHY_PATH/marketplace/registry.json"
        return 0
      fi
      mkdir -p "$cache_dir"
      curl -fsSL "$MARKETPLACE_REGISTRY_URL" -o "$cached"
      printf '%s\n' "$cached"
    }

    cmd_status() {
      local want_json=0
      if [[ "''${1:-}" == "--json" ]]; then
        want_json=1
      fi

      local theme_name="unknown"
      if [[ -f "$HOME/.local/state/omarchy/current/theme.name" ]]; then
        theme_name="$(tr -d '\n' < "$HOME/.local/state/omarchy/current/theme.name")"
      fi

      local shell_running="false"
      if omarchy-shell -q shell ping >/dev/null 2>&1 && [[ "$(omarchy-shell shell ping 2>/dev/null || true)" != "" ]]; then
        shell_running="true"
      elif pgrep -x quickshell >/dev/null 2>&1; then
        shell_running="true"
      fi

      local waybar_running="false"
      if pgrep -x waybar >/dev/null 2>&1; then
        waybar_running="true"
      fi

      local plugins_dir="$HOME/.config/omarchy/plugins"
      local installed_third_party="[]"
      if [[ -d "$plugins_dir" ]]; then
        installed_third_party="$(
          find "$plugins_dir" -mindepth 2 -maxdepth 2 -type f -name manifest.json ! -path "$plugins_dir/.*/*" 2>/dev/null \
            | sort \
            | xargs -r jq -sc '[.[] | {id: .id, name: .name, version: .version, kinds: .kinds}]'
        )"
      fi

      local skills_present=()
      for d in \
        "$HOME/.agents/skills/omarchnix" \
        "$HOME/.claude/skills/omarchnix" \
        "$HOME/.codex/skills/omarchnix" \
        "$HOME/.hermes/skills/omarchnix"; do
        if [[ -f "$d/SKILL.md" ]]; then
          skills_present+=("$d")
        fi
      done
      local skills_json
      if (( ''${#skills_present[@]} == 0 )); then
        skills_json="[]"
      else
        skills_json="$(printf '%s\n' "''${skills_present[@]}" | jq -R . | jq -s .)"
      fi

      if (( want_json )); then
        jq -nc \
          --arg theme "$theme_name" \
          --arg omarchyPath "$OMARCHY_PATH" \
          --argjson shellRunning "$shell_running" \
          --argjson waybarRunning "$waybar_running" \
          --argjson thirdPartyPlugins "$installed_third_party" \
          --argjson agentSkills "$skills_json" \
          '{
            theme: $theme,
            omarchyPath: $omarchyPath,
            shellRunning: $shellRunning,
            waybarRunning: $waybarRunning,
            thirdPartyPlugins: $thirdPartyPlugins,
            agentSkills: $agentSkills
          }'
      else
        echo "Theme:          $theme_name"
        echo "OMARCHY_PATH:   $OMARCHY_PATH"
        echo "omarchy-shell:  $shell_running"
        echo "waybar:         $waybar_running"
        echo "3rd-party:      $(jq -r 'map(.id) | if length == 0 then "none" else join(", ") end' <<<"$installed_third_party")"
        echo "Agent skills:   $(jq -r 'length' <<<"$skills_json") installed"
      fi
    }

    cmd_check() {
      local flake_dir=""
      local want_json=0
      while (( $# > 0 )); do
        case "$1" in
          --flake)
            if [[ $# -lt 2 || -z "''${2:-}" ]]; then
              echo "omarchnix check: --flake requires a directory" >&2
              exit 2
            fi
            flake_dir="$2"
            shift 2
            ;;
          --json)
            want_json=1
            shift
            ;;
          *)
            echo "omarchnix check: unknown option: $1" >&2
            exit 2
            ;;
        esac
      done

      local ok=true
      local checks=()

      if [[ -f "$OMARCHY_PATH/shell/shell.qml" ]]; then
        checks+=("shell_qml:ok")
      else
        checks+=("shell_qml:missing")
        ok=false
      fi

      local theme_count
      theme_count="$(find "$OMARCHY_PATH/themes" -mindepth 2 -maxdepth 2 -name colors.toml 2>/dev/null | wc -l | tr -d ' ')"
      if (( theme_count >= 23 )); then
        checks+=("bundled_themes:$theme_count")
      else
        checks+=("bundled_themes_insufficient:$theme_count")
        ok=false
      fi

      if [[ -d "$HOME/.config/omarchy/plugins" ]]; then
        while IFS= read -r pdir; do
          [[ -n "$pdir" ]] || continue
          if omarchy-plugin-validate "$pdir" >/dev/null 2>&1; then
            checks+=("plugin:$(basename "$pdir"):ok")
          else
            checks+=("plugin:$(basename "$pdir"):invalid")
            ok=false
          fi
        done < <(find "$HOME/.config/omarchy/plugins" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)
      fi

      if [[ -n "$flake_dir" ]]; then
        if nix --extra-experimental-features 'nix-command flakes' flake metadata "$flake_dir" >/dev/null 2>&1; then
          checks+=("flake_metadata:ok")
        else
          checks+=("flake_metadata:failed")
          ok=false
        fi
      fi

      local checks_json
      checks_json="$(printf '%s\n' "''${checks[@]}" | jq -R . | jq -s .)"

      if (( want_json )); then
        jq -nc \
          --argjson ok "$ok" \
          --argjson checks "$checks_json" \
          '{ ok: $ok, checks: $checks }'
      else
        printf '%s\n' "''${checks[@]}"
      fi

      [[ "$ok" == "true" ]]
    }

    normalize_slug() {
      printf '%s' "$1" | sed -E 's/<[^>]+>//g' | tr '[:upper:]' '[:lower:]' | tr ' _' '--'
    }

    theme_exists() {
      local slug
      slug="$(normalize_slug "$1")"
      [[ -n "$slug" ]] && [[ -d "$HOME/.config/omarchy/themes/$slug" || -d "$OMARCHY_PATH/themes/$slug" ]]
    }

    theme_has_background() {
      local slug
      slug="$(normalize_slug "$1")"
      [[ -n "$slug" ]] || return 1
      local bg
      bg="$(
        find -L \
          "$HOME/.config/omarchy/backgrounds/$slug" \
          "$HOME/.config/omarchy/themes/$slug/backgrounds" \
          "$OMARCHY_PATH/themes/$slug/backgrounds" \
          -maxdepth 1 -type f 2>/dev/null | head -n 1
      )"
      [[ -n "$bg" ]]
    }

    run_theme_set() {
      local target="$1"
      local offline="''${2:-0}"
      local preserve_user_bg="''${3:-0}"
      local state_bg_file="$HOME/.local/state/omarchy/theme-backgrounds/$target"

      # Drop stale build-time fallback wallpapers (e.g. omarchnix-wallpaper-tokyo-night.png)
      # accidentally recorded under another theme's remembered background slot.
      if [[ -f "$state_bg_file" ]]; then
        local remembered_bg
        remembered_bg="$(tr -d '\n' < "$state_bg_file" 2>/dev/null || true)"
        if [[ "$remembered_bg" == /nix/store/*-omarchnix-wallpaper-* && "$remembered_bg" != *"-omarchnix-wallpaper-''${target}.png" ]]; then
          rm -f "$state_bg_file"
        fi
      fi

      local skip_bg=0
      if (( preserve_user_bg )); then
        local cur_bg
        cur_bg="$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true)"
        if [[ -n "$cur_bg" && -f "$cur_bg" ]] \
          && [[ "$cur_bg" != "$HOME/.config/omarchy/themes/"* ]] \
          && [[ "$cur_bg" != "$HOME/.local/state/omarchy/current/theme/backgrounds/"* ]] \
          && [[ "$cur_bg" != "$OMARCHY_PATH/themes/"* ]] \
          && [[ "$cur_bg" != /nix/store/*-omarchnix-wallpaper-* ]] \
          && [[ "$cur_bg" != /nix/store/*-omarchy-theme-* ]]; then
          skip_bg=1
        fi
      fi

      if (( offline )); then
        OMARCHNIX_SYNCING_MODE=1 OMARCHY_THEME_OFFLINE=1 OMARCHY_THEME_SKIP_BACKGROUND=1 omarchy-theme-set "$target"
      elif (( skip_bg )) || ! theme_has_background "$target"; then
        OMARCHNIX_SYNCING_MODE=1 OMARCHY_THEME_WAIT=1 OMARCHY_THEME_SKIP_BACKGROUND=1 omarchy-theme-set "$target"
      else
        OMARCHNIX_SYNCING_MODE=1 OMARCHY_THEME_WAIT=1 omarchy-theme-set "$target"
      fi
    }

    pulse_hyprland_global_theme() {
      local bg_hex="''${1:-}"
      command -v hyprctl >/dev/null 2>&1 || return 0
      if [[ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        local sig
        sig="$(hyprctl instances -j 2>/dev/null | jq -r '.[0].instance // ""' 2>/dev/null || true)"
        [[ -n "$sig" ]] || return 0
        export HYPRLAND_INSTANCE_SIGNATURE="$sig"
      fi

      # On Wayland/Hyprland, windows on non-visible desktops receive zero frame
      # callbacks by default, leaving inactive desktops frozen in the previous
      # Light/Dark buffer in Mission Control thumbnails and workspace swipes.
      # Temporarily enable `render_unfocused` across all windows for 1.8s (15 FPS)
      # so every desktop repaints immediately with zero idle battery cost.
      local bg_lua=""
      if [[ -n "$bg_hex" ]]; then
        bg_lua="pcall(function() hl.config({ misc = { background_color = 'rgba(' .. \"$bg_hex\" .. 'ff)' } }) end)"
      fi
      hyprctl eval "
        $bg_lua
        local ok = false
        if _G.omarchnix_unfocused_repaint_rule then
          ok = pcall(function() _G.omarchnix_unfocused_repaint_rule:set_enabled(true) end)
        end
        if not ok then
          _G.omarchnix_unfocused_repaint_rule = hl.window_rule({
            name = 'omarchnix-theme-repaint',
            match = { class = '.*' },
            render_unfocused = true,
          })
        end
        pcall(function() hl.exec_scheduled_prop_refresh_immediately() end)
        _G.omarchnix_unfocused_repaint_seq = (_G.omarchnix_unfocused_repaint_seq or 0) + 1
        local seq = _G.omarchnix_unfocused_repaint_seq
        hl.timer(function()
          if _G.omarchnix_unfocused_repaint_seq == seq and _G.omarchnix_unfocused_repaint_rule then
            pcall(function() _G.omarchnix_unfocused_repaint_rule:set_enabled(false) end)
            pcall(function() hl.exec_scheduled_prop_refresh_immediately() end)
          end
        end, { timeout = 1800, type = 'oneshot' })
      " >/dev/null 2>&1 || true
    }

    apply_interface_mode() {
      local force_signal="''${1:-0}"
      local colors_file="$HOME/.local/state/omarchy/current/theme/colors.toml"
      local mode="dark"
      local bg_hex=""
      if [[ -f "$colors_file" ]]; then
        mode="$(omarchy-theme-color --file "$colors_file" mode 2>/dev/null || echo dark)"
        bg_hex="$(omarchy-theme-color --file "$colors_file" background 2>/dev/null | tr -d '#' || true)"
        [[ "$bg_hex" =~ ^[0-9A-Fa-f]{6}$ ]] || bg_hex=""
      fi
      local scheme="prefer-dark"
      local gtk_theme="Adwaita-dark"
      if [[ "$mode" == "light" ]]; then
        scheme="prefer-light"
        gtk_theme="Adwaita"
      fi

      # Ensure xdg-desktop-portal (+ gtk Settings backend) is D-Bus activated and
      # subscribed to dconf before writing so SettingChanged is never missed.
      if [[ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v gdbus >/dev/null 2>&1; then
        gdbus call --session --timeout 2 \
          --dest org.freedesktop.portal.Desktop \
          --object-path /org/freedesktop/portal/desktop \
          --method org.freedesktop.portal.Settings.Read \
          org.freedesktop.appearance color-scheme >/dev/null 2>&1 || true
      fi

      # dconf is authoritative for the xdg-desktop-portal-gtk Settings backend
      # (Electron, WebKitGTK/Orb, Qt6/Telegram, and Chromium/Brave read dark/light
      # preference there). When `--force-signal` is requested (login, portal
      # restart, or HM activation) and dconf already holds `$scheme`, bounce
      # briefly via `'default'` so dconf-service -> xdg-desktop-portal-gtk emits
      # a real `org.freedesktop.portal.Settings.SettingChanged` D-Bus signal.
      if command -v dconf >/dev/null 2>&1; then
        if [[ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
          local cur_dconf_scheme
          cur_dconf_scheme="$(dconf read /org/gnome/desktop/interface/color-scheme 2>/dev/null || true)"
          if (( force_signal )) && [[ "$cur_dconf_scheme" == "'$scheme'" ]]; then
            dconf write /org/gnome/desktop/interface/color-scheme "'default'" 2>/dev/null || true
            sleep 0.015
          fi
          dconf write /org/gnome/desktop/interface/color-scheme "'$scheme'" 2>/dev/null || true
          dconf write /org/gnome/desktop/interface/gtk-theme "'$gtk_theme'" 2>/dev/null || true
          dconf write /org/gnome/desktop/wm/preferences/button-layout "':'" 2>/dev/null || true
          dconf write /org/gnome/desktop/wm/preferences/theme "'$gtk_theme'" 2>/dev/null || true
          if [[ "$(dconf read /org/gnome/desktop/interface/icon-theme 2>/dev/null || true)" == "'Yaru-blue'" ]]; then
            dconf write /org/gnome/desktop/interface/icon-theme "'Adwaita'" 2>/dev/null || true
          fi
        elif command -v dbus-run-session >/dev/null 2>&1; then
          dbus-run-session -- sh -c '
            dconf write /org/gnome/desktop/interface/color-scheme "'"'$scheme'"'" 2>/dev/null || true
            dconf write /org/gnome/desktop/interface/gtk-theme "'"'$gtk_theme'"'" 2>/dev/null || true
            dconf write /org/gnome/desktop/wm/preferences/button-layout "'"':'"'" 2>/dev/null || true
            dconf write /org/gnome/desktop/wm/preferences/theme "'"'$gtk_theme'"'" 2>/dev/null || true
          ' >/dev/null 2>&1 || true
        fi
      fi
      if [[ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v gsettings >/dev/null 2>&1 \
        && gsettings get org.gnome.desktop.interface color-scheme >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.interface color-scheme "$scheme" 2>/dev/null || true
        gsettings set org.gnome.desktop.interface gtk-theme "$gtk_theme" 2>/dev/null || true
        gsettings set org.gnome.desktop.wm.preferences button-layout ":" 2>/dev/null || true
        gsettings set org.gnome.desktop.wm.preferences theme "$gtk_theme" 2>/dev/null || true
      fi

      # Ensure Antigravity 2.0 (Hub) & Antigravity IDE follow system color-scheme
      # instead of defaulting THEME_MODE_UNSPECIFIED (0) -> Dark.
      local ag_cfg="$HOME/.gemini/config/config.json"
      if [[ -f "$ag_cfg" && ! -L "$ag_cfg" ]]; then
        local cur_ag_mode
        cur_ag_mode="$(jq -r '.userSettings.themeMode // ""' "$ag_cfg" 2>/dev/null || true)"
        if [[ -z "$cur_ag_mode" || "$cur_ag_mode" == "null" || "$cur_ag_mode" == "0" || "$cur_ag_mode" == "THEME_MODE_UNSPECIFIED" ]]; then
          local tmp_ag
          tmp_ag="$(mktemp "$ag_cfg.XXXXXX")"
          if jq '.userSettings = ((.userSettings // {}) | .themeMode = "THEME_MODE_INHERIT")' "$ag_cfg" > "$tmp_ag" 2>/dev/null; then
            chmod 0600 "$tmp_ag"
            mv "$tmp_ag" "$ag_cfg"
          else
            rm -f "$tmp_ag"
          fi
          local ag_port ag_csrf
          ag_port="$(grep -Eo 'https://127\.0\.0\.1:[0-9]+' "$HOME/.config/Antigravity/logs/main.log" 2>/dev/null | tail -n 1 | sed 's/.*://' || true)"
          ag_csrf="$(ps -eo args 2>/dev/null | sed -nE 's/.*language_server .*--csrf_token ([0-9a-fA-F-]+).*/\1/p' | head -n 1 || true)"
          if [[ -n "$ag_port" && -n "$ag_csrf" ]]; then
            curl -ksS --max-time 2 \
              -X POST "https://127.0.0.1:''${ag_port}/exa.language_server_pb.LanguageServerService/JetboxWriteState" \
              -H "Content-Type: application/json" \
              -H "Connect-Protocol-Version: 1" \
              -H "x-codeium-csrf-token: ''${ag_csrf}" \
              -d '{"userConfig":{"userSettings":{"themeMode":"THEME_MODE_INHERIT"}}}' >/dev/null 2>&1 || true
          fi
        fi
      fi

      local ag_ide_cfg="$HOME/.config/Antigravity IDE/User/settings.json"
      if [[ -f "$ag_ide_cfg" && ! -L "$ag_ide_cfg" ]]; then
        if [[ "$(jq -r 'has("window.autoDetectColorScheme") and has("window.controlsStyle")' "$ag_ide_cfg" 2>/dev/null || echo true)" == "false" ]]; then
          local tmp_ide
          tmp_ide="$(mktemp "$ag_ide_cfg.XXXXXX")"
          if jq '
            .["window.autoDetectColorScheme"] = (if has("window.autoDetectColorScheme") then .["window.autoDetectColorScheme"] else true end)
            | .["window.controlsStyle"] = (.["window.controlsStyle"] // "hidden")
          ' "$ag_ide_cfg" > "$tmp_ide" 2>/dev/null; then
            chmod 0644 "$tmp_ide"
            mv "$tmp_ide" "$ag_ide_cfg"
          else
            rm -f "$tmp_ide"
          fi
        fi
      fi

      # Ensure Brave defaults to "Same as Linux" (`dark_mode = 0`) when unset,
      # and refresh managed BrowserColorScheme="device" policy if running.
      local brave_state="$HOME/.config/BraveSoftware/Brave-Browser/Local State"
      if [[ -f "$brave_state" && ! -L "$brave_state" ]] && ! pgrep -f 'brave-browser|BraveSoftware/Brave-Browser' >/dev/null 2>&1; then
        if [[ "$(jq -r '.brave.dark_mode // "unset"' "$brave_state" 2>/dev/null || echo 0)" == "unset" ]]; then
          local tmp_brave
          tmp_brave="$(mktemp "$brave_state.XXXXXX")"
          if jq '.brave = ((.brave // {}) | .dark_mode = 0)' "$brave_state" > "$tmp_brave" 2>/dev/null; then
            chmod 0600 "$tmp_brave"
            mv "$tmp_brave" "$brave_state"
          else
            rm -f "$tmp_brave"
          fi
        fi
      fi
      if [[ -e /etc/brave/policies/managed ]] && command -v brave >/dev/null 2>&1 && pgrep -f 'brave-browser|BraveSoftware/Brave-Browser' >/dev/null 2>&1; then
        brave --refresh-platform-policy --no-startup-window </dev/null >/dev/null 2>&1 &
      fi

      pulse_hyprland_global_theme "$bg_hex"
    }

    cmd_theme() {
      local sub="''${1:-list}"
      shift || true
      case "$sub" in
        list)
          if [[ "''${1:-}" == "--json" ]]; then
            {
              if [[ -d "$HOME/.config/omarchy/themes" ]]; then
                find "$HOME/.config/omarchy/themes" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -printf '%f\n'
              fi
              find "$OMARCHY_PATH/themes" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
            } | sort -u | jq -R . | jq -s .
          else
            omarchy-theme-list
          fi
          ;;
        current)
          omarchy-theme-current
          ;;
        sync-mode)
          local force_signal=1
          while (( $# > 0 )); do
            case "$1" in
              --force-signal)
                force_signal=1
                shift
                ;;
              --no-force-signal)
                force_signal=0
                shift
                ;;
              *)
                shift
                ;;
            esac
          done
          apply_interface_mode "$force_signal"
          ;;
        set)
          local name=""
          local offline=0
          while (( $# > 0 )); do
            case "$1" in
              --offline | --headless)
                offline=1
                shift
                ;;
              *)
                if [[ -z "$name" ]]; then
                  name="$1"
                else
                  name="$name $1"
                fi
                shift
                ;;
            esac
          done
          [[ -n "$name" ]] || { echo "Usage: omarchnix theme set <name> [--offline]" >&2; exit 1; }
          run_theme_set "$name" "$offline"
          apply_interface_mode
          ;;
        toggle)
          local pair_file="$HOME/.config/omarchy/theme-pair.json"
          local default_dark="tokyo-night"
          local default_light="white"
          if [[ -f "$pair_file" ]]; then
            default_dark="$(jq -r '.dark // "tokyo-night"' "$pair_file" 2>/dev/null || echo "tokyo-night")"
            default_light="$(jq -r '.light // "white"' "$pair_file" 2>/dev/null || echo "white")"
          fi
          local dark_theme="$default_dark"
          local light_theme="$default_light"
          local explicit_dark=0
          local explicit_light=0
          local offline=0
          while (( $# > 0 )); do
            case "$1" in
              --dark)
                dark_theme="''${2:-$default_dark}"
                explicit_dark=1
                shift 2
                ;;
              --light)
                light_theme="''${2:-$default_light}"
                explicit_light=1
                shift 2
                ;;
              --offline | --headless)
                offline=1
                shift
                ;;
              *)
                echo "Usage: omarchnix theme toggle [--dark <name>] [--light <name>] [--offline]" >&2
                exit 1
                ;;
            esac
          done
          local state_dir="$HOME/.local/state/omarchy"
          local colors_file="$state_dir/current/theme/colors.toml"
          local cur_slug=""
          if [[ -f "$state_dir/current/theme.name" ]]; then
            cur_slug="$(tr -d '\n' < "$state_dir/current/theme.name")"
          fi
          local cur_mode="dark"
          if [[ -f "$colors_file" ]]; then
            cur_mode="$(omarchy-theme-color --file "$colors_file" mode 2>/dev/null || echo dark)"
          fi
          mkdir -p "$state_dir"
          local target=""
          if [[ "$cur_mode" == "light" ]]; then
            [[ -n "$cur_slug" ]] && printf '%s\n' "$cur_slug" > "$state_dir/last-light-theme"
            if (( ! explicit_dark )) && [[ -f "$state_dir/last-dark-theme" ]]; then
              local remembered_dark
              remembered_dark="$(tr -d '\n' < "$state_dir/last-dark-theme")"
              if theme_exists "$remembered_dark"; then
                dark_theme="$remembered_dark"
              fi
            fi
            target="$dark_theme"
          else
            [[ -n "$cur_slug" ]] && printf '%s\n' "$cur_slug" > "$state_dir/last-dark-theme"
            if (( ! explicit_light )) && [[ -f "$state_dir/last-light-theme" ]]; then
              local remembered_light
              remembered_light="$(tr -d '\n' < "$state_dir/last-light-theme")"
              if theme_exists "$remembered_light"; then
                light_theme="$remembered_light"
              fi
            fi
            target="$light_theme"
          fi
          run_theme_set "$target" "$offline" 1
          apply_interface_mode
          ;;
        palette)
          local raw_name="''${1:-}"
          [[ -n "$raw_name" ]] || { echo "Usage: omarchnix theme palette <name> [--json]" >&2; exit 1; }
          shift
          local slug
          slug="$(printf '%s' "$raw_name" | tr '[:upper:]' '[:lower:]' | tr ' _' '--')"
          local colors_file="$HOME/.config/omarchy/themes/$slug/colors.toml"
          if [[ ! -f "$colors_file" ]]; then
            colors_file="$OMARCHY_PATH/themes/$slug/colors.toml"
          fi
          [[ -f "$colors_file" ]] || { echo "Unknown theme '$raw_name'" >&2; exit 1; }
          if [[ "''${1:-}" == "--json" ]]; then
            omarchy-theme-color --file "$colors_file" --all | jq -Rn '
              [inputs | split("\t") | select(length == 2) | {key: .[0], value: .[1]}] | from_entries
            '
          else
            omarchy-theme-color --file "$colors_file" --all
          fi
          ;;
        *)
          echo "Unknown theme subcommand: $sub" >&2
          exit 1
          ;;
      esac
    }

    cmd_plugin() {
      local sub="''${1:-list}"
      shift || true
      case "$sub" in
        registry | search)
          local query=""
          local want_json=0
          while (( $# > 0 )); do
            case "$1" in
              --json)
                want_json=1
                shift
                ;;
              --refresh)
                mkdir -p "''${XDG_CACHE_HOME:-$HOME/.cache}/omarchnix"
                curl -fsSL "$MARKETPLACE_REGISTRY_URL" -o "''${XDG_CACHE_HOME:-$HOME/.cache}/omarchnix/plugins-registry.json"
                shift
                ;;
              *)
                query="$1"
                shift
                ;;
            esac
          done
          local reg
          reg="$(resolve_registry_file)"
          local filtered
          filtered="$(jq -c --arg q "$query" '
            [
              .sources[]
              | select(.type == "plugin-source" or .type == "suite")
              | . as $src
              | (
                  if ($src.plugins? | type) == "object" then
                    ($src.plugins | keys)
                  elif ($src.catalog.id? != null) then
                    [$src.catalog.id]
                  else
                    []
                  end
                ) as $ids
              | {
                  ids: $ids,
                  type: $src.type,
                  repo: $src.repo,
                  commit: ($src.listingValidatedCommit // ""),
                  branch: ($src.listingValidatedBranch // "")
                }
              | select(
                  $q == ""
                  or (.repo | ascii_downcase | contains($q | ascii_downcase))
                  or any(.ids[]; ascii_downcase | contains($q | ascii_downcase))
                )
            ]
          ' "$reg")"
          if (( want_json )); then
            printf '%s\n' "$filtered"
          else
            jq -r '.[] | "\((.ids | join(",")))\t\(.type)\t\(.repo)\t\(.commit[0:12])"' <<<"$filtered"
          fi
          ;;
        install | add)
          local target=""
          local extra_args=()
          while (( $# > 0 )); do
            case "$1" in
              --enable | --yes | -y)
                extra_args+=("$1")
                shift
                ;;
              *)
                if [[ -z "$target" ]]; then
                  target="$1"
                else
                  extra_args+=("$1")
                fi
                shift
                ;;
            esac
          done
          [[ -n "$target" ]] || { echo "Usage: omarchnix plugin install <plugin-id|git-url> [--enable] [--yes]" >&2; exit 1; }

          local url="$target"
          local pinned_commit=""
          if [[ "$target" != *"://"* && "$target" != *@* && ! -d "$target" ]]; then
            local reg
            reg="$(resolve_registry_file)"
            local resolved
            resolved="$(jq -r --arg id "$target" '
              [
                .sources[]
                | select(.type == "plugin-source" or .type == "suite")
                | select(
                    ((.plugins? | type) == "object" and (.plugins | has($id)))
                    or (.catalog.id? == $id)
                  )
              ][0] // empty
              | if . == "" then "" else "\(.repo)\t\(.listingValidatedCommit // "")" end
            ' "$reg")"
            if [[ -z "$resolved" ]]; then
              echo "omarchnix plugin install: plugin '$target' not found in plugins.omarchy.org registry" >&2
              exit 1
            fi
            IFS=$'\t' read -r url pinned_commit <<<"$resolved"
          fi

          if [[ -n "$pinned_commit" ]]; then
            local tmpdir
            tmpdir="$(mktemp -d)"
            trap 'rm -rf "$tmpdir"' EXIT
            git clone --quiet "$url" "$tmpdir/repo"
            git -C "$tmpdir/repo" checkout --quiet "$pinned_commit"
            if [[ -f "$tmpdir/repo/manifest.json" ]]; then
              omarchy-plugin-add "$tmpdir/repo" "''${extra_args[@]}"
            elif [[ -d "$tmpdir/repo/$target" && -f "$tmpdir/repo/$target/manifest.json" ]]; then
              omarchy-plugin-add "$tmpdir/repo/$target" "''${extra_args[@]}"
            else
              local sub_manifest
              sub_manifest="$(find "$tmpdir/repo" -mindepth 2 -maxdepth 3 -name manifest.json -exec jq -r --arg id "$target" 'select(.id == $id) | input_filename' {} + | head -n1)"
              if [[ -n "$sub_manifest" ]]; then
                omarchy-plugin-add "$(dirname "$sub_manifest")" "''${extra_args[@]}"
              else
                omarchy-plugin-add "$tmpdir/repo" "''${extra_args[@]}"
              fi
            fi
          else
            omarchy-plugin-add "$url" "''${extra_args[@]}"
          fi
          ;;
        list)
          omarchy-plugin-list "$@"
          ;;
        enable)
          omarchy-plugin-enable "$@"
          ;;
        disable)
          omarchy-plugin-disable "$@"
          ;;
        remove | rm)
          omarchy-plugin-remove "$@"
          ;;
        validate)
          omarchy-plugin-validate "$@"
          ;;
        *)
          echo "Unknown plugin subcommand: $sub" >&2
          exit 1
          ;;
      esac
    }

    cmd_kbd_backlight() {
      local no_osd=0
      local want_json=0
      local args=()
      while (( $# > 0 )); do
        case "$1" in
          --no-osd)
            no_osd=1
            shift
            ;;
          --json)
            want_json=1
            shift
            ;;
          *)
            args+=("$1")
            shift
            ;;
        esac
      done

      local action="''${args[0]:-get}"
      if [[ "$action" == "get" || "$action" == "status" ]]; then
        local device=""
        for candidate in /sys/class/leds/*kbd_backlight*; do
          if [[ -e "$candidate" ]]; then
            device="$(basename "$candidate")"
            break
          fi
        done
        if [[ -z "$device" ]]; then
          echo "No keyboard backlight device found" >&2
          exit 1
        fi
        local cur max pct
        cur="$(brightnessctl -d "$device" get)"
        max="$(brightnessctl -d "$device" max)"
        pct=$(( (cur * 100 + max / 2) / max ))
        if (( want_json )); then
          jq -nc \
            --arg device "$device" \
            --argjson brightness "$cur" \
            --argjson maxBrightness "$max" \
            --argjson percent "$pct" \
            '{ device: $device, brightness: $brightness, maxBrightness: $maxBrightness, percent: $percent }'
        else
          printf '%d%%\n' "$pct"
        fi
        return 0
      fi

      local helper_args=()
      (( no_osd )) && helper_args+=("--no-osd")
      helper_args+=("''${args[@]}")
      omarchy-brightness-keyboard "''${helper_args[@]}"
    }

    cmd="''${1:-help}"
    shift || true
    case "$cmd" in
      status)
        cmd_status "$@"
        ;;
      check)
        cmd_check "$@"
        ;;
      theme)
        cmd_theme "$@"
        ;;
      plugin)
        cmd_plugin "$@"
        ;;
      kbd-backlight | keyboard-backlight)
        cmd_kbd_backlight "$@"
        ;;
      -h | --help | help)
        usage
        ;;
      *)
        echo "omarchnix: unknown command '$cmd'" >&2
        usage >&2
        exit 1
        ;;
    esac
  '';
}
