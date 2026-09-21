import test from "node:test";
import assert from "node:assert/strict";
import { normalizeMaintenanceSettings } from "../src/game-maintenance.js";
import { normalizeSettingsInput, firestoreDesiredSettingsFields, firestoreSettingsImportState,
  forwardSettingsWithFirestoreCas } from "../src/settings.js";

const now = 1770000001000;
const status = { schemaVersion: 1, capabilityVersion: 1, phase: "WAIT_OPEN", eventId: "event-1", observedAt: now };
const context = { status, nowMs: now, previous: { maintenanceEnabled: true } };
test("maintenance settings reject stale event, missing capability and invalid time without changing schema v1", () => {
  const settings = { maintenanceOverrideEventId: "event-1", maintenanceDelayUntilUtc: now + 60000 };
  const normalized = normalizeSettingsInput(settings, context);
  assert.equal(normalized.schemaVersion, 1);
  assert.equal(normalized.maintenanceDelayUntilUtc, now + 60000);
  for (const value of [{ ...settings, maintenanceOverrideEventId: "old-event" },
    { ...settings, maintenanceDelayUntilUtc: now - 1 }, { ...settings, maintenanceDelayUntilUtc: now + 172800001 },
    { maintenanceEnabled: "false" }, { maintenanceSkipEventId: "old-event" }]) {
    assert.throws(() => normalizeMaintenanceSettings(value, context));
  }
  assert.throws(() => normalizeMaintenanceSettings(settings, { nowMs: now }));
  assert.throws(() => normalizeMaintenanceSettings(settings, { ...context, status: { ...status, observedAt: now - 180001 } }));
});
test("old form submissions preserve omitted and expired event settings, rather than silently clearing them", () => {
  const previous = { maintenanceEnabled: false, maintenanceOverrideEventId: "yesterday", maintenanceDelayUntilUtc: now - 86400000,
    maintenanceSkipEventId: "", maintenanceRefreshRequestId: "refresh-1" };
  assert.deepEqual(normalizeMaintenanceSettings({}, { previous, nowMs: now }), previous);
  const result = normalizeSettingsInput({ maxRestartCount: 9 }, { previous, nowMs: now });
  assert.equal(result.maintenanceEnabled, false);
  assert.equal(result.maintenanceDelayUntilUtc, previous.maintenanceDelayUntilUtc);
});
test("maintenance fields round trip through existing Firestore revision fields with one read and one write", async () => {
  const settings = { maintenanceEnabled: true, maintenanceSkipEventId: "event-1" };
  let reads = 0, writes = 0;
  const result = await forwardSettingsWithFirestoreCas({ uid: "device-1", settings, now: () => now,
    readDocument: async () => { reads++; return { updateTime: "2026-09-21T00:00:00Z", fields: {
      remoteSettingsSchemaVersion: { integerValue: "1" }, lastSettingsAckRevision: { integerValue: "4" },
      desiredSettingsRevision: { integerValue: "4" }, gameMaintenanceJson: { stringValue: JSON.stringify(status) },
      effectiveMaintenanceEnabled: { booleanValue: false } } }; },
    patchDocument: async (uid, payload) => { writes++; assert.equal(payload.fields.desiredMaintenanceSkipEventId.stringValue, "event-1"); },
    isConcurrencyConflict: () => false });
  assert.equal(result.revision, 5);
  assert.deepEqual([reads, writes], [1, 1]);
  const fields = firestoreDesiredSettingsFields({ ...settings, maintenanceDelayUntilUtc: now + 10000 }, 5).fields;
  assert.equal(fields.desiredMaintenanceDelayUntilUtc.integerValue, String(now + 10000));
  const imported = firestoreSettingsImportState({ fields });
  assert.equal(imported.desiredSettings.maintenanceSkipEventId, "event-1");
  assert.equal(imported.desiredSettings.maintenanceEnabled, true);
});
test("CAS retry of an old form preserves maintenance settings from the winning document", async () => {
  let attempt = 0;
  const written = [];
  await forwardSettingsWithFirestoreCas({ uid: "device-1", settings: { maxRestartCount: 9 }, now: () => now,
    readDocument: async () => ({ updateTime: `revision-${++attempt}`, fields: {
      remoteSettingsSchemaVersion: { integerValue: "1" },
      effectiveMaintenanceEnabled: { booleanValue: attempt !== 1 },
    } }),
    patchDocument: async (uid, payload) => {
      written.push(payload.fields.desiredMaintenanceEnabled.booleanValue);
      if (attempt === 1) throw new Error("conflict");
    }, isConcurrencyConflict: (error) => error.message === "conflict" });
  assert.deepEqual(written, [false, true]);
});
