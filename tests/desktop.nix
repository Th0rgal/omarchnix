{
  pkgs,
  lib,
  inputs,
  m2airConfig,
  rehearsalConfig,
  vmConfig,
}:
assert m2airConfig.programs.hyprland.enable == true;
assert !(rehearsalConfig.programs.hyprland.enable or false);
assert !(vmConfig.programs.hyprland.enable or false);
assert !(rehearsalConfig ? home-manager) || (rehearsalConfig.home-manager.users == { });
assert !(vmConfig ? home-manager) || (vmConfig.home-manager.users == { });
assert m2airConfig.home-manager.users ? thomas;
assert m2airConfig.home-manager.users.thomas.wayland.windowManager.hyprland.enable == true;
assert m2airConfig.home-manager.users.thomas.wayland.windowManager.hyprland.configType == "lua";
assert m2airConfig.home-manager.users.thomas.wayland.windowManager.hyprland.extraConfig == "";
# UWSM owns graphical-session.target; HM's hyprland-session.target must stay off
# or the generated startup exec stops the compositor a few seconds after login.
assert m2airConfig.home-manager.users.thomas.wayland.windowManager.hyprland.systemd.enable == false;
assert builtins.any (p: (p.pname or "") == "orb-desktop") m2airConfig.environment.systemPackages;
assert m2airConfig.programs.thunar.enable == false;
assert m2airConfig.services.tumbler.enable == false;
assert builtins.any (p: (p.pname or "") == "flea") m2airConfig.xdg.portal.extraPortals;
assert m2airConfig.home-manager.users.thomas.programs.omarchnix.flea.enable == true;
assert
  m2airConfig.home-manager.users.thomas.xdg.mimeApps.defaultApplications."inode/directory"
  == [ "com.thisisgm.flea.desktop" ];
assert
  (m2airConfig.xdg.portal.config.hyprland."org.freedesktop.impl.portal.Settings" or null) == "gtk";
assert builtins.elem "pipewire.service" m2airConfig.systemd.user.services.xdg-desktop-portal.after;
assert builtins.elem "wireplumber.service"
  m2airConfig.systemd.user.services.xdg-desktop-portal.after;
assert m2airConfig.systemd.user.services.xdg-desktop-portal.enableDefaultPath == false;
assert !(m2airConfig.systemd.user.services.xdg-desktop-portal.environment ? PATH);
assert builtins.elem "pipewire.service"
  m2airConfig.systemd.user.services.xdg-desktop-portal-hyprland.after;
assert builtins.elem "pipewire.service"
  m2airConfig.systemd.user.services.xdg-desktop-portal-hyprland.partOf;
assert m2airConfig.systemd.user.services.xdg-desktop-portal-hyprland.enableDefaultPath == false;
assert !(m2airConfig.systemd.user.services.xdg-desktop-portal-hyprland.environment ? PATH);
assert m2airConfig.xdg.portal.xdgOpenUsePortal == true;
assert m2airConfig.home-manager.users.thomas.xdg.configFile ? "hypr/xdph.conf";
assert m2airConfig.fonts.enableDefaultPackages == false;
assert m2airConfig.home-manager.users.thomas.gtk.font.name == "IBM Plex Sans";
assert m2airConfig.home-manager.users.thomas.gtk.font.size == 9;
assert
  m2airConfig.home-manager.users.thomas.dconf.settings."org/gnome/desktop/interface".font-name
  == "IBM Plex Sans 9";
assert
  m2airConfig.home-manager.users.thomas.dconf.settings."org/gnome/desktop/interface".document-font-name
  == "Michelangelus 10";
assert
  m2airConfig.home-manager.users.thomas.dconf.settings."org/gnome/desktop/interface".monospace-font-name
  == "Lilex Nerd Font 11";
assert m2airConfig.home-manager.users.thomas.gtk.gtk3.extraConfig.gtk-decoration-layout == ":";
assert m2airConfig.home-manager.users.thomas.gtk.gtk4.extraConfig.gtk-decoration-layout == ":";
assert
  m2airConfig.home-manager.users.thomas.dconf.settings."org/gnome/desktop/wm/preferences".button-layout
  == ":";
assert m2airConfig.environment.etc ? "brave/policies/managed";
assert m2airConfig.environment.etc ? "chromium/policies/managed";
assert m2airConfig.omarchnix.desktop.widevine.enable == true;
assert builtins.elem "widevine-cdm" m2airConfig.nixpkgs.config.allowUnfreePackages;
assert m2airConfig.home-manager.users.thomas.programs.omarchnix.widevine.enable == true;
assert m2airConfig.home-manager.users.thomas.programs.omarchnix.widevine.package != null;
assert m2airConfig.home-manager.users.thomas.home.sessionVariables ? MOZ_GMP_PATH;
assert
  m2airConfig.home-manager.users.thomas.wayland.windowManager.hyprland.settings.config.input.kb_layout
  == "us";
assert
  m2airConfig.home-manager.users.thomas.wayland.windowManager.hyprland.settings.config.input.kb_variant
  == "intl";
assert
  m2airConfig.home-manager.users.thomas.wayland.windowManager.hyprland.settings.config.input.touchpad.natural_scroll
  == false;
assert
  m2airConfig.home-manager.users.thomas.wayland.windowManager.hyprland.settings.config.input.touchpad.scroll_factor
  == 0.5;
assert
  m2airConfig.home-manager.users.thomas.wayland.windowManager.hyprland.settings.config.input.touchpad.tap_to_click
  == true;
assert m2airConfig.home-manager.users.thomas.programs.foot.enable == true;
assert m2airConfig.home-manager.users.thomas.programs.waybar.enable == false;
assert m2airConfig.home-manager.users.thomas.systemd.user.services ? omarchy-shell;
assert m2airConfig.home-manager.users.thomas.systemd.user.services ? omarchy-fcitx5;
assert m2airConfig.i18n.inputMethod.enable == true;
assert m2airConfig.i18n.inputMethod.type == "fcitx5";
assert m2airConfig.i18n.inputMethod.fcitx5.waylandFrontend == true;
assert m2airConfig.home-manager.users.thomas.programs.fuzzel.enable == true;
assert m2airConfig.home-manager.users.thomas.programs.hyprlock.enable == true;
assert m2airConfig.home-manager.users.thomas.services.hypridle.enable == true;
assert m2airConfig.home-manager.users.thomas.services.hyprpaper.enable == true;
assert m2airConfig.home-manager.users.thomas.xdg.userDirs.enable == true;
assert m2airConfig.home-manager.users.thomas.xdg.userDirs.createDirectories == true;
assert m2airConfig.home-manager.users.thomas.xdg.userDirs.videos == "/home/thomas/Videos";
assert m2airConfig.home-manager.users.thomas.xdg.userDirs.pictures == "/home/thomas/Pictures";
# The internal panel must not pin an absolute timing: appledrm only exposes the
# modes the Apple DCP reports (e.g. 2560x1600 on J413 / Linux Asahi 7.2.15), and
# requesting a non-existent mode breaks the atomic commit and page-flip path.
assert
  let
    panel = builtins.head m2airConfig.home-manager.users.thomas.wayland.windowManager.hyprland.settings.monitor;
  in
  panel.output == "eDP-1" && panel.mode == "preferred" && panel.scale == "1.6";

pkgs.testers.runNixOSTest {
  name = "asahi-nixos-desktop";

  qemu.package = pkgs.symlinkJoin {
    name = "qemu-kvm-virgl-sw";
    paths = [ pkgs.qemu_kvm ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      for bin in qemu-kvm qemu-system-x86_64; do
        if [ -e "$out/bin/$bin" ]; then
          wrapProgram "$out/bin/$bin" \
            --set SDL_VIDEODRIVER offscreen \
            --set LIBGL_ALWAYS_SOFTWARE 1 \
            --set __EGL_VENDOR_LIBRARY_DIRS "${pkgs.mesa}/share/glvnd/egl_vendor.d" \
            --set LIBGL_DRIVERS_PATH "${pkgs.mesa}/lib/dri" \
            --set GBM_BACKENDS_PATH "${pkgs.mesa}/lib/gbm" \
            --prefix LD_LIBRARY_PATH : "${pkgs.libglvnd}/lib:${pkgs.mesa}/lib" \
            --append-flags "-display sdl,gl=on"
        fi
      done
    '';
  };

  node.specialArgs = { inherit inputs; };

  nodes.desktop =
    { pkgs, ... }:
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
        ../hosts/common.nix
        ../modules/hardening.nix
      ];

      networking.hostName = "desktop";

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        qemu.options = [
          "-vga none"
          "-device virtio-vga-gl"
        ];
      };

      hardware.graphics.enable = true;

      programs.hyprland = {
        enable = true;
        withUWSM = true;
        xwayland.enable = true;
      };

      security.pam.services.hyprlock = { };
      security.polkit.enable = true;

      services.getty.autologinUser = "thomas";

      environment.variables = {
        WLR_RENDERER_ALLOW_SOFTWARE = "1";
      };

      programs.zsh.loginShellInit = ''
        if [ "$(tty)" = "/dev/tty1" ]; then
          export HYPRLAND_NO_SD_NOTIFY=1
          exec start-hyprland >/tmp/hyprland.log 2>&1
        fi
      '';

      users.users.thomas = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = [
          "wheel"
          "video"
          "render"
          "audio"
        ];
        shell = "/run/current-system/sw/bin/zsh";
      };

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs = { inherit inputs; };
        users.thomas = import ../home;
      };

      environment.systemPackages = [
        pkgs.jq
        pkgs.netpbm
        pkgs.procps
        pkgs.orb-desktop
      ];
    };

  testScript = ''
    import json

    def hypr(cmd: str) -> str:
        return (
            "su - thomas -c '"
            "export XDG_RUNTIME_DIR=/run/user/1000; "
            "export HYPRLAND_INSTANCE_SIGNATURE=$(ls -1 /run/user/1000/hypr 2>/dev/null | head -n1); "
            "test -n \"$HYPRLAND_INSTANCE_SIGNATURE\" && "
            f"{cmd}'"
        )

    start_all()

    desktop.wait_for_unit("multi-user.target")

    with subtest("Hyprland starts with Lua config, zero extraConfig, and Waybar/hyprpaper/hypridle"):
        try:
            desktop.wait_until_succeeds(
                hypr("hyprctl instances -j | jq -e \"length >= 1\""),
                timeout=90,
            )
        except Exception:
            _, diag = desktop.execute(
                "cat /tmp/hyprland.log /home/thomas/.local/share/hyprland/hyprland.log /run/user/1000/hypr/*/hyprland.log 2>&1 || true; ps aux; ls -la /home/thomas /run/user/1000"
            )
            print("DIAGNOSTICS:\n" + diag)
            raise
        desktop.succeed("test -f /home/thomas/.config/hypr/hyprland.lua")
        desktop.succeed("test ! -e /home/thomas/.config/hypr/hyprland.conf")

        config_err_raw = desktop.succeed(hypr("hyprctl configerrors -j")).strip()
        config_errs = [e for e in json.loads(config_err_raw) if e.strip()]
        assert config_errs == [], f"Hyprland config errors: {config_errs!r}"

        kb_layout = desktop.succeed(
            hypr("hyprctl getoption input:kb_layout -j | jq -r .str")
        ).strip()
        assert kb_layout == "us", f"expected us keymap, got {kb_layout!r}"

        kb_variant = desktop.succeed(
            hypr("hyprctl getoption input:kb_variant -j | jq -r .str")
        ).strip()
        assert kb_variant == "intl", f"expected intl variant, got {kb_variant!r}"

        nat_scroll_data = json.loads(
            desktop.succeed(hypr("hyprctl getoption input:touchpad:natural_scroll -j"))
        )
        assert nat_scroll_data.get("bool") is True or nat_scroll_data.get("int") == 1, (
            f"expected natural_scroll=true, got {nat_scroll_data!r}"
        )

        tap_click_data = json.loads(
            desktop.succeed(hypr("hyprctl getoption input:touchpad:tap-to-click -j"))
        )
        assert tap_click_data.get("bool") is True or tap_click_data.get("int") == 1, (
            f"expected tap-to-click=true, got {tap_click_data!r}"
        )

        desktop.wait_until_succeeds("systemctl --user -M thomas@ is-active waybar.service", timeout=45)
        desktop.wait_until_succeeds("systemctl --user -M thomas@ is-active hypridle.service", timeout=45)
        desktop.wait_until_succeeds("systemctl --user -M thomas@ is-active hyprpaper.service", timeout=45)
        desktop.wait_until_succeeds(
            hypr("hyprctl layers -j | jq -e \".. | objects | select(.namespace? == \\\"hyprpaper\\\")\""),
            timeout=45,
        )
        desktop.succeed("systemctl --user -M thomas@ is-active waybar.service")
        desktop.succeed("systemctl --user -M thomas@ is-active hypridle.service")
        desktop.succeed("systemctl --user -M thomas@ is-active hyprpaper.service")
        desktop.succeed("test \"$(systemctl --user -M thomas@ show -p NRestarts --value waybar.service)\" = 0")
        desktop.succeed("test \"$(systemctl --user -M thomas@ show -p NRestarts --value hypridle.service)\" = 0")
        desktop.succeed("test \"$(systemctl --user -M thomas@ show -p NRestarts --value hyprpaper.service)\" = 0")
        desktop.succeed("test -z \"$(ls -A /var/lib/systemd/coredump 2>/dev/null)\"")

    with subtest("Special scratchpad spawns foot terminal and grim captures non-empty screenshot"):
        desktop.succeed(
            hypr(
                "hyprctl dispatch \"hl.dsp.workspace.toggle_special(\\\"scratchpad\\\")\""
            )
        )
        desktop.wait_until_succeeds(
            hypr(
                "hyprctl clients -j | jq -e \"map(select(.class == \\\"foot-scratchpad\\\")) | length >= 1\""
            ),
            timeout=45,
        )

        desktop.succeed(
            hypr("WAYLAND_DISPLAY=wayland-1 grim /tmp/desktop-shot.png")
        )
        shot_size = int(desktop.succeed("stat -c %s /tmp/desktop-shot.png").strip())
        assert shot_size > 8192, f"screenshot unexpectedly tiny: {shot_size} bytes"
        unique_colors = int(
            desktop.succeed(
                "pngtopam /tmp/desktop-shot.png | ppmhist -noheader | wc -l"
            ).strip()
        )
        assert unique_colors >= 16, f"screenshot looks blank ({unique_colors} unique colors)"
        desktop.succeed("orb --self-test")
        desktop.copy_from_machine("/tmp/desktop-shot.png", "")
  '';
}
