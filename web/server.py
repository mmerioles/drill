"""tetodoro server: serves the web app and is the home sync server.

One process, no dependencies beyond the Python standard library, one SQLite
file. Implements docs/SYNC.md:

    POST /v1/sessions/push   { "deviceID", "sessions": [...] } -> { "accepted" }
    GET  /v1/sessions/pull?cursor=N -> { "sessions", "cursor", "more" }
    GET  /healthz

Environment:
    TETODORO_TOKEN  shared secret for /v1 (Authorization: Bearer <token>).
                    Unset means the API is open; fine on a trusted LAN only.
    TETODORO_DATA   directory for tetodoro.sqlite (default: data/ next to this file)
    PORT            listen port (default 8080)
"""

from __future__ import annotations

import hmac
import json
import mimetypes
import os
import signal
import sqlite3
import sys
import threading
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

STATIC = Path(__file__).resolve().parent / "static"
mimetypes.add_type("application/manifest+json", ".webmanifest")
mimetypes.add_type("text/javascript", ".js")
PULL_LIMIT = 500
MAX_BODY = 8 * 1024 * 1024


# MARK: Sessions


class BadSession(ValueError):
    pass


def parse_date(value) -> float:
    if not isinstance(value, str):
        raise BadSession("dates must be ISO-8601 strings")
    try:
        d = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise BadSession(f"bad date: {value!r}") from None
    if d.tzinfo is None:
        raise BadSession(f"date needs a time zone: {value!r}")
    return d.timestamp()


def format_date(ts: float) -> str:
    # Whole seconds: Swift's .iso8601 decoder rejects fractional seconds.
    return datetime.fromtimestamp(int(ts), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def number(value, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise BadSession(f"{name} must be a number")
    return float(value)


def row_from_json(s) -> tuple:
    """Validates one FocusSession and returns it as a row, id uppercased."""
    if not isinstance(s, dict):
        raise BadSession("sessions must be objects")
    try:
        sid = str(uuid.UUID(str(s.get("id")))).upper()
    except ValueError:
        raise BadSession(f"bad id: {s.get('id')!r}") from None
    tag = s.get("tag")
    if tag is not None and not isinstance(tag, str):
        raise BadSession("tag must be a string or null")
    device = s.get("deviceID")
    if not isinstance(device, str) or not device:
        raise BadSession("deviceID is required")
    if not isinstance(s.get("completed"), bool):
        raise BadSession("completed must be a boolean")
    deleted = s.get("deletedAt")
    return (
        sid,
        parse_date(s.get("startedAt")),
        parse_date(s.get("endedAt")),
        number(s.get("focusSeconds"), "focusSeconds"),
        number(s.get("plannedSeconds"), "plannedSeconds"),
        1 if s["completed"] else 0,
        tag,
        device,
        parse_date(s.get("updatedAt")),
        None if deleted is None else parse_date(deleted),
    )


def json_from_row(r) -> dict:
    return {
        "id": r[0],
        "startedAt": format_date(r[1]),
        "endedAt": format_date(r[2]),
        "focusSeconds": r[3],
        "plannedSeconds": r[4],
        "completed": bool(r[5]),
        "tag": r[6],
        "deviceID": r[7],
        "updatedAt": format_date(r[8]),
        "deletedAt": None if r[9] is None else format_date(r[9]),
    }


class Store:
    """The union of every device's sessions. Each accepted write gets the
    next sequence number, which is what pull cursors count in."""

    COLUMNS = ("id, started_at, ended_at, focus_seconds, planned_seconds, completed, "
               "tag, device_id, updated_at, deleted_at")

    def __init__(self, path: str):
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.lock = threading.Lock()
        self.db.execute("PRAGMA journal_mode = WAL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS sessions (
                id              TEXT PRIMARY KEY,
                started_at      REAL NOT NULL,
                ended_at        REAL NOT NULL,
                focus_seconds   REAL NOT NULL,
                planned_seconds REAL NOT NULL,
                completed       INTEGER NOT NULL,
                tag             TEXT,
                device_id       TEXT NOT NULL,
                updated_at      REAL NOT NULL,
                deleted_at      REAL,
                seq             INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS sessions_seq ON sessions(seq);
        """)

    def push(self, rows: list[tuple]) -> int:
        """Last-writer-wins on updated_at; returns how many rows were taken."""
        accepted = 0
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                seq = self.db.execute("SELECT COALESCE(MAX(seq), 0) FROM sessions").fetchone()[0]
                for row in rows:
                    cur = self.db.execute(
                        f"""INSERT INTO sessions ({self.COLUMNS}, seq)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(id) DO UPDATE SET
                                started_at = excluded.started_at, ended_at = excluded.ended_at,
                                focus_seconds = excluded.focus_seconds,
                                planned_seconds = excluded.planned_seconds,
                                completed = excluded.completed, tag = excluded.tag,
                                device_id = excluded.device_id, updated_at = excluded.updated_at,
                                deleted_at = excluded.deleted_at, seq = excluded.seq
                            WHERE excluded.updated_at > sessions.updated_at""",
                        (*row, seq + 1),
                    )
                    if cur.rowcount:
                        seq += 1
                        accepted += 1
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise
        return accepted

    def pull(self, cursor: int, limit: int = PULL_LIMIT) -> tuple[list[dict], int, bool]:
        with self.lock:
            rows = self.db.execute(
                f"SELECT {self.COLUMNS}, seq FROM sessions WHERE seq > ? ORDER BY seq LIMIT ?",
                (cursor, limit + 1),
            ).fetchall()
        more = len(rows) > limit
        rows = rows[:limit]
        next_cursor = rows[-1][10] if rows else cursor
        return [json_from_row(r) for r in rows], next_cursor, more


# MARK: HTTP


class Handler(BaseHTTPRequestHandler):
    server_version = "tetodoro"
    store: Store
    token: str | None

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/healthz":
            return self.send_text(HTTPStatus.OK, "ok\n")
        if url.path == "/v1/sessions/pull":
            if not self.authorized():
                return
            raw = parse_qs(url.query).get("cursor", ["0"])[0] or "0"
            if not raw.isdigit():
                return self.send_json(HTTPStatus.BAD_REQUEST, {"error": "bad cursor"})
            sessions, cursor, more = self.store.pull(int(raw))
            return self.send_json(HTTPStatus.OK,
                                  {"sessions": sessions, "cursor": str(cursor), "more": more})
        if url.path.startswith("/v1/"):
            return self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        self.send_static(url.path)

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        if urlparse(self.path).path != "/v1/sessions/push":
            return self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            return self.send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "too large"})
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
            sessions = body.get("sessions") if isinstance(body, dict) else None
            if not isinstance(sessions, list):
                raise BadSession("sessions must be a list")
            rows = [row_from_json(s) for s in sessions]
        except (json.JSONDecodeError, UnicodeDecodeError):
            return self.send_json(HTTPStatus.BAD_REQUEST, {"error": "body must be JSON"})
        except BadSession as e:
            return self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(e)})
        self.send_json(HTTPStatus.OK, {"accepted": self.store.push(rows)})

    # Helpers

    def authorized(self) -> bool:
        if not self.token:
            return True
        given = self.headers.get("Authorization", "")
        if hmac.compare_digest(given.encode(), f"Bearer {self.token}".encode()):
            return True
        self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "bad or missing token"})
        return False

    def send_static(self, path: str):
        target = (STATIC / path.lstrip("/")).resolve()
        if target.is_dir():
            target = target / "index.html"
        if STATIC not in target.parents or not target.is_file():
            return self.send_text(HTTPStatus.NOT_FOUND, "not found\n")
        body = target.read_bytes()
        kind = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        if kind.startswith("text/") or kind.endswith("javascript"):
            kind += "; charset=utf-8"
        self.send_body(HTTPStatus.OK, body, kind, cache="no-cache")

    def send_json(self, status, obj):
        self.send_body(status, json.dumps(obj).encode(), "application/json", cache="no-store")

    def send_text(self, status, text: str):
        self.send_body(status, text.encode(), "text/plain; charset=utf-8", cache="no-store")

    def send_body(self, status, body: bytes, kind: str, cache: str):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def log_message(self, fmt, *args):
        if "/healthz" not in self.path:
            sys.stderr.write(f"{self.address_string()} {fmt % args}\n")


def make_server(store: Store, token: str | None, port: int, host: str = "") -> ThreadingHTTPServer:
    handler = type("BoundHandler", (Handler,), {"store": store, "token": token or None})
    return ThreadingHTTPServer((host, port), handler)


def main():
    data = Path(os.environ.get("TETODORO_DATA") or Path(__file__).resolve().parent / "data")
    data.mkdir(parents=True, exist_ok=True)
    token = os.environ.get("TETODORO_TOKEN", "").strip()
    port = int(os.environ.get("PORT", "8080"))

    server = make_server(Store(str(data / "tetodoro.sqlite")), token, port)
    # PID 1 in a container ignores SIGTERM unless it installs a handler.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if not token:
        print("warning: TETODORO_TOKEN is not set; the sync API is open to anyone "
              "who can reach this port.", file=sys.stderr)
    print(f"tetodoro listening on :{port}, data in {data.resolve()}", file=sys.stderr)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
