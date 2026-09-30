# src/router/v2/transcribe_router.py
import logging
from typing import Literal

from fastapi import APIRouter, Depends, File, Response, UploadFile
from faster_whisper import WhisperModel

from src.auth import require_api_key
from src.state import get_lock, get_model

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/v2",
    tags=["v2"],
    dependencies=[Depends(require_api_key)],
)


@router.post("/transcribe", summary="Transcribe an audio file (v2)")
async def transcribe_v2(
    response: Response,
    audio: UploadFile = File(...),
    model: WhisperModel = Depends(get_model),
    lock=Depends(get_lock),
) -> dict[Literal["response", "status"], str]:
    async with lock:
        try:
            segments, info = model.transcribe(
                audio=audio.file,
                beam_size=1,
                vad_filter=True,
                condition_on_previous_text=False,
            )

            text = "".join(segment.text for segment in segments)
            return {"status": "ok", "response": text}
        except Exception:
            # Log the details, return a generic message: decoder
            # exceptions carry file paths and codec internals.
            logger.exception("transcription failed")
            response.status_code = 500
            return {"status": "error", "response": "transcription failed"}
