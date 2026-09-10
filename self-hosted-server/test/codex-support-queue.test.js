import assert from "node:assert/strict";
import fs from "node:fs/promises";
import test from "node:test";

for (const name of ["SESSION_SECRET", "CODEX_BRIDGE_TOKEN", "LIVE_TOKEN_SECRET", "LIVE_SRT_PASSPHRASE"]) {
  process.env[name] ||= "test-only-secret-that-is-longer-than-32-characters";
}

const {
  CODEX_DISPATCH_LEASE_MS,
  isCodexResponseTransitionAllowed,
  isCodexResponseTurnCompatible,
  isDirectCodexTransitionAllowed,
  isCodexResponseChronologicallyValid,
  isDispatchResultUnknown,
  matchesDirectCodexClaim,
  normalizeCodexDispatcherId,
  resolveCodexDispatcherPresence,
} = await import("../src/codex-support-queue.js");

test("a terminal Codex reply must belong to the current request chronology", () => {
  assert.equal(isCodexResponseChronologicallyValid({
    response_state: "COMPLETED",
    queued_at: new Date("2026-09-10T08:00:00Z"),
    codex_response_at: new Date("2026-09-10T08:01:00Z"),
  }), true);
  assert.equal(isCodexResponseChronologicallyValid({
    response_state: "COMPLETED",
    queued_at: new Date("2026-09-10T08:00:00Z"),
    codex_response_at: new Date("2026-09-09T08:01:00Z"),
  }), false);
  assert.equal(isCodexResponseChronologicallyValid({
    response_state: "IN_PROGRESS",
    queued_at: new Date("2026-09-10T08:00:00Z"),
    codex_response_at: null,
  }), true);
});

test("Codex response state and turn identity cannot regress or jump requests", () => {
  assert.equal(isCodexResponseTransitionAllowed("WAITING", "IN_PROGRESS"), true);
  assert.equal(isCodexResponseTransitionAllowed("WAITING", "COMPLETED"), true);
  assert.equal(isCodexResponseTransitionAllowed("IN_PROGRESS", "COMPLETED"), true);
  assert.equal(isCodexResponseTransitionAllowed("IN_PROGRESS", "WAITING"), false);
  assert.equal(isCodexResponseTransitionAllowed("COMPLETED", "IN_PROGRESS"), false);
  assert.equal(isCodexResponseTurnCompatible("WAITING", "", "turn-a"), true);
  assert.equal(isCodexResponseTurnCompatible("IN_PROGRESS", "turn-a", "turn-a"), true);
  assert.equal(isCodexResponseTurnCompatible("IN_PROGRESS", "turn-a", "turn-b"), false);
  assert.equal(isCodexResponseTurnCompatible("IN_PROGRESS", "turn-a", ""), false);
});

test("dispatcher state machine accepts idempotent/forward updates and rejects stale regression", () => {
  assert.equal(isDirectCodexTransitionAllowed("PENDING", "RECEIVED"), true);
  assert.equal(isDirectCodexTransitionAllowed("RECEIVED", "VALIDATING"), true);
  assert.equal(isDirectCodexTransitionAllowed("VALIDATING", "QUEUEING"), true);
  assert.equal(isDirectCodexTransitionAllowed("QUEUEING", "QUEUED"), true);
  assert.equal(isDirectCodexTransitionAllowed("RETRYING", "RECEIVED"), true);
  assert.equal(isDirectCodexTransitionAllowed("VALIDATING", "RECEIVED"), false);
  assert.equal(isDirectCodexTransitionAllowed("QUEUED", "FAILED"), false);
  assert.equal(isDirectCodexTransitionAllowed("CANCELLED", "RECEIVED"), false);
  assert.ok(CODEX_DISPATCH_LEASE_MS >= 60_000);
});

test("dispatch-result-unknown is recognized as an unsafe retry result", () => {
  assert.equal(isDispatchResultUnknown({ error_code: "DISPATCH_RESULT_UNKNOWN" }), true);
  assert.equal(isDispatchResultUnknown({ errorCode: "dispatch_result_unknown" }), true);
  assert.equal(isDispatchResultUnknown({ error_code: "CODEX_EXIT_1" }), false);
});

test("claim ownership requires the exact generation and stable dispatcher identity", () => {
  const dispatcherId = normalizeCodexDispatcherId("MYTUF:2f135f1d-2db0-4f58-a65f-ff869b558bfd");
  const row = { claim_generation: 7, claimed_by: dispatcherId };
  assert.equal(matchesDirectCodexClaim(row, 7, dispatcherId), true);
  assert.equal(matchesDirectCodexClaim(row, 6, dispatcherId), false);
  assert.equal(matchesDirectCodexClaim(row, 7, "OTHERHOST:2f135f1d-2db0-4f58-a65f-ff869b558bfd"), false);
  assert.throws(
    () => normalizeCodexDispatcherId("short"),
    (error) => error.code === "CODEX_DISPATCHER_ID_INVALID",
  );
  assert.throws(
    () => normalizeCodexDispatcherId("bad identity with spaces"),
    (error) => error.code === "CODEX_DISPATCHER_ID_INVALID",
  );
});

test("bridge presence reports the newest heartbeat and derives online from that exact value", () => {
  const row = {
    bridge_heartbeat_at: new Date(20_000),
    bridge_host: "ROW-HOST",
    bridge_version: "2.0",
  };
  const dispatcher = { heartbeatAt: 10_000, host: "OLD-HOST", version: "1.0" };
  const fresh = resolveCodexDispatcherPresence(row, dispatcher, 20_500);
  assert.deepEqual(fresh, { heartbeatAt: 20_000, host: "ROW-HOST", version: "2.0", online: true });
  assert.equal(resolveCodexDispatcherPresence(row, dispatcher, 20_000 + 3 * 60_000).online, false);

  const newerDispatcher = resolveCodexDispatcherPresence(row, {
    heartbeatAt: 30_000,
    host: "NEW-HOST",
    version: "3.0",
  }, 30_500);
  assert.deepEqual(newerDispatcher, { heartbeatAt: 30_000, host: "NEW-HOST", version: "3.0", online: true });
});

test("queue SQL contract uses row locking, expiring leases, and state compare-and-set", async () => {
  const source = await fs.readFile(new URL("../src/codex-support-queue.js", import.meta.url), "utf8");
  const migration = await fs.readFile(new URL("../migrations/006_codex_support_queue.sql", import.meta.url), "utf8");
  const responseMigration = await fs.readFile(new URL("../migrations/008_codex_support_responses.sql", import.meta.url), "utf8");
  const responseRecoveryMigration = await fs.readFile(new URL("../migrations/010_codex_support_response_recovery.sql", import.meta.url), "utf8");
  const publicApp = await fs.readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const serverApp = await fs.readFile(new URL("../src/app.js", import.meta.url), "utf8");

  assert.match(source, /FOR UPDATE SKIP LOCKED/);
  assert.match(source, /state='RECEIVED',detail='中央 Codex 傳送器已原子領取/);
  assert.match(source, /claim_generation=claim_generation\+1/);
  assert.match(source, /claimed_by=\$5/);
  assert.match(source, /claimGeneration: Number\(request\.claim_generation\)/);
  assert.match(source, /dispatcherId: String\(request\.claimed_by/);
  assert.doesNotMatch(source, /state IN \('RECEIVED','VALIDATING'\)[\s\S]{0,200}claim_expires_at<=now\(\)/);
  assert.match(source, /WHERE id=\$1 AND state=\$14 AND claim_generation=\$15 AND claimed_by=\$16 RETURNING \*/);
  assert.match(source, /CODEX_SUPPORT_RESULT_UNKNOWN/);
  assert.match(source, /CODEX_SUPPORT_STALE_CLAIM/);
  assert.match(source, /system_settings\.value->>'heartbeatAt'/);
  assert.match(migration, /claim_generation integer NOT NULL DEFAULT 0/);
  assert.match(migration, /claimed_by text NOT NULL DEFAULT ''/);
  assert.match(migration, /claim_expires_at timestamptz/);
  assert.match(responseMigration, /CHECK \(response_state IN \('WAITING','IN_PROGRESS','COMPLETED','FAILED','INTERRUPTED'\)\)/);
  assert.match(source, /CODEX_RESPONSE_MESSAGE_MISMATCH/);
  assert.match(source, /CODEX_RESPONSE_ALREADY_TERMINAL/);
  assert.match(source, /CODEX_RESPONSE_PREDATES_REQUEST/);
  assert.match(source, /CODEX_RESPONSE_INVALID_TRANSITION/);
  assert.match(source, /CODEX_RESPONSE_TURN_MISMATCH/);
  assert.match(source, /responseRetryable/);
  assert.match(responseRecoveryMigration, /response_state = 'FAILED'/);
  assert.match(responseRecoveryMigration, /legacyCorrelationRejected/);
  assert.match(publicApp, /dispatchResultUnknown/);
  assert.match(publicApp, /deviceUid: \$\("codexLogDeviceSelect"\)\.value \|\| state\.selectedUid/);
  assert.match(serverApp, /nextDispatcherRequest\(dispatcherId\)/);
  assert.match(serverApp, /updateDispatcherRequest\([\s\S]*dispatcherId,[\s\S]*\)/);
});
