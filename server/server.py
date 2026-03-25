from __future__ import annotations

import asyncio
import os
import shutil
import tempfile  # used for temp WAV files in /transcribe
import threading
import time
from pathlib import Path

# Enable hf-transfer for faster parallel downloads.
# Progress is tracked via st_blocks (actual bytes written to disk) not st_size,
# because hf-transfer pre-allocates the full file size before writing chunks.
os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "1"

import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from huggingface_hub import snapshot_download
from pydantic import BaseModel

from llm import LLMResult, process_transcript
from transcriber import DEFAULT_MODEL, ModelNotReadyError, is_model_downloaded, transcribe_chunks

app = FastAPI(title="TranscribeMeeting Server", version="1.0.0")


# ── Health ─────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "version": "1.0.0"}


# ── Transcribe ─────────────────────────────────────────────────────────────────

@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form(DEFAULT_MODEL),
):
    """Receive a WAV file, return the transcript for the requested local model."""
    if not _get_model_info(model):
        raise HTTPException(status_code=404, detail="Model not found")
    if not is_model_downloaded(model):
        raise HTTPException(
            status_code=409,
            detail=f"Model '{model}' is not fully downloaded. Open Settings > Model and download it again.",
        )

    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        content = await file.read()
        tmp.write(content)
        tmp_path = Path(tmp.name)

    try:
        transcript = transcribe_chunks([tmp_path], model=model)
    except ModelNotReadyError as e:
        raise HTTPException(status_code=409, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        tmp_path.unlink(missing_ok=True)

    return {"transcript": transcript, "model": model}


# ── Summarise ──────────────────────────────────────────────────────────────────

class SummariseRequest(BaseModel):
    transcript: str
    api_key: str
    model: str = "claude-sonnet-4-6"


@app.post("/summarise")
def summarise(req: SummariseRequest):
    """Send a transcript to Claude, return cleaned transcript + summary."""
    if not req.transcript.strip():
        raise HTTPException(status_code=400, detail="Transcript is empty")
    try:
        result: LLMResult = process_transcript(req.transcript, req.api_key, req.model)
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))

    return {
        "cleaned_transcript": result.cleaned_transcript,
        "summary": result.summary,
    }


# ── Models ─────────────────────────────────────────────────────────────────────

AVAILABLE_MODELS = [
    {"id": "mlx-community/parakeet-tdt-0.6b-v3",  "label": "Parakeet 0.6B (English only, fastest)", "size_mb": 600},
    {"id": "mlx-community/whisper-large-v3-turbo", "label": "Whisper Large v3 Turbo (multilingual)", "size_mb": 809},
]

# HuggingFace cache where mlx-whisper stores downloaded models
_HF_CACHE = Path.home() / ".cache" / "huggingface" / "hub"

# In-memory progress tracking: model_id -> {downloaded_mb, total_mb, done, error}
_download_progress: dict[str, dict] = {}


def _get_model_info(model_id: str):
    return next((m for m in AVAILABLE_MODELS if m["id"] == model_id), None)


def _cleanup_partial_download(model_id: str):
    cache_key = "models--" + model_id.replace("/", "--")
    shutil.rmtree(_HF_CACHE / cache_key, ignore_errors=True)
    shutil.rmtree(_HF_CACHE / ".locks" / cache_key, ignore_errors=True)


@app.get("/models")
def list_models():
    """List available models and whether they are already downloaded."""
    result = []
    for m in AVAILABLE_MODELS:
        result.append({**m, "downloaded": is_model_downloaded(m["id"])})
    return {"models": result}


@app.post("/models/download")
async def download_model(model_id: str = Form(...)):
    """Download a model from HuggingFace. Streams progress via /models/download-progress."""
    model_info = _get_model_info(model_id)
    if not model_info:
        raise HTTPException(status_code=404, detail="Model not found")

    total_mb = model_info["size_mb"]
    if not is_model_downloaded(model_id):
        _cleanup_partial_download(model_id)
    _download_progress[model_id] = {"downloaded_mb": 0.0, "total_mb": total_mb, "done": False, "error": None}

    # Track progress by watching the HuggingFace cache directory size
    def track():
        cache_key = "models--" + model_id.replace("/", "--")
        cache_path = _HF_CACHE / cache_key
        while True:
            info = _download_progress.get(model_id)
            if info is None or info["done"]:
                return
            if cache_path.exists():
                try:
                    # Includes .incomplete files that grow during download
                    # Use st_blocks (actual disk blocks written) not st_size —
                    # hf-transfer pre-allocates the full file so st_size is
                    # always 100% from the start.
                    written = sum(f.stat().st_blocks * 512 for f in cache_path.rglob("*") if f.is_file())
                    if written > 0:
                        info["downloaded_mb"] = min(written / (1024 * 1024), total_mb)
                except Exception:
                    pass
            time.sleep(0.5)

    tracker = threading.Thread(target=track, daemon=True)
    tracker.start()

    try:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, lambda: snapshot_download(repo_id=model_id))
        if not is_model_downloaded(model_id):
            raise RuntimeError("Model download did not produce a usable local cache.")
        _download_progress[model_id].update({"downloaded_mb": float(total_mb), "done": True})
    except Exception as e:
        if model_id in _download_progress:
            _download_progress[model_id].update({"done": True, "error": str(e)})
        _cleanup_partial_download(model_id)
        _download_progress.pop(model_id, None)
        raise HTTPException(status_code=500, detail=str(e))

    return {"status": "ok", "model_id": model_id}


@app.get("/models/download-progress")
def download_progress(model_id: str):
    """Return current download progress for a model (0.0–1.0)."""
    info = _download_progress.get(model_id)
    if not info:
        return {"percent": 0.0, "downloaded_mb": 0.0, "total_mb": 0.0, "done": False, "error": None}
    total = info["total_mb"] or 1
    percent = min(info["downloaded_mb"] / total, 1.0)
    return {**info, "percent": percent}


# ── Entry point ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="info")
