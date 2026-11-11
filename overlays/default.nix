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
    plugins = {
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
