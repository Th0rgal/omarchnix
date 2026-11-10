#!/usr/bin/env bash
# Build a NixOS closure locally and activate it on a remote host that does not
# trust this machine's signing key for the substituter.
#
# On such a host `nix copy --to ssh-ng://...` fails with
#   "cannot add path ... lacks a signature by a trusted key"
# because `nix.settings.trusted-users = [ "root" ]`. This script imports only
# the missing store paths over `sudo nix-store --import`, which needs no
# signing key, and then switches the system profile in place.
#
# Usage:
#   scripts/remote-switch.sh <nixosConfiguration-attr> <ssh-target> [flake-dir]
#
# Example:
#   scripts/remote-switch.sh m2air thomas@192.168.1.165
#
# The remote user needs passwordless sudo for nix-store/nix-env (or you will
# be asked for the password on the remote terminal).
set -euo pipefail

attr="${1:?usage: remote-switch.sh <nixosConfiguration-attr> <ssh-target> [flake-dir]}"
target="${2:?usage: remote-switch.sh <nixosConfiguration-attr> <ssh-target> [flake-dir]}"
flake_dir="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

say() { printf '\n==> %s\n' "$*"; }

say "Building nixosConfigurations.$attr"
out="$(nix build "$flake_dir#nixosConfigurations.$attr.config.system.build.toplevel" \
  --no-link --print-out-paths)"
printf 'closure: %s\n' "$out"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "Resolving $out to its transitive store paths"
nix-store -qR "$out" >"$tmp/required.txt"

say "Checking which paths are already valid on $target"
# `nix-store --check-validity` takes paths as arguments, so feed them via xargs.
ssh "$target" "xargs -a /dev/stdin nix-store --check-validity --print-invalid" \
  <"$tmp/required.txt" >"$tmp/missing.txt" || true

missing_count="$(wc -l <"$tmp/missing.txt")"
printf 'missing paths: %s\n' "$missing_count"

if [ "$missing_count" -eq 0 ]; then
  say "Store already complete; skipping transfer"
else
  say "Exporting missing paths"
  # A single export stream keeps hardlinks and is far faster than scp per path.
  nix-store --export $(tr '\n' ' ' <"$tmp/missing.txt") >"$tmp/closure.nar"
  printf 'archive: %s\n' "$(du -h "$tmp/closure.nar" | cut -f1)"

  say "Copying archive to $target"
  scp -q "$tmp/closure.nar" "$target:/tmp/omarchnix-closure.nar"

  say "Importing archive on $target (sudo)"
  ssh -t "$target" "sudo nix-store --import < /tmp/omarchnix-closure.nar && rm -f /tmp/omarchnix-closure.nar"
fi

say "Activating $out on $target"
ssh -t "$target" "sudo nix-env -p /nix/var/nix/profiles/system --set '$out' && sudo '$out/bin/switch-to-configuration' switch"

say "Done: $attr is active on $target"
