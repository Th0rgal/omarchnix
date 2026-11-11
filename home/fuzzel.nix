{
  config,
  pkgs,
  theme,
  ...
}:
let
  cfg = config.programs.omarchnix;
in
{
  programs.fuzzel = {
    enable = true;
    settings = {
      main = {
        font = "${theme.fonts.sans.name}:size=${toString (theme.fonts.sans.size + 1)}";
        dpi-aware = "no";
        prompt = "> ";
        terminal =
          if (cfg.terminal or "foot") == "ghostty" then
            "${pkgs.ghostty}/bin/ghostty -e"
          else
            "${pkgs.foot}/bin/foot -e";
        layer = "overlay";
        width = 42;
        lines = 12;
        horizontal-pad = 20;
        vertical-pad = 12;
        inner-pad = 8;
        icons-enabled = "yes";
      };

      colors = {
        background = "${theme.colors.bg}cc";
        text = "${theme.colors.fg}ff";
        prompt = "${theme.colors.accent}ff";
        placeholder = "${theme.colors.fgMuted}ff";
        input = "${theme.colors.fg}ff";
        match = "${theme.colors.accentAlt}ff";
        selection = "${theme.colors.surface}ff";
        selection-text = "${theme.colors.fg}ff";
        selection-match = "${theme.colors.accent}ff";
        counter = "${theme.colors.fgMuted}ff";
        border = "${theme.colors.accent}ff";
      };

      border = {
        width = theme.ui.borderSize;
        radius = theme.ui.rounding;
      };
    };
  };
}
