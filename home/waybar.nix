{
  config,
  lib,
  pkgs,
  theme,
  ...
}:
let
  cfg = config.programs.omarchnix;
  wpctl = "${pkgs.wireplumber}/bin/wpctl";
in
{
  programs.waybar = {
    enable = lib.mkDefault (cfg.shell.backend == "waybar");
    systemd.enable = lib.mkDefault (cfg.shell.backend == "waybar");

    settings = {
      mainBar = {
        layer = "top";
        position = "top";
        height = theme.ui.barHeight;
        spacing = 6;
        margin-top = 6;
        margin-left = 10;
        margin-right = 10;

        modules-left = [
          "hyprland/workspaces"
          "hyprland/submap"
        ];
        modules-center = [
          "clock"
        ];
        modules-right = [
          "wireplumber"
          "backlight"
          "network"
          "battery"
          "tray"
        ];

        "hyprland/workspaces" = {
          format = "{name}";
          all-outputs = true;
          show-special = false;
          on-scroll-up = "hyprctl dispatch workspace e+1";
          on-scroll-down = "hyprctl dispatch workspace e-1";
        };

        "hyprland/submap" = {
          format = "{}";
          tooltip = false;
        };

        clock = {
          format = "{:%a %d %b  %H:%M}";
          tooltip-format = "<tt>{calendar}</tt>";
        };

        wireplumber = {
          format = "VOL {volume}%";
          format-muted = "MUTED";
          on-click = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle";
        };

        backlight = {
          format = "BRI {percent}%";
        };

        network = {
          format-wifi = "WIFI {essid}";
          format-ethernet = "ETH {ipaddr}";
          format-disconnected = "OFFLINE";
          tooltip-format = "{ifname} via {gwaddr}";
        };

        battery = {
          states = {
            warning = 25;
            critical = 12;
          };
          format = "BAT {capacity}%";
          format-charging = "CHG {capacity}%";
          format-plugged = "AC {capacity}%";
        };

        tray = {
          spacing = 8;
        };
      };
    };

    style = ''
      * {
        border: none;
        border-radius: 0;
        font-family: "${theme.fonts.sans.name}", "${theme.fonts.mono.name}", "${theme.fonts.icon.name}";
        font-size: ${toString theme.fonts.sans.size}pt;
        min-height: 0;
      }

      window#waybar {
        background: rgba(${theme.colors.bgRgb}, 0.88);
        color: #${theme.colors.fg};
        border: ${toString theme.ui.borderSize}px solid #${theme.colors.border};
        border-radius: ${toString theme.ui.rounding}px;
      }

      #workspaces {
        margin: 3px 4px;
      }

      #workspaces button {
        padding: 2px 9px;
        margin: 0 2px;
        border-radius: ${toString (theme.ui.rounding - 3)}px;
        background: transparent;
        color: #${theme.colors.fgMuted};
      }

      #workspaces button.active {
        background: #${theme.colors.accent};
        color: #${theme.colors.bg};
        font-weight: 600;
      }

      #workspaces button.urgent {
        background: #${theme.colors.urgent};
        color: #${theme.colors.bg};
      }

      #submap,
      #clock,
      #wireplumber,
      #backlight,
      #network,
      #battery,
      #tray {
        padding: 2px 10px;
        margin: 3px 2px;
        border-radius: ${toString (theme.ui.rounding - 3)}px;
        background: #${theme.colors.surface};
        color: #${theme.colors.fg};
      }

      #clock {
        font-family: "${theme.fonts.mono.name}";
        font-weight: 600;
      }

      #submap {
        background: #${theme.colors.warning};
        color: #${theme.colors.bg};
        font-weight: 600;
      }

      #battery.warning {
        color: #${theme.colors.warning};
      }

      #battery.critical:not(.charging) {
        background: #${theme.colors.urgent};
        color: #${theme.colors.bg};
      }
    '';
  };
}
