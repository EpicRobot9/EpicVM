"""Loopback-only EpicVM launch redemption and Moonlight forward-auth service."""

from __future__ import annotations

import argparse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from http.cookies import SimpleCookie
from pathlib import Path
import sqlite3
import sys
import time
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dashboard"))
from direct_stream_auth import ROUTE_RE, issue_session, verify_grant, verify_session  # noqa: E402


class Gateway(ThreadingHTTPServer):
    # The stream page requests many modules at once. Windows rejects excess
    # connections when the default five-connection accept backlog fills.
    request_queue_size = 256
    daemon_threads = True

    def __init__(self, address, *, key_path: Path, routes_path: Path, nonces_path: Path):
        super().__init__(address, GatewayHandler)
        self.key = key_path.read_bytes()
        if len(self.key) < 32:
            raise ValueError("Stream signing key is too short")
        self.routes_path = routes_path
        self.nonces_path = nonces_path
        with sqlite3.connect(nonces_path) as db:
            db.execute("CREATE TABLE IF NOT EXISTS used_grants (jti TEXT PRIMARY KEY, expires INTEGER NOT NULL)")

    def route(self, name: str) -> dict | None:
        if not ROUTE_RE.fullmatch(name):
            return None
        record = json.loads(self.routes_path.read_text(encoding="utf-8")).get(name)
        return record if isinstance(record, dict) and record.get("enabled") is True else None

    def redeem_once(self, grant: dict) -> bool:
        with sqlite3.connect(self.nonces_path) as db:
            db.execute("DELETE FROM used_grants WHERE expires < ?", (int(time.time()),))
            cursor = db.execute("INSERT OR IGNORE INTO used_grants VALUES (?,?)",
                                (grant["jti"], int(grant["exp"])))
            return cursor.rowcount == 1


class GatewayHandler(BaseHTTPRequestHandler):
    server: Gateway

    def log_message(self, fmt, *args):
        # Do not log launch grants, cookies, or the request URL.
        pass

    def _reply(self, code, body=b"", headers=()):
        self.send_response(code)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        endpoint = urlsplit(self.path).path
        if endpoint == "/health":
            self._reply(HTTPStatus.OK, b"ok")
            return
        if endpoint != "/authorize":
            self._reply(HTTPStatus.NOT_FOUND)
            return
        uri = self.headers.get("X-Forwarded-Uri", "")
        path = urlsplit(uri).path
        parts = path.split("/")
        if len(parts) < 4 or parts[1] != "EpicVM":
            self._reply(HTTPStatus.UNAUTHORIZED)
            return
        route = parts[2]
        record = self.server.route(route)
        if not record or not path.startswith(f"/EpicVM/{route}/"):
            self._reply(HTTPStatus.UNAUTHORIZED)
            return
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
            token = cookie[f"evs_{route}"].value
            verify_session(self.server.key, token, route=route)
        except (KeyError, ValueError):
            self._reply(HTTPStatus.UNAUTHORIZED)
            return
        self._reply(HTTPStatus.OK, headers=(("X-EpicVM-User", record["moonlightUser"]),))

    def do_POST(self):
        if self.path != "/redeem":
            self._reply(HTTPStatus.NOT_FOUND)
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if size < 1 or size > 4096:
                raise ValueError("Invalid grant size")
            body = self.rfile.read(size).decode("ascii")
            token = parse_qs(body, strict_parsing=True)["grant"][0]
            grant = verify_grant(self.server.key, token)
            if not self.server.route(grant["route"]) or not self.server.redeem_once(grant):
                raise ValueError("Unavailable or used stream grant")
            session = issue_session(self.server.key, grant)
        except (KeyError, UnicodeError, ValueError):
            self._reply(HTTPStatus.FORBIDDEN, b"Stream launch expired. Return to EpicVM and launch again.")
            return
        route = grant["route"]
        cookie = f"evs_{route}={session}; Path=/EpicVM/{route}/; Secure; HttpOnly; SameSite=Lax"
        self._reply(HTTPStatus.SEE_OTHER, headers=(("Set-Cookie", cookie), ("Location", grant["path"])))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--key", required=True, type=Path)
    parser.add_argument("--routes", required=True, type=Path)
    parser.add_argument("--nonces", required=True, type=Path)
    parser.add_argument("--port", default=8090, type=int)
    args = parser.parse_args()
    Gateway(("127.0.0.1", args.port), key_path=args.key, routes_path=args.routes,
            nonces_path=args.nonces).serve_forever()
