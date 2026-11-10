#!/usr/bin/env python3
"""Local Cohere Transcribe voice worker (Linux CrispASR Vulkan/KleidiAI + macOS MLX).

Speaks Protocol v1 (one JSON object per line, UTF-8) over stdio or via `voiced`:

    request  {"id": 1, "op": "hello"}
             {"id": 2, "op": "load"}
             {"id": 3, "op": "status"}
             {"id": 4, "op": "transcribe", "language": "en", "audio_bytes": N}
                 ... immediately followed by exactly N raw bytes: a PCM WAV
                 file (16-bit, mono preferred; other rates are resampled).
             {"id": 5, "op": "unload"}
             {"id": 6, "op": "shutdown"}
    response {"id": 1, "ok": true, "result": {...}}
             {"id": 1, "ok": false, "error": {"code": "...", "message": "..."}}

Audio never leaves the machine; logs contain durations and timings only.
"""

from __future__ import annotations

import os

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

import array
import ctypes
import glob
import io
import json
import math
import platform
import resource
import signal
import sys
import time
import wave
from typing import Any, BinaryIO, Dict, Optional, Tuple

PROTOCOL_VERSION = 1

if sys.platform == "darwin":
    MODEL_REPO = "MarkChen1214/cohere-transcribe-03-2026-MLX-Mixed-2bit3bit4bit"
    MODEL_REVISION = "553445e84959f9ec3fcd43443bce75ea05c400f3"
    GGUF_FILENAMES: Tuple[str, ...] = ()
else:
    MODEL_REPO = "cstr/cohere-transcribe-03-2026-GGUF"
    MODEL_REVISION = "4e98a8c31c95a92d651e60e3bfae4fe29fc6e026"
    GGUF_FILENAMES = (
        "cohere-transcribe-q4_k.gguf",
        "cohere-transcribe-q5_0.gguf",
        "cohere-transcribe-q5_1.gguf",
        "cohere-transcribe-q6_k.gguf",
        "cohere-transcribe-q8_0.gguf",
        "cohere-transcribe.gguf",
    )

SUPPORTED_LANGUAGES = (
    "en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "vi", "ko",
)

DEFAULT_MAX_SECS = 120.0
MIN_SECS = 0.15
TARGET_SAMPLE_RATE = 16000
MAX_HEADER_BYTES = 64 * 1024

SILENCE_PEAK = 64
SILENCE_RMS = 16.0


class WorkerError(Exception):
    def __init__(self, code: str, message: str, req_id: Any = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.req_id = req_id


class ProtocolError(WorkerError):
    """The stream can no longer be trusted to be framed; answer, then exit."""


def log(msg: str) -> None:
    sys.stderr.write(f"[orb-voice] {msg}\n")
    sys.stderr.flush()


def default_model_dir() -> str:
    hub = os.environ.get("HF_HUB_CACHE")
    if not hub:
        hub = os.path.join(
            os.environ.get("HF_HOME") or os.path.expanduser("~/.cache/huggingface"),
            "hub",
        )
    repo_dir = "models--" + MODEL_REPO.replace("/", "--")
    snap = os.path.join(hub, repo_dir, "snapshots", MODEL_REVISION)
    if os.path.isdir(snap):
        return snap
    snaps_root = os.path.join(hub, repo_dir, "snapshots")
    if os.path.isdir(snaps_root):
        try:
            entries = sorted(os.listdir(snaps_root))
            if entries:
                return os.path.join(snaps_root, entries[-1])
        except OSError:
            pass
    return snap


def resolve_model_dir() -> str:
    return os.environ.get("ORB_VOICE_MODEL_DIR") or default_model_dir()


def resolve_gguf_file(model_dir: str) -> Optional[str]:
    explicit = os.environ.get("VOICED_GGUF_FILE")
    if explicit and os.path.isfile(explicit):
        return explicit
    if os.path.isfile(model_dir) and model_dir.endswith(".gguf"):
        return model_dir
    for name in GGUF_FILENAMES:
        cand = os.path.join(model_dir, name)
        if os.path.isfile(cand):
            return cand
    if os.path.isdir(model_dir):
        found = sorted(glob.glob(os.path.join(model_dir, "*.gguf")))
        if found:
            return found[0]
    return None


def model_present(model_dir: str) -> bool:
    if sys.platform == "darwin":
        return all(
            os.path.exists(os.path.join(model_dir, f))
            for f in ("config.json", "model.safetensors")
        )
    return resolve_gguf_file(model_dir) is not None or all(
        os.path.exists(os.path.join(model_dir, f))
        for f in ("config.json", "model.safetensors")
    )


def max_seconds() -> float:
    raw = os.environ.get("ORB_VOICE_MAX_SECS")
    if raw is None:
        return DEFAULT_MAX_SECS
    try:
        secs = float(raw)
    except ValueError:
        return DEFAULT_MAX_SECS
    if not math.isfinite(secs) or secs <= 0:
        return DEFAULT_MAX_SECS
    return min(secs, DEFAULT_MAX_SECS)


def decode_wav(data: bytes) -> Tuple[array.array, int]:
    try:
        with wave.open(io.BytesIO(data), "rb") as wf:
            channels = wf.getnchannels()
            width = wf.getsampwidth()
            rate = wf.getframerate()
            frames = wf.getnframes()
            raw = wf.readframes(frames)
    except (wave.Error, EOFError) as e:
        raise WorkerError("bad_wav", f"not a PCM WAV file: {e}") from None
    if width != 2:
        raise WorkerError("bad_wav", f"expected 16-bit PCM, got {width * 8}-bit")
    if channels < 1 or rate <= 0:
        raise WorkerError("bad_wav", "invalid channel count or sample rate")
    samples = array.array("h")
    samples.frombytes(raw[: (len(raw) // (2 * channels)) * 2 * channels])
    if sys.byteorder != "little":
        samples.byteswap()
    if channels > 1:
        mono = array.array("h", bytes(len(samples) // channels * 2))
        for i in range(len(mono)):
            base = i * channels
            mono[i] = int(sum(samples[base : base + channels]) / channels)
        samples = mono
    return samples, rate


def resample_to_16k_f32(samples: array.array, rate: int) -> Tuple[ctypes.Array[ctypes.c_float], int]:
    n_in = len(samples)
    if n_in == 0:
        return (ctypes.c_float * 0)(), 0
    if rate == TARGET_SAMPLE_RATE:
        arr = (ctypes.c_float * n_in)(*(s / 32768.0 for s in samples))
        return arr, n_in
    ratio = rate / float(TARGET_SAMPLE_RATE)
    n_out = max(1, int(round(n_in / ratio)))
    arr = (ctypes.c_float * n_out)()
    last = n_in - 1
    for i in range(n_out):
        pos = i * ratio
        i0 = int(pos)
        i1 = min(i0 + 1, last)
        t = pos - i0
        v = samples[i0] * (1.0 - t) + samples[i1] * t
        arr[i] = v / 32768.0
    return arr, n_out


def check_duration(samples: array.array, rate: int) -> float:
    secs = len(samples) / float(rate)
    if secs > max_seconds():
        raise WorkerError("audio_too_long", f"{secs:.1f}s exceeds the {max_seconds():.0f}s limit")
    return secs


def signal_level(samples: array.array) -> Tuple[int, float]:
    if not samples:
        return 0, 0.0
    peak = max(abs(max(samples)), abs(min(samples)))
    if hasattr(math, "sumprod"):
        energy = math.sumprod(samples, samples)
    else:
        energy = sum(s * s for s in samples)
    return peak, math.sqrt(energy / len(samples))


def is_silent(samples: array.array) -> bool:
    peak, rms = signal_level(samples)
    return peak <= SILENCE_PEAK and rms <= SILENCE_RMS


class FakeBackend:
    """Deterministic stand-in for protocol & cancellation tests."""

    name = "fake"

    def __init__(self) -> None:
        self.loaded = False
        self.model_dir = resolve_model_dir()

    def load(self) -> Dict[str, Any]:
        self.loaded = True
        return {"load_secs": 0.0, "warmup_secs": 0.0}

    def transcribe(self, samples: array.array, rate: int, language: str, punctuation: bool) -> str:
        secs = len(samples) / float(rate)
        peak = max((abs(s) for s in samples), default=0)
        if peak == 0:
            return ""
        return f"[fake {language}] {secs:.2f}s peak={peak}"

    def unload(self) -> None:
        self.loaded = False

    def stats(self) -> Dict[str, Any]:
        return {"peak_memory_bytes": 0}


class _CohereContextParams(ctypes.Structure):
    _fields_ = [
        ("n_threads", ctypes.c_int),
        ("use_flash", ctypes.c_bool),
        ("use_gpu", ctypes.c_bool),
        ("no_punctuation", ctypes.c_bool),
        ("diarize", ctypes.c_bool),
        ("verbosity", ctypes.c_int),
    ]


class CrispCohereBackend:
    """Native C++ / GGML Cohere Transcribe backend (Apple M2 Honeykrisp Vulkan + ARMv8.6 KleidiAI)."""

    name = "crispasr-gguf"

    def __init__(self) -> None:
        self.loaded = False
        self.ctx: Optional[int] = None
        self.ctx_no_punc: Optional[bool] = None
        self.lib: Any = None
        self.libc: Any = None
        self.model_dir = resolve_model_dir()

    def _ensure_vulkan_icd(self) -> None:
        if os.environ.get("VK_ICD_FILENAMES") or os.environ.get("VK_DRIVER_FILES"):
            return
        icd_dir = "/run/opengl-driver/share/vulkan/icd.d"
        if os.path.isdir(icd_dir):
            asahi = os.path.join(icd_dir, "asahi_icd.aarch64.json")
            if os.path.isfile(asahi):
                os.environ["VK_ICD_FILENAMES"] = asahi
                return
            jsons = sorted(glob.glob(os.path.join(icd_dir, "*.json")))
            if jsons:
                os.environ["VK_ICD_FILENAMES"] = ":".join(jsons)

    def _default_threads(self) -> int:
        raw = os.environ.get("VOICED_THREADS") or os.environ.get("CRISPASR_COHERE_THREADS")
        if raw:
            try:
                return max(1, int(raw))
            except ValueError:
                pass
        # Count high-capacity P-cores when heterogeneous (e.g. 4 Avalanche P-cores on Apple M2)
        pcores = 0
        for cpu in range(os.cpu_count() or 4):
            try:
                with open(f"/sys/devices/system/cpu/cpu{cpu}/cpu_capacity", "r", encoding="utf-8") as f:
                    if int(f.read().strip()) >= 900:
                        pcores += 1
            except OSError:
                break
        if pcores > 0:
            return pcores
        return min(8, max(1, (os.cpu_count() or 4)))

    def _load_lib(self):
        if self.lib is not None:
            return self.lib
        self._ensure_vulkan_icd()
        lib_path = os.environ.get("VOICED_COHERE_LIB") or "@CRISPASR_LIB@"
        if not os.path.isfile(lib_path):
            raise WorkerError(
                "deps_missing",
                f"libcohere_asr.so not found at {lib_path}. Ensure crispasr-cohere is installed.",
            )
        lib = ctypes.CDLL(lib_path)
        libc = ctypes.CDLL("libc.so.6")
        libc.free.argtypes = [ctypes.c_void_p]
        libc.free.restype = None
        if hasattr(libc, "malloc_trim"):
            libc.malloc_trim.argtypes = [ctypes.c_size_t]
            libc.malloc_trim.restype = ctypes.c_int

        lib.cohere_context_default_params.argtypes = []
        lib.cohere_context_default_params.restype = _CohereContextParams
        lib.cohere_init_from_file.argtypes = [ctypes.c_char_p, _CohereContextParams]
        lib.cohere_init_from_file.restype = ctypes.c_void_p
        lib.cohere_free.argtypes = [ctypes.c_void_p]
        lib.cohere_free.restype = None
        lib.cohere_transcribe.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_float),
            ctypes.c_int,
            ctypes.c_char_p,
        ]
        lib.cohere_transcribe.restype = ctypes.c_void_p

        self.lib = lib
        self.libc = libc
        return lib

    def _init_ctx(self, no_punctuation: bool) -> float:
        self.model_dir = resolve_model_dir()
        gguf_path = resolve_gguf_file(self.model_dir)
        if not gguf_path:
            raise WorkerError(
                "model_missing",
                f"GGUF model not found in {self.model_dir}. Run `murmure download-model`.",
            )
        lib = self._load_lib()
        if self.ctx:
            lib.cohere_free(self.ctx)
            self.ctx = None
        params = lib.cohere_context_default_params()
        params.n_threads = self._default_threads()
        params.use_gpu = os.environ.get("VOICED_GPU", "1") != "0"
        params.use_flash = os.environ.get("VOICED_FLASH", "1") != "0"
        params.no_punctuation = no_punctuation
        params.diarize = False
        params.verbosity = int(os.environ.get("VOICED_VERBOSITY", "0"))

        t0 = time.perf_counter()
        ctx = lib.cohere_init_from_file(gguf_path.encode("utf-8"), params)
        if not ctx and params.use_gpu:
            log("Vulkan GPU init failed; retrying on CPU backend")
            params.use_gpu = False
            ctx = lib.cohere_init_from_file(gguf_path.encode("utf-8"), params)
        if not ctx:
            raise WorkerError("internal", f"failed to initialize Cohere GGUF model from {gguf_path}")
        self.ctx = ctx
        self.ctx_no_punc = no_punctuation
        self.loaded = True
        return time.perf_counter() - t0

    def load(self) -> Dict[str, Any]:
        if self.loaded and self.ctx:
            return {"load_secs": 0.0, "warmup_secs": 0.0, "cached": True}
        load_secs = self._init_ctx(no_punctuation=False)
        warm = 0.0
        if os.environ.get("ORB_VOICE_WARMUP", "1") != "0":
            t1 = time.perf_counter()
            n_warm = TARGET_SAMPLE_RATE
            tone = (ctypes.c_float * n_warm)(
                *(0.02 * math.sin(2.0 * math.pi * 440.0 * i / TARGET_SAMPLE_RATE) for i in range(n_warm))
            )
            try:
                ptr = self.lib.cohere_transcribe(self.ctx, tone, n_warm, b"en")
                if ptr:
                    self.libc.free(ptr)
            except Exception as e:
                log(f"warm-up failed: {e}")
            warm = time.perf_counter() - t1
        log(f"model loaded in {load_secs:.3f}s (warm-up {warm:.3f}s) from {self.model_dir}")
        return {"load_secs": round(load_secs, 3), "warmup_secs": round(warm, 3), "cached": False}

    def transcribe(self, samples: array.array, rate: int, language: str, punctuation: bool) -> str:
        want_no_punc = not punctuation
        if not self.loaded or not self.ctx or self.ctx_no_punc != want_no_punc:
            self._init_ctx(no_punctuation=want_no_punc)
        arr, n_samples = resample_to_16k_f32(samples, rate)
        if n_samples <= 0:
            return ""
        ptr = self.lib.cohere_transcribe(self.ctx, arr, n_samples, language.encode("utf-8"))
        if not ptr:
            return ""
        try:
            text = ctypes.string_at(ptr).decode("utf-8", errors="replace")
        finally:
            self.libc.free(ptr)
        return text.strip()

    def unload(self) -> None:
        if self.lib is not None and self.ctx:
            try:
                self.lib.cohere_free(self.ctx)
            except Exception:
                pass
        self.ctx = None
        self.ctx_no_punc = None
        self.loaded = False
        if self.libc is not None and hasattr(self.libc, "malloc_trim"):
            try:
                self.libc.malloc_trim(0)
            except Exception:
                pass

    def stats(self) -> Dict[str, Any]:
        rss_kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        return {"peak_memory_bytes": int(rss_kb * 1024)}


class MlxBackend:
    """macOS Apple Silicon MLX backend."""

    name = "mlx"

    def __init__(self) -> None:
        self.loaded = False
        self.model = None
        self.model_dir = resolve_model_dir()

    def _import(self):
        try:
            import mlx.core as mx  # noqa: F401
            import numpy as np  # noqa: F401
            from mlx_audio.stt import load
        except ImportError as e:
            raise WorkerError("deps_missing", f"mlx-audio not importable: {e}") from None
        return load

    def load(self) -> Dict[str, Any]:
        if self.loaded:
            return {"load_secs": 0.0, "warmup_secs": 0.0, "cached": True}
        if not model_present(self.model_dir):
            raise WorkerError("model_missing", f"model snapshot not found at {self.model_dir}")
        load = self._import()
        t0 = time.perf_counter()
        self.model = load(self.model_dir)
        load_secs = time.perf_counter() - t0
        self.loaded = True
        return {"load_secs": round(load_secs, 3), "warmup_secs": 0.0, "cached": False}

    def transcribe(self, samples: array.array, rate: int, language: str, punctuation: bool) -> str:
        import numpy as np

        audio = np.frombuffer(samples.tobytes(), dtype=np.int16).astype(np.float32) / 32768.0
        result = self.model.generate(audio=audio, sample_rate=rate, language=language, punctuation=punctuation)
        return (result.text or "").strip()

    def unload(self) -> None:
        self.model = None
        self.loaded = False

    def stats(self) -> Dict[str, Any]:
        return {"peak_memory_bytes": None}


def make_backend():
    if os.environ.get("ORB_VOICE_FAKE") == "1":
        return FakeBackend()
    if sys.platform == "darwin":
        return MlxBackend()
    return CrispCohereBackend()


class Worker:
    def __init__(self, backend=None) -> None:
        self.backend = backend or make_backend()
        self.started = time.time()
        self.requests = 0
        self.transcriptions = 0
        self.last_infer_secs: Optional[float] = None

    def handle(self, req: Dict[str, Any], payload: bytes) -> Dict[str, Any]:
        op = req.get("op")
        self.requests += 1
        if op == "hello":
            self.backend.model_dir = resolve_model_dir()
            return {
                "protocol": PROTOCOL_VERSION,
                "backend": self.backend.name,
                "python": platform.python_version(),
                "platform": sys.platform,
                "machine": platform.machine(),
                "model_repo": MODEL_REPO,
                "model_revision": MODEL_REVISION,
                "model_dir": self.backend.model_dir,
                "model_present": model_present(self.backend.model_dir),
                "languages": list(SUPPORTED_LANGUAGES),
                "max_seconds": max_seconds(),
            }
        if op == "load":
            return {"loaded": True, **self.backend.load()}
        if op == "status":
            return {
                "loaded": self.backend.loaded,
                "uptime_secs": round(time.time() - self.started, 1),
                "requests": self.requests,
                "transcriptions": self.transcriptions,
                "last_infer_secs": self.last_infer_secs,
                **self.backend.stats(),
            }
        if op == "transcribe":
            return self.transcribe(req, payload)
        if op == "unload":
            self.backend.unload()
            return {"loaded": False}
        if op == "shutdown":
            return {"bye": True}
        raise WorkerError("bad_request", f"unknown op {op!r}")

    def transcribe(self, req: Dict[str, Any], payload: bytes) -> Dict[str, Any]:
        language = req.get("language") or "en"
        if not isinstance(language, str) or language not in SUPPORTED_LANGUAGES:
            raise WorkerError(
                "unsupported_language",
                f"language {language!r} is not one of {', '.join(SUPPORTED_LANGUAGES)}",
            )
        punctuation = bool(req.get("punctuation", True))
        context = req.get("context")
        if context is not None and not isinstance(context, str):
            raise WorkerError("bad_request", "context must be a string")
        vocabulary = req.get("vocabulary")
        if vocabulary is not None:
            if not isinstance(vocabulary, list) or not all(isinstance(x, str) for x in vocabulary):
                raise WorkerError("bad_request", "vocabulary must be a list of strings")
        if not payload:
            raise WorkerError("bad_request", "transcribe needs audio_bytes")
        samples, rate = decode_wav(payload)
        secs = check_duration(samples, rate)
        load_info = {}
        if not self.backend.loaded:
            load_info = self.backend.load()
        infer = 0.0
        raw_text = ""
        if secs < MIN_SECS or is_silent(samples):
            text = ""
        else:
            t0 = time.perf_counter()
            raw_text = self.backend.transcribe(samples, rate, language, punctuation)
            infer = time.perf_counter() - t0
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import pipeline as vp

            text = vp.postprocess_transcript(
                raw_text,
                language=language,
                context=context,
                vocabulary=vocabulary,
            )
            vp.retain_recording_if_enabled(
                wav_bytes=payload,
                raw_text=raw_text,
                processed_text=text,
                language=language,
                duration_secs=secs,
                infer_secs=infer,
            )
        self.transcriptions += 1
        self.last_infer_secs = round(infer, 3)
        log(f"transcribe {secs:.2f}s audio lang={language} infer={infer:.3f}s chars={len(text)}")
        return {
            "text": text,
            "language": language,
            "duration_secs": round(secs, 3),
            "sample_rate": rate,
            "infer_secs": round(infer, 3),
            "load_secs": load_info.get("load_secs", 0.0),
        }


def read_exact(stream: BinaryIO, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            raise WorkerError("bad_request", f"audio payload truncated ({len(buf)}/{n} bytes)")
        buf.extend(chunk)
    return bytes(buf)


def payload_hard_cap() -> int:
    return int(max_seconds() * 4 * 48000) + 1_000_000


def read_request(stream: BinaryIO) -> Optional[Tuple[Dict[str, Any], bytes]]:
    line = stream.readline(MAX_HEADER_BYTES + 1)
    if not line:
        return None
    if len(line) > MAX_HEADER_BYTES or (len(line) == MAX_HEADER_BYTES and not line.endswith(b"\n")):
        raise ProtocolError("bad_request", f"header line exceeds {MAX_HEADER_BYTES} bytes")
    line = line.strip()
    if not line:
        return {}, b""
    try:
        req = json.loads(line.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        raise WorkerError("bad_request", f"malformed JSON frame: {e}") from None
    if not isinstance(req, dict):
        raise WorkerError("bad_request", "frame must be a JSON object")
    n = req.get("audio_bytes", 0)
    if not isinstance(n, int) or n < 0:
        raise WorkerError("bad_request", "audio_bytes must be a non-negative integer")
    if n > payload_hard_cap():
        raise ProtocolError("audio_too_long", f"payload of {n} bytes exceeds the hard cap", req.get("id"))
    payload = read_exact(stream, n) if n else b""
    return req, payload


def write_response(stream: BinaryIO, obj: Dict[str, Any]) -> None:
    stream.write((json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
    stream.flush()


def serve(stdin: BinaryIO, stdout: BinaryIO, worker: Optional[Worker] = None) -> int:
    worker = worker or Worker()
    log(f"worker ready pid={os.getpid()} backend={worker.backend.name} python={sys.executable}")
    while True:
        req_id: Any = None
        try:
            frame = read_request(stdin)
            if frame is None:
                log("stdin closed; exiting")
                return 0
            req, payload = frame
            if not req:
                continue
            req_id = req.get("id")
            result = worker.handle(req, payload)
            write_response(stdout, {"id": req_id, "ok": True, "result": result})
            if req.get("op") == "shutdown":
                return 0
        except ProtocolError as e:
            rid = e.req_id if e.req_id is not None else req_id
            write_response(stdout, {"id": rid, "ok": False, "error": {"code": e.code, "message": e.message}})
            log(f"protocol violation, exiting: {e.message}")
            return 2
        except WorkerError as e:
            rid = e.req_id if e.req_id is not None else req_id
            write_response(stdout, {"id": rid, "ok": False, "error": {"code": e.code, "message": e.message}})
        except MemoryError:
            write_response(stdout, {"id": req_id, "ok": False, "error": {"code": "internal", "message": "out of memory"}})
            return 3
        except Exception as e:
            log(f"unhandled error: {type(e).__name__}: {e}")
            write_response(
                stdout,
                {"id": req_id, "ok": False, "error": {"code": "internal", "message": f"{type(e).__name__}: {e}"}},
            )


def main() -> int:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    except (AttributeError, ValueError):
        pass
    worker = Worker()
    try:
        return serve(sys.stdin.buffer, sys.stdout.buffer, worker=worker)
    except (KeyboardInterrupt, SystemExit):
        return 0
    finally:
        try:
            worker.backend.unload()
        except Exception:
            pass


if __name__ == "__main__":
    rc = main()
    try:
        sys.stdout.flush()
        sys.stderr.flush()
    except Exception:
        pass
    os._exit(rc)
