"""Signed, resource-bound launch grants for host-local Moonlight streams."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
import time

ROUTE_RE = re.compile(r"^(?:seat-[0-9a-f]{24}|vm-[a-z0-9][a-z0-9._-]{0,62})$")


def _b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _unb64(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def issue_grant(key: bytes, *, route: str, user: str, path: str, now: int | None = None) -> str:
    if not ROUTE_RE.fullmatch(route):
        raise ValueError("Invalid stream route")
    if not user or len(user) > 128 or not re.fullmatch(r"[a-zA-Z0-9_.:@-]+", user):
        raise ValueError("Invalid stream user")
    if not path.startswith(f"/EpicVM/{route}/") or path.startswith("//"):
        raise ValueError("Stream path does not belong to the route")
    timestamp = int(time.time() if now is None else now)
    payload = {"v": 1, "route": route, "sub": user, "path": path,
               "iat": timestamp, "exp": timestamp + 60, "jti": secrets.token_hex(16)}
    encoded = _b64(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())
    signature = _b64(hmac.digest(key, encoded.encode(), hashlib.sha256))
    return encoded + "." + signature


def verify_grant(key: bytes, token: str, *, now: int | None = None) -> dict:
    try:
        encoded, signature = token.split(".", 1)
        expected = _b64(hmac.digest(key, encoded.encode(), hashlib.sha256))
        if not hmac.compare_digest(signature, expected):
            raise ValueError("Invalid signature")
        payload = json.loads(_unb64(encoded))
        timestamp = int(time.time() if now is None else now)
        if payload.get("v") != 1 or not ROUTE_RE.fullmatch(payload["route"]):
            raise ValueError("Invalid grant")
        if not payload["path"].startswith(f"/EpicVM/{payload['route']}/"):
            raise ValueError("Invalid route path")
        if not payload.get("sub") or not re.fullmatch(r"[a-zA-Z0-9_.:@-]+", payload["sub"]):
            raise ValueError("Invalid subject")
        if int(payload["iat"]) > timestamp + 30 or int(payload["exp"]) < timestamp:
            raise ValueError("Grant expired")
        if int(payload["exp"]) - int(payload["iat"]) > 60 or not re.fullmatch(r"[0-9a-f]{32}", payload["jti"]):
            raise ValueError("Invalid grant lifetime")
        return payload
    except (KeyError, TypeError, ValueError, UnicodeError, base64.binascii.Error) as exc:
        raise ValueError("Invalid or expired stream grant") from exc


def issue_session(key: bytes, grant: dict, *, now: int | None = None) -> str:
    timestamp = int(time.time() if now is None else now)
    payload = {"v": 1, "kind": "session", "route": grant["route"],
               "sub": grant["sub"], "iat": timestamp, "exp": timestamp + 8 * 3600}
    encoded = _b64(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())
    return encoded + "." + _b64(hmac.digest(key, encoded.encode(), hashlib.sha256))


def verify_session(key: bytes, token: str, *, route: str, now: int | None = None) -> dict:
    try:
        encoded, signature = token.split(".", 1)
        expected = _b64(hmac.digest(key, encoded.encode(), hashlib.sha256))
        if not hmac.compare_digest(signature, expected):
            raise ValueError("Invalid signature")
        payload = json.loads(_unb64(encoded))
        timestamp = int(time.time() if now is None else now)
        if payload.get("v") != 1 or payload.get("kind") != "session" or payload.get("route") != route:
            raise ValueError("Wrong stream session")
        if int(payload["iat"]) > timestamp + 30 or int(payload["exp"]) < timestamp:
            raise ValueError("Stream session expired")
        if int(payload["exp"]) - int(payload["iat"]) > 8 * 3600 or not payload.get("sub"):
            raise ValueError("Invalid stream session lifetime")
        return payload
    except (KeyError, TypeError, ValueError, UnicodeError, base64.binascii.Error) as exc:
        raise ValueError("Invalid or expired stream session") from exc
