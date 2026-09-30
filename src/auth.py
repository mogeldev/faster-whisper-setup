# src/auth.py
import os
import secrets

from dotenv import load_dotenv
from fastapi import Header, HTTPException, status

load_dotenv()

# No default on purpose: without a key the service refuses to start,
# so it can never end up on the internet unprotected by accident.
API_KEY = os.getenv("API_KEY")
if not API_KEY:
    raise RuntimeError(
        "API_KEY is not set. Generate one with 'openssl rand -hex 32' "
        "and put it in .env (template: .env.example)."
    )


def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    """Validate the X-API-Key header in constant time.

    A missing key and a wrong key both return 401 so the response
    does not tell an attacker which of the two it was.
    """
    if x_api_key is None or not secrets.compare_digest(x_api_key, API_KEY):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid api key",
        )
