import { Hono } from "hono";
import type { MiddlewareHandler } from "hono";
import { bearerAuth } from "hono/bearer-auth";

type Bindings = {
  DB: D1Database;
  API_TOKEN: string;
  // Comma-separated list of table names this deployment serves, e.g.
  // "notes,note_folders" or "reminders,calendar_events,reminder_lists".
  // Sourced from wrangler `vars`. The Worker is entity-agnostic: it serves
  // exactly these tables and rejects any other name, so a deployment never
  // depends on entities a consumer did not configure.
  ENTITIES?: string;
};

type PushItem = {
  id: string;
  data: unknown;
  last_modified: string;
};

type PushRequest = {
  device_id: string;
  items: PushItem[];
};

const MAX_BATCH_SIZE = 500;

// Hardcoded SQL per entity to avoid any table-name injection risk.
// Each key maps to the full set of prepared statements needed.
type EntitySQL = {
  upsert: string;
  selectPage: string;
  softDelete: string;
  purgeDeleted: string;
};

// The pull cursor is keyed on `seq`, a strictly increasing per-table integer the
// Worker bumps on every applied write (see migration 0002). `?1` is the cursor
// seq and `?2` its id tiebreaker. `?4` is the requesting device:
// `source_device IS NOT ?4` excludes a device's own writes (NULL-safe), and
// `?4 = ''` disables the filter when no device is given.
function selectPageSQL(table: string): string {
  return (
    `SELECT id, data, deleted, updated_at, last_modified, seq FROM ${table} ` +
    "WHERE (seq > ?1 OR (seq = ?1 AND id > ?2)) " +
    "AND (?4 = '' OR source_device IS NOT ?4) " +
    "ORDER BY seq ASC, id ASC LIMIT ?3"
  );
}

// `seq = MAX(seq)+1` makes every applied write land past any cursor a device
// already holds, so a change can never be stranded by a cursor that sits above
// it. Evaluated before the row is written, so it sees the current table max; on
// a conflicting update it still exceeds the row's own seq.
function upsertSQL(table: string): string {
  return (
    `INSERT INTO ${table} (id, data, last_modified, updated_at, source_device, seq)
      VALUES (?1, ?2, ?3, datetime('now'), ?4, (SELECT IFNULL(MAX(seq), 0) + 1 FROM ${table}))
      ON CONFLICT(id) DO UPDATE SET
        data = excluded.data, last_modified = excluded.last_modified,
        deleted = 0, updated_at = datetime('now'), source_device = excluded.source_device,
        seq = (SELECT IFNULL(MAX(seq), 0) + 1 FROM ${table})
      WHERE ${table}.last_modified <= excluded.last_modified`
  );
}

function entitySQL(table: string): EntitySQL {
  return {
    upsert: upsertSQL(table),
    selectPage: selectPageSQL(table),
    softDelete: `UPDATE ${table} SET deleted = 1, updated_at = datetime('now'), seq = (SELECT IFNULL(MAX(seq), 0) + 1 FROM ${table}) WHERE id = ? AND last_modified <= ?`,
    purgeDeleted: `DELETE FROM ${table} WHERE deleted = 1 AND updated_at < datetime('now', '-30 days')`,
  };
}

// Identifiers are baked into SQL strings at construction time, so a table name
// must match this allowlist before it is ever interpolated. Anything else is
// rejected, preserving the no-injection guarantee of the original per-entity
// hardcoded map.
const TABLE_NAME = /^[a-z_][a-z0-9_]*$/;

// Parse the ENTITIES binding into a validated table set once per worker
// instance. Same memoize pattern as authMiddleware below: the binding only
// changes when the worker is redeployed, so we compute the SQL map lazily and
// cache it on the closure.
function buildEntitySQL(entities?: string): Map<string, EntitySQL> {
  const map = new Map<string, EntitySQL>();
  if (!entities) {
    return map;
  }
  for (const raw of entities.split(",")) {
    const name = raw.trim();
    if (!name) {
      continue;
    }
    if (!TABLE_NAME.test(name)) {
      throw new Error(`Invalid entity name in ENTITIES: '${name}'`);
    }
    map.set(name, entitySQL(name));
  }
  return map;
}

let cachedEntities: Map<string, EntitySQL> | null = null;
function entitiesFor(env: Bindings): Map<string, EntitySQL> {
  cachedEntities ??= buildEntitySQL(env.ENTITIES);
  return cachedEntities;
}

function getSQL(env: Bindings, entity: string): EntitySQL | null {
  return entitiesFor(env).get(entity) ?? null;
}

// Normalize an ISO 8601 timestamp to UTC for consistent string comparison.
// Accepts "2026-03-10T14:00:00Z", "2026-03-10T14:00:00+08:00", or bare
// "2026-03-10 14:00:00". Returns null when the input is not a valid date.
function normalizeTimestamp(ts: string): string | null {
  const d = new Date(ts);
  if (isNaN(d.getTime())) {
    return null;
  }
  return d.toISOString();
}

// Delete soft-deleted records older than 30 days across all configured entities.
async function purgeExpired(env: Bindings): Promise<Record<string, number>> {
  const entities = entitiesFor(env);
  const results = await env.DB.batch(
    [...entities.values()].map((sql) => env.DB.prepare(sql.purgeDeleted))
  );
  const purged: Record<string, number> = {};
  let i = 0;
  for (const name of entities.keys()) {
    purged[name] = results[i].meta.changes ?? 0;
    i++;
  }
  return purged;
}

const app = new Hono<{ Bindings: Bindings }>();

// Auth middleware for all /api/* routes. The handler is memoized per worker
// instance since the token only changes when the worker is redeployed.
let authMiddleware: MiddlewareHandler | undefined;
app.use("/api/*", (c, next) => {
  authMiddleware ??= bearerAuth({ token: c.env.API_TOKEN });
  return authMiddleware(c, next);
});

// Health check (no auth required). Reports whether ENTITIES was configured so a
// misconfigured deployment is visible without triggering a 500 on every request.
app.get("/health", (c) => {
  const entities = entitiesFor(c.env);
  return c.json({ status: entities.size > 0 ? "ok" : "misconfigured", entities: [...entities.keys()] });
});

// Push: batch upsert with last-write-wins
app.post("/api/v1/:entity/push", async (c) => {
  const sql = getSQL(c.env, c.req.param("entity"));
  if (!sql) {
    return c.json({ error: "Invalid entity" }, 400);
  }

  let body: PushRequest;
  try {
    body = await c.req.json<PushRequest>();
  } catch {
    return c.json({ error: "Invalid JSON body" }, 400);
  }

  const { device_id, items } = body;

  if (!device_id || !Array.isArray(items)) {
    return c.json({ error: "Missing device_id or items" }, 400);
  }

  if (items.length === 0) {
    return c.json({ synced: 0, skipped: 0 });
  }

  if (items.length > MAX_BATCH_SIZE) {
    return c.json(
      { error: `Batch size ${items.length} exceeds maximum of ${MAX_BATCH_SIZE}` },
      400
    );
  }

  // Atomic upsert: INSERT ... ON CONFLICT with last_modified guard
  const stmts: D1PreparedStatement[] = [];
  for (const item of items) {
    if (!item || typeof item.id !== "string" || item.id.length === 0) {
      return c.json({ error: "Each item requires a non-empty string id" }, 400);
    }
    const normalizedLM = normalizeTimestamp(item.last_modified);
    if (normalizedLM === null) {
      return c.json({ error: `Invalid last_modified for item '${item.id}'` }, 400);
    }
    stmts.push(
      c.env.DB.prepare(sql.upsert).bind(
        item.id,
        JSON.stringify(item.data),
        normalizedLM,
        device_id
      )
    );
  }

  const results = await c.env.DB.batch(stmts);
  const synced = results.reduce((n, r) => n + (r.meta.changes ?? 0), 0);

  return c.json({ synced, skipped: items.length - synced });
});

// Pull: incremental cursor-based fetch using composite (seq, id) cursor
app.get("/api/v1/:entity/pull", async (c) => {
  const sql = getSQL(c.env, c.req.param("entity"));
  if (!sql) {
    return c.json({ error: "Invalid entity" }, 400);
  }

  const rawCursor = c.req.query("cursor") ?? "";
  const device = c.req.query("device") ?? "";
  const limit = 101; // fetch one extra to detect has_more

  let cursorSeq: number;
  let cursorId: string;

  if (rawCursor === "") {
    cursorSeq = 0;
    cursorId = "";
  } else {
    const pipeIdx = rawCursor.indexOf("|");
    const seqPart = pipeIdx === -1 ? rawCursor : rawCursor.slice(0, pipeIdx);
    const idPart = pipeIdx === -1 ? "" : rawCursor.slice(pipeIdx + 1);
    if (pipeIdx !== -1 && seqPart === "") {
      return c.json({ error: "Invalid cursor" }, 400);
    }
    if (/^\d+$/.test(seqPart)) {
      cursorSeq = Number(seqPart);
      cursorId = idPart;
    } else {
      // A non-integer seq segment is a legacy `updated_at` timestamp cursor left
      // over from before migration 0002. Restart from the beginning so the
      // device re-pulls and re-converges instead of stranding forever.
      cursorSeq = 0;
      cursorId = "";
    }
  }

  const { results } = await c.env.DB.prepare(sql.selectPage)
    .bind(cursorSeq, cursorId, limit, device)
    .all<{
      id: string;
      data: string;
      deleted: number;
      updated_at: string;
      last_modified: string;
      seq: number;
    }>();

  const hasMore = results.length === limit;
  const page = hasMore ? results.slice(0, limit - 1) : results;

  const items = page.flatMap((row) => {
    try {
      return [
        {
          id: row.id,
          data: JSON.parse(row.data),
          deleted: row.deleted === 1,
          updated_at: row.updated_at,
          last_modified: row.last_modified,
        },
      ];
    } catch (parseError) {
      console.error(`Failed to parse ${c.req.param("entity")} item ${row.id}:`, parseError);
      return [];
    }
  });

  const last = page[page.length - 1];
  // Always emit a normalized seq cursor so a legacy timestamp cursor is never
  // echoed back and stored again.
  const newCursor = last ? `${last.seq}|${last.id}` : `${cursorSeq}|${cursorId}`;

  return c.json({ items, cursor: newCursor, has_more: hasMore });
});

// Soft delete with last_modified guard
app.delete("/api/v1/:entity/:id", async (c) => {
  const sql = getSQL(c.env, c.req.param("entity"));
  const id = c.req.param("id");

  if (!sql) {
    return c.json({ error: "Invalid entity" }, 400);
  }

  const body: { last_modified?: string } = await c.req
    .json<{ last_modified?: string }>()
    .catch(() => ({}));

  let lastModified: string;
  if (typeof body.last_modified === "string") {
    const normalized = normalizeTimestamp(body.last_modified);
    if (normalized === null) {
      return c.json({ error: "Invalid last_modified" }, 400);
    }
    lastModified = normalized;
  } else {
    lastModified = new Date().toISOString();
  }

  const result = await c.env.DB.prepare(sql.softDelete).bind(id, lastModified).run();

  return c.json({ deleted: (result.meta.changes ?? 0) > 0 });
});

// Purge soft-deleted records older than 30 days (manual trigger;
// also runs on the scheduled cron defined in wrangler.toml)
app.post("/api/v1/purge", async (c) => {
  return c.json({ purged: await purgeExpired(c.env) });
});

export default {
  fetch: app.fetch,
  async scheduled(_event, env) {
    await purgeExpired(env);
  },
} satisfies ExportedHandler<Bindings>;
