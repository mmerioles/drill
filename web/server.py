"""drill server: serves the web app and is the sync server.

One process, no dependencies beyond the Python standard library, one SQLite
file. Implements docs/SYNC.md: accounts (email and password) and per-account
session sync.

    POST /v1/accounts        { "email", "password" } -> { "token", "email", "confirmed" }
    POST /v1/signin          { "email", "password" } -> { "token", "email", "confirmed" }
    POST /v1/signout         revokes the token it's called with
    GET  /v1/account         -> { "email", "confirmed" }
    POST /v1/sessions/push   { "deviceID", "sessions": [...] } -> { "accepted" }
    GET  /v1/sessions/pull?cursor=N -> { "sessions", "cursor", "more" }
    GET  /confirm?token=...  the link in the confirmation email
    GET  /healthz

Environment:
    DRILL_DATA        directory for drill.sqlite (default: data/ next to this file)
    PORT                 listen port (default 8080)
    DRILL_PUBLIC_URL  where people reach this server, for links in email,
                         e.g. https://drill.example.com
    DRILL_MAIL_URL    where to send email: the server POSTs
                         { "to", "subject", "text" } there as JSON, e.g. to a
                         Cloudflare Worker that sends it. Unset: links are
                         printed to the log instead.
    DRILL_MAIL_KEY    sent as "Authorization: Bearer <key>" to the mail URL
    DRILL_REQUIRE_CONFIRMED  "1" to block sync until the email is confirmed
"""

from __future__ import annotations

import hashlib
import hmac
import html
import json
import mimetypes
import os
import re
import secrets
import signal
import sqlite3
import sys
import threading
import time
import urllib.request
import uuid
from dataclasses import dataclass
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


# MARK: Accounts


class BadAccount(ValueError):
    pass


EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
MIN_PASSWORD = 8


def clean_email(value) -> str:
    email = value.strip().lower() if isinstance(value, str) else ""
    if len(email) > 254 or not EMAIL.match(email):
        raise BadAccount("that doesn't look like an email address")
    return email


def clean_password(value) -> str:
    if not isinstance(value, str) or len(value) < MIN_PASSWORD:
        raise BadAccount(f"use at least {MIN_PASSWORD} characters for the password")
    if len(value) > 1024:
        raise BadAccount("that password is too long")
    return value


# PBKDF2 rather than scrypt: every Python has it, including macOS's own.
PBKDF2_ROUNDS = 600_000


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PBKDF2_ROUNDS)
    return f"pbkdf2_sha256${PBKDF2_ROUNDS}${salt.hex()}${digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        _, rounds, salt, digest = stored.split("$")
        given = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), int(rounds))
    except ValueError:
        return False
    return hmac.compare_digest(given.hex(), digest)


def token_hash(token: str) -> str:
    # Tokens are long and random, so a plain hash is enough: a leaked
    # database doesn't hand out working tokens.
    return hashlib.sha256(token.encode()).hexdigest()


class Attempts:
    """Sign-in and sign-up attempts per address, to slow down guessing."""

    def __init__(self, limit: int = 20, window: float = 600):
        self.limit, self.window = limit, window
        self.seen: dict[str, list[float]] = {}
        self.lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.time()
        with self.lock:
            recent = [t for t in self.seen.get(key, []) if now - t < self.window]
            allowed = len(recent) < self.limit
            if allowed:
                recent.append(now)
            self.seen[key] = recent
            if len(self.seen) > 10_000:
                self.seen = {k: v for k, v in self.seen.items() if v and now - v[-1] < self.window}
        return allowed


@dataclass
class Mailer:
    """Sends mail by POSTing JSON to `url`, e.g. a Cloudflare Worker. With no
    url, it writes the message to the log, so links still work by hand."""

    url: str | None = None
    key: str | None = None

    def send(self, to: str, subject: str, text: str):
        if not self.url:
            print(f"mail to {to}: {subject}\n{text}", file=sys.stderr)
            return
        threading.Thread(target=self._post, args=(to, subject, text), daemon=True).start()

    def _post(self, to: str, subject: str, text: str):
        req = urllib.request.Request(
            self.url, data=json.dumps({"to": to, "subject": subject, "text": text}).encode(),
            headers={"Content-Type": "application/json"})
        if self.key:
            req.add_header("Authorization", f"Bearer {self.key}")
        try:
            urllib.request.urlopen(req, timeout=15).close()
        except OSError as e:
            print(f"couldn't send mail to {to}: {e}", file=sys.stderr)


class Store:
    """Accounts, their sign-in tokens, and the union of each account's
    sessions. Each accepted write gets the next sequence number, which is
    what pull cursors count in."""

    COLUMNS = ("id, started_at, ended_at, focus_seconds, planned_seconds, completed, "
               "tag, device_id, updated_at, deleted_at")

    def __init__(self, path: str):
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.lock = threading.Lock()
        self.db.execute("PRAGMA journal_mode = WAL")
        self.db.execute("PRAGMA foreign_keys = ON")
        columns = [r[1] for r in self.db.execute("PRAGMA table_info(sessions)")]
        if columns and "user_id" not in columns:
            # Sessions from before accounts, when one token shared everything.
            # Kept, but no account owns them.
            self.db.execute("ALTER TABLE sessions RENAME TO sessions_before_accounts")
            self.db.execute("DROP INDEX IF EXISTS sessions_seq")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS users (
                id            INTEGER PRIMARY KEY,
                email         TEXT NOT NULL UNIQUE,
                password      TEXT NOT NULL,
                created_at    REAL NOT NULL,
                confirmed_at  REAL,
                confirm_token TEXT UNIQUE
            );
            CREATE TABLE IF NOT EXISTS tokens (
                hash       TEXT PRIMARY KEY,
                user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sessions (
                user_id         INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                id              TEXT NOT NULL,
                started_at      REAL NOT NULL,
                ended_at        REAL NOT NULL,
                focus_seconds   REAL NOT NULL,
                planned_seconds REAL NOT NULL,
                completed       INTEGER NOT NULL,
                tag             TEXT,
                device_id       TEXT NOT NULL,
                updated_at      REAL NOT NULL,
                deleted_at      REAL,
                seq             INTEGER NOT NULL,
                PRIMARY KEY (user_id, id)
            );
            CREATE UNIQUE INDEX IF NOT EXISTS sessions_seq ON sessions(seq);
            CREATE INDEX IF NOT EXISTS sessions_user_seq ON sessions(user_id, seq);
        """)

    # Accounts

    def create_user(self, email: str, password: str) -> tuple[int, str] | None:
        """Returns (user id, confirm token), or None if the email is taken."""
        confirm = secrets.token_urlsafe(24)
        with self.lock:
            try:
                cur = self.db.execute(
                    "INSERT INTO users (email, password, created_at, confirm_token) VALUES (?, ?, ?, ?)",
                    (email, hash_password(password), time.time(), confirm))
            except sqlite3.IntegrityError:
                return None
        return cur.lastrowid, confirm

    def check_password(self, email: str, password: str) -> int | None:
        with self.lock:
            row = self.db.execute("SELECT id, password FROM users WHERE email = ?", (email,)).fetchone()
        if row is None:
            hash_password(password)  # same work either way, so timing doesn't reveal accounts
            return None
        return row[0] if verify_password(password, row[1]) else None

    def user(self, user_id: int) -> tuple[str, bool]:
        with self.lock:
            email, confirmed = self.db.execute(
                "SELECT email, confirmed_at FROM users WHERE id = ?", (user_id,)).fetchone()
        return email, confirmed is not None

    def confirm(self, token: str) -> bool:
        with self.lock:
            cur = self.db.execute(
                "UPDATE users SET confirmed_at = ?, confirm_token = NULL WHERE confirm_token = ?",
                (time.time(), token))
        return cur.rowcount == 1

    def issue_token(self, user_id: int) -> str:
        token = secrets.token_urlsafe(32)
        with self.lock:
            self.db.execute("INSERT INTO tokens (hash, user_id, created_at) VALUES (?, ?, ?)",
                            (token_hash(token), user_id, time.time()))
        return token

    def user_for_token(self, token: str) -> int | None:
        with self.lock:
            row = self.db.execute("SELECT user_id FROM tokens WHERE hash = ?",
                                  (token_hash(token),)).fetchone()
        return row[0] if row else None

    def revoke_token(self, token: str):
        with self.lock:
            self.db.execute("DELETE FROM tokens WHERE hash = ?", (token_hash(token),))

    # Sessions

    def push(self, user_id: int, rows: list[tuple]) -> int:
        """Last-writer-wins on updated_at; returns how many rows were taken."""
        accepted = 0
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                seq = self.db.execute("SELECT COALESCE(MAX(seq), 0) FROM sessions").fetchone()[0]
                for row in rows:
                    cur = self.db.execute(
                        f"""INSERT INTO sessions (user_id, {self.COLUMNS}, seq)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(user_id, id) DO UPDATE SET
                                started_at = excluded.started_at, ended_at = excluded.ended_at,
                                focus_seconds = excluded.focus_seconds,
                                planned_seconds = excluded.planned_seconds,
                                completed = excluded.completed, tag = excluded.tag,
                                device_id = excluded.device_id, updated_at = excluded.updated_at,
                                deleted_at = excluded.deleted_at, seq = excluded.seq
                            WHERE excluded.updated_at > sessions.updated_at""",
                        (user_id, *row, seq + 1),
                    )
                    if cur.rowcount:
                        seq += 1
                        accepted += 1
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise
        return accepted

    def pull(self, user_id: int, cursor: int, limit: int = PULL_LIMIT) -> tuple[list[dict], int, bool]:
        with self.lock:
            rows = self.db.execute(
                f"""SELECT {self.COLUMNS}, seq FROM sessions
                    WHERE user_id = ? AND seq > ? ORDER BY seq LIMIT ?""",
                (user_id, cursor, limit + 1),
            ).fetchall()
        more = len(rows) > limit
        rows = rows[:limit]
        next_cursor = rows[-1][10] if rows else cursor
        return [json_from_row(r) for r in rows], next_cursor, more


# MARK: HTTP


CONFIRM_PAGE = """<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>drill</title>
<style>
  :root { color-scheme: light dark; --paper: #F2F0ED; --ink: #2B2A2F; --faint: rgb(43 42 47 / .45); }
  @media (prefers-color-scheme: dark) {
    :root { --paper: #121211; --ink: #F1F0EB; --faint: rgb(241 240 235 / .45); }
  }
  body { margin: 0; min-height: 100dvh; display: grid; place-content: center; text-align: center;
         background: var(--paper); color: var(--ink);
         font: 15px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
  h1 { font-size: 20px; margin: 0 0 4px; } p { color: var(--faint); margin: 0; }
</style>
<h1>{title}</h1><p>{text}</p>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "drill"
    store: Store
    mailer: Mailer
    public_url: str | None
    require_confirmed: bool
    attempts: Attempts

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/healthz":
            return self.send_text(HTTPStatus.OK, "ok\n")
        if url.path == "/confirm":
            token = parse_qs(url.query).get("token", [""])[0]
            ok = bool(token) and self.store.confirm(token)
            return self.send_page(
                HTTPStatus.OK if ok else HTTPStatus.NOT_FOUND,
                "email confirmed" if ok else "link expired",
                "you're all set. back to focus." if ok else "this link was already used or isn't valid.")
        if url.path == "/v1/account":
            if (user := self.signed_in()) is None:
                return
            email, confirmed = self.store.user(user)
            return self.send_json(HTTPStatus.OK, {"email": email, "confirmed": confirmed})
        if url.path == "/v1/sessions/pull":
            if (user := self.syncing()) is None:
                return
            raw = parse_qs(url.query).get("cursor", ["0"])[0] or "0"
            if not raw.isdigit():
                return self.send_json(HTTPStatus.BAD_REQUEST, {"error": "bad cursor"})
            sessions, cursor, more = self.store.pull(user, int(raw))
            return self.send_json(HTTPStatus.OK,
                                  {"sessions": sessions, "cursor": str(cursor), "more": more})
        if url.path.startswith("/v1/"):
            return self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        self.send_static(url.path)

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        path = urlparse(self.path).path
        routes = {"/v1/accounts": self.sign_up, "/v1/signin": self.sign_in,
                  "/v1/signout": self.sign_out, "/v1/sessions/push": self.push}
        if path not in routes:
            return self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            return self.send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "too large"})
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(body, dict):
                raise ValueError
        except (ValueError, UnicodeDecodeError):
            return self.send_json(HTTPStatus.BAD_REQUEST, {"error": "body must be a JSON object"})
        try:
            routes[path](body)
        except (BadAccount, BadSession) as e:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(e)})

    # Routes

    def sign_up(self, body: dict):
        if not self.attempts.allow(self.client_address[0]):
            return self.send_json(HTTPStatus.TOO_MANY_REQUESTS, {"error": "too many tries. wait a bit."})
        email, password = clean_email(body.get("email")), clean_password(body.get("password"))
        created = self.store.create_user(email, password)
        if created is None:
            return self.send_json(HTTPStatus.CONFLICT, {"error": "there's already an account with that email"})
        user, confirm = created
        self.mailer.send(email, "confirm your drill account",
                         f"welcome to drill.\n\nconfirm your email here:\n"
                         f"{self.base_url()}/confirm?token={confirm}\n\n"
                         f"if you didn't sign up, you can ignore this.\n")
        self.send_account(HTTPStatus.CREATED, user)

    def sign_in(self, body: dict):
        if not self.attempts.allow(self.client_address[0]):
            return self.send_json(HTTPStatus.TOO_MANY_REQUESTS, {"error": "too many tries. wait a bit."})
        email = body.get("email").strip().lower() if isinstance(body.get("email"), str) else ""
        password = body.get("password") if isinstance(body.get("password"), str) else ""
        user = self.store.check_password(email, password)
        if user is None:
            return self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "wrong email or password"})
        self.send_account(HTTPStatus.OK, user)

    def sign_out(self, body: dict):
        if (token := self.bearer()) is not None:
            self.store.revoke_token(token)
        self.send_json(HTTPStatus.OK, {})

    def push(self, body: dict):
        if (user := self.syncing()) is None:
            return
        sessions = body.get("sessions")
        if not isinstance(sessions, list):
            raise BadSession("sessions must be a list")
        rows = [row_from_json(s) for s in sessions]
        self.send_json(HTTPStatus.OK, {"accepted": self.store.push(user, rows)})

    # Helpers

    def send_account(self, status, user: int):
        email, confirmed = self.store.user(user)
        self.send_json(status, {"token": self.store.issue_token(user), "email": email,
                                "confirmed": confirmed})

    def bearer(self) -> str | None:
        given = self.headers.get("Authorization", "")
        return given[7:] if given.startswith("Bearer ") and len(given) > 7 else None

    def signed_in(self) -> int | None:
        token = self.bearer()
        user = self.store.user_for_token(token) if token else None
        if user is None:
            self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "sign in again"})
        return user

    def syncing(self) -> int | None:
        if (user := self.signed_in()) is None:
            return None
        if self.require_confirmed and not self.store.user(user)[1]:
            self.send_json(HTTPStatus.FORBIDDEN, {"error": "confirm your email first"})
            return None
        return user

    def base_url(self) -> str:
        if self.public_url:
            return self.public_url.rstrip("/")
        return f"http://{self.headers.get('Host', 'localhost')}"

    def send_page(self, status, title: str, text: str):
        page = CONFIRM_PAGE.replace("{title}", html.escape(title)).replace("{text}", html.escape(text))
        self.send_body(status, page.encode(), "text/html; charset=utf-8", cache="no-store")

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


def make_server(store: Store, port: int, host: str = "", mailer: Mailer | None = None,
                public_url: str | None = None, require_confirmed: bool = False) -> ThreadingHTTPServer:
    handler = type("BoundHandler", (Handler,), {
        "store": store, "mailer": mailer or Mailer(), "public_url": public_url or None,
        "require_confirmed": require_confirmed, "attempts": Attempts()})
    return ThreadingHTTPServer((host, port), handler)


def main():
    data = Path(os.environ.get("DRILL_DATA") or Path(__file__).resolve().parent / "data")
    data.mkdir(parents=True, exist_ok=True)
    port = int(os.environ.get("PORT", "8080"))
    env = lambda name: os.environ.get(name, "").strip() or None
    mailer = Mailer(env("DRILL_MAIL_URL"), env("DRILL_MAIL_KEY"))

    server = make_server(Store(str(data / "drill.sqlite")), port, mailer=mailer,
                         public_url=env("DRILL_PUBLIC_URL"),
                         require_confirmed=env("DRILL_REQUIRE_CONFIRMED") == "1")
    # PID 1 in a container ignores SIGTERM unless it installs a handler.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if not mailer.url:
        print("note: DRILL_MAIL_URL is not set; confirmation links go to this log.",
              file=sys.stderr)
    print(f"drill listening on :{port}, data in {data.resolve()}", file=sys.stderr)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
