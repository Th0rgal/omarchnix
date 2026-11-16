"""reMarkable cloud <-> ~/Cloud/reMarkable sync.

pull   Mirror the reMarkable cloud into a hidden raw tree of .rmdoc bundles
       (`rmapi mget -i -d`), then publish readable files into the visible
       folder: the PDF or EPUB inside each bundle, and a rendered PDF for
       handwritten notebooks (`rmapi geta`, best effort). Files that left the
       cloud are removed from the visible folder, but only files this tool
       published itself.
watch  Upload what you drop into the visible folder (PDF / EPUB) to the same
       folder on the reMarkable cloud as soon as it is fully written, and
       create cloud folders for new local folders. Local deletes and renames
       are never sent to the cloud.

A manifest records which visible files came from the cloud, so a published
file is never uploaded back and a dropped file is never deleted by a pull.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from contextlib import contextmanager
from pathlib import Path

UPLOADABLE = {".pdf", ".epub"}
RMAPI = os.environ.get("REMARKABLE_SYNC_RMAPI", "rmapi")
INOTIFYWAIT = os.environ.get("REMARKABLE_SYNC_INOTIFYWAIT", "inotifywait")


def log(msg: str) -> None:
    print(msg, flush=True)


class Sync:
    def __init__(self, visible: Path, state: Path) -> None:
        self.visible = visible
        self.state = state
        self.raw = state / "raw"
        self.tmp = state / "tmp"
        self.manifest_path = state / "manifest.json"
        self.lock_path = state / "lock"
        for d in (self.visible, self.raw, self.tmp):
            d.mkdir(parents=True, exist_ok=True)

    # ---- shared state -------------------------------------------------
    @contextmanager
    def locked(self):
        with open(self.lock_path, "w") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(fh, fcntl.LOCK_UN)

    def load_manifest(self) -> dict:
        try:
            data = json.loads(self.manifest_path.read_text())
        except (OSError, ValueError):
            data = {}
        data.setdefault("published", {})  # visible rel path -> {raw, mtime}
        data.setdefault("uploaded", {})  # visible rel path -> {size, mtime}
        return data

    def save_manifest(self, data: dict) -> None:
        tmp = self.manifest_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=1, sort_keys=True))
        os.replace(tmp, self.manifest_path)

    def rmapi(self, *args: str, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
        proc = subprocess.run(
            [RMAPI, "-ni", *args],
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if check and proc.returncode != 0:
            raise RuntimeError(f"rmapi {' '.join(args)} failed: {proc.stdout.strip()}")
        return proc

    # ---- pull ----------------------------------------------------------
    def publish_from_bundle(self, bundle: Path, rel_dir: Path, stem: str) -> Path | None:
        """Write the readable form of one .rmdoc into the visible tree."""
        with zipfile.ZipFile(bundle) as zf:
            names = zf.namelist()
            payload = next(
                (n for n in names if "/" not in n and Path(n).suffix.lower() in UPLOADABLE),
                None,
            )
            if payload:
                rel = rel_dir / (stem + Path(payload).suffix.lower())
                dst = self.visible / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                fd, tmp = tempfile.mkstemp(dir=self.tmp)
                with os.fdopen(fd, "wb") as out, zf.open(payload) as src:
                    shutil.copyfileobj(src, out)
                os.replace(tmp, dst)
                return rel

        # A handwritten notebook: render it to PDF with rmapi (best effort).
        rel = rel_dir / (stem + ".pdf")
        remote = "/" + str(rel_dir / stem) if str(rel_dir) != "." else "/" + stem
        work = Path(tempfile.mkdtemp(dir=self.tmp))
        try:
            proc = self.rmapi("geta", remote, cwd=work, check=False)
            rendered = next(work.glob("*-annotations.pdf"), None)
            if proc.returncode != 0 or rendered is None:
                log(f"notebook not rendered: {remote}: {proc.stdout.strip()}")
                return None
            dst = self.visible / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            os.replace(rendered, dst)
            return rel
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def pull(self) -> None:
        # Download outside the lock: it is the slow part, and the watcher
        # only needs the lock to read the manifest.
        self.rmapi("mget", "-o", str(self.raw), "-i", "-d", "/")
        with self.locked():
            data = self.load_manifest()
            published = data["published"]
            seen: set[str] = set()
            for bundle in sorted(self.raw.rglob("*.rmdoc")):
                raw_rel = bundle.relative_to(self.raw)
                mtime = bundle.stat().st_mtime
                prev = next(
                    (k for k, v in published.items() if v["raw"] == str(raw_rel)),
                    None,
                )
                if prev and published[prev]["mtime"] == mtime and (self.visible / prev).exists():
                    seen.add(prev)
                    continue
                try:
                    rel = self.publish_from_bundle(bundle, raw_rel.parent, bundle.stem)
                except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
                    log(f"skip {raw_rel}: {exc}")
                    if prev:
                        seen.add(prev)
                    continue
                if rel is None:
                    continue
                key = str(rel)
                published[key] = {"raw": str(raw_rel), "mtime": mtime}
                data["uploaded"].pop(key, None)
                seen.add(key)
                log(f"pulled {key}")

            # Gone from the cloud: remove what we published, never user files.
            for key in [k for k in published if k not in seen]:
                target = self.visible / key
                if target.exists():
                    target.unlink()
                    log(f"removed {key}")
                del published[key]
            self.prune_empty_dirs()
            self.save_manifest(data)

    def prune_empty_dirs(self) -> None:
        for d in sorted((p for p in self.visible.rglob("*") if p.is_dir()), reverse=True):
            raw_twin = self.raw / d.relative_to(self.visible)
            if not raw_twin.exists() and not any(d.iterdir()):
                d.rmdir()

    # ---- push ----------------------------------------------------------
    def remote_dir(self, rel_dir: Path) -> str:
        return "/" if str(rel_dir) in ("", ".") else "/" + str(rel_dir)

    def ensure_remote_dirs(self, rel_dir: Path) -> None:
        parts = [] if str(rel_dir) in ("", ".") else list(rel_dir.parts)
        for i in range(len(parts)):
            sub = Path(*parts[: i + 1])
            if (self.raw / sub).is_dir():
                continue
            # Already-existing folders make mkdir fail; that's fine.
            self.rmapi("mkdir", "/" + str(sub), check=False)
            (self.raw / sub).mkdir(parents=True, exist_ok=True)

    def should_upload(self, path: Path) -> bool:
        if path.suffix.lower() not in UPLOADABLE or not path.is_file():
            return False
        rel = path.relative_to(self.visible)
        if any(part.startswith(".") for part in rel.parts):
            return False
        data = self.load_manifest()
        key = str(rel)
        if key in data["published"]:
            return False
        st = path.stat()
        done = data["uploaded"].get(key)
        return not (done and done["size"] == st.st_size and done["mtime"] == st.st_mtime)

    def push(self, path: Path) -> None:
        with self.locked():
            if not self.should_upload(path):
                return
            rel = path.relative_to(self.visible)
            self.ensure_remote_dirs(rel.parent)
            proc = self.rmapi("put", str(path), self.remote_dir(rel.parent), check=False)
            if proc.returncode != 0:
                log(f"upload failed {rel}: {proc.stdout.strip()}")
                notify("reMarkable upload failed", f"{rel.name}: {proc.stdout.strip()[-200:]}")
                return
            data = self.load_manifest()
            st = path.stat()
            data["uploaded"][str(rel)] = {"size": st.st_size, "mtime": st.st_mtime}
            self.save_manifest(data)
            log(f"uploaded {rel}")
            notify("Sent to reMarkable", str(rel))

    def push_dir(self, path: Path) -> None:
        rel = path.relative_to(self.visible)
        if any(part.startswith(".") for part in rel.parts):
            return
        with self.locked():
            self.ensure_remote_dirs(rel)
        # Files moved in together with the folder raise no events of their own.
        for f in sorted(path.rglob("*")):
            if f.is_file():
                self.push(f)

    def watch(self) -> None:
        # Catch up on anything dropped while the watcher was not running.
        # Without a manifest there's no telling dropped files from pulled
        # ones, so wait for the first pull instead of re-uploading them all.
        if self.manifest_path.exists():
            for f in sorted(self.visible.rglob("*")):
                if f.is_file():
                    self.push(f)
        proc = subprocess.Popen(
            [
                INOTIFYWAIT, "-m", "-r", "-q",
                "-e", "close_write", "-e", "moved_to", "-e", "create",
                "--format", "%e\t%w%f",
                "--exclude", r"(^|/)\.",
                str(self.visible),
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            events, _, name = line.rstrip("\n").partition("\t")
            path = Path(name)
            try:
                if "ISDIR" in events:
                    if path.is_dir():
                        self.push_dir(path)
                elif "CLOSE_WRITE" in events or "MOVED_TO" in events:
                    self.push(path)
            except Exception as exc:  # keep watching whatever happens
                log(f"error on {path}: {exc}")
        sys.exit(proc.wait() or 1)


def notify(title: str, body: str) -> None:
    exe = shutil.which("notify-send")
    if exe:
        subprocess.run([exe, "-a", "reMarkable", "-i", "document-send", title, body], check=False)


def main() -> None:
    home = Path.home()
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["pull", "watch", "push"])
    parser.add_argument("paths", nargs="*", type=Path)
    parser.add_argument("--dir", type=Path, default=home / "Cloud" / "reMarkable")
    parser.add_argument(
        "--state",
        type=Path,
        default=Path(os.environ.get("XDG_STATE_HOME", home / ".local" / "state")) / "remarkable-sync",
    )
    args = parser.parse_args()
    sync = Sync(args.dir, args.state)
    if args.command == "pull":
        sync.pull()
    elif args.command == "watch":
        sync.watch()
    else:
        for p in args.paths:
            sync.push(p.resolve())


if __name__ == "__main__":
    main()
