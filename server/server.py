from __future__ import annotations

import tempfile
from pathlib import Path

import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from pydantic import BaseModel

from llm import LLMResult, process_transcript
from transcriber import transcribe_chunks

app = FastAPI(title="TranscribeMeeting Server", version="1.0.0")


# ── Health ─────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "version": "1.0.0"}


# ── Transcribe ─────────────────────────────────────────────────────────────────

@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
):
    """Receive a WAV file, return the transcript via Parakeet."""
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        content = await file.read()
        tmp.write(content)
        tmp_path = Path(tmp.name)

    try:
        transcript = transcribe_chunks([tmp_path])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        tmp_path.unlink(missing_ok=True)

    return {"transcript": transcript, "model": "mlx-community/parakeet-tdt-0.6b-v3"}


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

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"

AVAILABLE_MODELS = [
    {"id": "mlx-community/parakeet-tdt-0.6b-v3",   "label": "Parakeet 0.6B (English only, fastest)", "size_mb": 600},
    {"id": "mlx-community/whisper-tiny-mlx",        "label": "Whisper Tiny (multilingual)",           "size_mb": 40},
    {"id": "mlx-community/whisper-small-mlx",       "label": "Whisper Small (multilingual)",          "size_mb": 150},
    {"id": "mlx-community/whisper-large-v3-turbo",  "label": "Whisper Large v3 Turbo (multilingual)", "size_mb": 809},
    {"id": "mlx-community/whisper-large-v3-mlx",    "label": "Whisper Large v3 (multilingual)",       "size_mb": 3000},
]

# HuggingFace cache where mlx-whisper stores downloaded models
_HF_CACHE = Path.home() / ".cache" / "huggingface" / "hub"


@app.get("/models")
def list_models():
    """List available Whisper models and whether they are already downloaded."""
    result = []
    for m in AVAILABLE_MODELS:
        cache_name = "models--" + m["id"].replace("/", "--")
        downloaded = (_HF_CACHE / cache_name).exists()
        result.append({**m, "downloaded": downloaded})
    return {"models": result}


# ── Entry point ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="info")
