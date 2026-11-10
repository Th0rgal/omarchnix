{
  lib,
  pkgs,
  omdropAwdlSrc,
  omdropPluginSrc,
  buildPlugin ? null,
  omarchyShell ? null,
}:
let
  awdlVersion = "0.10.5";
  coreVersion = "0.1.12";
  pluginVersion = "0.18.8";

  omdropPython = pkgs.python3.withPackages (
    ps: with ps; [
      dbus-python
      ifaddr
      libarchive-c
      pillow
      pygobject3
      zeroconf
    ]
  );

  radioChildPath = lib.makeBinPath [
    omdropPython
    pkgs.avahi
    pkgs.bash
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gzip
    pkgs.iproute2
    pkgs.iputils
    pkgs.iw
    pkgs.kmod
    pkgs.networkmanager
    pkgs.procps
    pkgs.systemd
    pkgs.util-linux
    pkgs.xz
    pkgs.zstd
  ];

  pluginRuntimePath = lib.makeBinPath (
    [
      omdropPython
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.glib
      pkgs.gnugrep
      pkgs.gnused
      pkgs.imagemagick
      pkgs.iproute2
      pkgs.libheif
      pkgs.libnotify
      pkgs.openssl
      pkgs.pipewire
      pkgs.pulseaudio
      pkgs.systemd
      pkgs.util-linux
      pkgs.wl-clipboard
      pkgs.xdg-utils
    ]
    ++ lib.optional (omarchyShell != null) omarchyShell
  );

  receiverServicePath = lib.makeBinPath [
    omdropPython
    pkgs.bash
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.imagemagick
    pkgs.iproute2
    pkgs.libheif
    pkgs.openssl
    pkgs.wl-clipboard
  ];

  # 1. Broadcom AWDL userspace radio hooks, vendor netlink iovar helpers,
  #    sleep safety hook, and legacy Polkit policy (`v0.10.5`).
  #    Note: On `nixos-aurora` (`Linux 7.3+`), firmware-native AWDL is already
  #    compiled directly into in-tree `brcmfmac.ko`, so no DKMS build is needed.
  awdl = pkgs.stdenvNoCC.mkDerivation {
    pname = "omdrop-awdl";
    version = awdlVersion;
    src = omdropAwdlSrc;
    dontBuild = true;
    # Keep real script files intact at exact paths annotated in Polkit policy.
    dontPatchShebangs = true;

    installPhase = ''
      runHook preInstall

      libDir="$out/lib/omdrop"
      mkdir -p "$libDir/radio" "$out/bin" "$out/share/polkit-1/actions"

      install -Dm755 userspace/omdrop-discoverable "$libDir/omdrop-discoverable"
      install -Dm644 userspace/omdrop-broadcom.sh "$libDir/omdrop-broadcom.sh"

      for hook in up identity tick peer-watch peers diag read trace; do
        install -Dm755 "userspace/radio/$hook" "$libDir/radio/$hook"
      done

      sed "s/@VERSION@/${awdlVersion}/g" userspace/radio/probe > "$libDir/radio/probe"
      chmod 0755 "$libDir/radio/probe"

      install -Dm755 userspace/awdl-up "$libDir/awdl-up"
      install -Dm755 userspace/awdl-warmup "$libDir/awdl-warmup"

      for helper in awdl-airdrop-adv awdl-election awdl-mdns-respond awdl-peer-watch \
                    awdl-peers awdl-stats ble-airdrop-adv brcm_iovar mkpsf \
                    awdl-af-parse airdrop-send; do
        install -Dm755 "userspace/$helper.py" "$libDir/$helper.py"
      done

      install -Dm755 userspace/send-to-peer "$libDir/send-to-peer"
      install -Dm755 userspace/awdl-resolve "$libDir/awdl-resolve"

      install -Dm644 userspace/awdl_identity.py "$libDir/awdl_identity.py"
      install -Dm644 userspace/awdl_debug.py "$libDir/awdl_debug.py"
      install -Dm644 userspace/awdl_plist.py "$libDir/awdl_plist.py"

      install -Dm755 packaging/omdrop-awdl-sleep "$out/bin/omdrop-awdl-sleep"
      install -Dm644 packaging/org.omarchy.omdrop.policy \
        "$out/share/polkit-1/actions/org.omarchy.omdrop.policy"

      substituteInPlace "$out/share/polkit-1/actions/org.omarchy.omdrop.policy" \
        --replace-fail "/usr/lib/omdrop/omdrop-discoverable" "$libDir/omdrop-discoverable"

      substituteInPlace "$out/bin/omdrop-awdl-sleep" \
        --replace-fail "#!/usr/bin/env bash" "#!${pkgs.bash}/bin/bash" \
        --replace-fail "LIB=/usr/lib/omdrop" "export PATH=\"${radioChildPath}:/run/current-system/sw/bin:\$PATH\"
      LIB=\"$libDir\""

      substituteInPlace "$libDir/radio/probe" \
        --replace-fail "/lib/modules" "/run/booted-system/kernel-modules/lib/modules"

      # Match any store-installed `/lib/omdrop-core/omdrop-radio` root supervisor
      # without creating a cyclic store reference between `awdl` and `core`.
      substituteInPlace "$libDir/omdrop-discoverable" \
        --replace-fail 'CORE_RADIO=/usr/lib/omdrop-core/omdrop-radio' 'CORE_RADIO=*/lib/omdrop-core/omdrop-radio' \
        --replace-fail '[[ ''${argv[0]:-} == "$CORE_RADIO" && ''${argv[1]:-} == __supervise ]]' \
                       '[[ ''${argv[0]:-} == */lib/omdrop-core/omdrop-radio && ''${argv[1]:-} == __supervise ]]' \
        --replace-fail '/usr/lib/omdrop/awdl-up' "$libDir/awdl-up"

      for shFile in \
        "$libDir/omdrop-discoverable" \
        "$libDir/awdl-up" \
        "$libDir/awdl-warmup" \
        "$libDir/radio/"*; do
        sed -i "1s|^#!/usr/bin/env bash$|#!${pkgs.bash}/bin/bash|" "$shFile"
        sed -i "2i export PATH=\"${radioChildPath}:/run/current-system/sw/bin:\''${PATH:-}\"" "$shFile"
      done

      for pyFile in "$libDir/"*.py "$libDir/send-to-peer" "$libDir/awdl-resolve"; do
        if head -n 1 "$pyFile" | grep -q '^#!/usr/bin/env python3'; then
          sed -i "1s|^#!/usr/bin/env python3$|#!${omdropPython}/bin/python3|" "$pyFile"
        fi
      done

      substituteInPlace "$libDir/awdl-peer-watch.py" \
        --replace-fail "/usr/lib/omdrop/awdl-up" "$libDir/awdl-up"

      runHook postInstall
    '';

    meta = {
      description = "Broadcom AWDL radio hooks, netlink iovar helpers, and sleep safety scripts for omdrop";
      homepage = "https://github.com/netmojo-systems/omdrop-awdl";
      license = lib.licenses.gpl2Only;
      platforms = lib.platforms.linux;
    };
  };

  # 2. Pure-Rust AirDrop receiver, sender, BLE/AWDL advertiser, Polkit radio
  #    supervisor, and CLI (`omdrop-core` `v0.1.12`).
  core = pkgs.rustPlatform.buildRustPackage {
    pname = "omdrop-core";
    version = coreVersion;
    src = omdropPluginSrc;
    sourceRoot = "${omdropPluginSrc.name or "source"}/core";
    cargoLock.lockFile = "${omdropPluginSrc}/core/Cargo.lock";

    # Upstream tests invoke `unshare`, `/usr/bin/ip`, `/usr/bin/python3`, and `dbus-daemon`.
    doCheck = false;

    # Never wrap `omdrop-radio` with `makeWrapper`: `pkexec` resolves `realpath`
    # against `org.freedesktop.policykit.exec.path`, so `$out/lib/omdrop-core/omdrop-radio`
    # must remain the direct ELF executable.
    postPatch = ''
      substituteInPlace crates/omdrop-radio/src/ctx.rs \
        --replace-fail 'const HOOKS: &str = "/usr/lib/omdrop/radio";' \
                       'const HOOKS: &str = "${awdl}/lib/omdrop/radio";' \
        --replace-fail 'const LEGACY: &str = "/usr/lib/omdrop";' \
                       'const LEGACY: &str = "${awdl}/lib/omdrop";' \
        --replace-fail 'busctl: PathBuf::from("/usr/bin/busctl"),' \
                       'busctl: PathBuf::from("${pkgs.systemd}/bin/busctl"),' \
        --replace-fail 'avahi_set_host_name: PathBuf::from("/usr/bin/avahi-set-host-name"),' \
                       'avahi_set_host_name: PathBuf::from("${pkgs.avahi}/bin/avahi-set-host-name"),' \
        --replace-fail '("PATH".into(), "/usr/bin:/usr/sbin".into()),' \
                       '("PATH".into(), "${radioChildPath}:/run/current-system/sw/bin".into()),'

      substituteInPlace crates/omdrop-radio/src/main.rs \
        --replace-fail '"/usr/lib/omdrop-core/omdrop-radio"' \
                       "\"$out/lib/omdrop-core/omdrop-radio\""

      substituteInPlace crates/omdrop-radio/src/window.rs \
        --replace-fail '/usr/lib/omdrop/awdl-up' '${awdl}/lib/omdrop/awdl-up'

      substituteInPlace crates/omdrop-cli/src/ctx.rs \
        --replace-fail 'pub const CORE_LIBEXEC: &str = "/usr/lib/omdrop-core";' \
                       "pub const CORE_LIBEXEC: &str = \"$out/lib/omdrop-core\";" \
        --replace-fail 'pub const LEGACY_LIBEXEC: &str = "/usr/lib/omdrop";' \
                       'pub const LEGACY_LIBEXEC: &str = "${awdl}/lib/omdrop";' \
        --replace-fail 'pub const RADIO_HOOKS: &str = "/usr/lib/omdrop/radio";' \
                       'pub const RADIO_HOOKS: &str = "${awdl}/lib/omdrop/radio";'

      substituteInPlace crates/omdrop-send/src/peer_env.rs \
        --replace-fail 'const LEGACY_DIR: &str = "/usr/lib/omdrop";' \
                       'const LEGACY_DIR: &str = "${awdl}/lib/omdrop";' \
        --replace-fail 'const RADIO_HOOKS_DIR: &str = "/usr/lib/omdrop/radio";' \
                       'const RADIO_HOOKS_DIR: &str = "${awdl}/lib/omdrop/radio";'

      substituteInPlace crates/omdrop-cli/src/driver.rs \
        --replace-fail '.unwrap_or_else(|| "/usr/bin/python3".to_string());' \
                       '.unwrap_or_else(|| "${omdropPython}/bin/python3".to_string());' \
        --replace-fail 'ctypes.CDLL(\"libkeyutils.so.1\")' \
                       'ctypes.CDLL(\"${pkgs.keyutils.lib}/lib/libkeyutils.so.1\")' \
        --replace-fail 'installed_pkg(DRIVER_PKG).is_some_and(|v| vercmp(&v, DRIVER_VERSION).is_ge())' \
                       'installed_pkg(DRIVER_PKG).or_else(|| awdl_backend().then(|| probe_field("version")).filter(|v| !v.is_empty())).is_some_and(|v| vercmp(&v, DRIVER_VERSION).is_ge())'
    '';

    postInstall = ''
      mkdir -p "$out/lib" "$out/share/polkit-1/actions"
      mv "$out/bin" "$out/lib/omdrop-core"

      install -Dm644 packaging/org.omarchy.omdrop.radio.policy \
        "$out/share/polkit-1/actions/org.omarchy.omdrop.radio.policy"
      substituteInPlace "$out/share/polkit-1/actions/org.omarchy.omdrop.radio.policy" \
        --replace-fail "/usr/lib/omdrop-core/omdrop-radio" "$out/lib/omdrop-core/omdrop-radio"
    '';

    meta = {
      description = "Rust AirDrop receiver, sender, advertiser, and Polkit radio supervisor for Omarchy";
      homepage = "https://github.com/netmojo-systems/omdrop-plugin";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  };

  # 3. Symlink-free Omarchy Shell bar plugin (`netmojo.omdrop` `v0.18.8`).
  patchPluginScript = ''
        rm -rf "$out/core" "$out/tests" "$out/omarchy-pkgs" "$out/.github" "$out/.gitignore"
        chmod 0755 "$out/bin/omdrop" "$out/bin/airdrop-serve.py"

        # Ensure `/run/wrappers/bin` comes FIRST so NixOS's setuid `pkexec` is used!
        sed -i 's|^set -uo pipefail$|set -uo pipefail\nexport PATH="/run/wrappers/bin:${pluginRuntimePath}:/run/current-system/sw/bin:''${PATH:-}"|' \
          "$out/bin/omdrop"

        substituteInPlace "$out/bin/omdrop" \
          --replace-fail '/usr/lib/omdrop-core/omdrop' '${core}/lib/omdrop-core/omdrop' \
          --replace-fail '/usr/lib/omdrop/radio' '${awdl}/lib/omdrop/radio' \
          --replace-fail '/usr/lib/omdrop/omdrop-discoverable' '${awdl}/lib/omdrop/omdrop-discoverable' \
          --replace-fail '/usr/lib/omdrop/send-to-peer' '${awdl}/lib/omdrop/send-to-peer' \
          --replace-fail '/usr/bin/python3' '${omdropPython}/bin/python3' \
          --replace-fail 'ctypes.CDLL("libkeyutils.so.1")' 'ctypes.CDLL("${pkgs.keyutils.lib}/lib/libkeyutils.so.1")' \
          --replace-fail 'installed=$(pacman -Q "$DRIVER_PKG" 2>/dev/null) || return 1' \
                         'installed=$(pacman -Q "$DRIVER_PKG" 2>/dev/null) || { radio_probe && installed=$(probe_field version); } || return 1'

        sed -i "1s|^#!/usr/bin/env bash$|#!${pkgs.bash}/bin/bash|" "$out/bin/omdrop"
        sed -i "1s|^#!/usr/bin/env python3$|#!${omdropPython}/bin/python3|" "$out/bin/airdrop-serve.py"

        substituteInPlace "$out/bin/identity.py" \
          --replace-fail "'libkeyutils.so.1'" "'${pkgs.keyutils.lib}/lib/libkeyutils.so.1'"

        # Keep `@PLUGIN_DIR@/bin/airdrop-serve.py` structure so `omdrop-cli`'s
        # `render_unit()` cleanly swaps it to `${core}/lib/omdrop-core/omdrop-receiver`
        # while injecting NixOS runtime tools (`ss`, `ip`, `openssl`, `wl-copy`, `heif-dec`, `magick`).
        substituteInPlace "$out/share/airdrop-receiver.service" \
          --replace-fail "[Service]" "[Service]
    Environment=\"PATH=${receiverServicePath}:/run/current-system/sw/bin\"" \
          --replace-fail "ExecStartPre=/bin/sh " "ExecStartPre=${pkgs.bash}/bin/sh " \
          --replace-fail "ExecStart=/usr/bin/python3 " "ExecStart=${omdropPython}/bin/python3 "

        substituteInPlace "$out/Radar.qml" \
          --replace-fail '"/bin/sh", "-c",' '"${pkgs.bash}/bin/sh", "-c",' \
          --replace-fail "'if command -v pw-play" "'export PATH=${
            lib.makeBinPath [
              pkgs.pipewire
              pkgs.pulseaudio
            ]
          }:\$PATH; if command -v pw-play"
  '';

  plugin =
    if buildPlugin != null then
      buildPlugin {
        src = omdropPluginSrc;
        postInstall = patchPluginScript;
      }
    else
      pkgs.runCommand "omdrop-plugin-${pluginVersion}" { } ''
        mkdir -p "$out"
        cp -r --no-preserve=mode,ownership "${omdropPluginSrc}/." "$out/"
        chmod -R u+w "$out"
        rm -rf "$out/.git"
        ${patchPluginScript}
      '';

  # 4. User-facing `omdrop` CLI wrapper on `$PATH`. Executes the materialized
  #    plugin entrypoint inside `~/.config/omarchy/plugins/netmojo.omdrop` when
  #    present so `plugin_from_invocation()` resolves the live plugin directory.
  cli =
    pkgs.runCommand "omdrop-${pluginVersion}"
      {
        passthru = {
          inherit
            awdl
            core
            plugin
            ;
          skillFile = "${omdropPluginSrc}/skills/omdrop/SKILL.md";
        };
        meta = {
          description = "Apple AirDrop for Omarchy & Linux over Broadcom AWDL (omdrop)";
          homepage = "https://github.com/netmojo-systems/omdrop-plugin";
          license = lib.licenses.mit;
          mainProgram = "omdrop";
          platforms = lib.platforms.linux;
        };
      }
      ''
        mkdir -p "$out/bin"
        cat > "$out/bin/omdrop" <<'EOF'
        #!${pkgs.bash}/bin/bash
        user_plugin="''${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/netmojo.omdrop/bin/omdrop"
        if [ -x "$user_plugin" ] && [ ! -L "$user_plugin" ]; then
          exec "$user_plugin" "$@"
        fi
        exec "${plugin}/bin/omdrop" "$@"
        EOF
        chmod 0755 "$out/bin/omdrop"
      '';
in
cli
