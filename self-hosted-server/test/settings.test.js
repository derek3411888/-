import assert from "node:assert/strict";
import test from "node:test";
import {
  FIRESTORE_SETTINGS_READ_FIELDS,
  firestoreSettingsImportState,
  forwardSettingsWithFirestoreCas,
  normalizeSettingsInput,
} from "../src/settings.js";

function firestoreDocument(updateTime, values = {}) {
  const fields = {};
  for (const [name, value] of Object.entries(values)) {
    fields[name] = typeof value === "boolean"
      ? { booleanValue: value }
      : typeof value === "number" ? { integerValue: String(value) } : { stringValue: String(value) };
  }
  return { updateTime, fields };
}

const validSettings = normalizeSettingsInput({
  serverScheduleEnabled: true,
  serverScheduleList: "亞洲 | HMT | SEA",
  mailNotifyEnabled: true,
  runtimeDiagnosticsEnabled: true,
  runtimeDiagnosticsIntervalSec: 90,
  runtimeDiagnosticsErrorKeepCount: 40,
  maxRestartCount: 12,
  liveQualityProfile: "smooth",
});

test("normalizes the supported server aliases and bounded settings", () => {
  assert.equal(validSettings.serverScheduleList, "Asia | HMT(HK,MO,TW) | SEA");
  assert.equal(validSettings.runtimeDiagnosticsIntervalSec, 90);
  assert.equal(validSettings.liveQualityProfile, "smooth");
  assert.throws(
    () => normalizeSettingsInput({ serverScheduleEnabled: true, serverScheduleList: "Asia | 火星" }),
    (error) => error.code === "INVALID_SERVER_LIST",
  );
});

test("forwards settings with the exact Firestore updateTime precondition", async () => {
  const patches = [];
  const result = await forwardSettingsWithFirestoreCas({
    uid: "device-1",
    settings: validSettings,
    readDocument: async (uid, fields) => {
      assert.equal(uid, "device-1");
      assert.deepEqual(fields, FIRESTORE_SETTINGS_READ_FIELDS);
      return firestoreDocument("2026-08-29T05:00:00.000000Z", {
        remoteSettingsSchemaVersion: 1,
        desiredSettingsRevision: 7,
        lastSettingsAckRevision: 7,
        effectiveSettingsRevision: 6,
      });
    },
    patchDocument: async (...args) => patches.push(args),
    isConcurrencyConflict: () => false,
    now: () => 123456789,
  });
  assert.equal(result.revision, 8);
  assert.equal(result.transport, "firestore");
  assert.equal(patches.length, 1);
  assert.equal(patches[0][2], "2026-08-29T05:00:00.000000Z");
  assert.equal(patches[0][1].fields.desiredSettingsRevision.integerValue, "8");
  assert.equal(patches[0][1].fields.desiredServerScheduleList.stringValue, "Asia | HMT(HK,MO,TW) | SEA");
  assert.equal(patches[0][1].fields.desiredLiveQualityProfile.stringValue, "smooth");
  assert.equal(patches[0][1].fields.desiredSettingsUpdatedAt.integerValue, "123456789");
});

test("re-reads and uses the new revision after an updateTime conflict", async () => {
  let reads = 0;
  const preconditions = [];
  const result = await forwardSettingsWithFirestoreCas({
    uid: "device-2",
    settings: validSettings,
    readDocument: async () => {
      reads += 1;
      return firestoreDocument(`stamp-${reads}`, {
        remoteSettingsSchemaVersion: 1,
        desiredSettingsRevision: reads,
        lastSettingsAckRevision: reads,
        effectiveSettingsRevision: reads,
      });
    },
    patchDocument: async (_uid, _fields, updateTime) => {
      preconditions.push(updateTime);
      if (preconditions.length === 1) {
        const error = new Error("precondition");
        error.status = 412;
        throw error;
      }
    },
    isConcurrencyConflict: (error) => error.status === 412,
  });
  assert.equal(reads, 2);
  assert.deepEqual(preconditions, ["stamp-1", "stamp-2"]);
  assert.equal(result.revision, 3);
});

test("does not overwrite a settings revision that is still waiting for ACK", async () => {
  await assert.rejects(
    forwardSettingsWithFirestoreCas({
      uid: "device-3",
      settings: validSettings,
      readDocument: async () => firestoreDocument("stamp", {
        remoteSettingsSchemaVersion: 1,
        desiredSettingsRevision: 9,
        lastSettingsAckRevision: 8,
        effectiveSettingsRevision: 8,
      }),
      patchDocument: async () => assert.fail("pending revision must not be patched"),
      isConcurrencyConflict: () => false,
    }),
    (error) => error.code === "SETTINGS_PENDING" && error.details.desiredRevision === 9,
  );
});

test("rejects clients that do not advertise remote settings support", async () => {
  await assert.rejects(
    forwardSettingsWithFirestoreCas({
      uid: "device-4",
      settings: validSettings,
      readDocument: async () => firestoreDocument("stamp", { remoteSettingsSchemaVersion: 0 }),
      patchDocument: async () => assert.fail("unsupported client must not be patched"),
      isConcurrencyConflict: () => false,
    }),
    (error) => error.code === "SETTINGS_UNSUPPORTED",
  );
});

test("keeps rejected Firestore desired settings separate from the effective settings", () => {
  const imported = firestoreSettingsImportState(firestoreDocument("stamp", {
    remoteSettingsSchemaVersion: 1,
    desiredSettingsRevision: 9,
    desiredServerScheduleEnabled: true,
    desiredServerScheduleList: "Asia",
    desiredMaxRestartCount: 9,
    desiredLiveQualityProfile: "economy",
    lastSettingsAckRevision: 9,
    lastSettingsAckApplied: false,
    lastSettingsAckResult: "REJECTED",
    lastSettingsAckDetail: "device rejected the requested settings",
    lastSettingsAckAt: 123456789,
    effectiveSettingsRevision: 8,
    effectiveServerScheduleEnabled: true,
    effectiveServerScheduleList: "HMT(HK,MO,TW) | Asia",
    effectiveMaxRestartCount: 10,
    effectiveLiveQualityProfile: "smooth",
  }));

  assert.equal(imported.supportedSchemaVersion, 1);
  assert.equal(imported.desiredRevision, 9);
  assert.equal(imported.ackRevision, 9);
  assert.equal(imported.effectiveRevision, 8);
  assert.equal(imported.maxRevision, 9);
  assert.equal(imported.ackApplied, false);
  assert.equal(imported.ackResult, "REJECTED");
  assert.equal(imported.desiredSettings.maxRestartCount, 9);
  assert.equal(imported.desiredSettings.liveQualityProfile, "economy");
  assert.equal(imported.effectiveSettings.maxRestartCount, 10);
  assert.equal(imported.effectiveSettings.liveQualityProfile, "smooth");
});

test("infers an applied ACK only when the effective revision reached it", () => {
  const applied = firestoreSettingsImportState(firestoreDocument("stamp", {
    desiredSettingsRevision: 11,
    lastSettingsAckRevision: 11,
    effectiveSettingsRevision: 11,
  }));
  const rejected = firestoreSettingsImportState(firestoreDocument("stamp", {
    desiredSettingsRevision: 12,
    lastSettingsAckRevision: 12,
    effectiveSettingsRevision: 11,
  }));
  assert.equal(applied.ackApplied, true);
  assert.equal(rejected.ackApplied, false);
});
