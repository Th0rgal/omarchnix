#!/usr/bin/env python3
"""Offline vocabulary & correction learner from retained recordings (`VOICED_RETAIN_AUDIO=1`)."""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from collections import Counter
from typing import Dict, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline as vp  # noqa: E402


def list_recordings(home: str) -> List[Dict]:
    rec_dir = os.path.join(home, "recordings")
    items = []
    for meta_path in sorted(glob.glob(os.path.join(rec_dir, "*.json"))):
        try:
            with open(meta_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            data["_meta_path"] = meta_path
            items.append(data)
        except (OSError, ValueError):
            continue
    return items


def main() -> int:
    ap = argparse.ArgumentParser(description="Inspect retained Murmure/voiced transcripts and vocabulary candidates.")
    ap.add_argument("--home", default=vp.voice_home(), help="Voice home directory")
    ap.add_argument("--limit", type=int, default=50, help="Recent recordings to inspect")
    args = ap.parse_args()

    recs = list_recordings(args.home)
    if not recs:
        print(f"No retained recordings in {os.path.join(args.home, 'recordings')}. Set VOICED_RETAIN_AUDIO=1 to opt in.")
        return 0

    vocab = {v.lower() for v in vp.load_vocabulary(args.home)}
    counts: Counter[str] = Counter()
    for item in recs[-args.limit :]:
        txt = item.get("processed_text") or item.get("raw_text") or ""
        for tok in txt.split():
            clean = tok.strip(vp.PUNCT_CHARS)
            if len(clean) >= 5 and clean[0].isupper() and clean.lower() not in vocab:
                counts[clean] += 1

    print(f"Inspected {min(len(recs), args.limit)} recordings in {args.home}:")
    if not counts:
        print("  No new capitalized proper-noun candidates found.")
    else:
        print("  Candidate proper nouns for vocabulary.txt:")
        for word, n in counts.most_common(20):
            print(f"    {word} ({n}x)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
