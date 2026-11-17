# orb-grant: short-lived (<=24 h) SSH certificates for agent sessions, signed with one YubiKey touch.
{ lib, writeShellApplication, openssh, coreutils, gnused, gnugrep, hostname }:
writeShellApplication {
  name = "orb-grant";
  runtimeInputs = [ openssh coreutils gnused gnugrep hostname ];
  text = builtins.readFile ./orb-grant.sh;
  # The script keeps its own `set -euo pipefail`; shellcheck runs at build time.
  meta = {
    description = "Mint, list and revoke short-lived SSH certificates for agent sessions";
    license = lib.licenses.mit;
    mainProgram = "orb-grant";
  };
}
