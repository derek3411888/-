import assert from "node:assert/strict";
import test from "node:test";

process.env.SESSION_SECRET = "fixture-session-secret-0000000000000000";
process.env.CODEX_BRIDGE_TOKEN = "fixture-bridge-secret-0000000000000000";
process.env.LIVE_TOKEN_SECRET = "fixture-live-secret-0000000000000000000";
process.env.LIVE_SRT_PASSPHRASE = "fixture-srt-secret-00000000000000000000";
process.env.SELFHOST_ONLY = "true";
// Old deployment settings must not resurrect a retired transport.
process.env.FIRESTORE_IMPORT_ENABLED = "true";
process.env.FIRESTORE_PROJECT_ID = "fixture-never-connect";
process.env.FIRESTORE_API_KEY = "fixture-not-a-credential";
const { config } = await import("../src/config.js");
const { pool } = await import("../src/db.js");
const bridge = await import("../src/firestore-bridge.js");

test("explicit retirement suppresses old import flag and all cloud entry points", async (t) => {
  let networkCalls = 0;
  t.mock.method(globalThis, "fetch", async () => { networkCalls++; throw new Error("forbidden external network"); });
  t.mock.method(pool, "query", async () => { throw new Error("unexpected database mutation"); });
  assert.equal(config.firestore.enabled, false);
  assert.deepEqual(await bridge.importFirestoreDevices(), { enabled: false, imported: 0 });
  assert.deepEqual(await bridge.publishDiscovery(), { published: 0, failed: 0 });
  assert.deepEqual(await bridge.syncFallbackCommandBaselines(), { enabled: false, synced: 0, skipped: 0 });
  await assert.rejects(bridge.saveFirestoreCommand("fixture_pc", "RUN"), { code: "FIRESTORE_COMMAND_UNAVAILABLE" });
  await assert.rejects(bridge.refreshFirestoreCommand("fixture_pc"), { code: "FIRESTORE_COMMAND_UNAVAILABLE" });
  await assert.rejects(bridge.saveFirestoreSettings("fixture_pc", {}), { code: "FIRESTORE_SETTINGS_UNAVAILABLE" });
  assert.equal(networkCalls, 0);
});

test("retirement refuses shadow or frozen DB state rather than silently resetting migration", async (t) => {
  let value = { mode: "shadow", epoch: "keep-epoch" };
  const queries = [];
  t.mock.method(pool, "query", async (sql) => {
    queries.push(sql);
    assert.match(sql, /^SELECT value,updated_at FROM system_settings/);
    return { rows: [{ value, updated_at: null }] };
  });
  await assert.rejects(bridge.getMigrationState(), { code: "SELFHOST_CUTOVER_REQUIRED" });
  value = { mode: "primary", writesFrozen: true, epoch: "keep-epoch" };
  await assert.rejects(bridge.getMigrationState(), { code: "SELFHOST_CUTOVER_REQUIRED" });
  value = { mode: "primary", writesFrozen: false, epoch: "keep-epoch", fallbackUntil: "2099-01-01T00:00:00Z" };
  const result = await bridge.getMigrationState();
  assert.equal(result.mode, "primary");
  assert.equal(result.epoch, "keep-epoch");
  assert.equal(result.fallbackUntil, null);
  assert.equal(value.fallbackUntil, "2099-01-01T00:00:00Z", "read must not mutate stored migration");
  assert.equal(queries.length, 3);
});

test("admin cannot reenable fallback or trigger cloud cutover after explicit retirement", async (t) => {
  t.mock.method(pool, "query", async () => { throw new Error("retirement guard must precede DB access"); });
  for (const mode of ["shadow", "fallback", "disabled"]) {
    await assert.rejects(bridge.forceMigrationMode(mode), { code: "FIRESTORE_RETIRED" });
  }
  await assert.rejects(bridge.cutoverToPrimary(), { code: "FIRESTORE_RETIRED" });
});
