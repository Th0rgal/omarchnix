{
  inputs,
  omarchyLib,
}:
final: prev:
let
  omarchyShell = import ../pkgs/omarchy-shell.nix {
    inherit (final) lib;
    pkgs = final;
    omarchySrc = inputs.omarchy;
    marketplaceSrc = inputs.omarchy-plugin-marketplace;
  };

  cli = import ../pkgs/omarchnix-cli.nix {
    pkgs = final;
    inherit omarchyShell;
    marketplaceSrc = inputs.omarchy-plugin-marketplace;
  };

  touchIdMonitorBin =
    final.runCommandCC "omarchnix-touchid-monitor"
      {
        nativeBuildInputs = [ final.pkg-config ];
        buildInputs = [
          final.glib
          final.json-glib
        ];
      }
      ''
        mkdir -p "$out/bin"
        $CC -O2 -Wall -Wextra \
          "${../pkgs/plugins/touchid/touchid-monitor.c}" \
          $(pkg-config --cflags --libs gio-2.0 gio-unix-2.0 json-glib-1.0) \
          -o "$out/bin/touchid-monitor"
      '';
in
{
  omarchnix = {
    inherit cli;
    omarchy-shell = omarchyShell;
    omarchySrc = inputs.omarchy;
    marketplaceSrc = inputs.omarchy-plugin-marketplace;
    importTheme =
      arg:
      omarchyLib.importTheme (
        if builtins.isAttrs arg && !(arg ? outPath) then
          { pkgs = final; } // arg
        else
          {
            theme = arg;
            pkgs = final;
          }
      );
    themes = omarchyLib.allBundledThemes final;
    buildTheme = args: omarchyLib.buildThemePkg ({ pkgs = final; } // args);
    buildPlugin = args: omarchyLib.buildPlugin ({ pkgs = final; } // args);
    michelangelus-font = final.michelangelus-font;
    omdrop = final.omdrop;
    omarchy-quickshare = final.omarchy-quickshare;
    omarchy-nearby = final.omarchy-nearby;
    orb-agent-sync = final.orb-agent-sync;
    flea = final.flea;
    lean-mesh-standalone = final.callPackage ../pkgs/lean-mesh.nix {
      orbSrc = inputs.orb-mesh or inputs.orb;
      inherit (final) turbo-lean;
    };
    lean-mesh =
      if (inputs ? orb-mesh) && ("${inputs.orb-mesh}" != "${inputs.orb}") then
        final.omarchnix.lean-mesh-standalone
      else
        final.runCommand "omarchnix-lean-mesh-bin"
          {
            meta.mainProgram = "lean-mesh";
          }
          ''
            mkdir -p "$out/bin"
            ln -s "${final.sandboxed-sh}/bin/lean-mesh" "$out/bin/lean-mesh"
          '';
    xdg-desktop-portal-hyprland = final.xdg-desktop-portal-hyprland;
    plugins = {
      mac-mesh = final.omarchnix.buildPlugin {
        src = ../pkgs/plugins/omarchnix-mac-mesh;
        postInstall = ''
          substituteInPlace "$out/Service.qml" \
            --replace-fail '@MAC_MESHCTL_BIN@' "/run/current-system/sw/bin/mac-meshctl" \
            --replace-fail '@XDG_OPEN_BIN@' "${final.xdg-utils}/bin/xdg-open"
        '';
      };
      mission-control = final.omarchnix.buildPlugin {
        src = ../pkgs/plugins/mission-control;
      };
      macos-dock = final.omarchnix.buildPlugin {
        src = ../pkgs/plugins/macos-dock;
      };
      spotlight = final.omarchnix.buildPlugin {
        src = ../pkgs/plugins/spotlight;
      };
      touchid = final.omarchnix.buildPlugin {
        src = ../pkgs/plugins/touchid;
        postInstall = ''
          rm -f "$out/touchid-monitor.c"
          substituteInPlace "$out/TouchId.qml" \
            --replace-fail '@TOUCHID_MONITOR_BIN@' "${touchIdMonitorBin}/bin/touchid-monitor"
        '';
      };
      workspace-wallpapers = final.omarchnix.buildPlugin {
        src = ../pkgs/plugins/workspace-wallpapers;
      };
      workspaces = final.omarchnix.buildPlugin {
        src = ../pkgs/plugins/workspaces;
      };
    };
  };

  michelangelus-font = final.callPackage ../pkgs/michelangelus-font.nix { };
  crispasr-cohere = final.callPackage ../pkgs/crispasr-cohere.nix { };
  murmure = final.callPackage ../pkgs/murmure {
    buildPlugin = final.omarchnix.buildPlugin;
  };
  omdrop = final.callPackage ../pkgs/omdrop.nix {
    omdropAwdlSrc = inputs.omdrop-awdl;
    omdropPluginSrc = inputs.omdrop-plugin;
    buildPlugin = final.omarchnix.buildPlugin;
    inherit omarchyShell;
  };
  omarchy-quickshare = final.callPackage ../pkgs/omarchy-quickshare.nix {
    omarchyQuickshareSrc = inputs.omarchy-quickshare;
    buildPlugin = final.omarchnix.buildPlugin;
    inherit omarchyShell;
  };
  omarchy-nearby = final.callPackage ../pkgs/omarchy-nearby.nix {
    omarchyNearbySrc = inputs.omarchy-nearby;
    buildPlugin = final.omarchnix.buildPlugin;
  };
  orb-agent-sync = final.callPackage ../pkgs/orb-agent-sync.nix { };
  flea = final.callPackage ../pkgs/flea.nix {
    omarchySrc = inputs.omarchy;
  };
  turbo-lean-guard-shims = final.callPackage ../pkgs/turbo-lean-guard-shims.nix { };
  opencode-v2 = final.callPackage ../pkgs/opencode-v2.nix { };
  signal-desktop-frameless = final.callPackage ../pkgs/signal-desktop-frameless.nix { };
  turbo-lean = final.callPackage ../pkgs/turbo-lean.nix {
    turboLeanSrc = inputs.turbo-lean;
  };
  orb-desktop = final.callPackage ../pkgs/orb-desktop.nix {
    orbSrc = inputs.orb;
    sandboxed-sh = final.callPackage "${inputs.orb}/nix/package.nix" {
      inherit (final) turbo-lean;
    };
  };
  sandboxed-sh = final.orb-desktop.passthru.sandboxed-sh;
  folio-desktop = inputs.folio.packages.${final.stdenv.hostPlatform.system}.folio-desktop;
  folio = final.folio-desktop;
  folio-locald = final.folio-desktop.passthru.folio-locald;
  notion-calendar = final.callPackage ../pkgs/notion-calendar.nix { };
  claude-desktop = final.callPackage ../pkgs/claude-desktop.nix { };
  helium = final.callPackage ../pkgs/helium.nix {
    widevineCdm =
      if
        final.stdenv.hostPlatform.isLinux
        && (final ? widevine-cdm)
        && (
          (final.config.allowUnfree or false)
          || builtins.elem "widevine-cdm" (final.config.allowUnfreePackages or [ ])
        )
      then
        final.widevine-cdm
      else
        null;
  };
  xdg-desktop-portal-hyprland = prev.xdg-desktop-portal-hyprland.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ../pkgs/patches/xdg-desktop-portal-hyprland-screencopy.patch
    ];
  });
  brave =
    if
      final.stdenv.hostPlatform.isLinux
      && (prev ? widevine-cdm)
      && (
        (final.config.allowUnfree or false)
        || builtins.elem "widevine-cdm" (final.config.allowUnfreePackages or [ ])
      )
    then
      let
        braveWidevineBootstrap = final.writeShellScript "brave-widevine-bootstrap" ''
          wv_dir="${final.widevine-cdm}/share/google/chrome/WidevineCdm"
          wv_ver="${final.widevine-cdm.version}"
          cfg_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/BraveSoftware/Brave-Browser"
          mkdir -p "$cfg_dir/WidevineCdm"
          hint_file="$cfg_dir/WidevineCdm/latest-component-updated-widevine-cdm"
          desired_hint=$(${final.jq}/bin/jq -nc --arg path "$wv_dir" --arg ver "$wv_ver" '{ Path: $path, LastBundledVersion: $ver }')
          if [ ! -f "$hint_file" ] || [ "$(cat "$hint_file" 2>/dev/null || true)" != "$desired_hint" ]; then
            tmp_hint="$(mktemp "$hint_file.XXXXXX")"
            printf '%s\n' "$desired_hint" > "$tmp_hint"
            chmod 0600 "$tmp_hint"
            mv "$tmp_hint" "$hint_file"
          fi

          local_state="$cfg_dir/Local State"
          if [ ! -e "$local_state" ]; then
            tmp_ls="$(mktemp "$local_state.XXXXXX")"
            printf '{"brave":{"widevine_opted_in":true}}\n' > "$tmp_ls"
            chmod 0600 "$tmp_ls"
            mv "$tmp_ls" "$local_state"
          elif [ -f "$local_state" ] && [ ! -L "$local_state" ] \
            && ! ${final.procps}/bin/pgrep -u "''${USER:-$(id -un)}" -f "/brave/brave " >/dev/null 2>&1; then
            if [ "$(${final.jq}/bin/jq -r '.brave | has("widevine_opted_in")' "$local_state" 2>/dev/null || echo true)" = "false" ]; then
              tmp_ls="$(mktemp "$local_state.XXXXXX")"
              if ${final.jq}/bin/jq '.brave = ((.brave // {}) | .widevine_opted_in = true)' "$local_state" > "$tmp_ls" 2>/dev/null; then
                chmod --reference="$local_state" "$tmp_ls" 2>/dev/null || chmod 0600 "$tmp_ls"
                mv "$tmp_ls" "$local_state"
              else
                rm -f "$tmp_ls"
              fi
            fi
          fi
        '';
      in
      final.symlinkJoin {
        name = "brave-${prev.brave.version}";
        paths = [ prev.brave ];
        nativeBuildInputs = [ final.makeWrapper ];
        postBuild = ''
          wrapProgram "$out/bin/brave" --run "${braveWidevineBootstrap}"
          for desktop in "$out/share/applications/"*.desktop; do
            if [ -L "$desktop" ]; then
              cp --remove-destination "$(readlink -f "$desktop")" "$desktop"
              substituteInPlace "$desktop" --replace-quiet "${prev.brave}/bin/brave" "$out/bin/brave"
            fi
          done
        '';
        inherit (prev.brave)
          pname
          version
          meta
          passthru
          ;
      }
    else
      prev.brave;
  antigravity-hub =
    if prev ? antigravity-hub then
      final.callPackage ../pkgs/antigravity-hub.nix {
        inherit (prev) antigravity-hub;
      }
    else
      prev.antigravity-hub;
}
// prev.lib.optionalAttrs (prev ? aurora-sep) {
  # nixos-aurora already runs Aurora's SEP contract tests (test_interface.py,
  # test_lockout_reason.py) in postPatch; upstream libfprint's 131 simulated USB
  # umockdev tests (egis_etu905, aes2550, etc.) fail/timeout under parallel builds.
  libfprint = prev.libfprint.overrideAttrs {
    doInstallCheck = false;
  };
}
