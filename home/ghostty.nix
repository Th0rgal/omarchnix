{
  config,
  lib,
  pkgs,
  theme,
  ...
}:
let
  cfg = config.programs.omarchnix;
in
{
  config = lib.mkIf (cfg.enable && cfg.terminal == "ghostty") {
    home.packages = [
      pkgs.ghostty
      pkgs.xdg-terminal-exec
    ];

    xdg.configFile = {
      "xdg-terminals.list".text = ''
        com.mitchellh.ghostty.desktop
        foot.desktop
      '';

      "ghostty/config".text = ''
        # Dynamic Omarchy theme colors (live-reloaded via SIGUSR2 on dark/light toggle)
        config-file = ?"~/.local/state/omarchy/current/theme/ghostty.conf"

        # Typography & HarfBuzz programming ligatures (!=, ==, ===, ->, =>, <=, >=)
        font-family = "${theme.fonts.mono.name}"
        font-size = ${toString theme.fonts.mono.size}
        font-feature = calt
        font-feature = liga

        # Borderless frosted-glass chrome matching the status bar & bottom dock (0.35 alpha + Wayland ext-background-effect-v1 blur)
        window-decoration = none
        gtk-titlebar = false
        window-theme = ghostty
        background-opacity = 0.35
        background-blur = true
        window-padding-x = 12
        window-padding-y = 12
        window-padding-balance = true
        confirm-close-surface = false
        resize-overlay = never
        mouse-hide-while-typing = true

        # Cursor & zsh + SSH terminfo integration
        cursor-style = block
        cursor-style-blink = false
        shell-integration = zsh
        shell-integration-features = no-cursor,ssh-env

        # Clipboard, tabs, and TUI keybindings
        keybind = ctrl+shift+c=copy_to_clipboard
        keybind = ctrl+shift+v=paste_from_clipboard
        keybind = super+ctrl+shift+c=copy_to_clipboard
        keybind = super+ctrl+shift+v=paste_from_clipboard
        keybind = super+c=copy_to_clipboard
        keybind = super+v=paste_from_clipboard
        keybind = super+t=new_tab
        keybind = super+w=close_surface
        keybind = ctrl+shift+w=close_surface
        keybind = shift+insert=paste_from_clipboard
        keybind = control+insert=copy_to_clipboard
        keybind = shift+enter=csi:13;2u
        keybind = alt+shift+enter=csi:13;4u

        # Smooth trackpad scrolling & Hyprland epoll backend
        mouse-scroll-multiplier = 0.95
        async-backend = epoll
      '';
    };
  };
}
