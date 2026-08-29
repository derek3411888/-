import assert from "node:assert/strict";
import test from "node:test";

process.env.SESSION_SECRET ||= "session-test-secret-00000000000000000000";
process.env.CODEX_BRIDGE_TOKEN ||= "codex-test-secret-000000000000000000000";
process.env.LIVE_TOKEN_SECRET ||= "live-test-secret-0000000000000000000000";
process.env.LIVE_SRT_PASSPHRASE ||= "srt-test-secret-00000000000000000000000";

const { runCutoverSequence } = await import("../src/firestore-bridge.js");

function sequence(overrides = {}) {
  const calls = [];
  const actions = {
    freeze: async () => { calls.push("freeze"); },
    reconcile: async () => { calls.push("reconcile"); },
    readiness: async () => { calls.push("readiness"); return { ready: true }; },
    publishPrimary: async () => { calls.push("publish-primary"); },
    commitPrimary: async () => { calls.push("commit-primary"); return { mode: "primary" }; },
    restore: async () => { calls.push("restore-shadow"); },
    ...overrides,
  };
  return { calls, actions };
}

test("cutover reconciles fresh state and strictly publishes before committing primary", async () => {
  const { calls, actions } = sequence();
  const result = await runCutoverSequence(actions);
  assert.deepEqual(result, { mode: "primary" });
  assert.deepEqual(calls, ["freeze", "reconcile", "readiness", "publish-primary", "commit-primary"]);
});

test("cutover restores shadow when fresh readiness fails", async () => {
  const { calls, actions } = sequence({
    readiness: async () => { calls.push("readiness"); return { ready: false, pendingFirestoreAcks: 1 }; },
  });
  await assert.rejects(
    runCutoverSequence(actions),
    (error) => error.code === "MIGRATION_NOT_READY" && error.details.pendingFirestoreAcks === 1,
  );
  assert.deepEqual(calls, ["freeze", "reconcile", "readiness", "restore-shadow"]);
});

test("cutover never reports success when primary discovery publishing fails", async () => {
  const { calls, actions } = sequence({
    publishPrimary: async () => { calls.push("publish-primary"); throw new Error("partial Firestore publish"); },
  });
  await assert.rejects(runCutoverSequence(actions), /partial Firestore publish/);
  assert.deepEqual(calls, ["freeze", "reconcile", "readiness", "publish-primary", "restore-shadow"]);
});

test("cutover surfaces rollback failure instead of hiding an unsafe split state", async () => {
  const { calls, actions } = sequence({
    publishPrimary: async () => { calls.push("publish-primary"); throw new Error("publish failed"); },
    restore: async () => { calls.push("restore-shadow"); throw new Error("restore failed"); },
  });
  await assert.rejects(
    runCutoverSequence(actions),
    (error) => error.code === "MIGRATION_ROLLBACK_FAILED"
      && error.details.cause === "publish failed"
      && error.details.restore === "restore failed",
  );
  assert.deepEqual(calls, ["freeze", "reconcile", "readiness", "publish-primary", "restore-shadow"]);
});
