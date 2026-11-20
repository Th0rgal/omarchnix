"""Copy a region from compositor pixels captured before the interactive picker."""
from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile


def output_bounds(outputs):
    bounds = []
    for output in outputs:
        if output.get("disabled") or output.get("mirrorOf") not in (None, "", "none"):
            continue
        width, height = output["width"], output["height"]
        if output["transform"] % 2:
            width, height = height, width
        scale = output["scale"]
        x, y = output["x"], output["y"]
        bounds.append((x, y, x + round(width / scale), y + round(height / scale), scale))
    return bounds


def main():
    outputs = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"]))
    bounds = output_bounds(outputs)
    left, top = min(b[0] for b in bounds), min(b[1] for b in bounds)
    right, bottom = max(b[2] for b in bounds), max(b[3] for b in bounds)
    geometry = f"{left},{top} {right-left}x{bottom-top}"
    with tempfile.TemporaryDirectory(dir=os.environ.get("XDG_RUNTIME_DIR")) as tmp:
        # grim chooses the highest scale of the outputs touched by the selection.
        # Freeze the available resolutions before slurp takes the pointer grab.
        def capture(scale):
            frame = Path(tmp) / f"frame-{scale}.ppm"
            subprocess.run(["grim", "-s", str(scale), "-g", geometry, "-t", "ppm", frame], check=True)
            return scale, frame

        scales = {b[4] for b in bounds}
        with ThreadPoolExecutor(max_workers=len(scales)) as pool:
            frames = dict(pool.map(capture, scales))
        pick = subprocess.run(["omarchy-capture-region", "region"], capture_output=True, text=True)
        if pick.returncode:
            return
        selected = re.fullmatch(r"(-?\d+),(-?\d+) (\d+)x(\d+)", pick.stdout.strip())
        if selected is None:
            raise ValueError("invalid selection geometry")
        x, y, width, height = map(int, selected.groups())
        if not (width and height and left <= x < x + width <= right and top <= y < y + height <= bottom):
            raise ValueError("selection outside captured desktop")
        def pixel(value):
            return math.floor(value * scale + 0.5)
        scale = max(s for l, t, r, b, s in bounds
                    if x < r and l < x + width and y < b and t < y + height)
        frame = frames[scale]
        cx, cy = pixel(x-left), pixel(y-top)
        # grim truncates scaled region dimensions, including at fractional scale.
        cw, ch = max(1, int(width * scale)), max(1, int(height * scale))
        image = Path(tmp) / "selection.png"
        subprocess.run(["magick", frame, "-crop", f"{cw}x{ch}+{cx}+{cy}", "+repage", image], check=True)
        with image.open("rb") as stream:
            subprocess.run(["wl-copy", "--type", "image/png"], stdin=stream, check=True)


if __name__ == "__main__":
    main()
