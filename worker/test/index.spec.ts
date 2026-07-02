import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

// The kit ships no business migrations. These tests exercise the entity-agnostic
// runtime against a single synthetic fixture table (kit_test_items) so they
// never reference any consumer's business schema (notes, events, etc.).
// Consumer repos own their real migrations and their own worker tests.

const BASE = "https://example.com";
const AUTH = { Authorization: "Bearer test-token" };
const ENTITY = "kit_test_items";

// Start every test from an empty table so cases never observe each other's rows.
beforeEach(async () => {
  await env.DB.batch([env.DB.prepare("DELETE FROM kit_test_items")]);
});

type PushItem = { id: string; data: unknown; last_modified: string };
type PushBody = { synced: number; skipped: number };
type PullItem = {
  id: string;
  data: unknown;
  deleted: boolean;
  updated_at: string;
  last_modified: string;
};
type PullBody = { items: PullItem[]; cursor: string; has_more: boolean };

function push(deviceId: string, items: PushItem[]): Promise<Response> {
  return SELF.fetch(`${BASE}/api/v1/${ENTITY}/push`, {
    method: "POST",
    headers: { ...AUTH, "Content-Type": "application/json" },
    body: JSON.stringify({ device_id: deviceId, items }),
  });
}

async function pull(opts: { device?: string; cursor?: string } = {}): Promise<PullBody> {
  const params = new URLSearchParams();
  if (opts.device) params.set("device", opts.device);
  if (opts.cursor) params.set("cursor", opts.cursor);
  const query = params.toString();
  const res = await SELF.fetch(
    `${BASE}/api/v1/${ENTITY}/pull${query ? `?${query}` : ""}`,
    { headers: AUTH }
  );
  expect(res.status).toBe(200);
  return (await res.json()) as PullBody;
}

describe("health", () => {
  it("responds without auth and lists configured entities", async () => {
    const res = await SELF.fetch(`${BASE}/health`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string; entities: string[] };
    expect(body.status).toBe("ok");
    expect(body.entities).toEqual([ENTITY]);
  });
});

describe("auth", () => {
  it("rejects API requests without a bearer token", async () => {
    const res = await SELF.fetch(`${BASE}/api/v1/${ENTITY}/pull`);
    expect(res.status).toBe(401);
  });

  it("rejects the purge endpoint without a bearer token", async () => {
    const res = await SELF.fetch(`${BASE}/api/v1/purge`, { method: "POST" });
    expect(res.status).toBe(401);
  });
});

describe("entities", () => {
  it("rejects an unknown entity", async () => {
    const res = await SELF.fetch(`${BASE}/api/v1/widgets/push`, {
      method: "POST",
      headers: { ...AUTH, "Content-Type": "application/json" },
      body: JSON.stringify({
        device_id: "device-a",
        items: [{ id: "x", data: {}, last_modified: "2026-03-10T10:00:00Z" }],
      }),
    });
    expect(res.status).toBe(400);
  });
});

describe("push / pull", () => {
  it("pushes an item and pulls it back from another device", async () => {
    const res = await push("device-a", [
      {
        id: "i1",
        data: { label: "anything", payload: "opaque-blob" },
        last_modified: "2026-03-10T10:00:00Z",
      },
    ]);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ synced: 1, skipped: 0 } satisfies PushBody);

    const body = await pull({ device: "device-b" });
    expect(body.items).toHaveLength(1);
    expect(body.items[0].id).toBe("i1");
    expect(body.items[0].data).toEqual({ label: "anything", payload: "opaque-blob" });
    expect(body.items[0].deleted).toBe(false);
  });

  it("excludes a device's own writes on pull", async () => {
    await push("device-a", [
      { id: "i1", data: { label: "mine" }, last_modified: "2026-03-10T10:00:00Z" },
    ]);
    const own = await pull({ device: "device-a" });
    expect(own.items).toHaveLength(0);

    const other = await pull({ device: "device-b" });
    expect(other.items).toHaveLength(1);
  });

  it("rejects a stale push via the last-write-wins guard", async () => {
    await push("device-a", [
      { id: "i1", data: { label: "current" }, last_modified: "2026-03-10T12:00:00Z" },
    ]);
    const res = await push("device-a", [
      { id: "i1", data: { label: "stale" }, last_modified: "2026-03-10T09:00:00Z" },
    ]);
    expect(await res.json()).toEqual({ synced: 0, skipped: 1 } satisfies PushBody);

    const body = await pull({ device: "device-b" });
    expect(body.items[0].data).toEqual({ label: "current" });
  });

  it("rejects a batch larger than the maximum", async () => {
    const items = Array.from({ length: 501 }, (_, i) => ({
      id: `i${i}`,
      data: {},
      last_modified: "2026-03-10T10:00:00Z",
    }));
    const res = await push("device-a", items);
    expect(res.status).toBe(400);
  });

  it("rejects a malformed JSON body", async () => {
    const res = await SELF.fetch(`${BASE}/api/v1/${ENTITY}/push`, {
      method: "POST",
      headers: { ...AUTH, "Content-Type": "application/json" },
      body: "{ not json",
    });
    expect(res.status).toBe(400);
  });

  it("rejects an item with an unparseable last_modified", async () => {
    const res = await push("device-a", [
      { id: "i1", data: {}, last_modified: "not-a-date" },
    ]);
    expect(res.status).toBe(400);
  });

  it("paginates with a stable composite cursor", async () => {
    const items = Array.from({ length: 150 }, (_, i) => ({
      id: `i${String(i).padStart(3, "0")}`,
      data: { label: `item ${i}` },
      last_modified: "2026-03-10T10:00:00Z",
    }));
    expect((await push("device-a", items)).status).toBe(200);

    const first = await pull({ device: "device-b" });
    expect(first.items).toHaveLength(100);
    expect(first.has_more).toBe(true);

    const second = await pull({ device: "device-b", cursor: first.cursor });
    expect(second.items).toHaveLength(50);
    expect(second.has_more).toBe(false);
  });
});

describe("delete", () => {
  it("soft-deletes an item and surfaces the tombstone on pull", async () => {
    await push("device-a", [
      { id: "i1", data: { label: "doomed" }, last_modified: "2026-03-10T10:00:00Z" },
    ]);

    const res = await SELF.fetch(`${BASE}/api/v1/${ENTITY}/i1`, {
      method: "DELETE",
      headers: { ...AUTH, "Content-Type": "application/json" },
      body: JSON.stringify({ last_modified: "2026-03-10T11:00:00Z" }),
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ deleted: true });

    const body = await pull({ device: "device-b" });
    expect(body.items).toHaveLength(1);
    expect(body.items[0].deleted).toBe(true);
  });
});

describe("purge", () => {
  it("purges soft-deleted records older than 30 days", async () => {
    await push("device-a", [
      { id: "i1", data: { label: "old" }, last_modified: "2026-03-10T10:00:00Z" },
    ]);
    await SELF.fetch(`${BASE}/api/v1/${ENTITY}/i1`, {
      method: "DELETE",
      headers: { ...AUTH, "Content-Type": "application/json" },
      body: JSON.stringify({ last_modified: "2026-03-10T11:00:00Z" }),
    });

    // Backdate the tombstone so it is older than the 30-day purge window.
    await env.DB.prepare(
      "UPDATE kit_test_items SET updated_at = datetime('now', '-31 days') WHERE id = ?"
    )
      .bind("i1")
      .run();

    const res = await SELF.fetch(`${BASE}/api/v1/purge`, {
      method: "POST",
      headers: AUTH,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { purged: Record<string, number> };
    expect(body.purged[ENTITY]).toBeGreaterThan(0);

    const pulled = await pull({ device: "device-b" });
    expect(pulled.items).toHaveLength(0);
  });
});
