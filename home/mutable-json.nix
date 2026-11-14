# Declarative keys inside JSON files that applications also write to themselves
# (editor settings, CLI configs). Home Manager would make such files read-only store
# symlinks; this keeps them regular, writable files and only reconciles chosen keys:
#
#   programs.omarchnix.mutableJson.".config/rbw/config.json" = {
#     force.pinentry = "/nix/store/...-pinentry";       # always set
#   };
#   programs.omarchnix.mutableJson.".config/Code/User/settings.json" = {
#     defaults."editor.fontLigatures" = true;          # set only when absent
#     onlyIfExists = ".config/Code";                   # skip until the app ran once
#   };
#
# Merging is shallow: `defaults // existing // force`. Writes are atomic; a file that
# is a symlink or not a JSON object is replaced by `{}` first. Invalid JSON is left
# untouched and reported, never clobbered.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.omarchnix.mutableJson;

  entry =
    path: e:
    let
      file = "$HOME/${path}";
    in
    ''
      ${lib.optionalString (e.onlyIfExists != null) ''
        if [ -e "$HOME/${e.onlyIfExists}" ]; then
      ''}
      f=${lib.escapeShellArg path}
      f="$HOME/$f"
      mkdir -p "$(dirname "$f")"
      if [ -L "$f" ] || [ ! -s "$f" ]; then
        rm -f "$f"
        printf '{}\n' > "$f"
      fi
      tmp="$(mktemp "$f.XXXXXX")"
      if ${lib.getExe pkgs.jq} \
        --argjson defaults ${lib.escapeShellArg (builtins.toJSON e.defaults)} \
        --argjson force ${lib.escapeShellArg (builtins.toJSON e.force)} \
        'if type == "object" then $defaults + . + $force else error("not a JSON object") end' \
        "$f" > "$tmp" 2>/dev/null; then
        chmod ${e.mode} "$tmp"
        mv "$tmp" "$f"
      else
        rm -f "$tmp"
        echo "mutableJson: left ${file} unchanged (not a JSON object)" >&2
      fi
      ${lib.optionalString (e.onlyIfExists != null) "fi"}
    '';
in
{
  options.programs.omarchnix.mutableJson = lib.mkOption {
    default = { };
    description = "Writable JSON files under $HOME whose selected top-level keys are reconciled on activation.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          defaults = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            description = "Keys written only when the file does not already define them.";
          };
          force = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            description = "Keys overwritten on every activation.";
          };
          mode = lib.mkOption {
            type = lib.types.str;
            default = "0644";
            description = "File mode after writing.";
          };
          onlyIfExists = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Path relative to $HOME that must exist, typically the app's config directory.";
          };
        };
      }
    );
  };

  config = lib.mkIf (cfg != { }) {
    home.activation.omarchnixMutableJson = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatStrings (lib.mapAttrsToList entry cfg)
    );
  };
}
