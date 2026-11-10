{
  pkgs,
  lib,
  inputs,
  omarchyLib,
  self,
}:
let
  allThemes = omarchyLib.allBundledThemes pkgs;
  themeList = builtins.attrValues allThemes;
  samplePlugin = pkgs.omarchnix.buildPlugin {
    src = inputs.omarchy-plugin-opencode-usage;
  };
in
assert builtins.length omarchyLib.themeNames >= 23;
assert builtins.all (
  t:
  t.name != ""
  && (t.mode == "dark" || t.mode == "light")
  && builtins.stringLength t.colors.bg == 6
  && builtins.stringLength t.colors.fg == 6
  && builtins.stringLength t.colors.accent == 6
) themeList;
assert allThemes.tokyo-night.mode == "dark";
assert allThemes.catppuccin-latte.mode == "light";
assert allThemes.flexoki-light.mode == "light";
assert allThemes.white.mode == "light";
assert
  (omarchyLib.importTheme {
    theme = "Rose Pine";
    inherit pkgs;
  }).name == "rose-pine";
assert samplePlugin.pluginId == "dizziee.opencode-model-usage";
pkgs.testers.runNixOSTest {
  name = "omarchnix-omarchy-compat";

  qemu.package = pkgs.symlinkJoin {
    name = "qemu-kvm-virgl-sw";
    paths = [ pkgs.qemu_kvm ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      for bin in qemu-kvm qemu-system-x86_64 qemu-system-aarch64; do
        if [ -x "$out/bin/$bin" ]; then
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

  nodes.workstation =
    { pkgs, ... }:
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
        self.nixosModules.omarchnix
      ];

      networking.hostName = "omarchy-vm";

      omarchnix = {
        enable = true;
        profile = "vm";
        hardening.enable = true;
        desktop = {
          enable = true;
          user = "thomas";
          theme = "tokyo-night";
          shellBackend = "omarchy-shell";
        };
      };

      virtualisation = {
        memorySize = 3072;
        cores = 2;
        qemu.options = [
          "-vga none"
          "-device virtio-vga-gl"
        ];
      };

      services.getty.autologinUser = "thomas";

      environment.variables = {
        WLR_RENDERER_ALLOW_SOFTWARE = "1";
        LIBGL_ALWAYS_SOFTWARE = "1";
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

      home-manager.users.thomas = {
        programs.omarchnix.plugins.locked."dizziee.opencode-model-usage" = {
          package = samplePlugin;
          enable = true;
          section = "right";
        };
      };

      environment.systemPackages = [
        pkgs.dconf
        pkgs.jq
        pkgs.procps
      ];
    };

  testScript = ''
    import json

    def as_thomas(cmd: str) -> str:
        return (
            "su - thomas -c '"
            "export XDG_RUNTIME_DIR=/run/user/1000; "
            "export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; "
            "export WAYLAND_DISPLAY=wayland-1; "
            "export HYPRLAND_INSTANCE_SIGNATURE=$(ls -1 /run/user/1000/hypr 2>/dev/null | head -n1); "
            f"{cmd}'"
        )

    start_all()
    workstation.wait_for_unit("multi-user.target")

    with subtest("Hyprland and omarchy-shell QML runtime start cleanly with zero symlink plugins"):
        try:
            workstation.wait_until_succeeds(
                as_thomas("test -n \"$HYPRLAND_INSTANCE_SIGNATURE\" && hyprctl instances -j | jq -e \"length >= 1\""),
                timeout=90,
            )
            workstation.wait_until_succeeds("systemctl --user -M thomas@ is-active omarchy-shell.service", timeout=60)
            workstation.wait_until_succeeds(
                as_thomas("test \"$(omarchy-shell shell ping)\" = ok"),
                timeout=60,
            )
            workstation.wait_until_succeeds(
                as_thomas("omarchnix plugin list --json | jq -e 'type == \"array\" and length >= 1'"),
                timeout=90,
            )
        except Exception:
            _, diag = workstation.execute(
                "journalctl -t omarchy-shell --no-pager -n 120; systemctl --user -M thomas@ status omarchy-shell.service --no-pager || true; cat /tmp/hyprland.log || true"
            )
            print("OMARCHY_SHELL_DIAG:\n" + diag)
            raise

        workstation.succeed("test ! -L /home/thomas/.config/omarchy/shell.json")
        workstation.succeed("test -d /home/thomas/.config/omarchy/plugins/dizziee.opencode-model-usage")
        workstation.succeed("test -z \"$(find /home/thomas/.config/omarchy/plugins/dizziee.opencode-model-usage -type l)\"")

    with subtest("Declarative plugins.omarchy.org plugin is discovered & enabled inside omarchy-shell"):
        plugins_raw = workstation.succeed(as_thomas("omarchnix plugin list --json")).strip()
        plugins = json.loads(plugins_raw)
        plugin_ids = {p["id"]: p for p in plugins}
        assert "omarchy.bar" in plugin_ids, f"expected built-in omarchy.bar in {list(plugin_ids)}"
        assert "dizziee.opencode-model-usage" in plugin_ids, f"expected locked plugin in {list(plugin_ids)}"
        assert plugin_ids["dizziee.opencode-model-usage"]["enabled"] is True, (
            f"expected dizziee.opencode-model-usage enabled=True, got {plugin_ids['dizziee.opencode-model-usage']!r}"
        )

        reg_raw = workstation.succeed(as_thomas("omarchnix plugin registry opencode --json")).strip()
        reg_entries = json.loads(reg_raw)
        assert len(reg_entries) >= 5, f"expected plugins.omarchy.org registry results, got {len(reg_entries)}"

    with subtest("Live theme switching updates shell, templates, Claude skin, and omarchnix status"):
        initial_theme = workstation.succeed(as_thomas("omarchnix theme current")).strip()
        assert initial_theme == "Tokyo Night", f"expected Tokyo Night, got {initial_theme!r}"

        workstation.succeed("mkdir -p /home/thomas/.claude && chown -R thomas:users /home/thomas/.claude")
        workstation.succeed(as_thomas("omarchnix theme set \"Catppuccin\""))

        switched = workstation.succeed(as_thomas("omarchnix theme current")).strip()
        assert switched == "Catppuccin", f"expected Catppuccin after live switch, got {switched!r}"
        workstation.succeed("test -f /home/thomas/.local/state/omarchy/current/theme/shell.toml")
        workstation.succeed("test -f /home/thomas/.local/state/omarchy/current/theme/foot.ini")
        workstation.succeed("test -f /home/thomas/.claude/themes/omarchy.json")

        workstation.succeed(as_thomas("omarchnix theme set \"Catppuccin Latte\""))
        switched_light = workstation.succeed(as_thomas("omarchnix theme current")).strip()
        assert switched_light == "Catppuccin Latte", f"expected Catppuccin Latte, got {switched_light!r}"
        color_scheme_light = workstation.succeed(as_thomas("dconf read /org/gnome/desktop/interface/color-scheme")).strip()
        assert color_scheme_light == "'prefer-light'", f"expected prefer-light in dconf, got {color_scheme_light!r}"

        workstation.succeed(as_thomas("omarchnix theme toggle"))
        toggled_dark = workstation.succeed(as_thomas("omarchnix theme current")).strip()
        assert toggled_dark == "Tokyo Night", f"expected Tokyo Night after toggle from light, got {toggled_dark!r}"
        color_scheme_dark = workstation.succeed(as_thomas("dconf read /org/gnome/desktop/interface/color-scheme")).strip()
        assert color_scheme_dark == "'prefer-dark'", f"expected prefer-dark in dconf, got {color_scheme_dark!r}"

        workstation.succeed(as_thomas("omarchnix theme toggle"))
        toggled_back_light = workstation.succeed(as_thomas("omarchnix theme current")).strip()
        assert toggled_back_light == "Catppuccin Latte", f"expected remembered Catppuccin Latte after toggle, got {toggled_back_light!r}"

    with subtest("Agent skills for opencode, claude, codex, and hermes + omarchnix check pass"):
        for skill_dir in [
            "/home/thomas/.agents/skills/omarchnix",
            "/home/thomas/.claude/skills/omarchnix",
            "/home/thomas/.codex/skills/omarchnix",
            "/home/thomas/.hermes/skills/omarchnix",
            "/home/thomas/.config/opencode/skills/omarchnix",
        ]:
            workstation.succeed(f"test -f {skill_dir}/SKILL.md")
            workstation.succeed(f"test -f {skill_dir}/themes.md")
            workstation.succeed(f"test -f {skill_dir}/shell-and-plugins.md")
        workstation.succeed("test -f /home/thomas/.config/opencode/opencode.json")
        workstation.succeed("test -f /home/thomas/.config/opencode/cli.json")

        check_json = json.loads(workstation.succeed(as_thomas("omarchnix check --json")).strip())
        assert check_json["ok"] is True, f"omarchnix check failed: {check_json!r}"

        status_json = json.loads(workstation.succeed(as_thomas("omarchnix status --json")).strip())
        assert status_json["shellRunning"] is True, f"expected shellRunning=True, got {status_json!r}"
        assert len(status_json["agentSkills"]) == 4, f"expected 4 agent skill dirs, got {status_json!r}"
  '';
}
