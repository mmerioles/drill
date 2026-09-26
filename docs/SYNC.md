# sync contract (draft)

The home server's job is small: keep the union of every device's sessions and
hand back what each device hasn't seen yet. Devices do all merging themselves
with a single rule.

## Merge rule

Rows are keyed by `id` (UUID). **For each `id`, the row with the greater
`updatedAt` wins.** Deletes are tombstones (`deletedAt` set, `updatedAt`
bumped), so a delete also wins by being the newer write. Rows are never
hard-deleted. `SQLiteSessionStore.save` already enforces this rule, so saving a
pulled row is the whole merge.

## Endpoints

Auth for all endpoints: `Authorization: Bearer <token>`, one token per device.

```
POST /v1/sessions/push
  { "deviceID": "…", "sessions": [FocusSession, …] }
  → 200 { "accepted": n }

GET  /v1/sessions/pull?cursor=<opaque>
  → 200 { "sessions": [FocusSession, …], "cursor": "<opaque>", "more": false }
```

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

Dates are ISO-8601 UTC. Each client buckets sessions into days in its own time
zone.

## Client loop (`HTTPSync`, to be written)

1. `store.changes(since: lastPushedAt)` → push → on success, save `lastPushedAt`.
2. Pull with the saved cursor → `store.save` each row → save the new cursor.
   Repeat while `more` is true.
3. Run at launch, after each logged session, and every few minutes while the app is open.
