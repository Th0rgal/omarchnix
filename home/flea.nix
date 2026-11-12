{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omarchnix;
  fleaCfg = cfg.flea;

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
  options.programs.omarchnix.flea = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Flea GPUI/Vulkan file manager as the default desktop file browser, FileManager1 D-Bus service, and FileChooser portal with Nearby Share integration.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.flea;
      defaultText = lib.literalExpression "pkgs.flea";
      description = "Package providing `flea`, `flea-gui`, `flea-portal`, and `flea-filemanager1`.";
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

  config = lib.mkIf (cfg.enable && fleaCfg.enable) {
    home.packages = [
      fleaCfg.package
    ]
    ++ lib.optional fleaCfg.autoTrash.enable pkgs.autotrash;

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
        Exec=${fleaCfg.package}/bin/flea --gui %f
        Icon=com.thisisgm.flea
        Terminal=false
        Categories=System;FileTools;FileManager;
        MimeType=inode/directory;inode/mount-point;x-directory/normal;
        Keywords=file folder;file explorer;file manager;files;folder;folders;finder;explorer;manager;browser;flea;directory;downloads;browse;
        StartupWMClass=com.thisisgm.flea
      '';
      "icons/hicolor/scalable/apps/com.thisisgm.flea.svg".source =
        "${fleaCfg.package}/share/icons/hicolor/scalable/apps/com.thisisgm.flea.svg";
      "xdg-desktop-portal/portals/flea.portal".source =
        "${fleaCfg.package}/share/xdg-desktop-portal/portals/flea.portal";
      "dbus-1/services/org.freedesktop.impl.portal.desktop.flea.service".source =
        "${fleaCfg.package}/share/dbus-1/services/org.freedesktop.impl.portal.desktop.flea.service";
      "dbus-1/services/org.freedesktop.FileManager1.service".text = ''
        [D-BUS Service]
        Name=org.freedesktop.FileManager1
        Exec=${fleaCfg.package}/lib/flea/flea-filemanager1
      '';
    };

    # Purge trashed items older than `autoTrash.days` based on Freedesktop `.trashinfo`
    # `DeletionDate` metadata (preserving older nested files inside recently trashed folders),
    # and age out stale image/PDF thumbnails in `~/.cache/thumbnails`.
    systemd.user.services.omarchnix-autotrash = lib.mkIf fleaCfg.autoTrash.enable {
      Unit = {
        Description = "Purge expired XDG Trash items (autotrash)";
        ConditionPathIsDirectory = "%h/.local/share/Trash/info";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pkgs.autotrash} --trash-mounts --days=${toString fleaCfg.autoTrash.days} --min-free=${toString fleaCfg.autoTrash.minFreeMb}";
      };
    };

    systemd.user.timers.omarchnix-autotrash = lib.mkIf fleaCfg.autoTrash.enable {
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

    # Provision the `omarchnix.sharing` context-menu plugin as regular files under
    # `~/.config/flea/plugins/omarchnix.sharing/`, enable it in Flea's state store,
    # refresh `~/.local/share/applications/mimeinfo.cache` after `linkGeneration`,
    # and restart `xdg-desktop-portal` so FileChooser dialogs route through Flea immediately.
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
          "${fleaCfg.package}/bin/flea" plugin enable omarchnix.sharing >/dev/null 2>&1 || true

          ${pkgs.desktop-file-utils}/bin/update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

          rm -rf "$HOME/.config/Thunar"
          rm -f "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/thunar.xml"

          if [ -S "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]; then
            "${pkgs.systemd}/bin/systemctl" --user try-restart xdg-desktop-portal.service >/dev/null 2>&1 || true
          fi
        '';
  };
}
