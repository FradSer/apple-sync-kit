import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  // The kit ships NO business migrations. Tests exercise the entity-agnostic
  // runtime against a single synthetic fixture table (kit_test_items) so they
  // never depend on any consumer's business schema. Consumer repos own their
  // real migrations and run their own worker tests.
  const fixtures = await readD1Migrations("./test/fixtures/migrations");

  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            API_TOKEN: "test-token",
            TEST_MIGRATIONS: fixtures,
          },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/apply-migrations.ts"],
    },
  };
});
