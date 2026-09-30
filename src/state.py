# src/state.py
import asyncio
import logging
import os

from dotenv import load_dotenv
from faster_whisper import WhisperModel

load_dotenv()

logger = logging.getLogger(__name__)

MODEL_SIZE = os.getenv("MODEL_SIZE", "large-v3-turbo")
MODELS_DIR = os.getenv("MODELS_DIR", "whisper_models")
CPU_THREADS = int(os.getenv("CPU_THREADS", "2"))
COMPUTE_TYPE = os.getenv("COMPUTE_TYPE", "int8")

model: WhisperModel | None = None
lock: asyncio.Lock | None = None


def load_model() -> WhisperModel:
    """Load the model once and keep it in memory.

    Called from the lifespan handler so the first request does not
    pay for the download and initialisation.
    """
    global model
    if model is None:
        logger.info(
            "Loading model=%s (cpu, %s, %d threads)",
            MODEL_SIZE,
            COMPUTE_TYPE,
            CPU_THREADS,
        )
        model = WhisperModel(
            model_size_or_path=MODEL_SIZE,
            device="cpu",
            compute_type=COMPUTE_TYPE,
            cpu_threads=CPU_THREADS,
            num_workers=1,
            download_root=MODELS_DIR,
            local_files_only=False,
        )
    return model


def get_model() -> WhisperModel:
    return load_model()


def get_lock() -> asyncio.Lock:
    """Serialise transcriptions.

    One CTranslate2 model instance is not meant to be driven
    concurrently, and on a small CPU box parallel requests would only
    make every request slower.
    """
    global lock
    if lock is None:
        lock = asyncio.Lock()
    return lock
