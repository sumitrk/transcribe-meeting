from __future__ import annotations

from pathlib import Path

import mlx_whisper
import numpy as np
import soundfile as sf

_HF_CACHE = Path.home() / ".cache" / "huggingface" / "hub"
MODEL_CACHE = Path.home() / "Library" / "Application Support" / "TranscribeMeeting" / "models"


def _model_is_cached(model_repo: str) -> bool:
    """Check if the HuggingFace model is already downloaded locally."""
    cache_name = "models--" + model_repo.replace("/", "--")
    return (_HF_CACHE / cache_name).exists()


def transcribe_chunks(chunk_paths: list[Path], model: str) -> str:
    """
    Transcribe a list of WAV chunk files in order.
    Returns the concatenated raw transcript string.
    """
    if not chunk_paths:
        return ""

    if not _model_is_cached(model):
        print(f"First run: downloading Whisper model '{model}'...", flush=True)
        size_hint = "~809 MB for large-v3-turbo" if "turbo" in model else (
            "~3 GB for large-v3" if "large" in model else "~150 MB for small"
        )
        print(f"This may take a few minutes ({size_hint}).", flush=True)

    total = len(chunk_paths)
    texts: list[str] = []

    for i, path in enumerate(chunk_paths, start=1):
        print(f"Transcribing chunk {i}/{total}: {path.name}...", flush=True)
        # Load audio with soundfile (no ffmpeg needed — works directly with our WAV files).
        # mlx_whisper.transcribe() accepts a float32 numpy array at 16 kHz.
        audio, sr = sf.read(str(path), dtype="float32", always_2d=False)
        if audio.ndim > 1:
            audio = audio.mean(axis=1)          # stereo → mono
        if sr != 16000:
            # Simple resample via numpy (only needed if something changed the WAV)
            ratio = 16000 / sr
            out_len = int(len(audio) * ratio)
            indices = np.linspace(0, len(audio) - 1, out_len)
            audio = np.interp(indices, np.arange(len(audio)), audio).astype(np.float32)
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=model,
            verbose=False,
        )
        text = result.get("text", "").strip()
        texts.append(text)

    return "\n".join(texts)
