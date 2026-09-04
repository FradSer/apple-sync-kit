# Repository Guidelines

This directory contains the canonical Cloudflare D1 sync Worker (`apple-sync-worker`) backing `AppleSyncKit`.

## Project Structure & Module Organization

- **`src/index.ts`**: Hono application exposing `/api/v1/:entity/push`, `/api/v1/:entity/pull`, soft delete, `/api/v1/purge`, and `/health` endpoints.
- **`test/`**: Integration tests executed via Vitest and `@cloudflare/vitest-pool-workers` against local Miniflare D1.
- **`wrangler.toml`**: Cloudflare Workers configuration, bindings (`DB`), and entity environment variables (`ENTITIES`).
- *Note on tooling*: `@fradser/pi-kit` workspace runtime is absent in this package.

## Development & Test Commands

- **Install dependencies**: `pnpm install`
- **Run tests**: `pnpm test`
- **Type check**: `pnpm run typecheck`
- **Local dev server**: `pnpm run dev`
- **Apply migrations locally**: `pnpm run db:migrate`
- **Apply migrations remotely**: `pnpm run db:migrate:remote`
- **Deploy**: `pnpm run deploy`

## Invariants & Design Rules

- **Batch Size**: `MAX_BATCH_SIZE = 500` must stay exactly synchronized with `maxBatchSize` in `Sources/AppleSyncKit/Network/D1SyncClient.swift`.
- **Entity Agnostic**: The Worker defines no domain schemas. Tables are configured via the `ENTITIES` environment variable in `wrangler.toml`.
- **Migrations**: The kit ships no business migrations. Consumer CLIs own their table schemas and point `migrations_dir` in `wrangler.toml` to their migration files.
- **Authentication**: All API endpoints (except `/health`) require bearer token authentication matching `API_TOKEN`.
