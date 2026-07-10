import logging
import os
from typing import Mapping

import firebase_admin
from firebase_admin import auth as firebase_auth
from firebase_admin import credentials

from pathlib import Path

logger = logging.getLogger(__name__)


BASE_DIR = Path(__file__).resolve().parent  # folder containing auth.py

def initialize_firebase() -> None:
    if getattr(firebase_admin, "_apps", None):
        return

    credential_path = os.getenv("FIREBASE_CREDENTIALS_PATH") or os.getenv(
        "GOOGLE_APPLICATION_CREDENTIALS"
    )

    print(f"Credential Path: {credential_path}")

    project_id = os.getenv("FIREBASE_PROJECT_ID") or os.getenv("GOOGLE_CLOUD_PROJECT")

    if credential_path:
        # Resolve relative paths against the project root (parent of this file's dir),
        # not whatever directory the process happened to be launched from.
        resolved = Path(credential_path)
        
        print(f"Credential Path: {credential_path}")
        print(f"Resolved Path: {resolved}")

        if not resolved.is_absolute():
            resolved = (BASE_DIR / credential_path).resolve()

        print(f"Final Resolved Path: {resolved}")

        if resolved.exists():
            options = {"projectId": project_id} if project_id else None
            firebase_admin.initialize_app(credentials.Certificate(str(resolved)), options)
            return
        else:
            logger.error("Firebase credential file not found at resolved path: %s", resolved)

    if project_id:
        firebase_admin.initialize_app(options={"projectId": project_id})
        return

    logger.error(
        "Firebase Admin SDK not initialized: no credentials or project ID found."
    )


def extract_auth_token(headers: Mapping[str, str] | None = None) -> str | None:
    """Extract a bearer token from the websocket Authorization header."""
    headers = dict(headers or {})

    authorization = headers.get("authorization") or headers.get("Authorization")
    if authorization:
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() == "bearer" and token:
            return token

    return None


def verify_firebase_token(token: str) -> str:
    """Verify a Firebase ID token and return the decoded uid."""
    if not token:
        raise ValueError("missing auth token")

    try:
        decoded = firebase_auth.verify_id_token(token)
    except Exception as exc:  # pragma: no cover - uses external SDK
        raise ValueError(f"invalid auth token: {exc}") from exc

    uid = decoded.get("uid")
    if not uid:
        raise ValueError("token missing uid")

    return str(uid)


def authenticate_websocket(headers: Mapping[str, str] | None = None) -> str:
    """Authenticate a websocket connection and return the verified user id."""
    if os.getenv("AUTH_BYPASS", "").lower() in {"1", "true", "yes", "on"}:
        return "local-dev"

    token = extract_auth_token(headers=headers)
    if not token:
        raise ValueError("missing auth token")

    return verify_firebase_token(token)
