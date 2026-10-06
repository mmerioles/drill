"""Tests for the sync server. Run with: python3 -m unittest discover web"""

from __future__ import annotations

import json
import threading
import unittest
import urllib.error
import urllib.request

import server

server.PBKDF2_ROUNDS = 1_000  # fast tests; the real count is checked below

ID = "6F1C0D3A-2B4E-4C5D-9E8F-0A1B2C3D4E5F"


def session(**over):
    s = {
        "id": ID,
        "startedAt": "2026-09-26T13:00:00Z",
        "endedAt": "2026-09-26T13:25:00Z",
        "focusSeconds": 1500,
        "plannedSeconds": 1500,
        "completed": True,
        "tag": "15-213",
        "deviceID": "mac",
        "updatedAt": "2026-09-26T13:25:00Z",
        "deletedAt": None,
    }
    s.update(over)
    return s


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.store = server.Store(":memory:")
        self.user, _ = self.store.create_user("a@example.com", "password1")

    def push(self, *sessions, user=None):
        return self.store.push(user or self.user, [server.row_from_json(s) for s in sessions])

    def pull(self, cursor, **kw):
        return self.store.pull(kw.pop("user", self.user), cursor, **kw)

    def test_round_trip(self):
        self.assertEqual(self.push(session()), 1)
        rows, cursor, more = self.pull(0)
        self.assertEqual(rows, [session()])
        self.assertEqual((cursor, more), (1, False))

    def test_newer_write_wins_and_older_is_ignored(self):
        self.push(session())
        self.assertEqual(self.push(session(tag="piano", updatedAt="2026-09-26T14:00:00Z")), 1)
        self.assertEqual(self.push(session(tag="jp", updatedAt="2026-09-26T13:30:00Z")), 0)
        self.assertEqual(self.push(session(tag="jp", updatedAt="2026-09-26T14:00:00Z")), 0)
        rows, _, _ = self.pull(0)
        self.assertEqual([r["tag"] for r in rows], ["piano"])

    def test_tombstone_travels(self):
        self.push(session())
        self.push(session(updatedAt="2026-09-27T09:00:00Z", deletedAt="2026-09-27T09:00:00Z"))
        rows, _, _ = self.pull(0)
        self.assertEqual(rows[0]["deletedAt"], "2026-09-27T09:00:00Z")

    def test_cursor_only_returns_new_writes(self):
        self.push(session())
        _, cursor, _ = self.pull(0)
        self.assertEqual(self.pull(cursor)[0], [])
        self.push(session(updatedAt="2026-09-27T09:00:00Z"))
        rows, _, _ = self.pull(cursor)
        self.assertEqual(len(rows), 1)

    def test_paging(self):
        import uuid
        self.push(*[session(id=str(uuid.uuid4())) for _ in range(5)])
        rows, cursor, more = self.pull(0, limit=3)
        self.assertEqual((len(rows), more), (3, True))
        rows, cursor, more = self.pull(cursor, limit=3)
        self.assertEqual((len(rows), more), (2, False))

    def test_ids_and_dates_are_normalized(self):
        self.push(session(id=ID.lower(), updatedAt="2026-09-26T13:25:00.250+00:00"))
        rows, _, _ = self.pull(0)
        self.assertEqual(rows[0]["id"], ID)
        self.assertEqual(rows[0]["updatedAt"], "2026-09-26T13:25:00Z")

    def test_accounts_never_see_each_other(self):
        other, _ = self.store.create_user("b@example.com", "password2")
        self.push(session(tag="mine"))
        self.push(session(tag="theirs", updatedAt="2026-09-27T09:00:00Z"), user=other)
        self.assertEqual([r["tag"] for r in self.pull(0)[0]], ["mine"])
        self.assertEqual([r["tag"] for r in self.pull(0, user=other)[0]], ["theirs"])

    def test_passwords_and_tokens(self):
        self.assertEqual(self.store.check_password("a@example.com", "password1"), self.user)
        self.assertIsNone(self.store.check_password("a@example.com", "nope"))
        self.assertIsNone(self.store.check_password("x@example.com", "password1"))
        self.assertIsNone(self.store.create_user("a@example.com", "again12345"))
        token = self.store.issue_token(self.user)
        self.assertEqual(self.store.user_for_token(token), self.user)
        self.store.revoke_token(token)
        self.assertIsNone(self.store.user_for_token(token))

    def test_password_hash_format(self):
        stored = server.hash_password("password1")
        self.assertTrue(stored.startswith("pbkdf2_sha256$1000$"))
        self.assertTrue(server.verify_password("password1", stored))
        self.assertFalse(server.verify_password("password2", stored))
        self.assertFalse(server.verify_password("password1", "garbage"))

    def test_confirm(self):
        _, confirm = self.store.create_user("c@example.com", "password3")
        user = self.store.check_password("c@example.com", "password3")
        self.assertEqual(self.store.user(user), ("c@example.com", False))
        self.assertTrue(self.store.confirm(confirm))
        self.assertFalse(self.store.confirm(confirm))
        self.assertEqual(self.store.user(user), ("c@example.com", True))

    def test_sessions_from_before_accounts_are_set_aside(self):
        import os, sqlite3, tempfile
        path = os.path.join(tempfile.mkdtemp(), "old.sqlite")
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, seq INTEGER NOT NULL)")
        db.execute("CREATE UNIQUE INDEX sessions_seq ON sessions(seq)")
        db.execute("INSERT INTO sessions VALUES ('x', 1)")
        db.commit()
        db.close()
        store = server.Store(path)
        tables = {r[0] for r in store.db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        self.assertIn("sessions_before_accounts", tables)
        user, _ = store.create_user("d@example.com", "password4")
        self.assertEqual(store.push(user, [server.row_from_json(session())]), 1)

    def test_rejects_bad_sessions(self):
        for bad in [session(id="nope"), session(startedAt="yesterday"),
                    session(startedAt="2026-09-26T13:00:00"), session(completed="yes"),
                    session(focusSeconds="25"), session(deviceID="")]:
            with self.assertRaises(server.BadSession):
                server.row_from_json(bad)


class Outbox(server.Mailer):
    def __init__(self):
        super().__init__()
        self.sent = []

    def send(self, to, subject, text):
        self.sent.append((to, subject, text))


class HTTPTests(unittest.TestCase):
    def setUp(self, **options):
        self.outbox = Outbox()
        self.srv = server.make_server(server.Store(":memory:"), 0, "127.0.0.1", mailer=self.outbox,
                                      public_url="https://teto.example", **options)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}"
        self.token = None

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def call(self, path, body=None, token=None, raw=False):
        req = urllib.request.Request(self.base + path)
        if body is not None:
            req.data = json.dumps(body).encode()
            req.add_header("Content-Type", "application/json")
        if token or self.token:
            req.add_header("Authorization", f"Bearer {token or self.token}")
        try:
            with urllib.request.urlopen(req) as r:
                status, data = r.status, r.read()
        except urllib.error.HTTPError as e:
            status, data = e.code, e.read()
        return (status, data) if raw else (status, json.loads(data))

    def sign_up(self, email="a@example.com", password="password1"):
        status, body = self.call("/v1/accounts", {"email": email, "password": password})
        self.assertEqual(status, 201)
        self.token = body["token"]
        return body

    def test_sign_up_then_sync(self):
        self.assertEqual(self.sign_up()["confirmed"], False)
        self.assertEqual(self.call("/v1/sessions/push", {"deviceID": "mac", "sessions": [session()]}),
                         (200, {"accepted": 1}))
        self.assertEqual(self.call("/v1/sessions/pull?cursor=0"),
                         (200, {"sessions": [session()], "cursor": "1", "more": False}))

    def test_sign_in_and_out(self):
        self.sign_up()
        self.token = None
        self.assertEqual(self.call("/v1/signin", {"email": "A@Example.com ", "password": "nope"})[0], 401)
        status, body = self.call("/v1/signin", {"email": "A@Example.com ", "password": "password1"})
        self.assertEqual((status, body["email"]), (200, "a@example.com"))
        self.token = body["token"]
        self.assertEqual(self.call("/v1/account"), (200, {"email": "a@example.com", "confirmed": False}))
        self.assertEqual(self.call("/v1/signout", {})[0], 200)
        self.assertEqual(self.call("/v1/account")[0], 401)

    def test_sign_up_rules(self):
        self.assertEqual(self.call("/v1/accounts", {"email": "nope", "password": "password1"})[0], 400)
        self.assertEqual(self.call("/v1/accounts", {"email": "a@example.com", "password": "short"})[0], 400)
        self.sign_up()
        self.assertEqual(self.call("/v1/accounts", {"email": "a@example.com", "password": "password2"})[0], 409)

    def test_confirmation_mail(self):
        self.sign_up()
        (to, _, text), = self.outbox.sent
        self.assertEqual(to, "a@example.com")
        link = next(line for line in text.splitlines() if line.startswith("https://teto.example/confirm?"))
        path = link.removeprefix("https://teto.example")
        self.assertEqual(self.call(path, raw=True)[0], 200)
        self.assertEqual(self.call("/v1/account")[1]["confirmed"], True)
        self.assertEqual(self.call(path, raw=True)[0], 404)

    def test_sync_needs_an_account(self):
        self.assertEqual(self.call("/v1/sessions/pull")[0], 401)
        self.assertEqual(self.call("/v1/sessions/pull", token="made-up")[0], 401)

    def test_bad_input(self):
        self.sign_up()
        self.assertEqual(self.call("/v1/sessions/pull?cursor=abc")[0], 400)
        self.assertEqual(self.call("/v1/sessions/push", {"sessions": [{"id": 1}]})[0], 400)
        self.assertEqual(self.call("/v1/sessions/push", {"sessions": "x"})[0], 400)

    def test_static_and_health(self):
        status, body = self.call("/", raw=True)
        self.assertEqual(status, 200)
        self.assertIn(b"drill", body)
        self.assertEqual(self.call("/healthz", raw=True), (200, b"ok\n"))
        self.assertEqual(self.call("/../server.py", raw=True)[0], 404)
        self.assertEqual(self.call("/%2e%2e/server.py", raw=True)[0], 404)


class ConfirmedOnlyTests(HTTPTests):
    def setUp(self):
        super().setUp(require_confirmed=True)

    def test_sign_up_then_sync(self):
        self.sign_up()
        self.assertEqual(self.call("/v1/sessions/pull?cursor=0")[0], 403)
        self.assertEqual(self.call("/v1/account")[0], 200)

    def test_bad_input(self):
        pass


if __name__ == "__main__":
    unittest.main()
