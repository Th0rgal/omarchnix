{ pkgs }:
{
  mode = "dark";

  fonts = {
    sans = {
      name = "IBM Plex Sans";
      package = pkgs.ibm-plex;
      size = 9;
    };
    serif = {
      name = "Michelangelus";
      package = pkgs.michelangelus-font or (pkgs.callPackage ../pkgs/michelangelus-font.nix { });
      size = 10;
    };
    mono = {
      name = "Lilex Nerd Font";
      package = pkgs.nerd-fonts.lilex;
      size = 11;
    };
    icon = {
      name = "Font Awesome 7 Free";
      package = pkgs.font-awesome;
    };
  };

  cursor = {
    name = "Bibata-Modern-Classic";
    package = pkgs.bibata-cursors;
    size = 24;
  };

  ui = {
    gapsIn = 5;
    gapsOut = 10;
    borderSize = 2;
    rounding = 10;
    barHeight = 32;
  };

  colors = {
    bg = "111318";
    bgRgb = "17, 19, 24";
    bgAlt = "191c24";
    surface = "222631";
    border = "343b4c";
    fg = "e6eaf2";
    fgMuted = "939ab0";
    accent = "7aa2f7";
    accentAlt = "7dcfff";
    urgent = "f7768e";
    warning = "e0af68";
    success = "9ece6a";
    magenta = "bb9af7";
  };
}
