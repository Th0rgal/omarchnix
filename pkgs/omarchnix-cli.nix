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
    pkgs.coreutils
    pkgs.curl
    pkgs.findutils
    pkgs.gawk
    pkgs.git
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.nix
    pkgs.procps
    pkgs.python3
    pkgs.systemd
    pkgs.wayland-utils
  ];
  text = ''
    set -euo pipefail

    export OMARCHY_PATH="''${OMARCHY_PATH:-${omarchyShell.sharePath}}"
    export OMARCHY_SHELL_IPC_TIMEOUT="''${OMARCHY_SHELL_IPC_TIMEOUT:-10s}"
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

    apply_interface_mode() {
      local colors_file="$HOME/.local/state/omarchy/current/theme/colors.toml"
      local mode="dark"
      if [[ -f "$colors_file" ]]; then
        mode="$(omarchy-theme-color --file "$colors_file" mode 2>/dev/null || echo dark)"
      fi
      local scheme="prefer-dark"
      local gtk_theme="Adwaita-dark"
      if [[ "$mode" == "light" ]]; then
        scheme="prefer-light"
        gtk_theme="Adwaita"
      fi
      # dconf is authoritative for the xdg-desktop-portal-gtk Settings backend
      # (Electron apps such as Bitwarden read dark/light preference there), and
      # it works without the GNOME GSettings schema directory.
      if command -v dconf >/dev/null 2>&1; then
        dconf write /org/gnome/desktop/interface/color-scheme "'$scheme'" 2>/dev/null || true
        dconf write /org/gnome/desktop/interface/gtk-theme "'$gtk_theme'" 2>/dev/null || true
      fi
      if command -v gsettings >/dev/null 2>&1 \
        && gsettings get org.gnome.desktop.interface color-scheme >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.interface color-scheme "$scheme" 2>/dev/null || true
        gsettings set org.gnome.desktop.interface gtk-theme "$gtk_theme" 2>/dev/null || true
      fi
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
          if (( offline )); then
            OMARCHY_THEME_OFFLINE=1 OMARCHY_THEME_SKIP_BACKGROUND=1 omarchy-theme-set "$name"
          else
            OMARCHY_THEME_WAIT=1 omarchy-theme-set "$name"
          fi
          apply_interface_mode
          ;;
        toggle)
          local dark_theme="tokyo-night"
          local light_theme="white"
          local offline=0
          while (( $# > 0 )); do
            case "$1" in
              --dark)
                dark_theme="''${2:-tokyo-night}"
                shift 2
                ;;
              --light)
                light_theme="''${2:-white}"
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
            if [[ "$dark_theme" == "tokyo-night" && -f "$state_dir/last-dark-theme" ]]; then
              dark_theme="$(tr -d '\n' < "$state_dir/last-dark-theme")"
            fi
            target="$dark_theme"
          else
            [[ -n "$cur_slug" ]] && printf '%s\n' "$cur_slug" > "$state_dir/last-dark-theme"
            if [[ "$light_theme" == "white" && -f "$state_dir/last-light-theme" ]]; then
              light_theme="$(tr -d '\n' < "$state_dir/last-light-theme")"
            fi
            target="$light_theme"
          fi
          if (( offline )); then
            OMARCHY_THEME_OFFLINE=1 OMARCHY_THEME_SKIP_BACKGROUND=1 omarchy-theme-set "$target"
          else
            OMARCHY_THEME_WAIT=1 omarchy-theme-set "$target"
          fi
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
