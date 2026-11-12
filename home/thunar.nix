{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omarchnix;
  fmCfg = cfg.fileManager;

  foot = "${pkgs.foot}/bin/foot";
  ghostty = "${pkgs.ghostty}/bin/ghostty";
  defaultTerminal = if (cfg.terminal or "foot") == "ghostty" then ghostty else foot;

  omarchyShellExe =
    if cfg.shell.package != null then "${cfg.shell.package}/bin/omarchy-shell" else "omarchy-shell";

  shareFilesScript = pkgs.writeShellScript "omarchnix-share-files" ''
    set -euo pipefail
    [ "$#" -gt 0 ] || exit 0

    payload="$(printf '%s\0' "$@" | ${pkgs.jq}/bin/jq -cRs 'split("\u0000") | map(select(length > 0))')"
    if [ "${cfg.shell.backend}" = "omarchy-shell" ] && "${omarchyShellExe}" omarchnix.sharing share "$payload" >/dev/null 2>&1; then
      exit 0
    fi

    if command -v omdrop >/dev/null 2>&1; then
      omdrop on 10m >/dev/null 2>&1 || true
      peer="$(omdrop peers -n --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[] | select(.name != null and .name != "") | "\(.name)\t\(.mac)"' | ${pkgs.fuzzel}/bin/fuzzel --dmenu -p 'AirDrop to: ' || true)"
      mac="''${peer#*$'\t'}"
      if [ -n "$mac" ] && [ "$mac" != "$peer" ]; then
        exec omdrop send --to "$mac" "$@"
      fi
    fi
  '';

  openTerminalHereScript = pkgs.writeShellScript "omarchnix-open-terminal-here" ''
    target="''${1:-$HOME}"
    if [ -e "$target" ] && [ ! -d "$target" ]; then
      target="$(dirname -- "$target")"
    fi
    [ -d "$target" ] || target="$HOME"
    cd -- "$target" || exit 1
    exec ${lib.escapeShellArg defaultTerminal} --working-directory="$target"
  '';

  copyPathScript = pkgs.writeShellScript "omarchnix-copy-path" ''
    [ "$#" -gt 0 ] || exit 0
    {
      printf '%s' "$1"
      shift
      for p in "$@"; do
        printf '\n%s' "$p"
      done
    } | ${pkgs.wl-clipboard}/bin/wl-copy
  '';

  thunarDataDirs = lib.makeSearchPath "share" [
    pkgs.morewaita-icon-theme
    pkgs.adwaita-icon-theme
    pkgs.adw-gtk3
  ];

  thunarWrapped = pkgs.symlinkJoin {
    name = "thunar-themed-${pkgs.thunar.version}";
    paths = [ pkgs.thunar ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      for bin in thunar Thunar thunar-settings; do
        if [ -e "$out/bin/$bin" ]; then
          wrapProgram "$out/bin/$bin" \
            --prefix XDG_DATA_DIRS : ${lib.escapeShellArg thunarDataDirs}
        fi
      done
    '';
    inherit (pkgs.thunar) meta;
  };

  defaultThunarXml = pkgs.writeText "omarchnix-thunar.xml" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <channel name="thunar" version="1.0">
      <property name="last-view" type="string" value="ThunarDetailsView"/>
      <property name="last-location-bar" type="string" value="ThunarLocationButtons"/>
      <property name="last-menubar-visible" type="bool" value="false"/>
      <property name="last-statusbar-visible" type="bool" value="true"/>
      <property name="last-toolbar-items" type="string" value="menu:1,back:1,forward:1,open-parent:1,open-home:0,new-tab:0,new-window:0,toggle-split-view:1,undo:0,redo:0,zoom-out:0,zoom-in:0,zoom-reset:0,view-as-icons:0,view-as-detailed-list:0,view-as-compact-list:0,view-switcher:1,location-bar:1,reload:0,search:1"/>
      <property name="last-details-view-zoom-level" type="string" value="THUNAR_ZOOM_LEVEL_50_PERCENT"/>
      <property name="last-icon-view-zoom-level" type="string" value="THUNAR_ZOOM_LEVEL_100_PERCENT"/>
      <property name="last-separator-position" type="int" value="196"/>
      <property name="last-window-width" type="int" value="1060"/>
      <property name="last-window-height" type="int" value="680"/>
      <property name="last-window-maximized" type="bool" value="false"/>
      <property name="misc-use-csd" type="bool" value="true"/>
      <property name="misc-symbolic-icons-in-sidepane" type="bool" value="true"/>
      <property name="misc-symbolic-icons-in-toolbar" type="bool" value="true"/>
      <property name="misc-thumbnail-draw-frames" type="bool" value="false"/>
      <property name="misc-folders-first" type="bool" value="true"/>
      <property name="misc-expandable-folders" type="bool" value="true"/>
      <property name="misc-show-delete-action" type="bool" value="true"/>
      <property name="misc-tab-close-middle-click" type="bool" value="true"/>
      <property name="misc-thumbnail-mode" type="string" value="THUNAR_THUMBNAIL_MODE_ALWAYS"/>
      <property name="misc-date-style" type="string" value="THUNAR_DATE_STYLE_SHORT"/>
    </channel>
  '';

  fleaSharingManifest = pkgs.writeText "omarchnix-flea-sharing-manifest.json" (
    builtins.toJSON {
      schemaVersion = 1;
      id = "omarchnix.sharing";
      name = "Nearby Sharing";
      version = "1.0.0";
      author = "Omarchnix";
      license = "MIT";
      description = "Stage selected files or folders in Omarchy's top-bar Share menu for AirDrop, Paired Phone, Quick Share, or LocalSend.";
      kinds = [ "menu-action" ];
      entryPoints = {
        run = "plugin.py";
      };
      menuActions = [
        {
          id = "share-nearby";
          label = "Share Nearby…";
          glyph = "cloud-upload";
          menus = [ "file" ];
          when = {
            minItems = 1;
            maxItems = 512;
            folders = true;
          };
        }
      ];
      access = [
        "selection"
        "exec:systemd-run"
      ];
    }
    + "\n"
  );

  fleaSharingPluginPy = pkgs.writeScript "omarchnix-flea-sharing-plugin.py" ''
    #!${pkgs.python3}/bin/python3
    import json
    import os
    import subprocess
    import sys

    SHARE_SCRIPT = ${builtins.toJSON (toString shareFilesScript)}
    SYSTEMD_RUN = "/run/current-system/sw/bin/systemd-run"


    def reply(obj):
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()


    def child_env():
        env = os.environ.copy()
        rt = env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
        if os.path.isdir(rt):
            env["XDG_RUNTIME_DIR"] = rt
            bus = f"{rt}/bus"
            if not env.get("DBUS_SESSION_BUS_ADDRESS") and os.path.exists(bus):
                env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path={bus}"
        return env


    def run_share(paths):
        if not paths:
            return False, "No items selected."
        env = child_env()
        if os.path.exists(SYSTEMD_RUN):
            res = subprocess.run(
                [SYSTEMD_RUN, "--user", "--collect", "--quiet", SHARE_SCRIPT, *paths],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if res.returncode == 0:
                return True, "Opened Share Nearby."
        try:
            subprocess.Popen(
                [SHARE_SCRIPT, *paths],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return True, "Opened Share Nearby."
        except OSError as exc:
            return False, str(exc)


    def main():
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            op = msg.get("op")
            req_id = msg.get("id")
            if op == "hello":
                reply({"op": "ready", "protocolVersion": 1})
            elif op == "settings":
                out = {"op": "done"}
                if req_id is not None:
                    out["id"] = req_id
                reply(out)
            elif op == "cancel":
                break
            elif op == "run":
                selection = msg.get("selection") or []
                paths = [p for p in selection if isinstance(p, str) and p]
                ok, text = run_share(paths)
                out = {"op": "done" if ok else "error", "message": text}
                if req_id is not None:
                    out["id"] = req_id
                reply(out)


    if __name__ == "__main__":
        main()
  '';
in
{
  options.programs.omarchnix.fileManager = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the declarative desktop file manager (Flea GPUI/Vulkan by default, or Thunar GTK3) with Nearby Share integration.";
    };

    backend = lib.mkOption {
      type = lib.types.enum [
        "flea"
        "thunar"
      ];
      default = "flea";
      description = "Desktop file manager implementation (`flea` GPUI/Vulkan Explorer or legacy `thunar` GTK3).";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.flea;
      defaultText = lib.literalExpression "pkgs.flea";
      description = "Package providing the `flea` and `flea-gui` binaries when `backend = \"flea\"`.";
    };

    autoTrash = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically purge XDG Trash items older than `days` (like macOS Finder's 30-day Trash auto-removal) via `autotrash`.";
      };

      days = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Maximum age in days (`DeletionDate` in `.trashinfo`) before trashed items are permanently removed.";
      };

      minFreeMb = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2048;
        description = "Minimum free disk space (MiB) below which `autotrash` proactively purges oldest trashed items first.";
      };
    };
  };

  config = lib.mkIf (cfg.enable && fmCfg.enable) (
    lib.mkMerge [
      {
        home.packages = lib.optional fmCfg.autoTrash.enable pkgs.autotrash;

        # Purge trashed items older than `autoTrash.days` based on Freedesktop `.trashinfo`
        # `DeletionDate` metadata (preserving older nested files inside recently trashed folders),
        # and age out stale Tumbler image/PDF thumbnails in `~/.cache/thumbnails`.
        systemd.user.services.omarchnix-autotrash = lib.mkIf fmCfg.autoTrash.enable {
          Unit = {
            Description = "Purge expired XDG Trash items (autotrash)";
            ConditionPathIsDirectory = "%h/.local/share/Trash/info";
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${lib.getExe pkgs.autotrash} --trash-mounts --days=${toString fmCfg.autoTrash.days} --min-free=${toString fmCfg.autoTrash.minFreeMb}";
          };
        };

        systemd.user.timers.omarchnix-autotrash = lib.mkIf fmCfg.autoTrash.enable {
          Unit = {
            Description = "Daily XDG Trash auto-cleanup timer";
          };
          Timer = {
            OnCalendar = "daily";
            Persistent = true;
            RandomizedDelaySec = "15m";
          };
          Install = {
            WantedBy = [ "timers.target" ];
          };
        };

        systemd.user.tmpfiles.rules = [
          "d %h/.cache/thumbnails 0700 - - 30d"
        ];
      }

      (lib.mkIf (fmCfg.backend == "flea") {
        home.packages = [ fmCfg.package ];

        xdg.mimeApps = {
          defaultApplications = {
            "inode/directory" = lib.mkDefault [ "com.thisisgm.flea.desktop" ];
            "inode/mount-point" = lib.mkDefault [ "com.thisisgm.flea.desktop" ];
            "x-directory/normal" = lib.mkDefault [ "com.thisisgm.flea.desktop" ];
          };
          associations.added = {
            "inode/directory" = [ "com.thisisgm.flea.desktop" ];
            "inode/mount-point" = [ "com.thisisgm.flea.desktop" ];
            "x-directory/normal" = [ "com.thisisgm.flea.desktop" ];
          };
        };

        xdg.configFile."xdg-desktop-portal/hyprland-portals.conf".text = lib.mkDefault ''
          [preferred]
          default=hyprland;gtk
          org.freedesktop.impl.portal.FileChooser=flea;gtk
          org.freedesktop.impl.portal.Settings=gtk
        '';

        xdg.dataFile = {
          "applications/com.thisisgm.flea.desktop".text = ''
            [Desktop Entry]
            Type=Application
            Name=Flea
            GenericName=File Manager
            Comment=Fast, keyboard-first file manager
            Exec=${fmCfg.package}/bin/flea --gui %f
            Icon=com.thisisgm.flea
            Terminal=false
            Categories=System;FileTools;FileManager;
            MimeType=inode/directory;inode/mount-point;x-directory/normal;
            Keywords=file folder;file explorer;file manager;files;folder;folders;finder;explorer;manager;browser;flea;directory;downloads;browse;
            StartupWMClass=com.thisisgm.flea
          '';
          "icons/hicolor/scalable/apps/com.thisisgm.flea.svg".source =
            "${fmCfg.package}/share/icons/hicolor/scalable/apps/com.thisisgm.flea.svg";
          "xdg-desktop-portal/portals/flea.portal".source =
            "${fmCfg.package}/share/xdg-desktop-portal/portals/flea.portal";
          "dbus-1/services/org.freedesktop.impl.portal.desktop.flea.service".source =
            "${fmCfg.package}/share/dbus-1/services/org.freedesktop.impl.portal.desktop.flea.service";
          "dbus-1/services/org.freedesktop.FileManager1.service".text = ''
            [D-BUS Service]
            Name=org.freedesktop.FileManager1
            Exec=${fmCfg.package}/lib/flea/flea-filemanager1
          '';
        };

        # Provision the `omarchnix.sharing` context-menu plugin as regular files under
        # `~/.config/flea/plugins/omarchnix.sharing/`, enable it in Flea's state store,
        # refresh `~/.local/share/applications/mimeinfo.cache` after `linkGeneration`,
        # migrate legacy Thunar Spotlight rank, and restart `xdg-desktop-portal` so
        # FileChooser dialogs route through Flea immediately.
        home.activation.omarchnixFleaSetup =
          config.lib.dag.entryAfter [ "linkGeneration" "writeBoundary" "omarchnixUserDirs" ]
            ''
              flea_plugin_dir="$HOME/.config/flea/plugins/omarchnix.sharing"
              rm -rf "$flea_plugin_dir"
              mkdir -p "$flea_plugin_dir"
              cp --no-preserve=mode,ownership "${fleaSharingManifest}" "$flea_plugin_dir/manifest.json"
              chmod 0644 "$flea_plugin_dir/manifest.json"
              cp --no-preserve=mode,ownership "${fleaSharingPluginPy}" "$flea_plugin_dir/plugin.py"
              chmod 0755 "$flea_plugin_dir/plugin.py"
              "${fmCfg.package}/bin/flea" plugin enable omarchnix.sharing >/dev/null 2>&1 || true

              ${pkgs.desktop-file-utils}/bin/update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

              spotlight_usage="$HOME/.local/state/omarchy/spotlight-usage.json"
              if [ -f "$spotlight_usage" ] && "${pkgs.jq}/bin/jq" -e 'has("thunar")' "$spotlight_usage" >/dev/null 2>&1; then
                tmp_usage="$(mktemp "$spotlight_usage.XXXXXX")"
                if "${pkgs.jq}/bin/jq" '
                  . as $root
                  | ($root["com.thisisgm.flea"].count // 0) as $fc
                  | ($root["thunar"].count // 0) as $tc
                  | ($root["com.thisisgm.flea"].last // 0) as $fl
                  | ($root["thunar"].last // 0) as $tl
                  | .["com.thisisgm.flea"] = {
                      count: (if $fc > $tc then $fc else $tc end),
                      last: (if $fl > $tl then $fl else $tl end)
                    }
                  | del(.["thunar"])
                ' "$spotlight_usage" > "$tmp_usage" 2>/dev/null; then
                  mv -f "$tmp_usage" "$spotlight_usage"
                else
                  rm -f "$tmp_usage"
                fi
              fi

              if [ -S "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]; then
                "${pkgs.systemd}/bin/systemctl" --user try-restart xdg-desktop-portal.service >/dev/null 2>&1 || true
              fi
            '';
      })

      (lib.mkIf (fmCfg.backend == "thunar") {
        home.packages = [
          thunarWrapped
          pkgs.xarchiver
        ];

        xdg.mimeApps.defaultApplications = {
          "inode/directory" = lib.mkDefault [ "thunar.desktop" ];
        };

        xdg.dataFile = {
          "applications/thunar.desktop".text = ''
            [Desktop Entry]
            Version=1.5
            Type=Application
            Name=File Explorer
            GenericName=File Manager
            Comment=Browse files and folders
            Keywords=file explorer;file manager;files;folders;finder;explorer;thunar;directory;downloads;browse;
            Exec=${thunarWrapped}/bin/thunar %U
            Icon=${pkgs.adwaita-icon-theme}/share/icons/Adwaita/scalable/places/folder.svg
            Terminal=false
            StartupNotify=true
            StartupWMClass=thunar
            Categories=System;Core;GTK;FileTools;FileManager;
            MimeType=inode/directory;
          '';
          "applications/thunar-bulk-rename.desktop".text = ''
            [Desktop Entry]
            Type=Application
            Name=Bulk Rename
            Exec=${thunarWrapped}/bin/thunar --bulk-rename %F
            NoDisplay=true
          '';
          "applications/thunar-settings.desktop".text = ''
            [Desktop Entry]
            Type=Application
            Name=File Manager Settings
            Exec=${thunarWrapped}/bin/thunar-settings
            NoDisplay=true
          '';
          "dbus-1/services/org.freedesktop.FileManager1.service".text = ''
            [D-BUS Service]
            Name=org.freedesktop.FileManager1
            Exec=${thunarWrapped}/bin/Thunar --gapplication-service
          '';
        };

        xdg.configFile."Thunar/uca.xml".text = ''
          <?xml version="1.0" encoding="UTF-8"?>
          <actions>
            <action>
              <icon>document-send</icon>
              <name>Share Nearby (AirDrop / Phone / Quick Share / LocalSend)…</name>
              <submenu></submenu>
              <unique-id>1730000000000001-1</unique-id>
              <command>${shareFilesScript} %F</command>
              <description>Stage selected file(s) in the top-bar Share menu to send via AirDrop, Paired Phone (KDE Connect), Quick Share, or LocalSend</description>
              <range>*</range>
              <patterns>*</patterns>
              <audio-files/>
              <image-files/>
              <other-files/>
              <text-files/>
              <video-files/>
            </action>
            <action>
              <icon>utilities-terminal</icon>
              <name>Open Terminal Here</name>
              <submenu></submenu>
              <unique-id>1730000000000002-1</unique-id>
              <command>${openTerminalHereScript} %f</command>
              <description>Open ${cfg.terminal} in this folder</description>
              <range></range>
              <patterns>*</patterns>
              <directories/>
            </action>
            <action>
              <icon>edit-copy</icon>
              <name>Copy as Path</name>
              <submenu></submenu>
              <unique-id>1730000000000003-1</unique-id>
              <command>${copyPathScript} %F</command>
              <description>Copy full file or folder path(s) to the clipboard</description>
              <range>*</range>
              <patterns>*</patterns>
              <directories/>
              <audio-files/>
              <image-files/>
              <other-files/>
              <text-files/>
              <video-files/>
            </action>
          </actions>
        '';

        # Seed Windows-Explorer-style Thunar defaults as a writable file so `xfconfd`
        # can freely persist runtime column widths, view toggles, and window geometry,
        # merging any newly introduced default `<property>` entries without resetting
        # existing user preferences.
        home.activation.omarchnixThunarDefaults = config.lib.dag.entryAfter [ "writeBoundary" ] ''
          thunar_cfg_dir="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
          thunar_cfg="$thunar_cfg_dir/thunar.xml"
          mkdir -p "$thunar_cfg_dir"
          if [ ! -f "$thunar_cfg" ] || [ -L "$thunar_cfg" ]; then
            rm -f "$thunar_cfg"
            cp --no-preserve=mode,ownership "${defaultThunarXml}" "$thunar_cfg"
            chmod 0644 "$thunar_cfg"
          else
            ${pkgs.python3}/bin/python3 - "$thunar_cfg" "${defaultThunarXml}" <<'PY'
          import os
          import shutil
          import sys
          import tempfile
          import xml.etree.ElementTree as ET

          cfg_path, defaults_path = sys.argv[1], sys.argv[2]
          try:
              cur_tree = ET.parse(cfg_path)
              cur_root = cur_tree.getroot()
              def_root = ET.parse(defaults_path).getroot()
              if cur_root.tag != "channel":
                  raise ValueError("unexpected root tag")
          except Exception:
              shutil.copyfile(defaults_path, cfg_path)
              os.chmod(cfg_path, 0o644)
              sys.exit(0)

          existing = {
              el.attrib.get("name")
              for el in cur_root.findall("property")
              if el.attrib.get("name")
          }
          changed = False
          for prop in def_root.findall("property"):
              name = prop.attrib.get("name")
              if name and name not in existing:
                  cur_root.append(prop)
                  existing.add(name)
                  changed = True

          if changed:
              ET.indent(cur_tree, space="  ")
              fd, tmp_path = tempfile.mkstemp(prefix="thunar.xml.", dir=os.path.dirname(cfg_path))
              try:
                  os.fchmod(fd, 0o644)
                  with os.fdopen(fd, "wb") as fh:
                      cur_tree.write(fh, encoding="UTF-8", xml_declaration=True)
                      fh.write(b"\n")
                  os.replace(tmp_path, cfg_path)
              except Exception:
                  try:
                      os.unlink(tmp_path)
                  except OSError:
                      pass
                  raise
          PY
          fi
        '';
      })
    ]
  );
}
