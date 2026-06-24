# apple-sync-worker

The canonical Cloudflare D1 sync Worker shared by the `note` and `event` CLIs.
It is **entity-agnostic**: a single deployment serves whichever tables you
declare in the `ENTITIES` wrangler var. The recommended setup is **one Worker
and one D1 serving every table**, with both CLIs pointed at the same URL and
token (encryption keys stay independent — the Worker only stores opaque blobs).
A single-entity deployment is still supported as a variant.

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
The example defaults to the shared setup; pick the `ENTITIES` value and matching
`migrations_dir` for your usage:

| You use | `ENTITIES` | `migrations_dir` |
|---|---|---|
| both (recommended) | `notes,note_folders,reminders,calendar_events,reminder_lists` | `migrations/all` |
| note only | `notes,note_folders` | `migrations/notes` |
| event only | `reminders,calendar_events,reminder_lists` | `migrations/events` |

Set the auth token as a secret:

```sh
wrangler secret put API_TOKEN
# generate one: openssl rand -base64 32
```

### 3. Apply migrations

`wrangler d1 migrations apply` reads `migrations_dir` from `wrangler.toml`, so
set that to match your usage before running:

```sh
pnpm install
pnpm run db:migrate            # applies locally; reads migrations_dir from wrangler.toml
pnpm run db:migrate:remote     # :remote variant applies to production D1
```

The default `migrations/all` creates every table in one pass. (`migrations/all`
is just the per-entity files renumbered into one sequence; the `migrations/notes`
and `migrations/events` directories remain for single-entity deployments.)

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
