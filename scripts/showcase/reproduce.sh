#!/usr/bin/env bash
# Deterministically build & boot the Omarchnix QEMU/KVM showcase guest and copy
# the 3 native 2560x1600 Wayland `grim` captures into docs/assets/showcase/ (or $1).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${1:-$REPO_ROOT/docs/assets/showcase}"
SYSTEM="${SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

WP_PATH=""
if [[ -n "${WALLPAPERS_DIR:-}" && -d "${WALLPAPERS_DIR}" ]]; then
  WP_PATH="${WALLPAPERS_DIR}"
elif [[ -d "${HOME:-}/Pictures/Wallpapers" && -f "${HOME:-}/Pictures/Wallpapers/singapore.webp" ]]; then
  WP_PATH="${HOME}/Pictures/Wallpapers"
fi

DRV_OUT="$(
  OMARCHNIX_REPO_ROOT="${REPO_ROOT}" \
  OMARCHNIX_SYSTEM="${SYSTEM}" \
  OMARCHNIX_WP_PATH="${WP_PATH}" \
  nix build --impure --no-link --print-out-paths -L --expr '
    let
      repoRoot = builtins.getEnv "OMARCHNIX_REPO_ROOT";
      system = builtins.getEnv "OMARCHNIX_SYSTEM";
      wpPath = builtins.getEnv "OMARCHNIX_WP_PATH";
      flake = builtins.getFlake ("path:" + repoRoot);
      inputs = flake.inputs;
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [
          inputs.orb.overlays.default
          flake.overlays.default
        ];
      };
      wallpapersSrc =
        if wpPath != "" then
          builtins.path {
            path = wpPath;
            name = "th0rgal-wallpapers";
            filter = p: _: baseNameOf p != ".git";
          }
        else
          builtins.fetchGit {
            url = "https://github.com/Th0rgal/wallpapers.git";
            ref = "main";
          };
    in
    import (repoRoot + "/scripts/showcase/capture.nix") {
      inherit pkgs inputs wallpapersSrc;
      omarchnixModule = flake.nixosModules.omarchnix;
    }
  '
)"

mkdir -p "$OUT_DIR"
for f in 01-terminal-singapore.png 02-orb-bologna.png 03-touchid-canyon.png SHA256SUMS; do
  install -m 0644 "$DRV_OUT/$f" "$OUT_DIR/$f"
done

python3 - "$OUT_DIR/02-orb-bologna.png" <<'PY'
import struct, sys, zlib

raw = open(sys.argv[1], "rb").read()
pos = 8
idat = bytearray()
while pos < len(raw):
    ln, ct = struct.unpack(">I4s", raw[pos : pos + 8])
    ch = raw[pos + 8 : pos + 8 + ln]
    pos += 12 + ln
    if ct == b"IHDR":
        w, h, bd, ctype, *_ = struct.unpack(">IIBBBBB", ch)
    elif ct == b"IDAT":
        idat.extend(ch)
    elif ct == b"IEND":
        break
assert (w, h) == (2560, 1600), f"unexpected {w}x{h}"
bpp = {2: 3, 6: 4}[ctype]
stride = 1 + w * bpp
buf = zlib.decompressobj().decompress(bytes(idat), max_length=220 * stride)
prev = bytearray(w * bpp)
rows = []
for y in range(220):
    ft = buf[y * stride]
    cur = bytearray(buf[y * stride + 1 : (y + 1) * stride])
    if ft == 1:
        for i in range(bpp, len(cur)):
            cur[i] = (cur[i] + cur[i - bpp]) & 255
    elif ft == 2:
        for i in range(len(cur)):
            cur[i] = (cur[i] + prev[i]) & 255
    elif ft == 3:
        for i in range(len(cur)):
            a = cur[i - bpp] if i >= bpp else 0
            cur[i] = (cur[i] + ((a + prev[i]) >> 1)) & 255
    elif ft == 4:
        for i in range(len(cur)):
            a = cur[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            cur[i] = (cur[i] + pr) & 255
    rows.append(bytes(cur))
    prev = cur

bad = [
    (x, y, (rows[y][x * bpp], rows[y][x * bpp + 1], rows[y][x * bpp + 2]))
    for y in range(166, 206)
    for x in range(1010, 2210)
    if (rows[y][x * bpp], rows[y][x * bpp + 1], rows[y][x * bpp + 2]) != (20, 20, 20)
]
if bad:
    xs = [p[0] for p in bad]
    ys = [p[1] for p in bad]
    raise AssertionError(
        f"titlebar glitch ({len(bad)} non-#141414 px in x={min(xs)}..{max(xs)}, y={min(ys)}..{max(ys)}): {bad[:8]}"
    )
print("Verified: 02-orb-bologna.png .titlebar is 100% uniform #141414 across x=1010..2210, y=166..206")
PY

echo "Showcase captures written to $OUT_DIR:"
ls -lh "$OUT_DIR"/*.png "$OUT_DIR/SHA256SUMS"
