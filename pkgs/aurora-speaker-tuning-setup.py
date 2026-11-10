#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Extract and verify this Mac's own speaker tuning bundle on Linux.

When a Mac running Linux on Aurora kernel + speakerguardd-v2 was installed
without aurora-installer's ESP audio-tuning bundle (for example, an existing
Asahi Linux + NixOS installation migrated in place), `/lib/firmware/vendor/apple/audio-tuning`
and `/boot/vendorfw/firmware.tar` carry no `apple/audio-tuning/` directory.

This tool populates `/var/lib/speakerguardd/audio-tuning` strictly read-only
from this Mac's own hardware and local unencrypted macOS System volume:
  1. If `/var/lib/speakerguardd/audio-tuning` already passes
     `aurora-speaker-tuning identify` and `dump` for this board and unit,
     exit 0 immediately (`--check-needed` / idempotent boot fast-path).
  2. If `aurora-speaker-tuning` already finds a valid Installer bundle in the
     ESP vendor firmware (`vendorfw/firmware.tar`), import it atomically.
  3. Otherwise, read `acoustic-id`, `speaker-thiele-small` (`SpTS`),
     `target-type` (`board`), and `serial-number` (`unit_id`) from this Mac's
     live Apple DeviceTree (`/dev/mtd/by-name/adt`) and Linux `/proc/device-tree`,
     read `AID<n>/`, `DeviceDSPDatabase.plist`, `Config/AID<n>.plist`,
     referenced `Common/` files, `DRC/loudness-manager.plist`, `macos_build`,
     and `lsm2-mask-lattice.bin` (`AudioDSP.component`) strictly read-only
     from the local macOS System APFS volume (via `apfs-fuse -l` or the built-in
     read-only APFS Sealed-System-Volume B-tree reader + `liblzfse` / `zlib`),
     verify with `aurora-speaker-tuning`, and install atomically.
"""

import argparse
import ctypes
import glob
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import zlib

DEFAULT_OUTPUT = "/var/lib/speakerguardd/audio-tuning"
DT_ROOT = "/proc/device-tree"
ADT_PATHS = ("/dev/mtd/by-name/adt", "/dev/mtd1ro", "/dev/mtd1")
CONTAINER_LABEL = "/dev/disk/by-partlabel/Container"

SCHEMA = 2
BASED_ON = "aurora-audio-dsp by saku (MIT)"
MANIFEST = "manifest.json"
SPTS = "speaker-thiele-small.bin"
DATABASE = "DeviceDSPDatabase.plist"
AID_DATABASE = "DSP/DSPDatabase.plist"
LATTICE = "lsm2-mask-lattice.bin"
LOUDNESS = "DRC/loudness-manager.plist"
SHARED_ROOTS = ("Common",)
SPEAKER_DEVICE = "Built-in Speaker"

TUNINGS_REL = "System/Library/Audio/Tunings"
AUDIODSP_REL = "System/Library/Components/AudioDSP.component/Contents/MacOS/AudioDSP"
SYSVERSION_CANDIDATES = (
    "System/Library/CoreServices/SystemVersion.plist",
    "System/Library/CoreServices/ServerVersion.plist",
)

MAX_FILES = 1024
MAX_BYTES = 64 << 20
MAX_DATABASE_BYTES = 64 << 20
MAX_CONFIG_BYTES = 1 << 20
MAX_SPTS_BYTES = 4096
MAX_COMPONENT_BYTES = 256 << 20

UNIT_ID_DOMAIN = b"aurora-speaker-unit-v1\0"
UNIT_ID_RE = re.compile(r"\A[0-9a-f]{64}\Z")
BOARD_RE = re.compile(r"\A[a-z0-9]{1,8}\Z")

LATTICE_ENTRIES = 100
LATTICE_SINGLETONS = 64
LATTICE_POINTS = 640
LATTICE_FINAL_END = LATTICE_POINTS // 2 + 1
LATTICE_SIZE = LATTICE_ENTRIES * 8
LATTICE_VERSION = 1
LATTICE_FORMAT = "u64le-exclusive-ends"

FAT_MAGIC = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}
MACHO64_MAGIC = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}
LC_SEGMENT_64 = 0x19
SECTION_TYPE = 0xFF
ZEROFILL_TYPES = (0x1, 0xC, 0x12)


def log(msg):
    print(f"aurora-speaker-tuning-setup: {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Machine identity & Apple DeviceTree (ADT) reader
# ---------------------------------------------------------------------------


def compute_unit_id(raw):
    if not isinstance(raw, bytes):
        return None
    serial = raw.rstrip(b"\0")
    if not 0 < len(serial) <= 64 or not all(0x21 <= b <= 0x7E for b in serial):
        return None
    return hashlib.sha256(UNIT_ID_DOMAIN + serial).hexdigest()


def normalize_board(raw):
    if isinstance(raw, bytes):
        raw = raw.rstrip(b"\0").decode("ascii", "replace")
    if not isinstance(raw, str):
        return None
    if raw.upper().endswith("AP"):
        raw = raw[:-2]
    board = raw.lower()
    return board if BOARD_RE.match(board) else None


def read_linux_dt_identity(dt_root=DT_ROOT):
    board = None
    try:
        with open(os.path.join(dt_root, "compatible"), "rb") as f:
            first = f.read().split(b"\0", 1)[0].decode("ascii", "replace")
        if first.startswith("apple,") and len(first) > 6:
            cand = first[len("apple,") :]
            if BOARD_RE.match(cand):
                board = cand
    except OSError:
        pass

    unit = None
    try:
        with open(os.path.join(dt_root, "serial-number"), "rb") as f:
            unit = compute_unit_id(f.read(128))
    except OSError:
        pass

    speaker_id = None
    try:
        with open(os.path.join(dt_root, "chosen", "asahi,speaker-id"), "rb") as f:
            raw = f.read(8)
        if len(raw) == 4:
            speaker_id = int.from_bytes(raw, "big")
    except OSError:
        pass

    return board, unit, speaker_id


def parse_adt_node(buf, pos=0, depth=0):
    if depth > 32 or pos + 8 > len(buf):
        raise ValueError("ADT truncated or nested too deeply")
    prop_count, child_count = struct.unpack_from("<II", buf, pos)
    pos += 8
    if prop_count > 4096 or child_count > 4096:
        raise ValueError(f"implausible ADT node counts ({prop_count}, {child_count})")
    props = {}
    for _ in range(prop_count):
        if pos + 36 > len(buf):
            raise ValueError("ADT property header truncated")
        raw_name = buf[pos : pos + 32]
        size_word = struct.unpack_from("<I", buf, pos + 32)[0]
        size = size_word & 0x7FFFFFFF
        pos += 36
        if pos + size > len(buf):
            raise ValueError("ADT property value truncated")
        name = raw_name.split(b"\0", 1)[0].decode("ascii", "replace")
        props[name] = bytes(buf[pos : pos + size])
        pos += (size + 3) & ~3
    children = []
    for _ in range(child_count):
        child, pos = parse_adt_node(buf, pos, depth + 1)
        children.append(child)
    return (props, children), pos


def iter_adt_nodes(node):
    props, children = node
    yield props
    for ch in children:
        yield from iter_adt_nodes(ch)


def probe_adt(adt_paths=ADT_PATHS):
    raw = None
    used_path = None
    for p in adt_paths:
        if os.path.exists(p):
            with open(p, "rb") as f:
                raw = f.read(8 << 20)
            used_path = p
            break
    if not raw:
        raise RuntimeError("cannot find live Apple DeviceTree (/dev/mtd/by-name/adt)")

    root, _ = parse_adt_node(raw, 0)
    root_props = root[0]
    adt_board = normalize_board(root_props.get("target-type"))
    adt_unit = compute_unit_id(root_props.get("serial-number"))

    audio_matches = []
    for props in iter_adt_nodes(root):
        node_name = props.get("name", b"").rstrip(b"\0").decode("ascii", "replace")
        if node_name == "audio" and "acoustic-id" in props:
            aid_bytes = props["acoustic-id"]
            if len(aid_bytes) == 4:
                val = int.from_bytes(aid_bytes, "little")
                if 0 < val < 100000:
                    spts = props.get("speaker-thiele-small")
                    if not spts:
                        spts = None
                    audio_matches.append((val, spts))

    if len(audio_matches) != 1:
        raise RuntimeError(
            f"expected 1 audio node with acoustic-id in {used_path}, found {len(audio_matches)}"
        )

    acoustic, spts = audio_matches[0]
    return acoustic, spts, adt_board, adt_unit


# ---------------------------------------------------------------------------
# lsm2 masker bucket lattice extraction (from AudioDSP Mach-O __TEXT,__const)
# ---------------------------------------------------------------------------


def lattice_valid(blob):
    if not isinstance(blob, (bytes, bytearray)) or len(blob) != LATTICE_SIZE:
        return False
    ends = struct.unpack(f"<{LATTICE_ENTRIES}Q", blob)
    return (
        ends[:LATTICE_SINGLETONS] == tuple(range(1, LATTICE_SINGLETONS + 1))
        and all(a < b for a, b in zip(ends, ends[1:]))
        and all(1 <= e <= LATTICE_FINAL_END for e in ends)
        and ends[-1] == LATTICE_FINAL_END
    )


def _within(total, offset, size, what):
    if offset < 0 or size < 0 or offset > total or size > total - offset:
        raise ValueError(f"{what} lies outside Mach-O file")


def _macho_slices(data):
    if len(data) < 8:
        raise ValueError("AudioDSP component too short")
    fat = FAT_MAGIC.get(bytes(data[:4]))
    if fat is None:
        return [("thin", 0, len(data))]
    endian, wide = fat
    count = struct.unpack_from(endian + "I", data, 4)[0]
    if not 0 < count <= 64:
        raise ValueError(f"implausible fat slice count {count}")
    entry = endian + ("iiQQII" if wide else "iiIII")
    step = struct.calcsize(entry)
    _within(len(data), 8, count * step, "fat slice table")
    out = []
    for i in range(count):
        cputype, subtype, offset, size = struct.unpack_from(entry, data, 8 + i * step)[:4]
        _within(len(data), offset, size, f"slice {i}")
        for _, o, s in out:
            if offset < o + s and o < offset + size:
                raise ValueError("overlapping Mach-O slices")
        out.append((f"cpu {cputype & 0xFFFFFFFF:#x}/{subtype & 0xFFFFFF}", offset, size))
    return out


def _const_section(view):
    endian = MACHO64_MAGIC.get(bytes(view[:4]))
    if endian is None:
        raise ValueError("slice is not a 64-bit Mach-O image")
    _within(len(view), 0, 32, "Mach-O header")
    ncmds, sizeofcmds = struct.unpack_from(endian + "II", view, 16)
    if ncmds > 65536:
        raise ValueError(f"implausible load command count {ncmds}")
    _within(len(view), 32, sizeofcmds, "load commands")
    pos, end = 32, 32 + sizeofcmds
    found = []
    for _ in range(ncmds):
        _within(end, pos, 8, "load command")
        cmd, cmdsize = struct.unpack_from(endian + "II", view, pos)
        if cmdsize < 8 or cmdsize > end - pos:
            raise ValueError("invalid load command size")
        if cmd == LC_SEGMENT_64:
            if cmdsize < 72:
                raise ValueError("short LC_SEGMENT_64")
            nsects = struct.unpack_from(endian + "I", view, pos + 64)[0]
            if 72 + nsects * 80 > cmdsize:
                raise ValueError("sections overrun LC_SEGMENT_64")
            for k in range(nsects):
                base = pos + 72 + k * 80
                sect, seg = struct.unpack_from(endian + "16s16s", view, base)
                if (sect.split(b"\0", 1)[0], seg.split(b"\0", 1)[0]) != (b"__const", b"__TEXT"):
                    continue
                addr, size, offset = struct.unpack_from(endian + "QQI", view, base + 32)
                flags = struct.unpack_from(endian + "I", view, base + 64)[0]
                if (flags & SECTION_TYPE) in ZEROFILL_TYPES:
                    raise ValueError("__TEXT,__const has no file contents")
                _within(len(view), offset, size, "__TEXT,__const")
                found.append((offset, size, addr))
        pos += cmdsize
    if pos != end:
        raise ValueError("load commands do not fill sizeofcmds")
    if len(found) != 1:
        raise ValueError(f"expected 1 __TEXT,__const section, found {len(found)}")
    return found[0]


def extract_lattice(data):
    data = bytes(data)
    prefix = struct.pack(f"<{LATTICE_SINGLETONS}Q", *range(1, LATTICE_SINGLETONS + 1))
    tables = []
    for name, offset, size in _macho_slices(data):
        view = bytes(data[offset : offset + size])
        sec_off, sec_size, sec_addr = _const_section(view)
        stop = sec_off + sec_size
        cands = []
        at = view.find(prefix, sec_off, stop)
        while at >= 0:
            if (
                (sec_addr + at - sec_off) % 8 == 0
                and at + LATTICE_SIZE <= stop
                and lattice_valid(view[at : at + LATTICE_SIZE])
            ):
                cands.append(at)
            at = view.find(prefix, at + 1, stop)
        if len(cands) != 1:
            raise ValueError(
                f"slice {name}: expected 1 lsm2 masker lattice in __TEXT,__const, found {len(cands)}"
            )
        tables.append(view[cands[0] : cands[0] + LATTICE_SIZE])
    if any(t != tables[0] for t in tables[1:]):
        raise ValueError("Mach-O slices hold different lsm2 masker lattices")
    return tables[0]


# ---------------------------------------------------------------------------
# Virtual VFS interface & schema-2 bundle builder
# ---------------------------------------------------------------------------


def admitted(relative):
    parts = relative.split("/")
    if not relative or relative.startswith("/") or "\\" in relative or "\0" in relative:
        return False
    if any(p in ("", ".", "..") for p in parts):
        return False
    return not any(p.startswith("._") or p == ".DS_Store" for p in parts)


def _iter_plist_paths(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "Path" and isinstance(v, str):
                yield v
            else:
                yield from _iter_plist_paths(v)
    elif isinstance(node, list):
        for v in node:
            yield from _iter_plist_paths(v)


def speaker_references(entry_bytes, acoustic):
    root = plistlib.loads(entry_bytes)
    aid = f"AID{acoustic}"
    speaker = root.get(aid, {}).get(SPEAKER_DEVICE) if isinstance(root.get(aid), dict) else None
    own, shared = set(), set()
    for p in _iter_plist_paths(speaker or {}):
        if not admitted(p):
            raise ValueError(f"inadmissible speaker graph reference {p!r}")
        if p.startswith(aid + "/"):
            own.add(p[len(aid) + 1 :])
        elif p.split("/")[0] in SHARED_ROOTS and "/" in p:
            shared.add(p)
        else:
            raise ValueError(f"speaker graph references file outside {aid}/ and Common/: {p}")
    return own, shared


def record_entry(path, data):
    return {
        "path": path,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


class MountedSysrootVFS:
    """Read-only VFS backed by a mounted macOS System directory."""

    def __init__(self, sysroot):
        self.sysroot = os.path.realpath(sysroot)

    def _resolve(self, rel_path, allow_link=False, root_limit=None):
        limit = os.path.realpath(root_limit) if root_limit else self.sysroot
        cur = os.path.join(self.sysroot, rel_path.lstrip("/"))
        if not allow_link:
            if os.path.islink(cur):
                raise ValueError(f"unexpected symlink at {rel_path}")
            real = os.path.realpath(cur)
            if real != cur or os.path.commonpath([real, limit]) != limit:
                raise ValueError(f"path reached through a link: {rel_path}")
            return real
        for _ in range(16):
            if not os.path.islink(cur):
                real = os.path.realpath(cur)
                if os.path.commonpath([real, limit]) != limit:
                    raise ValueError(f"symlink escapes root: {rel_path}")
                return real
            target = os.readlink(cur)
            if target.startswith("/"):
                cur = os.path.join(self.sysroot, target.lstrip("/"))
            else:
                cur = os.path.normpath(os.path.join(os.path.dirname(cur), target))
        raise ValueError(f"symlink loop at {rel_path}")

    def exists(self, rel_path):
        return os.path.lexists(os.path.join(self.sysroot, rel_path.lstrip("/")))

    def isdir(self, rel_path):
        p = os.path.join(self.sysroot, rel_path.lstrip("/"))
        return os.path.isdir(p) and not os.path.islink(p)

    def read_file(self, rel_path, maximum, allow_link=False):
        target = self._resolve(rel_path, allow_link=allow_link)
        fd = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                raise ValueError(f"not a regular file: {rel_path}")
            data = f.read(maximum + 1)
        if len(data) > maximum:
            raise ValueError(f"file over budget: {rel_path}")
        return data

    def walk_folder_files(self, folder_rel, max_files, max_bytes):
        folder_full = self._resolve(folder_rel, allow_link=False)
        files = {}
        total = 0
        for parent, dirs, names in os.walk(folder_full, followlinks=False):
            dirs.sort()
            for dname in dirs:
                rel = os.path.relpath(os.path.join(parent, dname), folder_full)
                if admitted(rel) and os.path.islink(os.path.join(parent, dname)):
                    raise ValueError(f"tuning folder holds a directory symlink: {rel}")
            for name in sorted(names):
                full = os.path.join(parent, name)
                rel = os.path.relpath(full, folder_full)
                if not admitted(rel):
                    continue
                if len(files) >= max_files:
                    raise ValueError("tuning folder over file count budget")
                target = self._resolve(
                    os.path.join(folder_rel, rel), allow_link=True, root_limit=folder_full
                )
                fd = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                with os.fdopen(fd, "rb") as f:
                    if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                        raise ValueError(f"not a regular file: {rel}")
                    data = f.read(max_bytes - total + 1)
                if len(data) > max_bytes - total:
                    raise ValueError(f"tuning folder over byte budget at {rel}")
                total += len(data)
                files[rel] = data
        return files


def collect_bundle_from_vfs(vfs, acoustic, spts, board, unit_id, speaker_id):
    aid = f"AID{acoustic}"
    folder_rel = f"{TUNINGS_REL}/{aid}"
    if not vfs.isdir(folder_rel):
        raise RuntimeError(f"missing tuning folder {folder_rel}")

    macos_build = None
    for rel in SYSVERSION_CANDIDATES:
        if vfs.exists(rel):
            pdata = plistlib.loads(vfs.read_file(rel, MAX_CONFIG_BYTES, allow_link=True))
            cand = str(pdata.get("ProductBuildVersion", "")).strip()
            if cand and cand.isalnum() and len(cand) <= 16:
                macos_build = cand
                break
    if not macos_build:
        raise RuntimeError("could not determine valid ProductBuildVersion from macOS System volume")

    files = vfs.walk_folder_files(folder_rel, MAX_FILES, MAX_BYTES)
    if not files:
        raise RuntimeError(f"tuning folder {aid} is empty")
    total = sum(len(v) for v in files.values())

    selection = {}
    source = DATABASE
    per_aid_rel = f"{aid}/{AID_DATABASE}"
    db_rel = f"{TUNINGS_REL}/{DATABASE}"
    if vfs.exists(f"{TUNINGS_REL}/{per_aid_rel}"):
        source = per_aid_rel
        db_rel = f"{TUNINGS_REL}/{source}"
    if not vfs.exists(db_rel):
        raise RuntimeError(f"missing {db_rel}")
    raw_db = vfs.read_file(db_rel, MAX_DATABASE_BYTES, allow_link=False)
    parsed_db = plistlib.loads(raw_db)
    if not isinstance(parsed_db, dict) or aid not in parsed_db or not isinstance(parsed_db[aid], dict):
        raise RuntimeError(f"{source} has no {aid} dictionary entry")
    if source != DATABASE and list(parsed_db) == [aid]:
        selection[DATABASE] = raw_db
    else:
        selection[DATABASE] = plistlib.dumps({aid: parsed_db[aid]}, fmt=plistlib.FMT_XML)

    cfg_rel = f"Config/{aid}.plist"
    cfg_vfs_rel = f"{TUNINGS_REL}/{cfg_rel}"
    if not vfs.exists(cfg_vfs_rel):
        raise RuntimeError(f"missing {cfg_vfs_rel}")
    selection[cfg_rel] = vfs.read_file(cfg_vfs_rel, MAX_CONFIG_BYTES, allow_link=False)
    total += sum(len(v) for v in selection.values())

    own_refs, shared_refs = speaker_references(selection[DATABASE], acoustic)
    shared = {}
    for srel in sorted(shared_refs):
        shared[srel] = vfs.read_file(f"{TUNINGS_REL}/{srel}", MAX_BYTES - total, allow_link=False)
        total += len(shared[srel])

    missing_own = sorted(f"{aid}/{p}" for p in own_refs if p not in files)
    if missing_own:
        raise RuntimeError(f"speaker graph references missing files: {', '.join(missing_own[:4])}")

    loudness = None
    lm_rel = f"{TUNINGS_REL}/{LOUDNESS}"
    if vfs.exists(lm_rel):
        lm_data = vfs.read_file(lm_rel, MAX_CONFIG_BYTES, allow_link=False)
        lm_root = plistlib.loads(lm_data)
        listed = lm_root.get("Supported_Hardware") if isinstance(lm_root, dict) else None
        if not isinstance(listed, list) or not all(isinstance(x, str) for x in listed):
            raise RuntimeError("malformed loudness-manager.plist")
        if aid in listed:
            loudness = lm_data

    audiodsp_bytes = vfs.read_file(AUDIODSP_REL, MAX_COMPONENT_BYTES, allow_link=True)
    lattice = extract_lattice(audiodsp_bytes)

    if spts is not None and not 0 < len(spts) <= MAX_SPTS_BYTES:
        raise RuntimeError(f"implausible speaker-thiele-small size ({len(spts)} bytes)")

    out = {}
    for rel, data in files.items():
        out[f"{aid}/{rel}"] = data
    out.update(selection)
    out.update(shared)
    if loudness is not None:
        out[LOUDNESS] = loudness
    if spts is not None:
        out[SPTS] = spts
    out[LATTICE] = lattice

    lattice_rec = record_entry(LATTICE, lattice)
    lattice_rec.update(
        {
            "version": LATTICE_VERSION,
            "format": LATTICE_FORMAT,
            "entries": LATTICE_ENTRIES,
        }
    )

    manifest_obj = {
        "board": board,
        "unit_id": unit_id,
        "speaker_id": speaker_id,
        "schema": SCHEMA,
        "kind": "aurora-audio-tuning",
        "source_file_count": len(files),
        "complete": True,
        "acoustic_id": acoustic,
        "aid": aid,
        "macos_build": macos_build,
        "speaker_thiele_small": None if spts is None else record_entry(SPTS, spts),
        "device_dsp_database": DATABASE,
        "device_dsp_database_source": source,
        "shared_files": [record_entry(p, shared[p]) for p in sorted(shared)],
        "loudness_manager": None if loudness is None else record_entry(LOUDNESS, loudness),
        "lsm2_mask_lattice": lattice_rec,
        "config": cfg_rel,
        "files": [record_entry(f"{aid}/{rel}", files[rel]) for rel in sorted(files)]
        + [record_entry(name, selection[name]) for name in sorted(selection)],
        "based_on": BASED_ON,
    }
    out[MANIFEST] = json.dumps(manifest_obj, indent=2, sort_keys=True).encode("utf-8")
    return out, aid, macos_build


# ---------------------------------------------------------------------------
# Built-in Read-Only APFS Sealed-System-Volume Reader (zlib + liblzfse)
# ---------------------------------------------------------------------------

APFS_ROLE_SYSTEM = 0x0001
DECMPFS_MAGIC = 0x636D7066  # 'fpmc'


def _fletcher64(block):
    low = high = 0
    for (word,) in struct.iter_unpack("<I", block[8:]):
        low = (low + word) % 0xFFFFFFFF
        high = (high + low) % 0xFFFFFFFF
    check_low = 0xFFFFFFFF - (low + high) % 0xFFFFFFFF
    return check_low | ((0xFFFFFFFF - (low + check_low) % 0xFFFFFFFF) << 32)


def _obj_xid(block):
    return struct.unpack_from("<Q", block, 16)[0]


def decode_lzvn_raw(src, expected_len):
    out = bytearray()
    ip = 0
    n = len(src)
    d_prev = 0
    while len(out) < expected_len and ip < n:
        opc = src[ip]
        if opc == 0x06:
            break
        if opc in (0x0E, 0x16):
            ip += 1
            continue
        if opc == 0xE0:
            lit = src[ip + 1] + 16
            out.extend(src[ip + 2 : ip + 2 + lit])
            ip += 2 + lit
            continue
        if 0xE1 <= opc <= 0xEF:
            lit = opc & 0x0F
            out.extend(src[ip + 1 : ip + 1 + lit])
            ip += 1 + lit
            continue
        if opc == 0xF0:
            mlen = src[ip + 1] + 16
            ip += 2
            dist = d_prev
        elif 0xF1 <= opc <= 0xFF:
            mlen = opc & 0x0F
            ip += 1
            dist = d_prev
        elif 0xA0 <= opc <= 0xBF:
            b1, b2 = src[ip + 1], src[ip + 2]
            lit = (opc >> 3) & 0x03
            mlen = (((opc & 0x07) << 2) | (b1 & 0x03)) + 3
            dist = (b2 << 6) | (b1 >> 2)
            d_prev = dist
            out.extend(src[ip + 3 : ip + 3 + lit])
            ip += 3 + lit
        else:
            low = opc & 0x07
            lit = (opc >> 6) & 0x03
            mlen = ((opc >> 3) & 0x07) + 3
            if low == 0x06:
                dist = d_prev
                hdr = 1
            elif low == 0x07:
                dist = src[ip + 1] | (src[ip + 2] << 8)
                d_prev = dist
                hdr = 3
            else:
                dist = (low << 8) | src[ip + 1]
                d_prev = dist
                hdr = 2
            out.extend(src[ip + hdr : ip + hdr + lit])
            ip += hdr + lit
        if dist <= 0 or dist > len(out):
            raise ValueError(f"invalid LZVN match distance {dist} at out={len(out)}")
        for _ in range(mlen):
            out.append(out[-dist])
    if len(out) != expected_len:
        raise ValueError(f"LZVN decoded {len(out)} bytes, expected {expected_len}")
    return bytes(out)


class LzfseDecoder:
    def __init__(self, lib_path=None):
        self._lib = None
        candidates = [p for p in [lib_path, "liblzfse.so"] if p]
        for cand in candidates:
            try:
                lib = ctypes.CDLL(cand)
                lib.lzfse_decode_buffer.argtypes = [
                    ctypes.c_void_p,
                    ctypes.c_size_t,
                    ctypes.c_void_p,
                    ctypes.c_size_t,
                    ctypes.c_void_p,
                ]
                lib.lzfse_decode_buffer.restype = ctypes.c_size_t
                self._lib = lib
                break
            except OSError:
                continue

    def _call_lib(self, raw_bytes, expected_len):
        dst_cap = expected_len + 64
        dst = (ctypes.c_ubyte * dst_cap)()
        src = (ctypes.c_ubyte * len(raw_bytes)).from_buffer_copy(raw_bytes)
        n = self._lib.lzfse_decode_buffer(dst, dst_cap, src, len(raw_bytes), None)
        return n, dst

    def decode_lzfse(self, src, expected_len):
        if not self._lib:
            raise RuntimeError("liblzfse.so unavailable for LZFSE decompression")
        if expected_len == 0:
            return b""
        raw = bytes(src)
        n, dst = self._call_lib(raw, expected_len)
        if n != expected_len and not raw.endswith(b"bvx$"):
            n, dst = self._call_lib(raw + b"bvx$", expected_len)
        if n != expected_len:
            raise ValueError(
                f"LZFSE decoded {n} bytes, expected {expected_len} (head={raw[:8].hex()})"
            )
        return bytes(dst[:expected_len])

    def decode_lzvn(self, src, expected_len):
        if expected_len == 0:
            return b""
        raw = bytes(src)
        if self._lib:
            # Try C liblzfse first with 0 and 7 trailing zero lookahead bytes after 0x06 EOS
            stripped = raw.rstrip(b"\x00")
            for body in (raw, stripped + b"\x00" * 7):
                stream = b"bvxn" + struct.pack("<II", expected_len, len(body)) + body + b"bvx$"
                n, dst = self._call_lib(stream, expected_len)
                if n == expected_len:
                    return bytes(dst[:expected_len])
        return decode_lzvn_raw(raw, expected_len)


class DirectApfsSystemVFS:
    """Zero-mount, strictly read-only APFS Sealed-System-Volume reader."""

    def __init__(self, dev_path, lzfse_decoder):
        self.fd = os.open(dev_path, os.O_RDONLY)
        self.lzfse = lzfse_decoder
        self._block_cache = {}
        self._dir_cache = {}
        try:
            head = os.pread(self.fd, 4096, 0)
            if len(head) < 4096 or head[32:36] != b"NXSB":
                raise ValueError("not an APFS container")
            self.block_size, self.blocks = struct.unpack_from("<IQ", head, 36)
            if not 4096 <= self.block_size <= 65536 or (self.block_size & (self.block_size - 1)):
                raise ValueError(f"unsupported APFS block size {self.block_size}")

            first = self._read_block(0, 0x1)
            xp_count = struct.unpack_from("<I", first, 104)[0] & 0x7FFFFFFF
            xp_base = struct.unpack_from("<Q", first, 112)[0]
            best = first
            if 0 < xp_count <= 4096:
                for blk in range(xp_base, xp_base + xp_count):
                    try:
                        cand = self._read_block(blk, 0x1)
                    except ValueError:
                        continue
                    if cand[32:36] == b"NXSB" and _obj_xid(cand) > _obj_xid(best):
                        best = cand
            self.nxsb = best
            nx_omap = self._read_block(struct.unpack_from("<Q", self.nxsb, 160)[0], 0xB)
            self.nx_omap_root = struct.unpack_from("<Q", nx_omap, 48)[0]

            # Find unencrypted System role volume (or volume holding /System/Library/Audio/Tunings)
            max_fs = min(struct.unpack_from("<I", self.nxsb, 180)[0], 100)
            vol_candidates = []
            for idx in range(max_fs):
                fs_oid = struct.unpack_from("<Q", self.nxsb, 184 + 8 * idx)[0]
                if not fs_oid:
                    continue
                try:
                    paddr = self._omap_lookup(self.nx_omap_root, fs_oid, _obj_xid(self.nxsb))
                    apsb = self._read_block(paddr, 0xD)
                except ValueError:
                    continue
                if apsb[32:36] != b"APSB":
                    continue
                fs_flags = struct.unpack_from("<Q", apsb, 264)[0]
                if not (fs_flags & 1):
                    # Skip encrypted volumes (e.g. Data) without touching keys
                    continue
                role = struct.unpack_from("<H", apsb, 964)[0]
                vol_candidates.append((0 if role == APFS_ROLE_SYSTEM else 1, apsb))

            if not vol_candidates:
                raise ValueError("no unencrypted APFS volume found in container")
            vol_candidates.sort(key=lambda x: x[0])

            selected = False
            vol_errors = []
            for _, apsb in vol_candidates:
                vol_name = apsb[704:960].split(b"\0", 1)[0].decode("utf-8", "replace")
                try:
                    if self._try_init_volume(apsb, vol_errors):
                        if self.isdir(TUNINGS_REL):
                            selected = True
                            break
                        vol_errors.append(f"{vol_name}: mounted root lacks {TUNINGS_REL}")
                except Exception as exc:  # noqa: BLE001
                    vol_errors.append(f"{vol_name}: {exc}")
            if not selected:
                why = f" [{' | '.join(vol_errors[:4])}]" if vol_errors else ""
                raise ValueError(f"no unencrypted volume in {dev_path} contains {TUNINGS_REL}{why}")
        except Exception:
            self.close()
            raise

    def close(self):
        if getattr(self, "fd", None) is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None

    def _activate_apsb(self, target_apsb, as_of_xid, fallback_omap_root):
        self._dir_cache.clear()
        omap_oid = struct.unpack_from("<Q", target_apsb, 128)[0]
        if omap_oid > 0:
            omap_blk = self._read_block(omap_oid, 0xB)
            self.vol_omap_root = struct.unpack_from("<Q", omap_blk, 48)[0]
        else:
            self.vol_omap_root = fallback_omap_root

        self.as_of_xid = max(as_of_xid, _obj_xid(target_apsb))
        self.sealed_volume = bool(struct.unpack_from("<Q", target_apsb, 56)[0] & 0x20)
        rt_type = struct.unpack_from("<I", target_apsb, 116)[0]
        self.root_physical = bool(rt_type & 0x40000000)
        rt_oid = struct.unpack_from("<Q", target_apsb, 136)[0]
        self.root_tree_oid = rt_oid
        self.fext_tree_oid = struct.unpack_from("<Q", target_apsb, 1032)[0]
        fext_type = struct.unpack_from("<I", target_apsb, 1040)[0]
        self.fext_physical = bool(fext_type & 0x40000000) or fext_type == 0
        self.root_tree_blk = (
            rt_oid
            if self.root_physical
            else self._omap_lookup(self.vol_omap_root, rt_oid, self.as_of_xid)
        )

    def _try_init_volume(self, apsb, vol_errors):
        vol_name = apsb[704:960].split(b"\0", 1)[0].decode("utf-8", "replace")
        live_omap_blk = self._read_block(struct.unpack_from("<Q", apsb, 128)[0], 0xB)
        live_omap_root = struct.unpack_from("<Q", live_omap_blk, 48)[0]
        root_to_xid = struct.unpack_from("<Q", apsb, 968)[0]
        snap_meta_oid = struct.unpack_from("<Q", apsb, 152)[0]

        incompat = struct.unpack_from("<Q", apsb, 56)[0]
        candidates = []
        if root_to_xid > 0 and snap_meta_oid > 0:
            sblock_paddr = self._find_snapshot_sblock(snap_meta_oid, root_to_xid)
            if sblock_paddr:
                candidates.append((f"snap@{root_to_xid}", self._read_block(sblock_paddr, 0xD), root_to_xid))

        snap_cands = []
        if snap_meta_oid > 0:
            for snap_xid, sblock_paddr in sorted(self._list_snapshots(snap_meta_oid), reverse=True):
                if snap_xid == root_to_xid:
                    continue
                try:
                    snap_cands.append((f"snap@{snap_xid}", self._read_block(sblock_paddr, 0xD), snap_xid))
                except ValueError as exc:
                    vol_errors.append(f"{vol_name}/snap@{snap_xid}: {exc}")

        if incompat & 0x20:  # APFS_INCOMPAT_SEALED_VOLUME
            candidates.extend(snap_cands)
            candidates.append(("live", apsb, _obj_xid(apsb)))
        else:
            candidates.append(("live", apsb, _obj_xid(apsb)))
            candidates.extend(snap_cands)

        for tag, cand_apsb, cand_xid in candidates:
            try:
                self._activate_apsb(cand_apsb, cand_xid, live_omap_root)
                sys_info = self._lookup_path("System", allow_final_link=False)
                if sys_info and sys_info[2] == 4:
                    return True
            except ValueError as exc:
                vol_errors.append(f"{vol_name}/{tag}: {exc}")
        return False

    def _read_block(self, blk, expected_kind=None, allow_hashed_btree=False):
        cached = self._block_cache.get(blk)
        if cached is None:
            if blk < 0 or blk >= self.blocks:
                raise ValueError(f"APFS block {blk} out of range")
            data = os.pread(self.fd, self.block_size, blk * self.block_size)
            if len(data) != self.block_size:
                raise ValueError(f"APFS block {blk} short read")
            obj_kind = struct.unpack_from("<I", data, 24)[0] & 0xFFFF
            btn_flags = struct.unpack_from("<H", data, 32)[0]
            is_hashed_btree = allow_hashed_btree and (
                (data[:32] == b"\0" * 32 and bool(btn_flags & 0x10))
                or (obj_kind in (0x2, 0x3) and bool(btn_flags & 0x30))
            )
            if not is_hashed_btree and struct.unpack_from("<Q", data, 0)[0] != _fletcher64(data):
                raise ValueError(f"APFS block {blk} checksum mismatch")
            if len(self._block_cache) > 4096:
                self._block_cache.clear()
            self._block_cache[blk] = data
            cached = data
        if expected_kind is not None and (struct.unpack_from("<I", cached, 24)[0] & 0xFFFF) != expected_kind:
            raise ValueError(f"unexpected APFS object kind at block {blk}")
        return cached

    def _parse_btree_node(self, blk, fixed_kv=None):
        node = self._read_block(blk, allow_hashed_btree=True)
        obj_kind = struct.unpack_from("<I", node, 24)[0] & 0xFFFF
        flags, level, count = struct.unpack_from("<HHI", node, 32)
        if obj_kind not in (0x2, 0x3) and not (node[:32] == b"\0" * 32 and bool(flags & 0x10)):
            raise ValueError(f"block {blk} is not a B-tree node (kind {obj_kind:#x})")
        toc_off, toc_len = struct.unpack_from("<HH", node, 40)
        keys_base = 56 + toc_off + toc_len
        vals_end = self.block_size - (40 if (flags & 1) else 0)
        fixed = bool(flags & 4)
        if fixed and fixed_kv is None and (flags & 1):
            bt_k, bt_v = struct.unpack_from("<II", node, self.block_size - 32)
            if bt_k > 0 and bt_v > 0:
                fixed_kv = (bt_k, bt_v)
        width = 4 if fixed else 8
        items = []
        for i in range(count):
            at = 56 + toc_off + i * width
            if fixed:
                k_off, v_off = struct.unpack_from("<HH", node, at)
                k_len = fixed_kv[0] if fixed_kv else 16
                v_len = (fixed_kv[1] if fixed_kv else 16) if level == 0 else 8
            else:
                k_off, k_len, v_off, v_len = struct.unpack_from("<HHHH", node, at)
            ka = keys_base + k_off
            va = vals_end - v_off
            items.append((node[ka : ka + k_len], node[va : va + v_len]))
        return level, items, fixed_kv

    def _omap_lookup(self, root_blk, target_oid, max_xid, depth=0, fixed_kv=None):
        if depth > 12:
            raise ValueError("omap tree too deep")
        level, items, fixed_kv = self._parse_btree_node(root_blk, fixed_kv)
        if level == 0:
            best = None
            for k, v in items:
                k_oid, k_xid = struct.unpack_from("<QQ", k)
                if k_oid == target_oid and k_xid <= max_xid:
                    if best is None or k_xid > best[0]:
                        best = (k_xid, v)
            if best is None:
                return None
            flags, _, paddr = struct.unpack_from("<IIQ", best[1])
            if flags & 0x1:  # OMAP_VAL_DELETED
                return None
            return paddr

        best_paddr = None
        for idx, (k, v) in enumerate(items):
            min_oid, min_xid = struct.unpack_from("<QQ", k)
            if (min_oid, min_xid) > (target_oid, max_xid):
                break
            if idx + 1 < len(items):
                next_oid, _ = struct.unpack_from("<QQ", items[idx + 1][0])
                if next_oid < target_oid:
                    continue
            child_blk = struct.unpack_from("<Q", v)[0]
            res = self._omap_lookup(child_blk, target_oid, max_xid, depth + 1, fixed_kv)
            if res is not None:
                best_paddr = res
        if best_paddr is None and depth == 0:
            raise ValueError(f"oid {target_oid} (<= xid {max_xid}) missing from omap")
        return best_paddr

    def _list_snapshots(self, blk, depth=0, fixed_kv=None):
        if depth > 8:
            return []
        level, items, fixed_kv = self._parse_btree_node(blk, fixed_kv)
        out = []
        if level == 0:
            for k, v in items:
                hdr = struct.unpack_from("<Q", k)[0]
                oid, kind = hdr & ((1 << 60) - 1), hdr >> 60
                if kind == 1 and len(v) >= 16:
                    sblock_oid = struct.unpack_from("<Q", v, 8)[0]
                    out.append((oid, sblock_oid))
        else:
            for _, v in items:
                out.extend(self._list_snapshots(struct.unpack_from("<Q", v)[0], depth + 1, fixed_kv))
        return out

    def _find_snapshot_sblock(self, snap_meta_blk, want_xid):
        for xid, sb in self._list_snapshots(snap_meta_blk):
            if xid == want_xid:
                return sb
        return None

    def _resolve_fs_child(self, child_oid):
        if self.root_physical:
            return child_oid
        if self.sealed_volume and child_oid < self.root_tree_oid:
            return self._omap_lookup(
                self.vol_omap_root, self.root_tree_oid + child_oid, self.as_of_xid
            )
        return self._omap_lookup(self.vol_omap_root, child_oid, self.as_of_xid)

    def _fs_entries_for_oid(self, blk, target_oid, depth=0, fixed_kv=None):
        if depth > 12:
            raise ValueError("FS B-tree too deep")
        level, items, fixed_kv = self._parse_btree_node(blk, fixed_kv)
        if level == 0:
            for k, v in items:
                hdr = struct.unpack_from("<Q", k)[0]
                oid, kind = hdr & ((1 << 60) - 1), hdr >> 60
                if oid == target_oid:
                    yield kind, k, v
                elif oid > target_oid:
                    break
            return

        for idx, (k, v) in enumerate(items):
            min_oid = struct.unpack_from("<Q", k)[0] & ((1 << 60) - 1)
            if min_oid > target_oid:
                break
            if idx + 1 < len(items):
                next_oid = struct.unpack_from("<Q", items[idx + 1][0])[0] & ((1 << 60) - 1)
                if next_oid < target_oid:
                    continue
            child_blk = self._resolve_fs_child(struct.unpack_from("<Q", v)[0])
            yield from self._fs_entries_for_oid(child_blk, target_oid, depth + 1, fixed_kv)

    def _fext_entries_for_id(self, blk, private_id, depth=0, fixed_kv=None):
        if depth > 12:
            raise ValueError("fext B-tree too deep")
        if depth == 0 and not self.fext_physical:
            blk = self._omap_lookup(self.vol_omap_root, blk, self.as_of_xid)
        level, items, fixed_kv = self._parse_btree_node(blk, fixed_kv)
        if level == 0:
            for k, v in items:
                pid, logical = struct.unpack_from("<QQ", k)
                if pid == private_id:
                    length_flags, phys_blk = struct.unpack_from("<QQ", v)
                    yield logical, length_flags & ((1 << 56) - 1), phys_blk
                elif pid > private_id:
                    break
            return

        for idx, (k, v) in enumerate(items):
            min_pid = struct.unpack_from("<Q", k)[0]
            if min_pid > private_id:
                break
            if idx + 1 < len(items):
                next_pid = struct.unpack_from("<Q", items[idx + 1][0])[0]
                if next_pid < private_id:
                    continue
            child_oid = struct.unpack_from("<Q", v)[0]
            child_blk = (
                child_oid
                if self.fext_physical
                else self._omap_lookup(self.vol_omap_root, child_oid, self.as_of_xid)
            )
            yield from self._fext_entries_for_id(child_blk, private_id, depth + 1, fixed_kv)

    def _read_dir(self, dir_oid):
        if dir_oid in self._dir_cache:
            return self._dir_cache[dir_oid]
        entries = {}
        for kind, k, v in self._fs_entries_for_oid(self.root_tree_blk, dir_oid):
            if kind != 9:
                continue
            if len(k) >= 13 and 12 + (struct.unpack_from("<I", k, 8)[0] & 0x3FF) == len(k):
                name_len = struct.unpack_from("<I", k, 8)[0] & 0x3FF
                name_at = 12
            else:
                name_len = struct.unpack_from("<H", k, 8)[0]
                name_at = 10
            name = k[name_at : name_at + name_len].rstrip(b"\0").decode("utf-8", "replace")
            file_id, _, flags = struct.unpack_from("<QQH", v)
            d_type = flags & 0xF
            if d_type == 0:
                _, _, mode, _, _, _ = self._read_inode_info(file_id)
                d_type = (mode >> 12) & 0xF
            entries[name] = (file_id, d_type)
        self._dir_cache[dir_oid] = entries
        return entries

    def _read_inode_info(self, file_id):
        inode_val = None
        xattrs = {}
        inline_extents = []
        for kind, k, v in self._fs_entries_for_oid(self.root_tree_blk, file_id):
            if kind == 3:
                inode_val = v
            elif kind == 4:
                nlen = struct.unpack_from("<H", k, 8)[0]
                xname = k[10 : 10 + nlen].rstrip(b"\0").decode("utf-8", "replace")
                xattrs[xname] = v
            elif kind == 8:
                logical = struct.unpack_from("<Q", k, 8)[0]
                lf, pblk = struct.unpack_from("<QQ", v)
                inline_extents.append((logical, lf & ((1 << 56) - 1), pblk))
        if inode_val is None or len(inode_val) < 92:
            raise ValueError(f"missing inode {file_id}")
        private_id = struct.unpack_from("<Q", inode_val, 8)[0]
        bsd_flags = struct.unpack_from("<I", inode_val, 68)[0]
        mode = struct.unpack_from("<H", inode_val, 80)[0]
        dstream_size = struct.unpack_from("<Q", inode_val, 84)[0]
        if len(inode_val) >= 96:
            xf_count = struct.unpack_from("<H", inode_val, 92)[0]
            types_off = 96
            val_off = 96 + 4 * xf_count
            for i in range(xf_count):
                if types_off + 4 * (i + 1) > len(inode_val):
                    break
                x_type, _, x_len = struct.unpack_from("<BBH", inode_val, types_off + 4 * i)
                if val_off + x_len > len(inode_val):
                    break
                if x_type == 8 and x_len >= 8:  # INO_EXT_TYPE_DSTREAM
                    dstream_size = struct.unpack_from("<Q", inode_val, val_off)[0]
                val_off += (x_len + 7) & ~7
        return private_id, bsd_flags, mode, dstream_size, xattrs, inline_extents

    def _read_stream(self, private_id, size, inline_extents=None, maximum=MAX_COMPONENT_BYTES):
        if size > maximum:
            raise ValueError(f"stream size {size} exceeds budget {maximum}")
        if size == 0:
            return b""
        exts = list(inline_extents or [])
        if not exts and self.fext_tree_oid > 0:
            exts = list(self._fext_entries_for_id(self.fext_tree_oid, private_id))
        if not exts:
            # Also check FS tree under private_id in case private_id != file_id
            for kind, k, v in self._fs_entries_for_oid(self.root_tree_blk, private_id):
                if kind == 8:
                    logical = struct.unpack_from("<Q", k, 8)[0]
                    lf, pblk = struct.unpack_from("<QQ", v)
                    exts.append((logical, lf & ((1 << 56) - 1), pblk))
        exts.sort(key=lambda x: x[0])
        out = bytearray()
        for logical, length, pblk in exts:
            if len(out) >= size:
                break
            if logical > len(out):
                out.extend(b"\0" * min(size - len(out), logical - len(out)))
            if pblk == 0:
                out.extend(b"\0" * min(size - len(out), length))
            else:
                to_read = min(length, size - len(out))
                out.extend(os.pread(self.fd, to_read, pblk * self.block_size))
        return bytes(out[:size])

    def _read_xattr(self, xattrs, name, maximum):
        raw = xattrs.get(name)
        if raw is None:
            return None
        flags, xlen = struct.unpack_from("<HH", raw, 0)
        if flags & 0x2:  # XATTR_DATA_EMBEDDED
            if xlen > maximum:
                raise ValueError(f"xattr {name} over budget")
            return bytes(raw[4 : 4 + xlen])
        if flags & 0x1:  # XATTR_DATA_STREAM
            xobj_id, xsize = struct.unpack_from("<QQ", raw, 4)
            return self._read_stream(xobj_id, xsize, None, maximum)
        raise ValueError(f"unsupported xattr flags {flags:#x} on {name}")

    def _decompress_decmpfs(self, xattrs, private_id, dstream_size, inline_extents, maximum):
        hdr = self._read_xattr(xattrs, "com.apple.decmpfs", maximum + 64)
        if not hdr or len(hdr) < 16:
            raise ValueError("compressed APFS inode missing com.apple.decmpfs")
        magic, ctype, usize = struct.unpack_from("<IIQ", hdr, 0)
        if magic != DECMPFS_MAGIC:
            raise ValueError(f"invalid decmpfs magic {magic:#x}")
        if usize > maximum:
            raise ValueError(f"decmpfs uncompressed size {usize} over budget")
        if usize == 0:
            return b""
        inline = hdr[16:]

        # Inline attribute payloads: 3 (zlib), 7 (LZVN), 9 (uncompressed), 11 (LZFSE)
        if ctype == 3:
            if inline and inline[0] == 0xFF:
                out = inline[1:]
            else:
                out = zlib.decompress(inline)
            if len(out) != usize:
                raise ValueError("zlib attr size mismatch")
            return out
        if ctype == 7:
            if inline and inline[0] == 0x06:
                out = inline[1 : 1 + usize]
            else:
                out = self.lzfse.decode_lzvn(inline, usize)
            return out
        if ctype == 9:
            return inline[1 : 1 + usize] if len(inline) == usize + 1 else inline[:usize]
        if ctype == 11:
            if inline[:3] != b"bvx" and len(inline) >= usize + 1 and inline[0] in (0x06, 0xFF):
                return inline[1 : 1 + usize]
            return self.lzfse.decode_lzfse(inline, usize)

        # ResourceFork / data-stream chunked payloads: 4 (zlib), 8 (LZVN), 10 (uncompressed), 12 (LZFSE)
        rsrc = self._read_xattr(xattrs, "com.apple.ResourceFork", maximum + (4 << 20))
        if rsrc is None and dstream_size > 0:
            rsrc = self._read_stream(private_id, dstream_size, inline_extents, maximum + (4 << 20))
        if not rsrc:
            raise ValueError(f"decmpfs type {ctype} missing ResourceFork")

        out = bytearray()
        if ctype == 4:
            data_off = struct.unpack_from(">I", rsrc, 0)[0]
            base = data_off + 4
            nchunks = struct.unpack_from("<I", rsrc, base)[0]
            coff0 = struct.unpack_from("<I", rsrc, base + 4)[0] if nchunks > 0 else 0
            origin = base if coff0 == 4 + 8 * nchunks else base + 4
            for i in range(nchunks):
                coff, csize = struct.unpack_from("<II", rsrc, base + 4 + 8 * i)
                chunk = rsrc[origin + coff : origin + coff + csize]
                if chunk[0] == 0xFF:
                    out.extend(chunk[1:])
                else:
                    out.extend(zlib.decompress(chunk))
        elif ctype in (8, 10, 12):
            first_off = struct.unpack_from("<I", rsrc, 0)[0]
            nentries = first_off // 4
            if nentries < 2:
                raise ValueError(f"invalid decmpfs type {ctype} offset table")
            offs = struct.unpack_from(f"<{nentries}I", rsrc, 0)
            for i in range(nentries - 1):
                chunk = rsrc[offs[i] : offs[i + 1]]
                want = min(65536, usize - len(out))
                if ctype == 10:
                    out.extend(chunk[1 : 1 + want] if len(chunk) == want + 1 else chunk[:want])
                elif ctype == 8:
                    if chunk and chunk[0] == 0x06:
                        out.extend(chunk[1 : 1 + want])
                    else:
                        out.extend(self.lzfse.decode_lzvn(chunk, want))
                else:
                    if chunk[:3] != b"bvx" and len(chunk) >= want + 1 and chunk[0] in (0x06, 0xFF):
                        out.extend(chunk[1 : 1 + want])
                    else:
                        out.extend(self.lzfse.decode_lzfse(chunk, want))
        else:
            raise ValueError(f"unsupported decmpfs compression type {ctype}")

        if len(out) != usize:
            raise ValueError(f"decmpfs decoded {len(out)} bytes, expected {usize}")
        return bytes(out)

    def _lookup_path(self, rel_path, allow_final_link=False, root_limit_parts=()):
        parts = [p for p in rel_path.strip("/").split("/") if p]
        cur_oid = 2  # APFS root directory OID
        resolved = []
        hops = 0
        idx = 0
        while idx < len(parts):
            part = parts[idx]
            is_last = idx == len(parts) - 1
            if part == ".":
                idx += 1
                continue
            if part == "..":
                if len(resolved) <= len(root_limit_parts):
                    raise ValueError(f"path {rel_path} escapes root limit")
                resolved.pop()
                cur_oid = resolved[-1][1] if resolved else 2
                idx += 1
                continue
            entries = self._read_dir(cur_oid)
            if part not in entries:
                return None
            child_id, d_type = entries[part]
            if d_type == 10:  # DT_LNK
                if is_last and not allow_final_link:
                    raise ValueError(f"unexpected symlink at {rel_path}")
                hops += 1
                if hops > 16:
                    raise ValueError(f"symlink loop at {rel_path}")
                _, _, _, _, xattrs, _ = self._read_inode_info(child_id)
                target_bytes = self._read_xattr(xattrs, "com.apple.fs.symlink", 4096)
                if not target_bytes:
                    raise ValueError(f"broken APFS symlink at {rel_path}")
                target = target_bytes.rstrip(b"\0").decode("utf-8", "replace")
                if target.startswith("/"):
                    if root_limit_parts:
                        raise ValueError(f"absolute symlink inside bounded folder: {rel_path}")
                    parts = [p for p in target.strip("/").split("/") if p] + parts[idx + 1 :]
                    cur_oid = 2
                    resolved = []
                    idx = 0
                else:
                    rel_parts = [p for p in target.split("/") if p]
                    parts = parts[:idx] + rel_parts + parts[idx + 1 :]
                continue
            resolved.append((part, child_id, d_type))
            cur_oid = child_id
            idx += 1
        return resolved[-1] if resolved else ("", 2, 4)

    def exists(self, rel_path):
        parts = [p for p in rel_path.strip("/").split("/") if p]
        if not parts:
            return True
        parent = "/".join(parts[:-1])
        if parent:
            pinfo = self._lookup_path(parent, allow_final_link=True)
            if not pinfo or pinfo[2] != 4:
                return False
            entries = self._read_dir(pinfo[1])
        else:
            entries = self._read_dir(2)
        return parts[-1] in entries

    def isdir(self, rel_path):
        try:
            info = self._lookup_path(rel_path, allow_final_link=False)
        except ValueError:
            return False
        return bool(info and info[2] == 4)

    def read_file(self, rel_path, maximum, allow_link=False):
        info = self._lookup_path(rel_path, allow_final_link=allow_link)
        if not info or info[2] != 8:
            raise ValueError(f"not a regular file: {rel_path}")
        return self._read_file_by_oid(info[1], maximum)

    def _read_file_by_oid(self, file_id, maximum):
        private_id, iflags, _, usize, xattrs, inline_extents = self._read_inode_info(file_id)
        if iflags & 0x20:  # INODE_IS_COMPRESSED
            return self._decompress_decmpfs(xattrs, private_id, usize, inline_extents, maximum)
        return self._read_stream(private_id, usize, inline_extents, maximum)

    def walk_folder_files(self, folder_rel, max_files, max_bytes):
        info = self._lookup_path(folder_rel, allow_final_link=False)
        if not info or info[2] != 4:
            raise ValueError(f"missing directory: {folder_rel}")
        limit_parts = tuple(p for p in folder_rel.strip("/").split("/") if p)
        files = {}
        total = 0

        def _walk(dir_oid, rel_prefix):
            nonlocal total
            entries = self._read_dir(dir_oid)
            for name in sorted(entries):
                child_id, d_type = entries[name]
                rel = f"{rel_prefix}/{name}" if rel_prefix else name
                if not admitted(rel):
                    continue
                if d_type == 4:
                    _walk(child_id, rel)
                elif d_type in (8, 10):
                    if len(files) >= max_files:
                        raise ValueError("tuning folder over file count budget")
                    if d_type == 10:
                        target_info = self._lookup_path(
                            f"{folder_rel}/{rel}",
                            allow_final_link=True,
                            root_limit_parts=limit_parts,
                        )
                        if not target_info or target_info[2] != 8:
                            raise ValueError(f"tuning folder symlink {rel} does not point to a regular file")
                        child_id = target_info[1]
                    data = self._read_file_by_oid(child_id, max_bytes - total)
                    total += len(data)
                    files[rel] = data

        _walk(info[1], "")
        return files


# ---------------------------------------------------------------------------
# APFS container discovery & extraction orchestration
# ---------------------------------------------------------------------------


def candidate_apfs_devices():
    seen = set()
    devs = []
    if os.path.exists(CONTAINER_LABEL):
        real = os.path.realpath(CONTAINER_LABEL)
        seen.add(real)
        devs.append(real)

    sized = []
    for path in sorted(glob.glob("/dev/nvme*n*p*")):
        real = os.path.realpath(path)
        if real in seen:
            continue
        try:
            with open(real, "rb") as f:
                head = f.read(64)
                f.seek(0, os.SEEK_END)
                sz = f.tell()
            if len(head) >= 36 and head[32:36] == b"NXSB":
                seen.add(real)
                sized.append((sz, real))
        except OSError:
            continue
    sized.sort(reverse=True)
    devs.extend(d for _, d in sized)
    return devs


def unmount_quiet(mnt):
    for cmd in (
        ["fusermount3", "-u", mnt],
        ["fusermount", "-u", mnt],
        ["umount", mnt],
        ["umount", "-l", mnt],
    ):
        if shutil.which(cmd[0]):
            r = subprocess.run(cmd, capture_output=True)
            if r.returncode == 0:
                return
        time.sleep(0.05)


def parse_apfsutil_snapshots(dev):
    apfsutil = shutil.which("apfsutil")
    if not apfsutil:
        return []
    r = subprocess.run(
        [apfsutil, dev], capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL
    )
    if r.returncode != 0:
        return []
    pairs = []
    cur_vol = None
    in_snaps = False
    for line in r.stdout.splitlines():
        m_vol = re.match(r"^Volume\s+(\d+)\b", line)
        if m_vol:
            cur_vol = int(m_vol.group(1))
            in_snaps = False
            continue
        if line.strip() == "Snapshots:":
            in_snaps = True
            continue
        if cur_vol is not None and in_snaps:
            m_snap = re.match(r"^\s*(\d+)\s*:", line)
            if m_snap:
                pair = (cur_vol, int(m_snap.group(1)))
                if pair not in pairs:
                    pairs.append(pair)
    return pairs


def extract_from_apfs(acoustic, spts, board, unit_id, speaker_id, lzfse_lib=None):
    devices = candidate_apfs_devices()
    if not devices:
        raise RuntimeError("no APFS container partitions found on NVMe")

    errors = []

    # Strategy 1: Direct zero-mount read-only APFS Sealed-System-Volume reader (fast, immune to newer container incompat bits)
    decoder = LzfseDecoder(lzfse_lib)
    for dev in devices:
        vfs = None
        try:
            vfs = DirectApfsSystemVFS(dev, decoder)
            if vfs.isdir(f"{TUNINGS_REL}/AID{acoustic}"):
                log(f"reading AID{acoustic} directly from APFS System volume on {dev}")
                return collect_bundle_from_vfs(vfs, acoustic, spts, board, unit_id, speaker_id)
        except Exception as exc:  # noqa: BLE001
            errors.append(f"direct({dev}): {exc}")
        finally:
            if vfs is not None:
                vfs.close()

    # Strategy 2: apfs-fuse -l fallback (both live volumes and sealed snapshots)
    apfs_fuse = shutil.which("apfs-fuse")
    if apfs_fuse:
        mnt = tempfile.mkdtemp(prefix="aurora-audio-tuning-mnt.")
        mounted = False
        try:
            for dev in devices:
                arg_sets = []
                for vol, xid in parse_apfsutil_snapshots(dev):
                    arg_sets.append(["-l", "-v", str(vol), "-o", f"snap={xid}"])
                for vol in range(8):
                    arg_sets.append(["-l", "-v", str(vol)])

                for m_args in arg_sets:
                    r = subprocess.run(
                        [apfs_fuse, *m_args, dev, mnt],
                        capture_output=True,
                        text=True,
                        timeout=30,
                        stdin=subprocess.DEVNULL,
                    )
                    if r.returncode != 0:
                        continue
                    mounted = True
                    try:
                        for sub in (os.path.join(mnt, "root"), mnt):
                            if os.path.isdir(os.path.join(sub, TUNINGS_REL, f"AID{acoustic}")):
                                log(f"reading AID{acoustic} via apfs-fuse from {dev} ({' '.join(m_args)})")
                                return collect_bundle_from_vfs(
                                    MountedSysrootVFS(sub),
                                    acoustic,
                                    spts,
                                    board,
                                    unit_id,
                                    speaker_id,
                                )
                    finally:
                        unmount_quiet(mnt)
                        mounted = False
        finally:
            if mounted:
                unmount_quiet(mnt)
            try:
                os.rmdir(mnt)
            except OSError:
                pass

    detail = "; ".join(errors[:4])
    raise RuntimeError(
        f"could not read {TUNINGS_REL}/AID{acoustic} from {devices}"
        + (f" ({detail})" if detail else "")
    )


# ---------------------------------------------------------------------------
# Verification & atomic installation
# ---------------------------------------------------------------------------


def verify_bundle(cli, bundle_path, expected_board, expected_unit):
    args = [bundle_path] if bundle_path else []
    r_id = subprocess.run(
        [cli, "identify", "--json", *args],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if r_id.returncode != 0:
        return False, f"identify failed: {(r_id.stderr or r_id.stdout).strip()}"
    try:
        ident = json.loads(r_id.stdout)
    except ValueError as e:
        return False, f"identify JSON parse error: {e}"

    if ident.get("verified") is not True or ident.get("kind") != "Installer":
        return False, f"bundle is not a verified Installer bundle ({ident})"
    if expected_board and ident.get("board") != expected_board:
        return False, f"bundle board {ident.get('board')!r} != {expected_board!r}"
    if expected_unit:
        if ident.get("unit_bound") is not True or ident.get("unit_id") != expected_unit:
            return False, "bundle unit_id does not match this Mac"
    if not ident.get("macos_build"):
        return False, "bundle lacks macos_build"

    r_dump = subprocess.run(
        [cli, "dump", "--json", *args],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if r_dump.returncode != 0:
        return False, f"dump refused bundle: {(r_dump.stderr or r_dump.stdout).strip()[:300]}"
    return True, ident


def write_bundle_atomic(target_dir, bundle_files, cli, expected_board, expected_unit):
    parent = os.path.dirname(os.path.abspath(target_dir))
    os.makedirs(parent, mode=0o755, exist_ok=True)
    tmp_dir = tempfile.mkdtemp(prefix=".audio-tuning.tmp.", dir=parent)
    old_dir = os.path.join(parent, f".audio-tuning.old.{os.getpid()}")
    try:
        os.chmod(tmp_dir, 0o755)
        for rel, data in sorted(bundle_files.items()):
            dest = os.path.join(tmp_dir, rel)
            os.makedirs(os.path.dirname(dest), mode=0o755, exist_ok=True)
            with open(dest, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(dest, 0o644)

        ok, info = verify_bundle(cli, tmp_dir, expected_board, expected_unit)
        if not ok:
            raise RuntimeError(f"newly extracted bundle failed verification: {info}")

        shutil.rmtree(old_dir, ignore_errors=True)
        if os.path.lexists(target_dir):
            os.rename(target_dir, old_dir)
        os.rename(tmp_dir, target_dir)
        shutil.rmtree(old_dir, ignore_errors=True)
        return info
    except Exception:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise


def try_copy_existing_vendor_bundle(target_dir, cli, board, unit):
    for esp in ("/boot/efi", "/boot", "/efi", "/run/.system-efi"):
        tar_path = os.path.join(esp, "vendorfw", "firmware.tar")
        if not os.path.isfile(tar_path):
            continue
        ok, _ = verify_bundle(cli, tar_path, board, unit)
        if not ok:
            continue
        bundle_files = {}
        prefix = "apple/audio-tuning/"
        with tarfile.open(tar_path, "r:*") as tf:
            for m in tf.getmembers():
                name = m.name.lstrip("./")
                if name.startswith(prefix) and m.isfile():
                    rel = name[len(prefix) :]
                    if admitted(rel):
                        bundle_files[rel] = tf.extractfile(m).read()
        if MANIFEST in bundle_files:
            info = write_bundle_atomic(target_dir, bundle_files, cli, board, unit)
            log(f"imported verified bundle {info.get('aid')} from {tar_path}")
            return True
    return False


def main():
    parser = argparse.ArgumentParser(description="Provision this Mac's speaker tuning bundle")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="Target bundle directory")
    parser.add_argument("--cli", default=None, help="Path to aurora-speaker-tuning binary")
    parser.add_argument("--lzfse-lib", default=None, help="Path to liblzfse.so")
    parser.add_argument(
        "--check-needed",
        action="store_true",
        help="Exit 0 if setup is needed, 1 if target bundle is already valid (for systemd ExecCondition)",
    )
    parser.add_argument("--force", action="store_true", help="Re-extract even if already valid")
    args = parser.parse_args()

    cli = args.cli or shutil.which("aurora-speaker-tuning")
    if not cli:
        log("aurora-speaker-tuning binary not found")
        return 1

    dt_board, dt_unit, dt_speaker_id = read_linux_dt_identity()

    if not args.force and os.path.isfile(os.path.join(args.output, MANIFEST)):
        ok, info = verify_bundle(cli, args.output, dt_board, dt_unit)
        if ok:
            if args.check_needed:
                return 1
            log(
                f"bundle at {args.output} ({info.get('aid')}, macOS {info.get('macos_build')}) is already valid"
            )
            return 0

    if args.check_needed:
        return 0

    if not args.force and try_copy_existing_vendor_bundle(args.output, cli, dt_board, dt_unit):
        return 0

    acoustic, spts, adt_board, adt_unit = probe_adt()
    board = dt_board or adt_board
    unit_id = dt_unit or adt_unit
    if dt_board and adt_board and dt_board != adt_board:
        raise RuntimeError(f"Linux DT board {dt_board!r} disagrees with ADT board {adt_board!r}")
    if dt_unit and adt_unit and dt_unit != adt_unit:
        raise RuntimeError("Linux DT serial-number disagrees with ADT serial-number")
    if not board or not unit_id:
        raise RuntimeError("cannot determine Mac board and unit_id from device tree")

    bundle_files, aid, macos_build = extract_from_apfs(
        acoustic, spts, board, unit_id, dt_speaker_id, lzfse_lib=args.lzfse_lib
    )
    info = write_bundle_atomic(args.output, bundle_files, cli, board, unit_id)
    log(
        f"installed verified {aid} bundle (macOS {macos_build}, {len(bundle_files)} files, "
        f"SpTS={'yes' if spts else 'no'}) to {args.output} [digest {str(info.get('digest', ''))[:16]}]"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        log(f"ERROR: {exc}")
        raise SystemExit(1)
