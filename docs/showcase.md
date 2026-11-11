# Reproducing the Desktop Showcase

The three showcase screenshots in [`README.md`](../README.md) are unretouched `2560×1600` (`1.6x` HiDPI) Wayland captures taken inside a declarative NixOS QEMU/KVM desktop guest with `grim`.

| Asset | Space | Wallpaper (`github:Th0rgal/wallpapers`) | Scene |
| :--- | :---: | :--- | :--- |
| [`docs/assets/showcase/01-terminal-singapore.png`](assets/showcase/01-terminal-singapore.png) | `1` | `singapore.webp` | Centered (`Option + C`) frosted Ghostty terminal (`0.35` alpha + 3-pass Kawase blur), `fastfetch`, and `Lilex Nerd Font` programming ligatures |
| [`docs/assets/showcase/02-orb-bologna.png`](assets/showcase/02-orb-bologna.png) | `2` | `bologna-dome.webp` | Centered native `orb-desktop` (`GTK4` + `WebKitGTK 6.0`, `78%` Kawase-blurred sidebar, opaque `#141414` surface) connected to [`scripts/showcase/mock-orb-server.py`](../scripts/showcase/mock-orb-server.py) |
| [`docs/assets/showcase/03-touchid-canyon.png`](assets/showcase/03-touchid-canyon.png) | `3` | `kazakhstan-charyn-canyon-peaks.webp` | Centered biometric `Touch ID` HUD (`th0rgal.touchid`) held in active fingerprint-scan state via `omarchy-shell touchid hold` |

---

## 1. One-Command Deterministic Reproduction (`aarch64-linux` & `x86_64-linux`)

On any Linux host with Nix (`kvm` and `nixos-test` enabled in `system-features`), run [`scripts/showcase/reproduce.sh`](../scripts/showcase/reproduce.sh):

```bash
git clone https://github.com/Th0rgal/omarchnix.git
cd omarchnix

# Optional: point at an existing Th0rgal/wallpapers checkout (otherwise fetched automatically)
export WALLPAPERS_DIR="$HOME/Pictures/Wallpapers"

./scripts/showcase/reproduce.sh
```

Under the hood, [`scripts/showcase/capture.nix`](../scripts/showcase/capture.nix) runs a sandboxed `pkgs.testers.runNixOSTest` VM with offscreen software EGL/Virgl (`virtio-gpu-gl-pci` on `aarch64-linux`, `virtio-vga-gl` on `x86_64-linux`) so Hyprland's 3-pass Kawase blur (`passes = 3`, `size = 10`) renders identically on headless runners and local machines without touching your host session:

1. Boots `omarchnix` (`profile = "vm"`, `theme = "starship-subtle"`, `dock = false`, `persistentWorkspaces = 3`, `touchIdHud = true`) at `2560x1600@60` (`scale = 1.6`, `cursor.invisible = true`).
2. Starts [`scripts/showcase/mock-orb-server.py`](../scripts/showcase/mock-orb-server.py) on `127.0.0.1:1430` to serve the packaged `orb-ui` bundle and deterministic `/api/*` fixture (`Polish the Linux desktop experience`).
3. Populates Spaces `1`, `2`, and `3`, centers each window into showcase geometry (`Option + C` → logical `[128, 99]`, `1344×828`), verifies pixel-level `.titlebar` uniformity (`#141414`) on `02-orb-bologna.png`, and writes all three PNGs plus `SHA256SUMS` to `docs/assets/showcase/`.

---

## 2. Declarative Module Options Used

To adopt the same dockless 3-Space layout in your own NixOS + Home Manager configuration (using [`themes/starship-subtle`](../themes/starship-subtle/default.nix)):

```nix
{ lib, pkgs, wallpapersSrc, ... }:
let
  starshipSubtle = import ./themes/starship-subtle { inherit pkgs lib; };
in
{
  omarchnix.desktop = {
    enable = true;
    user = "thomas";
    theme = starshipSubtle.dark.name;
    shellBackend = "omarchy-shell";
    macos = {
      enable = true;
      dock = false;
      persistentWorkspaces = 3;
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
  };

  home-manager.users.thomas = {
    programs.omarchnix.theme = {
      name = starshipSubtle.dark.name;
      darkName = starshipSubtle.dark.name;
      lightName = starshipSubtle.light.name;
      attrset = starshipSubtle.dark.attrset;
      customThemes = {
        ${starshipSubtle.dark.name} = starshipSubtle.dark.package;
        ${starshipSubtle.light.name} = starshipSubtle.light.package;
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
        ecosystem = {
          no_donation_nag = true;
          no_update_news = true;
        };
      };
    };
  };
}
```

---

## 3. Manual / Interactive Capture Commands

Inside a live `omarchnix` Wayland session (physical hardware or interactive QEMU guest):

- **Space 1 — Frosted Ghostty (`01-terminal-singapore.png`):**
  ```bash
  hyprctl dispatch "hl.dsp.focus({ workspace = 1 })"
  ghostty --font-size=14 &
  # Press Option + C (or `wtype -M alt -k c -m alt`), run `fastfetch`, then:
  grim /tmp/01-terminal-singapore.png
  ```

- **Space 2 — Native `orb-desktop` (`02-orb-bologna.png`):**
  ```bash
  python3 scripts/showcase/mock-orb-server.py --port 1430 &
  hyprctl dispatch "hl.dsp.focus({ workspace = 2 })"
  ORB_DEV_URL=http://127.0.0.1:1430 orb &
  # Press Option + C to center into [128, 99] 1344x828 showcase geometry, then:
  grim /tmp/02-orb-bologna.png
  ```
  *(Under software Virgl in headless QEMU, add `GSK_RENDERER=cairo WEBKIT_DISABLE_DMABUF_RENDERER=1` when launching `orb`.)*

- **Space 3 — Biometric Touch ID HUD (`03-touchid-canyon.png`):**
  ```bash
  hyprctl dispatch "hl.dsp.focus({ workspace = 3 })"
  omarchy-shell touchid hold \
    '{"app":"Orb","subtitle":"Approve desktop session","state":"scanning","progress":0.92}'
  grim /tmp/03-touchid-canyon.png
  omarchy-shell touchid cancel
  ```
