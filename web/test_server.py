"""Tests for the sync server. Run with: python3 -m unittest discover web"""

from __future__ import annotations

import json
import threading
import unittest
import urllib.error
import urllib.request

import server

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

    def push(self, *sessions):
        return self.store.push([server.row_from_json(s) for s in sessions])

    def test_round_trip(self):
        self.assertEqual(self.push(session()), 1)
        rows, cursor, more = self.store.pull(0)
        self.assertEqual(rows, [session()])
        self.assertEqual((cursor, more), (1, False))

    def test_newer_write_wins_and_older_is_ignored(self):
        self.push(session())
        self.assertEqual(self.push(session(tag="piano", updatedAt="2026-09-26T14:00:00Z")), 1)
        self.assertEqual(self.push(session(tag="jp", updatedAt="2026-09-26T13:30:00Z")), 0)
        self.assertEqual(self.push(session(tag="jp", updatedAt="2026-09-26T14:00:00Z")), 0)
        rows, _, _ = self.store.pull(0)
        self.assertEqual([r["tag"] for r in rows], ["piano"])

    def test_tombstone_travels(self):
        self.push(session())
        self.push(session(updatedAt="2026-09-27T09:00:00Z", deletedAt="2026-09-27T09:00:00Z"))
        rows, _, _ = self.store.pull(0)
        self.assertEqual(rows[0]["deletedAt"], "2026-09-27T09:00:00Z")

    def test_cursor_only_returns_new_writes(self):
        self.push(session())
        _, cursor, _ = self.store.pull(0)
        self.assertEqual(self.store.pull(cursor)[0], [])
        self.push(session(updatedAt="2026-09-27T09:00:00Z"))
        rows, _, _ = self.store.pull(cursor)
        self.assertEqual(len(rows), 1)

    def test_paging(self):
        import uuid
        self.push(*[session(id=str(uuid.uuid4())) for _ in range(5)])
        rows, cursor, more = self.store.pull(0, limit=3)
        self.assertEqual((len(rows), more), (3, True))
        rows, cursor, more = self.store.pull(cursor, limit=3)
        self.assertEqual((len(rows), more), (2, False))

    def test_ids_and_dates_are_normalized(self):
        self.push(session(id=ID.lower(), updatedAt="2026-09-26T13:25:00.250+00:00"))
        rows, _, _ = self.store.pull(0)
        self.assertEqual(rows[0]["id"], ID)
        self.assertEqual(rows[0]["updatedAt"], "2026-09-26T13:25:00Z")

    def test_rejects_bad_sessions(self):
        for bad in [session(id="nope"), session(startedAt="yesterday"),
                    session(startedAt="2026-09-26T13:00:00"), session(completed="yes"),
                    session(focusSeconds="25"), session(deviceID="")]:
            with self.assertRaises(server.BadSession):
                server.row_from_json(bad)


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.srv = server.make_server(server.Store(":memory:"), "secret", 0, "127.0.0.1")
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def call(self, path, body=None, token="secret"):
        req = urllib.request.Request(self.base + path)
        if body is not None:
            req.data = json.dumps(body).encode()
            req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def test_push_then_pull(self):
        status, body = self.call("/v1/sessions/push", {"deviceID": "mac", "sessions": [session()]})
        self.assertEqual((status, json.loads(body)), (200, {"accepted": 1}))
        status, body = self.call("/v1/sessions/pull?cursor=0")
        self.assertEqual(json.loads(body), {"sessions": [session()], "cursor": "1", "more": False})

    def test_token_required(self):
        self.assertEqual(self.call("/v1/sessions/pull", token=None)[0], 401)
        self.assertEqual(self.call("/v1/sessions/pull", token="wrong")[0], 401)

    def test_bad_input(self):
        self.assertEqual(self.call("/v1/sessions/pull?cursor=abc")[0], 400)
        self.assertEqual(self.call("/v1/sessions/push", {"sessions": [{"id": 1}]})[0], 400)
        self.assertEqual(self.call("/v1/sessions/push", {"sessions": "x"})[0], 400)

    def test_static_and_health(self):
        status, body = self.call("/", token=None)
        self.assertEqual(status, 200)
        self.assertIn(b"tetodoro", body)
        self.assertEqual(self.call("/healthz", token=None), (200, b"ok\n"))
        self.assertEqual(self.call("/../server.py", token=None)[0], 404)
        self.assertEqual(self.call("/%2e%2e/server.py", token=None)[0], 404)


if __name__ == "__main__":
    unittest.main()
