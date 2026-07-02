# apple-sync-worker

The canonical Cloudflare D1 sync Worker shared by the `note` and `event` CLIs.
It is **entity-agnostic**: a single deployment serves whichever tables you
declare in the `ENTITIES` wrangler var. The recommended setup is **one Worker
and one D1 serving every table**, with both CLIs pointed at the same URL and
token (encryption keys stay independent — the Worker only stores opaque blobs).

The kit ships **no business migrations**. Each consumer CLI owns its own table
schemas and the SQL migrations that create them; the Worker only provides the
runtime. Point `migrations_dir` at the consumer repo's migration directory.

## What it does

Bidirectional, last-write-wins sync over D1, matching the algorithm in
`AppleSyncKit` (`Sources/AppleSyncKit/Engine/SyncEngine.swift`):

- `POST /api/v1/:entity/push` — batch upsert, `last_modified` guard (≤500 items)
- `GET  /api/v1/:entity/pull` — incremental, composite `(seq, id)` cursor, excludes the caller's own writes
- `DELETE /api/v1/:entity/:id` — soft delete with tombstones
- `POST /api/v1/purge` — drops tombstones older than 30 days (also runs on a daily cron)
- `GET /health` — no auth; reports the configured entity set

All writes are bearer-token authenticated. `MAX_BATCH_SIZE = 500` must stay
aligned with `maxBatchSize` in `Sources/AppleSyncKit/Network/D1SyncClient.swift`.

## Deploy

### 1. Create a D1 database

```sh
wrangler d1 create apple-sync
# copy the database_id from the output
```

### 2. Configure

Copy `wrangler.toml.example` to `wrangler.toml` and fill in your `database_id`.
Set `ENTITIES` to the comma-separated table list your consumers use, and point
`migrations_dir` at the consumer repo's migration directory (the kit does not
provide migrations):

Migrations live in the consumer repo. For example, `note` ships its schemas
(`notes`, `note_folders`, `note_preferences`) under
`skills/apple-notes/references/migrations/`; `event` ships its own. For a shared
note + event D1, merge both consumers' migration directories into one
`migrations_dir` (namespaced filenames like `0001_note_*`, `0001_event_*` avoid
collisions in D1's `d1_migrations` table) and list every entity in `ENTITIES`.
See each consumer's cloud-sync docs for the merge procedure.

| You use | `ENTITIES` | `migrations_dir` |
|---|---|---|
| note only | `notes,note_folders,note_preferences` | note's `references/migrations` |
| event only | `reminders,calendar_events,reminder_lists` | event's migrations dir |
| both (shared D1) | all of the above | merged dir (see consumer docs) |

Set the auth token as a secret:

```sh
wrangler secret put API_TOKEN
# generate one: openssl rand -base64 32
```

### 3. Apply migrations

`wrangler d1 migrations apply` reads `migrations_dir` from `wrangler.toml`. Run
it from the consumer repo that owns the migrations, or from this Worker dir if
your `wrangler.toml` points `migrations_dir` at the consumer path:

```sh
pnpm install
pnpm run db:migrate            # applies locally; reads migrations_dir from wrangler.toml
pnpm run db:migrate:remote     # :remote variant applies to production D1
```

### 4. Deploy

```sh
pnpm run deploy
```

Point both CLIs at the deployed URL (env-first, then config file). For the shared
Worker, `NOTE_SYNC_API_URL` and `EVENT_SYNC_API_URL` are the same URL, and
`NOTE_SYNC_API_TOKEN` and `EVENT_SYNC_API_TOKEN` are the same token; the
encryption keys stay independent:

```sh
# note
NOTE_SYNC_API_URL=https://<your-worker>.workers.dev NOTE_SYNC_API_TOKEN=<token> \
  NOTE_SYNC_DEVICE_ID=<machine-name> .build/debug/note sync config ...
# event (same URL + token)
EVENT_SYNC_API_URL=https://<your-worker>.workers.dev EVENT_SYNC_API_TOKEN=<token> \
  EVENT_SYNC_DEVICE_ID=<machine-name> .build/debug/event sync config ...
```

## Develop

```sh
pnpm install
pnpm run dev          # local wrangler dev
pnpm test            # vitest-pool-workers against local Miniflare D1
pnpm run typecheck
```
