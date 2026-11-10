"""Daemon-side and session-side text post-processing, vocabulary snapping, and
opt-in audio retention for voiced / Murmure on Linux & macOS.

Mirrors Sources/MurmureCore/TextPipeline.swift so both Orb and Murmure benefit
from vocabulary.txt and corrections.json when present, and provides opt-in
local audio + transcript retention for `voiced/learn.py`.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from typing import Any, Dict, List, Optional, Sequence

if sys.platform == "darwin":
    DEFAULT_HOME = os.path.expanduser("~/Library/Application Support/md.thomas.voice")
else:
    DEFAULT_HOME = os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
        "md.thomas.voice",
    )

LANGUAGES = [
    {"code": "fr", "name": "Français", "joiner": " "},
    {"code": "en", "name": "English", "joiner": " "},
    {"code": "de", "name": "Deutsch", "joiner": " "},
    {"code": "es", "name": "Español", "joiner": " "},
    {"code": "it", "name": "Italiano", "joiner": " "},
    {"code": "pt", "name": "Português", "joiner": " "},
    {"code": "nl", "name": "Nederlands", "joiner": " "},
    {"code": "pl", "name": "Polski", "joiner": " "},
    {"code": "el", "name": "Ελληνικά", "joiner": " "},
    {"code": "ar", "name": "العربية", "joiner": " "},
    {"code": "ja", "name": "日本語", "joiner": ""},
    {"code": "zh", "name": "中文", "joiner": ""},
    {"code": "vi", "name": "Tiếng Việt", "joiner": " "},
    {"code": "ko", "name": "한국어", "joiner": " "},
]
LANGUAGE_BY_CODE = {lang["code"]: lang for lang in LANGUAGES}

FILLERS_BY_LANG = {
    "en": {"um", "uh", "erm", "er", "hm", "hmm", "uhm"},
    "fr": {"euh", "heu", "bah", "ben", "hmm", "hm"},
    "de": {"äh", "ähm", "hm", "hmm"},
    "es": {"eh", "este", "em", "hm"},
}

ONES = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
    "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
}
TENS = {
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
}

PUNCT_CHARS = ".,!?;:\"'()[]{}«»—–-"


def voice_home() -> str:
    return os.environ.get("VOICED_HOME") or DEFAULT_HOME


def language_joiner(language: str) -> str:
    info = LANGUAGE_BY_CODE.get(language)
    return info["joiner"] if info else " "


def parse_vocabulary(raw: str) -> List[str]:
    seen = set()
    terms: List[str] = []
    for line in raw.splitlines():
        head = line.split("#", 1)[0].strip()
        if not head:
            continue
        key = head.lower()
        if key not in seen:
            seen.add(key)
            terms.append(head)
    return terms


def load_vocabulary(home: Optional[str] = None) -> List[str]:
    path = os.path.join(home or voice_home(), "vocabulary.txt")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return parse_vocabulary(f.read())
    except OSError:
        return []


def load_corrections(home: Optional[str] = None) -> Dict[str, str]:
    path = os.path.join(home or voice_home(), "corrections.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
            if isinstance(data, dict):
                return {str(k): str(v) for k, v in data.items() if k and isinstance(v, str)}
    except (OSError, ValueError):
        pass
    return {}


def levenshtein(a: str, b: str) -> int:
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    curr = [0] * (len(b) + 1)
    for i, ca in enumerate(a):
        curr[0] = i + 1
        for j, cb in enumerate(b):
            cost = 0 if ca == cb else 1
            curr[j + 1] = min(prev[j + 1] + 1, curr[j] + 1, prev[j] + cost)
        prev, curr = curr, prev
    return prev[len(b)]


def _strip_disfluencies_line(line: str, fillers: set[str]) -> str:
    tokens = line.split()
    kept: List[str] = []
    for tok in tokens:
        bare = tok.strip(PUNCT_CHARS).lower()
        if bare in fillers:
            continue
        if kept:
            prev_bare = kept[-1].strip(PUNCT_CHARS).lower()
            if bare and bare == prev_bare and len(bare) <= 4 and not kept[-1].endswith((",", ".")):
                continue
        kept.append(tok)
    result = " ".join(kept)
    if result.startswith(", "):
        result = result[2:]
    stripped = line.lstrip()
    if stripped and stripped[0].isupper() and result and result[0].islower():
        result = result[0].upper() + result[1:]
    return result


def strip_disfluencies(text: str, language: str = "en") -> str:
    fillers = FILLERS_BY_LANG.get(language, FILLERS_BY_LANG["en"])
    if "\n" not in text:
        return _strip_disfluencies_line(text, fillers)
    return "\n".join(_strip_disfluencies_line(ln, fillers) for ln in text.split("\n"))


def apply_voice_commands(text: str, language: str = "en") -> str:
    current = text
    scratch_patterns = ["efface ça", "annule ça"] if language == "fr" else ["scratch that", "delete that"]
    for pat in scratch_patterns:
        rx = re.compile(re.escape(pat), re.IGNORECASE)
        while True:
            m = rx.search(current)
            if not m:
                break
            before = current[: m.start()].strip()
            after = current[m.end() :].strip()
            cut_idx = -1
            for idx in range(len(before) - 2, -1, -1):
                if before[idx] in ".!?\n":
                    cut_idx = idx
                    break
            if cut_idx >= 0:
                prefix = before[: cut_idx + 1]
                current = f"{prefix} {after}".strip()
            else:
                current = after.lstrip(".,!?;: ")

    replacements = (
        [("nouveau paragraphe", "\n\n"), ("nouvelle ligne", "\n"), ("à la ligne", "\n")]
        if language == "fr"
        else [("new paragraph", "\n\n"), ("new line", "\n")]
    )
    for phrase, rep in replacements:
        pattern = r"\b" + re.escape(phrase) + r"\b[.,!?;:]?"
        current = re.sub(pattern, rep, current, flags=re.IGNORECASE)
    return current


def _convert_spoken_numbers_line(line: str) -> str:
    words = line.split()
    if len(words) < 2:
        return line
    out: List[str] = []
    i = 0
    while i < len(words):
        w1 = words[i].strip(PUNCT_CHARS).lower()
        if w1 in TENS and i + 1 < len(words):
            raw2 = words[i + 1]
            w2 = raw2.strip(PUNCT_CHARS).lower()
            if w2 in ONES and 0 < ONES[w2] < 10:
                trailing = ""
                for ch in reversed(raw2):
                    if ch in PUNCT_CHARS:
                        trailing = ch + trailing
                    else:
                        break
                out.append(f"{TENS[w1] + ONES[w2]}{trailing}")
                i += 2
                continue
        out.append(words[i])
        i += 1
    return " ".join(out)


def convert_spoken_numbers(text: str) -> str:
    if "\n" not in text:
        return _convert_spoken_numbers_line(text)
    return "\n".join(_convert_spoken_numbers_line(ln) for ln in text.split("\n"))


def apply_corrections(text: str, rules: Dict[str, str]) -> str:
    out = text
    for wrong, right in sorted(rules.items(), key=lambda kv: len(kv[0]), reverse=True):
        if not wrong:
            continue
        pattern = r"(?<![\w])" + re.escape(wrong) + r"(?![\w])"
        out = re.sub(pattern, lambda _, r=right: r, out, flags=re.IGNORECASE)
    return out


def snap_to_vocabulary(text: str, vocabulary: Sequence[str]) -> str:
    if not vocabulary:
        return text
    exact = {term.lower(): term for term in vocabulary if term}
    out = apply_corrections(text, exact)
    single_terms = [t for t in vocabulary if " " not in t and len(t) >= 5]
    if not single_terms:
        return out
    tokens = out.split(" ")
    snapped: List[str] = []
    for tok in tokens:
        lead = ""
        for ch in tok:
            if not ch.isalnum():
                lead += ch
            else:
                break
        trail = ""
        for ch in reversed(tok):
            if not ch.isalnum():
                trail = ch + trail
            else:
                break
        core_end = len(tok) - len(trail) if trail else len(tok)
        core = tok[len(lead) : core_end]
        if len(core) < 5:
            snapped.append(tok)
            continue
        core_lower = core.lower()
        if core_lower in exact:
            snapped.append(lead + exact[core_lower] + trail)
            continue
        best_term: Optional[str] = None
        best_dist = 999
        for term in single_terms:
            tl = term.lower()
            if abs(len(tl) - len(core_lower)) > 2 or tl[0] != core_lower[0]:
                continue
            max_allowed = 2 if len(tl) >= 8 else 1
            d = levenshtein(core_lower, tl)
            if d <= max_allowed and d < best_dist:
                best_dist = d
                best_term = term
        snapped.append(lead + best_term + trail if best_term else tok)
    return " ".join(snapped)


def clean_spacing_and_punctuation(text: str) -> str:
    out = re.sub(r"[ \t]{2,}", " ", text)
    out = re.sub(r" *\n *", "\n", out)
    out = re.sub(r" +([.,!?;:])", r"\1", out)
    out = re.sub(r"^\s*[.,;:]+\s*", "", out)
    return out.strip()


def postprocess_transcript(
    text: str,
    language: str = "en",
    context: Optional[str] = None,
    vocabulary: Optional[Sequence[str]] = None,
    corrections: Optional[Dict[str, str]] = None,
    remove_disfluencies: bool = True,
    voice_commands: bool = False,
    convert_numbers: bool = False,
) -> str:
    if not text:
        return ""
    out = text.strip()
    if not out:
        return ""
    if voice_commands:
        out = apply_voice_commands(out, language=language)
    if remove_disfluencies:
        out = strip_disfluencies(out, language=language)
    if convert_numbers and language == "en":
        out = convert_spoken_numbers(out)
    vocab = list(vocabulary) if vocabulary is not None else load_vocabulary()
    rules = dict(corrections) if corrections is not None else load_corrections()
    if rules:
        out = apply_corrections(out, rules)
    if vocab:
        out = snap_to_vocabulary(out, vocab)
    if context and out:
        prev = context.strip()
        if prev and prev[-1] not in ".!?…:;\"')]\n":
            first_word = out.split(" ", 1)[0].strip(PUNCT_CHARS)
            vocab_lower = {v.lower() for v in vocab}
            if (
                first_word
                and first_word != "I"
                and not first_word.startswith("I'")
                and (not first_word.isupper() or len(first_word) == 1)
                and first_word.lower() not in vocab_lower
            ):
                out = out[0].lower() + out[1:]
    return clean_spacing_and_punctuation(out)


def join_and_process(
    chunks: Sequence[str],
    language: str = "en",
    vocabulary: Optional[Sequence[str]] = None,
    corrections: Optional[Dict[str, str]] = None,
    remove_disfluencies: bool = True,
    voice_commands: bool = False,
    convert_numbers: bool = False,
) -> str:
    non_empty = [c.strip() for c in chunks if c and c.strip()]
    if not non_empty:
        return ""
    vocab = list(vocabulary) if vocabulary is not None else load_vocabulary()
    vocab_lower = {v.lower() for v in vocab}
    joiner = language_joiner(language)
    merged = non_empty[0]

    for nxt_raw in non_empty[1:]:
        nxt = nxt_raw
        prev_trimmed = merged.rstrip()
        prev_ends_sentence = (not prev_trimmed) or (prev_trimmed[-1] in ".!?…:;\"')]\n")
        if not prev_ends_sentence:
            first_word = nxt.split(" ", 1)[0].strip(PUNCT_CHARS)
            if (
                first_word
                and first_word != "I"
                and not first_word.startswith("I'")
                and (not first_word.isupper() or len(first_word) == 1)
                and first_word.lower() not in vocab_lower
            ):
                nxt = nxt[0].lower() + nxt[1:]
        merged += joiner + nxt

    return postprocess_transcript(
        merged,
        language=language,
        vocabulary=vocab,
        corrections=corrections,
        remove_disfluencies=remove_disfluencies,
        voice_commands=voice_commands,
        convert_numbers=convert_numbers,
    )


def retain_recording_if_enabled(
    wav_bytes: bytes,
    raw_text: str,
    processed_text: str,
    language: str,
    duration_secs: float,
    infer_secs: float,
    home: Optional[str] = None,
) -> Optional[str]:
    if os.environ.get("VOICED_RETAIN_AUDIO") != "1":
        return None
    rec_dir = os.path.join(home or voice_home(), "recordings")
    os.makedirs(rec_dir, mode=0o700, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{time.time_ns() % 1_000_000_000:09d}"
    wav_path = os.path.join(rec_dir, f"{stamp}.wav")
    meta_path = os.path.join(rec_dir, f"{stamp}.json")
    meta: Dict[str, Any] = {
        "timestamp": time.time(),
        "language": language,
        "duration_secs": round(duration_secs, 3),
        "infer_secs": round(infer_secs, 3),
        "raw_text": raw_text,
        "processed_text": processed_text,
    }
    old_umask = os.umask(0o177)
    try:
        with open(wav_path, "wb") as wf:
            wf.write(wav_bytes)
        with open(meta_path, "w", encoding="utf-8") as mf:
            json.dump(meta, mf, ensure_ascii=False, indent=2)
    finally:
        os.umask(old_umask)
    return wav_path
