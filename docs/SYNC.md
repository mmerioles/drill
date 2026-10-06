# sync contract

The server is `web/server.py` (see the README to run it). Its clients are the
web app in `web/static` (`store.js`), the mac app (`SyncAPI` in
DrillCore, driven by `Sync.swift` in the app), and the android app
(`SyncApi.kt` and `Sync.kt` in `android/.../data`).

The home server's job is small: keep the union of every device's sessions and
hand back what each device hasn't seen yet. Devices do all merging themselves
with a single rule.

## Merge rule

Rows are keyed by `id` (UUID). **For each `id`, the row with the greater
`updatedAt` wins.** Deletes are tombstones (`deletedAt` set, `updatedAt`
bumped), so a delete also wins by being the newer write. Rows are never
hard-deleted. `SQLiteSessionStore.save` already enforces this rule, so saving a
pulled row is the whole merge.

## Accounts

Syncing needs an account: an email and a password, nothing else. Signing in
returns a token, which every other call sends as
`Authorization: Bearer <token>`. Each account only ever sees its own
sessions.

```
POST /v1/accounts   { "email": "…", "password": "…" }
  → 201 { "token": "…", "email": "…", "confirmed": false }
POST /v1/signin     { "email": "…", "password": "…" }
  → 200 { "token": "…", "email": "…", "confirmed": true }
POST /v1/signout    revokes the token it's sent with → 200 {}
GET  /v1/account    → 200 { "email": "…", "confirmed": true }
GET  /confirm?token=…   the link in the confirmation email; a small page
```

Emails are trimmed and lowercased. Passwords need at least 8 characters and
are stored as salted PBKDF2-SHA256. Errors come back as
`{ "error": "…" }` with a lowercase sentence the apps show as-is:
`400` bad input, `401` wrong email or password (or, on other calls, a dead
token: sign in again), `409` email taken, `429` too many tries from one
address.

Signing up sends a confirmation email. The server POSTs
`{ "to", "subject", "text" }` as JSON to `DRILL_MAIL_URL`, e.g. a
Cloudflare Worker that sends it, with `Authorization: Bearer
$DRILL_MAIL_KEY`. Without a mail URL it prints the message to its log.
Links use `DRILL_PUBLIC_URL`. Accounts can sync before confirming unless
`DRILL_REQUIRE_CONFIRMED=1`, in which case sync calls answer
`403 { "error": "confirm your email first" }`.

## Sessions

```
POST /v1/sessions/push
  { "deviceID": "…", "sessions": [FocusSession, …] }
  → 200 { "accepted": n }

GET  /v1/sessions/pull?cursor=<opaque>
  → 200 { "sessions": [FocusSession, …], "cursor": "<opaque>", "more": false }

GET  /healthz
  → 200 ok
```

`accepted` counts rows that won the merge; older or equal rows are ignored.
A bad row fails the whole push with `400 { "error": "…" }`. Pulls come in
pages of 500; start with `cursor=0` and repeat while `more` is true.

`cursor` is a server-assigned sequence number, not a device timestamp, so a
device with a wrong clock can't make other devices skip rows. The server
stamps each row with a sequence number as it arrives.

## FocusSession JSON

```json
{
  "id": "6F1C…",
  "startedAt": "2026-09-26T13:00:00Z",
  "endedAt": "2026-09-26T13:25:00Z",
  "focusSeconds": 1500,
  "plannedSeconds": 1500,
  "completed": true,
  "tag": "15-213",
  "deviceID": "A1B2…",
  "updatedAt": "2026-09-26T13:25:00Z",
  "deletedAt": null
}
```

Dates are ISO-8601 with a zone; the server returns whole-second UTC (`Z`),
which Swift's `.iso8601` strategy decodes. IDs come back uppercase. Each
client buckets sessions into days in its own time zone.

## Hosted sync (Supabase)

With no server in settings, the apps sync through drill's Supabase project
(`SupabaseAPI.swift`, `SupabaseApi.kt`). Same rows, same merge rule, same
cursor; only the calls differ. The schema is
`supabase/migrations/20261005000000_sessions.sql`.

- **Accounts** are Supabase Auth users (email and password). Signing up
  (`/auth/v1/signup`) emails a link that lands on `site/confirmed/`. The
  app keeps the new user's id and asks
  `POST /rest/v1/rpc/email_confirmed { user_id }` every few seconds; once
  it says `true`, the app signs in by itself. `/auth/v1/resend` sends the
  link again. Sign-in is
  `/auth/v1/token?grant_type=password`. Access tokens last an hour; the apps
  swap them with the refresh token before a sync, and once more if a call
  comes back 401.
- **Push** is `POST /rest/v1/rpc/push_sessions { sessions: [FocusSession] }`
  → the number of rows that won. Accounts that haven't confirmed their email
  get `403` (`42501`).
- **Pull** is `POST /rest/v1/rpc/pull_sessions { after: <cursor> }` →
  `{ sessions, cursor, more }`, as above.

Clients send the project's publishable key as `apikey`. It's public by
design; the table only lets each user read their own rows, and only
`push_sessions` writes.

## Client loop

`web/static/store.js`, `Sources/DrillApp/Sync.swift` and the android
app's `Sync.kt` all do this:

1. `store.changes(since: lastPushedAt)` → push in batches → on success, save
   `lastPushedAt` (taken before reading the changes).
2. Pull with the saved cursor → `store.save` each row → save the new cursor.
   Repeat while `more` is true.
3. Run at launch, after each logged session, every few minutes, and when the
   sync button is pressed.

On sign-in, a client forgets its push mark and cursor, so everything already
on the device joins the account and the whole account comes down.

Servers from before accounts kept one shared history. On first start the
server renames that table to `sessions_before_accounts` and leaves it alone.
