# sync contract

Backend: drill's Supabase project, schema in `supabase/migrations/`. Clients:
web (`web/static/supabase.js`, driven by `store.js`), mac (`SupabaseAPI` in
`mac/Sources/DrillCore`, driven by `DrillApp/Sync.swift`), android
(`SupabaseApi.kt`, `Sync.kt` in `android/.../data`), windows
(`windows/Drill.Core/Sync`, driven by `windows/Drill/Services/Sync.cs`).

Supabase keeps the union of every device's sessions and hands back what each
device hasn't seen. Devices merge with one rule.

## Merge rule

Rows are keyed by `id` (UUID). **For each `id`, the row with the greater
`updatedAt` wins.** Deletes are tombstones (`deletedAt` set, `updatedAt`
bumped), so a delete also wins by being the newer write. Rows are never
hard-deleted. `SQLiteSessionStore.save` already enforces this rule, so saving a
pulled row is the whole merge.

## Accounts

An email and a password (`20261015075640_emails.sql`). Apps trim and lowercase the
email; it's valid when it matches `^[^\s@]+@[^\s@]+\.[^\s@]+$` and is at
most 254 characters. Passwords need 6+ characters (Supabase's floor), at most 72 UTF-8 bytes. Email confirmation
is off: the email isn't verified at sign-up; it's kept for account recovery.

```
POST /rest/v1/rpc/email_available   { "email": "…" } → true | false
  anon key, no auth; whether no account has that email yet
POST /auth/v1/signup   { "email": "…", "password": "…" }
  → tokens, same shape as sign-in
POST /auth/v1/token?grant_type=password   { "email": "…", "password": "…" }
POST /auth/v1/token?grant_type=refresh_token
POST /auth/v1/logout
```

Every REST call sends the publishable key as `apikey`; signed-in calls add
`Authorization: Bearer <access token>`. Access tokens last an hour; apps swap
them with the refresh token before a sync, and once more if a call comes back
`401`.

Error mapping, from the Auth reply's `error_code`/`msg`:

- sign-up: message containing `Database error`, `user_already_exists` or
  `email_exists` → "an account with this email already exists";
  `email_address_invalid` → "that email doesn't look right"; `weak_password` →
  "use at least 6 characters".
- sign-in: `invalid_credentials` or `invalid_grant` → "wrong email or password".

Apps store and show the account's email, updating it from `user.email` on
every token refresh. An account stored by an older version (email ending
`@users.mmerioles.github.io`) stays signed in; on launch, when online, the app
refreshes once to pick up the real email.
- anything else: the generic unreachable/rejected copy.

## Sessions

`20261006061038_sessions.sql`. Clients never touch `public.sessions`
directly; they call two RPCs as the signed-in user:

```
POST /rest/v1/rpc/push_sessions   { "sessions": [FocusSession, …] }
  push_sessions(sessions jsonb) → integer    rows that won the merge

POST /rest/v1/rpc/pull_sessions   { "after": <cursor> }
  pull_sessions(after bigint default 0) → jsonb
  → { "sessions": [FocusSession, …], "cursor": "<n>", "more": false }
```

Push takes at most 500 rows; the newest copy of an id wins within a batch.
Older or equal rows are ignored. A bad row fails the whole push (`22023`,
message `bad session: …`); no session → `28000` "sign in again"; `42501` is
a 403 (the function still requires `email_confirmed_at`, which Supabase sets
at sign-up with confirmation off).

`cursor` is a server-assigned sequence number (`sessions_seq`) restamped on
each row every time it's written, so `seq > cursor` is exactly what a device
hasn't seen and a wrong device clock can't make others skip rows. Pulls come
in pages of 500 ordered by `seq`; start with `after: 0`, save the returned
`cursor` (a string; it equals `after` when nothing came back) and repeat
while `more` is true.

Row-level security: `sessions` is readable only by its own
user (`user_id = auth.uid()`); nothing is writable from a client. Writes go
through `push_sessions`, which runs as definer and stamps `auth.uid()` on
every row. The publishable key is public by design.

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
which Swift's `.iso8601` strategy decodes. IDs come back uppercase. An empty
`tag` is stored as null. Each client buckets sessions into days in its own
time zone.

## Client loop

Every client (`store.js`, `Sync.swift`, `Sync.kt`, `Sync.cs`):

1. `store.changes(since: lastPushedAt)` → push in batches → on success, save
   `lastPushedAt` (taken before reading the changes).
2. Pull with the saved cursor → `store.save` each row → save the new cursor.
   Repeat while `more` is true.
3. Run at launch, after each logged session, every few minutes, and when the
   sync button is pressed.

Sessions belong to one account, and an account is required: signed out,
the apps show only the sign-in screen. Each client keeps one store per
signed-in account, keyed by its Supabase user id, with that account's own
push mark and cursor. Signing in or making an account opens that account's
store (a new one starts empty), pulls from `0` and pushes only that store's
rows; nothing ever moves between accounts. A pre-accounts offline store is
left on disk untouched. Signing out pushes what it can (asking first if that
fails), then deletes the account's store and marks. With "stay signed in"
off, quitting does the same.
