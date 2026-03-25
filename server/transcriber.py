from __future__ import annotations

from pathlib import Path

from huggingface_hub import snapshot_download
from huggingface_hub.errors import LocalEntryNotFoundError
from mlx_audio.stt.utils import load_model as load_stt

DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"

# Module-level model cache so we only load each resolved model once per server process
_models: dict[str, object] = {}


class ModelNotReadyError(RuntimeError):
    pass


def _resolve_cached_model_path(model_repo: str) -> Path | None:
    try:
        model_path = Path(snapshot_download(repo_id=model_repo, local_files_only=True))
    except LocalEntryNotFoundError:
        return None

    if not model_path.exists():
        return None

    has_weights = any(model_path.glob("*.safetensors"))
    has_config = any(model_path.glob("*.json"))
    return model_path if has_weights and has_config else None


def is_model_downloaded(model_repo: str) -> bool:
    return _resolve_cached_model_path(model_repo) is not None


def _require_cached_model_path(model_repo: str) -> Path:
    model_path = _resolve_cached_model_path(model_repo)
    if model_path is None:
        raise ModelNotReadyError(
            f"Model '{model_repo}' is not fully downloaded. Open Settings > Model and download it again."
        )
    return model_path


def _get_model(model_repo: str):
    if model_repo not in _models:
        model_path = _require_cached_model_path(model_repo)
        print(f"Loading STT model: {model_repo}", flush=True)
        _models[model_repo] = load_stt(str(model_path))
    return _models[model_repo]


def transcribe_chunks(chunk_paths: list[Path], model: str = DEFAULT_MODEL) -> str:
    """
    Transcribe a list of WAV chunk files using Parakeet via mlx-audio.
    Returns the concatenated transcript string.
    """
    if not chunk_paths:
        return ""

    stt = _get_model(model)
    total = len(chunk_paths)
    texts: list[str] = []

    for i, path in enumerate(chunk_paths, start=1):
        print(f"Transcribing chunk {i}/{total}: {path.name}...", flush=True)
        result = stt.generate(str(path))
        text = result.text.strip()
        texts.append(text)
        print(f"  → {text[:80]}{'...' if len(text) > 80 else ''}", flush=True)

    return "\n".join(texts)
