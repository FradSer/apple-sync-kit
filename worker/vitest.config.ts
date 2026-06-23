import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  // Resolved relative to the worker directory, where Vitest loads this config.
  // Load both entity migrations so a single test D1 can serve notes *and*
  // events tables (the dual-use deployment shape).
  const notes = await readD1Migrations("./migrations/notes");
  const events = await readD1Migrations("./migrations/events");

  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            API_TOKEN: "test-token",
            TEST_MIGRATIONS: [...notes, ...events],
          },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/apply-migrations.ts"],
    },
  };
});
