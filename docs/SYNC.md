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

A username and a password (`20261015024006_usernames.sql`). Usernames are
3–20 characters of `a-z 0-9 _`; apps lowercase and trim as the user types.
Passwords need at least 8 characters.

Supabase Auth wants an email, so each app derives one and never shows it:
`<username>@users.mmerioles.github.io`. The username shown in the app is the
account's email with the domain stripped. Email confirmation is off.

```
POST /rest/v1/rpc/username_available   { "name": "…" } → true | false
  anon key, no auth; false for names that fail the rule too
POST /auth/v1/signup
  { "email": synthetic, "password": "…", "data": { "username": "…" } }
  → tokens, same shape as sign-in. A trigger on auth.users makes
    public.profiles (user_id, username unique); a taken or bad name fails
    the sign-up.
POST /auth/v1/token?grant_type=password   { "email": synthetic, "password" }
POST /auth/v1/token?grant_type=refresh_token
POST /auth/v1/logout
```

Every REST call sends the publishable key as `apikey`; signed-in calls add
`Authorization: Bearer <access token>`. Access tokens last an hour; apps swap
them with the refresh token before a sync, and once more if a call comes back
`401`.

Error mapping, from the Auth reply's `error_code`/`msg`:

- sign-up: message containing `Database error`, or `user_already_exists` →
  "that username is taken"; `weak_password` → "use at least 8 characters".
- sign-in: `invalid_credentials` → "wrong username or password".
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

Row-level security: `sessions` and `profiles` are readable only by their own
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

On sign-in a client resets its push mark and cursor, so local sessions join
the account and the whole account comes down.
