# src/app.py
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, status
from fastapi.responses import JSONResponse

from src.state import get_lock, load_model
from src.router.v2.transcribe_router import router as v2_router

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    get_lock()
    load_model()
    yield


app = FastAPI(
    title="faster-whisper-fastapi",
    version="2.0.0",
    lifespan=lifespan,
    # Interactive docs and schema are off: the service is meant to be
    # reachable from the internet behind a reverse proxy.
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

app.include_router(v2_router)


@app.get("/health")
def health():
    """Unauthenticated so monitoring works without the API key."""
    return {"status": "ok"}


@app.exception_handler(Exception)
def handle_exception(request: Request, exc: Exception):
    # Details go to the log only. str(exc) leaks file paths and
    # internal state to the caller.
    logger.exception("unhandled error on %s", request.url.path)
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={"detail": "internal server error"},
    )
