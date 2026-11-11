# Deterministic NixOS QEMU/KVM desktop showcase capture (`aarch64-linux` & `x86_64-linux`).
# Invoked by `scripts/showcase/reproduce.sh` to produce:
#   - 01-terminal-singapore.png  (Space 1 · Frosted Ghostty over singapore.webp)
#   - 02-orb-bologna.png         (Space 2 · Native orb-desktop over bologna-dome.webp)
#   - 03-touchid-canyon.png      (Space 3 · Biometric Touch ID HUD over kazakhstan-charyn-canyon-peaks.webp)
#   - SHA256SUMS
{
  pkgs,
  lib ? pkgs.lib,
  inputs,
  omarchnixModule ? import ../../modules/omarchnix.nix,
  wallpapersSrc,
}:
let
  starshipSubtle = import ../../themes/starship-subtle { inherit pkgs lib; };
  mockOrbServer = ./mock-orb-server.py;

  termSpace1 = pkgs.writeScript "showcase-term-space1" ''
    #!${pkgs.zsh}/bin/zsh
    mkdir -p "$HOME/work/omarchnix"
    cd "$HOME/work/omarchnix"
    clear
    ${pkgs.fastfetch}/bin/fastfetch
    printf '\n  Programming ligatures   !=   ===   ->   =>   <=   >=\n\n'
    printf '\033[38;2;156;199;216mthomas\033[0m \033[38;2;142;142;147m~/work/omarchnix\033[0m \033[1;38;2;142;184;151m❯\033[0m '
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';

  termSpace3 = pkgs.writeScript "showcase-term-space3" ''
    #!${pkgs.zsh}/bin/zsh
    mkdir -p "$HOME/work/nixos-config"
    cd "$HOME/work/nixos-config"
    clear
    printf '\n  NixOS · Declarative fleet configuration\n\n'
    printf '  Host      m2air\n'
    printf '  Profile   Omarchnix desktop\n'
    printf '  Change    Verified system generation\n\n'
    printf '\033[38;2;156;199;216mthomas\033[0m \033[38;2;142;142;147m~/work/nixos-config\033[0m \033[1;38;2;142;184;151m❯\033[0m sudo nixos-rebuild switch --flake .#m2air'
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';
in
pkgs.testers.runNixOSTest {
  name = "omarchnix-showcase-captures";

  qemu.package = pkgs.symlinkJoin {
    name = "qemu-kvm-virgl-sw";
    paths = [ pkgs.qemu_kvm ];
    postBuild = ''
      for bin in qemu-kvm qemu-system-x86_64 qemu-system-aarch64; do
        if [ -e "$out/bin/$bin" ]; then
          real_bin="$(readlink -f "$out/bin/$bin")"
          rm -f "$out/bin/$bin"
          cat > "$out/bin/$bin" <<EOF
      #!${pkgs.runtimeShell}
      export SDL_VIDEODRIVER=offscreen
      export LIBGL_ALWAYS_SOFTWARE=1
      export __EGL_VENDOR_LIBRARY_DIRS="${pkgs.mesa}/share/glvnd/egl_vendor.d"
      export LIBGL_DRIVERS_PATH="${pkgs.mesa}/lib/dri"
      export GBM_BACKENDS_PATH="${pkgs.mesa}/lib/gbm"
      export LD_LIBRARY_PATH="${pkgs.libglvnd}/lib:${pkgs.mesa}/lib\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
      args=()
      while [ \$# -gt 0 ]; do
        if [ "\$1" = "-device" ] && [ "\''${2:-}" = "virtio-gpu-pci" ]; then
          shift 2
          continue
        fi
        args+=("\$1")
        shift
      done
      exec "$real_bin" "\''${args[@]}" -display sdl,gl=on
      EOF
          chmod +x "$out/bin/$bin"
        fi
      done
    '';
  };

  node.specialArgs = { inherit inputs; };

  nodes.showcase =
    { pkgs, ... }:
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
        omarchnixModule
      ];

      networking.hostName = "omarchnix-vm";
      documentation.enable = false;
      boot.loader.systemd-boot.enable = lib.mkForce false;

      virtualisation = {
        memorySize = 6144;
        cores = 4;
        qemu.options =
          if pkgs.stdenv.hostPlatform.isAarch64 then
            [
              "-vga none"
              "-device virtio-gpu-gl-pci,xres=2560,yres=1600"
            ]
          else
            [
              "-vga none"
              "-device virtio-vga-gl,xres=2560,yres=1600"
            ];
      };

      hardware.graphics.enable = true;

      environment.variables = {
        WLR_RENDERER_ALLOW_SOFTWARE = "1";
      };

      omarchnix = {
        enable = true;
        profile = "vm";
        defaultTimeZone = "Europe/Lisbon";
        hardening.enable = true;
        containers.enable = false;
        secrets.enable = false;
        desktop = {
          enable = true;
          user = "thomas";
          theme = starshipSubtle.dark.name;
          shellBackend = "omarchy-shell";
          murmure.enable = false;
          keyboard = {
            layout = "us";
            variant = "intl";
          };
          macos = {
            enable = true;
            dock = false;
            persistentWorkspaces = 3;
            gestures = false;
            touchIdHud = true;
            wallpapers = {
              default = "${wallpapersSrc}/singapore.webp";
              workspaces = {
                "1" = "${wallpapersSrc}/singapore.webp";
                "2" = "${wallpapersSrc}/bologna-dome.webp";
                "3" = "${wallpapersSrc}/kazakhstan-charyn-canyon-peaks.webp";
              };
            };
          };
          autostartTty = {
            enable = true;
            unlockKeyringFromLuks = false;
          };
        };
      };

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
        programs.fastfetch.enable = true;

        programs.omarchnix = {
          agents.enable = false;
          theme = {
            name = lib.mkForce starshipSubtle.dark.name;
            darkName = starshipSubtle.dark.name;
            lightName = starshipSubtle.light.name;
            attrset = starshipSubtle.dark.attrset;
            customThemes = {
              ${starshipSubtle.dark.name} = starshipSubtle.dark.package;
              ${starshipSubtle.light.name} = starshipSubtle.light.package;
            };
          };
        };

        wayland.windowManager.hyprland.settings = {
          monitor = lib.mkForce [
            {
              output = "";
              mode = "2560x1600@60";
              position = "0x0";
              scale = "1.6";
            }
          ];
          config = {
            general = {
              border_size = 1;
              col = {
                active_border = lib.mkForce starshipSubtle.dark.palette.hyprland_active_border;
                inactive_border = lib.mkForce starshipSubtle.dark.palette.hyprland_inactive_border;
              };
            };
            ecosystem = {
              no_donation_nag = true;
              no_update_news = true;
            };
            cursor = {
              invisible = true;
              inactive_timeout = 1;
              no_hardware_cursors = true;
            };
          };
        };
      };

      environment.systemPackages = [
        pkgs.jq
        pkgs.grim
        pkgs.wtype
        pkgs.fastfetch
        pkgs.python3
        pkgs.procps
        pkgs.orb-desktop
      ];
    };

  testScript = ''
    import json
    import shlex
    import time

    def hypr(cmd: str) -> str:
        inner = (
            "export XDG_RUNTIME_DIR=/run/user/1000; "
            "export HYPRLAND_INSTANCE_SIGNATURE=$(ls -1 /run/user/1000/hypr 2>/dev/null | head -n1); "
            "export WAYLAND_DISPLAY=$(ls -1 /run/user/1000/wayland-* 2>/dev/null | grep -v '\\.lock$' | head -n1 | xargs -r basename); "
            'test -n "$HYPRLAND_INSTANCE_SIGNATURE" && test -n "$WAYLAND_DISPLAY" && '
            + cmd
        )
        return "su - thomas -c " + shlex.quote(inner)

    def center_showcase() -> None:
        showcase.succeed(hypr("hyprctl dispatch \"hl.dsp.window.float({ action = 'enable' })\""))
        time.sleep(0.8)
        showcase.succeed(
            hypr("hyprctl dispatch 'hl.dsp.window.resize({ x = 1344, y = 828, relative = false })'")
        )
        time.sleep(0.8)
        w = json.loads(showcase.succeed(hypr("hyprctl activewindow -j")))
        m = json.loads(showcase.succeed(hypr("hyprctl monitors -j")))[0]
        rt = m.get("reserved", [0, 32, 0, 0])[1]
        ww, wh = w["size"]
        cx = round((1600 - ww) / 2)
        cy = round(rt + ((1000 - rt) - wh) / 2)
        showcase.succeed(
            hypr(f"hyprctl dispatch 'hl.dsp.window.move({{ x = {cx}, y = {cy}, relative = false }})'")
        )
        showcase.wait_until_succeeds(
            hypr("hyprctl activewindow -j | jq -e '.floating == true and .size[0] >= 1280'"),
            timeout=20,
        )

    start_all()
    showcase.wait_for_unit("multi-user.target")

    showcase.wait_until_succeeds(
        hypr("hyprctl instances -j | jq -e \"length >= 1\""),
        timeout=120,
    )
    showcase.wait_until_succeeds(
        "systemctl --user -M thomas@ is-active omarchy-shell.service",
        timeout=90,
    )
    showcase.succeed("systemctl --user -M thomas@ stop hypridle.service || true")
    showcase.wait_until_succeeds(
        hypr("hyprctl layers -j | jq -e \".. | objects | select(.namespace? == \\\"omarchnix-workspace-wallpaper\\\")\""),
        timeout=90,
    )

    # Start deterministic mock Core + static Orb UI server on 127.0.0.1:1430
    showcase.succeed(
        "su - thomas -c 'nohup python3 ${mockOrbServer} --port 1430 >/tmp/mock-orb.log 2>&1 </dev/null &'"
    )
    showcase.wait_until_succeeds(
        "python3 -c \"import urllib.request; assert urllib.request.urlopen('http://127.0.0.1:1430/api/health', timeout=2).status == 200\"",
        timeout=30,
    )

    # Populate all three Spaces first so workspace chips 1, 2, 3 all show active/occupied state
    # Space 3: Ghostty backdrop for Touch ID HUD
    showcase.succeed(hypr("hyprctl dispatch \"hl.dsp.focus({ workspace = 3 })\""))
    showcase.succeed(
        hypr("nohup ghostty --font-size=14 -e ${termSpace3} >/tmp/ghostty-s3.log 2>&1 </dev/null &")
    )
    showcase.wait_until_succeeds(
        hypr("hyprctl clients -j | jq -e \"map(select(.workspace.id == 3)) | length >= 1\""),
        timeout=45,
    )
    time.sleep(1.5)
    center_showcase()

    # Space 2: Native GTK4 + WebKitGTK orb-desktop connected to mock-orb-server.py
    showcase.succeed(hypr("hyprctl dispatch \"hl.dsp.focus({ workspace = 2 })\""))
    showcase.succeed(
        hypr(
            "nohup env ORB_DEV_URL=http://127.0.0.1:1430 GSK_RENDERER=cairo WEBKIT_DISABLE_DMABUF_RENDERER=1 orb >/tmp/orb.log 2>&1 </dev/null &"
        )
    )
    showcase.wait_until_succeeds(
        hypr("hyprctl clients -j | jq -e \"map(select(.workspace.id == 2)) | length >= 1\""),
        timeout=60,
    )
    showcase.wait_until_succeeds(
        "python3 -c \"import urllib.request; assert urllib.request.urlopen('http://127.0.0.1:1430/__showcase_ready', timeout=2).status == 200\"",
        timeout=45,
    )
    time.sleep(2.5)
    center_showcase()

    # Space 1: Frosted Ghostty running fastfetch + Lilex Nerd Font ligature showcase
    showcase.succeed(hypr("hyprctl dispatch \"hl.dsp.focus({ workspace = 1 })\""))
    showcase.succeed(
        hypr("nohup ghostty --font-size=14 -e ${termSpace1} >/tmp/ghostty-s1.log 2>&1 </dev/null &")
    )
    showcase.wait_until_succeeds(
        hypr("hyprctl clients -j | jq -e \"map(select(.workspace.id == 1)) | length >= 1\""),
        timeout=45,
    )
    time.sleep(2.0)
    center_showcase()

    # Capture 1: Space 1 (singapore.webp + Frosted Ghostty)
    time.sleep(2.5)
    showcase.succeed(hypr("grim /tmp/01-terminal-singapore.png"))

    # Capture 2: Space 2 (bologna-dome.webp + Native Orb Desktop UI)
    showcase.succeed(hypr("hyprctl dispatch \"hl.dsp.focus({ workspace = 2 })\""))
    time.sleep(3.5)
    showcase.succeed(hypr("grim /tmp/02-orb-bologna.png"))

    # Capture 3: Space 3 (kazakhstan-charyn-canyon-peaks.webp + Touch ID HUD)
    showcase.succeed(hypr("hyprctl dispatch \"hl.dsp.focus({ workspace = 3 })\""))
    time.sleep(1.5)
    showcase.succeed(
        hypr(
            "omarchy-shell touchid hold '{\"app\":\"Orb\",\"subtitle\":\"Approve desktop session\",\"state\":\"scanning\",\"progress\":0.92}'"
        )
    )
    showcase.wait_until_succeeds(
        hypr("hyprctl layers -j | jq -e \".. | objects | select(.namespace? == \\\"omarchnix-touchid\\\")\""),
        timeout=20,
    )
    time.sleep(1.5)
    showcase.succeed(hypr("grim /tmp/03-touchid-canyon.png"))
    showcase.succeed(hypr("omarchy-shell touchid cancel"))

    showcase.succeed(
        "cd /tmp && sha256sum 01-terminal-singapore.png 02-orb-bologna.png 03-touchid-canyon.png > /tmp/SHA256SUMS"
    )
    showcase.copy_from_machine("/tmp/01-terminal-singapore.png", "")
    showcase.copy_from_machine("/tmp/02-orb-bologna.png", "")
    showcase.copy_from_machine("/tmp/03-touchid-canyon.png", "")
    showcase.copy_from_machine("/tmp/SHA256SUMS", "")
  '';
}
