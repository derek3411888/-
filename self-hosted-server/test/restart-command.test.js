import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, readdirSync } from "node:fs";
import vm from "node:vm";
import { forwardCommandWithFirestoreCas, firestoreCommandState } from "../src/firestore-command.js";
import { HttpError, boundedText, integer } from "../src/utils.js";

const now = Date.now();
function value(input) {
  if (typeof input === "string") return { stringValue: input };
  if (typeof input === "boolean") return { booleanValue: input };
  if (typeof input === "number") return { integerValue: String(input) };
  if (Array.isArray(input)) return { arrayValue: { values: input.map(value) } };
  return { mapValue: { fields: Object.fromEntries(Object.entries(input).map(([key, item]) => [key, value(item)])) } };
}
const document = (fields) => ({ updateTime: "stamp", fields: Object.fromEntries(Object.entries(fields).map(([key, item]) => [key, value(item)])) });
function firestoreHarness(overrides = {}) {
  let stored = document({ nonce: 7, lastAckNonce: 7, desiredState: "RUN", status: "RUN", lastHeartbeat: now,
    remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.33", ...overrides });
  const writes = [];
  return {
    writes,
    send: (command, requestId = "restart-1") => forwardCommandWithFirestoreCas({ uid: "PC", command,
      idempotencyKey: requestId, now: () => now,
      readDocument: async (_uid, fields) => ({ ...stored, fields: Object.fromEntries(Object.entries(stored.fields).filter(([key]) => fields.includes(key))) }),
      patchDocument: async (_uid, patch) => { writes.push(patch); stored = { ...stored, fields: { ...stored.fields, ...patch.fields } }; },
      isConcurrencyConflict: () => false }),
  };
}

test("Firestore restart uses one nonce and history, retries are idempotent, STOP supersedes", async () => {
  const harness = firestoreHarness();
  const row = await harness.send("RESTART_UPDATE");
  assert.equal(row.nonce, 8);
  assert.equal(row.status, "PENDING");
  assert.equal(firestoreCommandState({ fields: harness.writes[0].fields }).history[0].requestedState, "RESTART_UPDATE");
  assert.equal((await harness.send("RESTART_UPDATE")).nonce, 8);
  assert.equal(harness.writes.length, 1);
  await assert.rejects(harness.send("RESTART_UPDATE", "another-click"), (error) => error.code === "COMMAND_PENDING");
  const stop = await harness.send("STOP", "stop-1");
  assert.equal(stop.nonce, 9);
  assert.equal(stop.history[1].statusReason, "STOP_PRIORITY");
  assert.equal((await harness.send("STOP", "stop-again")).nonce, 9);
});

test("Firestore rejects legacy, string capability and offline restart before any patch", async () => {
  for (const fields of [
    { remoteRestartSupported: false }, { remoteRestartSupported: "true" },
    { payloadVersion: "5.28" }, { remoteRestartVersion: "" },
    { payloadVersion: "5.28", runtime: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.33" } },
    { lastHeartbeat: now - 301000 }, { status: "STOP" }, { status: "OFFLINE" },
  ]) {
    const harness = firestoreHarness(fields);
    await assert.rejects(harness.send("RESTART_UPDATE"), (error) => ["UNSUPPORTED_CLIENT", "DEVICE_OFFLINE"].includes(error.code));
    assert.equal(harness.writes.length, 0);
  }
  const harness = firestoreHarness({ remoteRestartSupported: false, runtime: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.33" } });
  assert.equal((await harness.send("RESTART_UPDATE")).command, "RESTART_UPDATE");
  await assert.rejects(harness.send("REBOOT_WINDOWS"), (error) => error.code === "INVALID_COMMAND");
});

function centralHarness(deviceOverrides = {}, { mode = "primary", firestore = null } = {}) {
  const source = readFileSync(new URL("../src/app.js", import.meta.url), "utf8");
  const start = source.indexOf("async function sendCommand(");
  const end = source.indexOf("\nfunction firestoreString", start);
  const rows = [];
  const device = { uid: "PC", state: "RUN", last_seen: new Date(now).toISOString(), command_nonce: 7,
    status: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.33" }, ...deviceOverrides };
  const client = { query: async (sql, params) => {
    if (sql.startsWith("SELECT * FROM devices")) return { rowCount: 1, rows: [device] };
    if (sql.includes("idempotency_key=$2")) {
      const matching = rows.filter((row) => row.idempotency_key === params[1]);
      return { rowCount: matching.length, rows: matching };
    }
    if (sql.startsWith("SELECT * FROM commands")) {
      const pending = rows.filter((row) => row.status === "PENDING");
      return { rowCount: pending.length, rows: pending };
    }
    if (sql.startsWith("UPDATE commands SET status='SUPERSEDED'")) { rows.find((row) => row.id === params[0]).status = "SUPERSEDED"; return {}; }
    if (sql.includes("INSERT INTO commands")) {
      const row = { id: rows.length + 1, uid: params[0], nonce: params[1], command: params[2], payload: params[3], idempotency_key: params[4], status: "PENDING" };
      rows.push(row); return { rows: [row] };
    }
    if (sql.startsWith("UPDATE devices")) { device.command_nonce = params[1]; return {}; }
    throw new Error(`Unexpected SQL: ${sql}`);
  } };
  const context = vm.createContext({ HttpError, boundedText, integer, Date, commandPayload: () => ({}),
    withTransaction: (fn) => fn(client), migrationMode: async () => mode,
    saveFirestoreCommand: async (_uid, command, _payload, key) => firestore.send(command, key),
    scheduleFirestoreCommandSync: () => {},
  });
  vm.runInContext(source.slice(start, end), context);
  return { rows, send: (command, idempotencyKey = "request-1") => context.sendCommand("PC", { command, idempotencyKey }) };
}

test("central primary transaction supports restart with idempotency, pending guard and priority STOP", async () => {
  const harness = centralHarness();
  assert.equal((await harness.send("RESTART_UPDATE")).nonce, 8);
  assert.equal((await harness.send("RESTART_UPDATE")).nonce, 8);
  await assert.rejects(harness.send("RESTART_UPDATE", "request-2"), (error) => error.code === "COMMAND_PENDING");
  assert.equal((await harness.send("STOP", "stop-1")).nonce, 9);
  assert.equal(harness.rows[0].status, "SUPERSEDED");
  assert.equal((await harness.send("STOP", "stop-2")).nonce, 9);
});

test("central primary rejects unsupported, stale and invalid requests without inserting", async () => {
  for (const device of [{ status: {} }, { status: { remoteRestartSupported: "true" } },
    { status: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.28" } },
    { status: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.28",
      runtime: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.33" } } },
    { state: "OFFLINE" }, { state: "STOP" }, { last_seen: new Date(now - 301000).toISOString() }]) {
    const harness = centralHarness(device);
    await assert.rejects(harness.send("RESTART_UPDATE"), (error) => ["UNSUPPORTED_CLIENT", "DEVICE_OFFLINE"].includes(error.code));
    assert.equal(harness.rows.length, 0);
  }
  await assert.rejects(centralHarness().send("REBOOT_WINDOWS"), (error) => error.code === "INVALID_COMMAND");
});

test("central shadow and fallback route restart to real Firestore CAS, never local insertion", async () => {
  for (const mode of ["shadow", "fallback"]) {
    const firestore = firestoreHarness();
    const harness = centralHarness({}, { mode, firestore });
    const row = await harness.send("RESTART_UPDATE");
    assert.equal(row.transport, "firestore");
    assert.equal(row.command, "RESTART_UPDATE");
    assert.equal(firestore.writes.length, 1);
    assert.equal(harness.rows.length, 0);
    assert.equal((await harness.send("RESTART_UPDATE")).nonce, 8);
    await assert.rejects(harness.send("RESTART_UPDATE", "second"), (error) => error.code === "COMMAND_PENDING");
    assert.equal((await harness.send("STOP", "stop")).nonce, 9);
    const unsupported = centralHarness({}, { mode, firestore: firestoreHarness({ remoteRestartSupported: false }) });
    await assert.rejects(unsupported.send("RESTART_UPDATE"), (error) => error.code === "UNSUPPORTED_CLIENT");
  }
});

test("Firestore import mirrors restart capability bound to its reported payload version", async () => {
  const source = readFileSync(new URL("../src/firestore-bridge.js", import.meta.url), "utf8");
  const block = source.slice(source.indexOf("export async function importFirestoreDevices("), source.indexOf("\nasync function updateShadowConsistencyWindow("))
    .replace("export async function", "async function");
  const queries = [];
  const context = vm.createContext({ URL, Date, Math, Number, String, JSON, integer, boundedText,
    config: { firestore: { enabled: true, projectId: "fixture", apiKey: "not-a-real-key", collection: "clients" } },
    firestoreBase: () => "https://fixture.invalid", field: (doc, name, fallback) => doc[name] ?? fallback,
    firestoreFetch: async () => ({ documents: [{ uid: "PC1", payloadVersion: "5.33", remoteRestartVersion: "5.33", remoteRestartSupported: true }] }),
    firestoreCommandState: () => ({}), firestoreSettingsImportState: () => ({}), normalizeGameMaintenance: () => null,
    withTransaction: async (callback) => callback({ query: async (sql, params) => { queries.push({ sql, params }); return { rows: [] }; } }),
    updateShadowConsistencyWindow: async () => {}, publishDiscovery: async () => {},
  });
  vm.runInContext(block, context);
  await context.importFirestoreDevices({ publish: false });
  const capabilityWrite = queries.find(({ sql }) => /remoteRestartSupported/.test(sql));
  assert.ok(capabilityWrite, "import must carry capability and its version to central status");
  const encoded = JSON.stringify(capabilityWrite.params);
  assert.match(encoded, /5\.33/);
  assert.match(capabilityWrite.sql, /payloadVersion|remoteRestartVersion/);
});

test("schema migration command allowlist accepts restart, preserves old commands and rejects Windows reboot", () => {
  const migrationRoot = new URL("../migrations/", import.meta.url);
  const migrations = readdirSync(migrationRoot).filter((name) => /^\d+.*\.sql$/.test(name)).sort();
  const sql = migrations.map((name) => readFileSync(new URL(name, migrationRoot), "utf8")).join("\n");
  const checks = [...sql.matchAll(/CHECK\s*\(command\s+IN\s*\(([^)]+)\)\)/gi)];
  assert.ok(checks.length > 0);
  const allowed = [...checks.at(-1)[1].matchAll(/'([^']+)'/g)].map((match) => match[1]);
  for (const command of ["RUN", "PAUSE", "STOP", "SWITCH_SERVER", "COMPLETE_SERVER", "RESTART_UPDATE"]) {
    assert.ok(allowed.includes(command), `schema must allow ${command}`);
  }
  assert.ok(!allowed.includes("REBOOT_WINDOWS"));
});
