import { analyzeServerSchedule } from "./server-names.js";
import { HttpError, boundedText, integer } from "./utils.js";

export const SETTINGS_SCHEMA_VERSION = 1;

export const FIRESTORE_SETTINGS_READ_FIELDS = Object.freeze([
  "remoteSettingsSchemaVersion",
  "desiredSettingsRevision",
  "lastSettingsAckRevision",
  "effectiveSettingsRevision",
]);

export function normalizeLiveQualityProfile(value) {
  const profile = String(value ?? "").trim().toLowerCase();
  return ["economy", "balanced", "smooth"].includes(profile) ? profile : "balanced";
}

export function normalizeSettingsInput(body = {}) {
  const serverSchedule = analyzeServerSchedule(body.serverScheduleList);
  if (serverSchedule.invalid.length) {
    throw new HttpError(
      400,
      `只允許 America、Europe、Asia、HMT(HK,MO,TW)、SEA；無效項目：${serverSchedule.invalid.join("、")}`,
      "INVALID_SERVER_LIST",
    );
  }
  if (serverSchedule.duplicates.length) {
    throw new HttpError(400, `伺服器不可重複：${serverSchedule.duplicates.join("、")}`, "DUPLICATE_SERVER");
  }
  if (Boolean(body.serverScheduleEnabled) && !serverSchedule.servers.length) {
    throw new HttpError(400, "啟用排程時至少要選擇一個伺服器", "EMPTY_SERVER_LIST");
  }
  return {
    schemaVersion: SETTINGS_SCHEMA_VERSION,
    serverScheduleEnabled: Boolean(body.serverScheduleEnabled),
    serverScheduleList: boundedText(serverSchedule.servers.join(" | "), 1200),
    mailNotifyEnabled: Boolean(body.mailNotifyEnabled),
    runtimeDiagnosticsEnabled: body.runtimeDiagnosticsEnabled !== false,
    runtimeDiagnosticsIntervalSec: integer(body.runtimeDiagnosticsIntervalSec, 60, 60, 600),
    runtimeDiagnosticsErrorKeepCount: integer(body.runtimeDiagnosticsErrorKeepCount, 30, 5, 200),
    maxRestartCount: integer(body.maxRestartCount, 10, 1, 50),
    liveQualityProfile: normalizeLiveQualityProfile(body.liveQualityProfile),
  };
}

function firestoreField(document, name, fallback = undefined) {
  const value = document?.fields?.[name];
  if (!value) return fallback;
  if ("integerValue" in value) return Number(value.integerValue);
  if ("stringValue" in value) return value.stringValue;
  if ("booleanValue" in value) return Boolean(value.booleanValue);
  return fallback;
}

function normalizedFirestoreSettings(document, prefix, fallback = {}) {
  return {
    schemaVersion: SETTINGS_SCHEMA_VERSION,
    serverScheduleEnabled: Boolean(firestoreField(
      document,
      `${prefix}ServerScheduleEnabled`,
      fallback.serverScheduleEnabled ?? false,
    )),
    serverScheduleList: boundedText(firestoreField(
      document,
      `${prefix}ServerScheduleList`,
      fallback.serverScheduleList ?? "",
    ), 1200),
    mailNotifyEnabled: Boolean(firestoreField(
      document,
      `${prefix}MailNotifyEnabled`,
      fallback.mailNotifyEnabled ?? false,
    )),
    runtimeDiagnosticsEnabled: Boolean(firestoreField(
      document,
      `${prefix}RuntimeDiagnosticsEnabled`,
      fallback.runtimeDiagnosticsEnabled ?? true,
    )),
    runtimeDiagnosticsIntervalSec: integer(
      firestoreField(document, `${prefix}RuntimeDiagnosticsIntervalSec`, fallback.runtimeDiagnosticsIntervalSec ?? 60),
      60,
      60,
      600,
    ),
    runtimeDiagnosticsErrorKeepCount: integer(
      firestoreField(document, `${prefix}RuntimeDiagnosticsErrorKeepCount`, fallback.runtimeDiagnosticsErrorKeepCount ?? 30),
      30,
      5,
      200,
    ),
    maxRestartCount: integer(
      firestoreField(document, `${prefix}MaxRestartCount`, fallback.maxRestartCount ?? 10),
      10,
      1,
      50,
    ),
    liveQualityProfile: normalizeLiveQualityProfile(firestoreField(
      document,
      `${prefix}LiveQualityProfile`,
      fallback.liveQualityProfile ?? "balanced",
    )),
  };
}

function firestoreString(value) { return { stringValue: String(value ?? "") }; }
function firestoreInteger(value) { return { integerValue: String(Math.max(0, Number(value) || 0)) }; }
function firestoreBoolean(value) { return { booleanValue: Boolean(value) }; }

export function firestoreDesiredSettingsFields(settings, revision, updatedAt = Date.now()) {
  return {
    fields: {
      desiredSettingsSchemaVersion: firestoreInteger(settings.schemaVersion ?? SETTINGS_SCHEMA_VERSION),
      desiredSettingsRevision: firestoreInteger(revision),
      desiredServerScheduleEnabled: firestoreBoolean(settings.serverScheduleEnabled),
      desiredServerScheduleList: firestoreString(settings.serverScheduleList),
      desiredMailNotifyEnabled: firestoreBoolean(settings.mailNotifyEnabled),
      desiredRuntimeDiagnosticsEnabled: firestoreBoolean(settings.runtimeDiagnosticsEnabled),
      desiredRuntimeDiagnosticsIntervalSec: firestoreInteger(settings.runtimeDiagnosticsIntervalSec),
      desiredRuntimeDiagnosticsErrorKeepCount: firestoreInteger(settings.runtimeDiagnosticsErrorKeepCount),
      desiredMaxRestartCount: firestoreInteger(settings.maxRestartCount),
      desiredLiveQualityProfile: firestoreString(normalizeLiveQualityProfile(settings.liveQualityProfile)),
      desiredSettingsUpdatedAt: firestoreInteger(updatedAt),
    },
  };
}

export function firestoreSettingsRevisions(document) {
  return {
    supportedSchemaVersion: integer(firestoreField(document, "remoteSettingsSchemaVersion", 0), 0),
    desiredRevision: integer(firestoreField(document, "desiredSettingsRevision", 0), 0),
    ackRevision: integer(firestoreField(document, "lastSettingsAckRevision", 0), 0),
    effectiveRevision: integer(firestoreField(document, "effectiveSettingsRevision", 0), 0),
  };
}

export function firestoreSettingsImportState(document) {
  const revisions = firestoreSettingsRevisions(document);
  const effectiveSettings = normalizedFirestoreSettings(document, "effective");
  const desiredSettings = normalizedFirestoreSettings(document, "desired", effectiveSettings);
  const explicitAckApplied = firestoreField(document, "lastSettingsAckApplied", undefined);
  const ackApplied = typeof explicitAckApplied === "boolean"
    ? explicitAckApplied
    : revisions.ackRevision > 0 && revisions.effectiveRevision >= revisions.ackRevision;
  return {
    ...revisions,
    maxRevision: Math.max(revisions.desiredRevision, revisions.ackRevision, revisions.effectiveRevision),
    effectiveSettings,
    desiredSettings,
    ackApplied,
    ackResult: boundedText(firestoreField(document, "lastSettingsAckResult", ""), 120),
    ackDetail: boundedText(firestoreField(document, "lastSettingsAckDetail", ""), 2000),
    ackAt: integer(firestoreField(document, "lastSettingsAckAt", 0), 0, 0, Number.MAX_SAFE_INTEGER),
  };
}

export async function forwardSettingsWithFirestoreCas({
  uid,
  settings,
  readDocument,
  patchDocument,
  isConcurrencyConflict,
  now = Date.now,
  maxAttempts = 5,
}) {
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const document = await readDocument(uid, FIRESTORE_SETTINGS_READ_FIELDS);
    const updateTime = String(document?.updateTime ?? "").trim();
    if (!updateTime) {
      throw new HttpError(409, "Firestore 裝置文件缺少版本時間，無法安全儲存", "SETTINGS_CAS_UNAVAILABLE");
    }
    const revisions = firestoreSettingsRevisions(document);
    if (revisions.supportedSchemaVersion < SETTINGS_SCHEMA_VERSION) {
      throw new HttpError(409, "裝置版本尚不支援遠端設定", "SETTINGS_UNSUPPORTED", {
        supportedSchemaVersion: revisions.supportedSchemaVersion,
      });
    }
    if (revisions.desiredRevision > revisions.ackRevision) {
      throw new HttpError(409, "上一版設定尚未收到 ACK，不能覆蓋", "SETTINGS_PENDING", revisions);
    }

    const revision = Math.max(
      revisions.desiredRevision,
      revisions.ackRevision,
      revisions.effectiveRevision,
    ) + 1;
    const fields = firestoreDesiredSettingsFields(settings, revision, now());
    try {
      await patchDocument(uid, fields, updateTime);
      return {
        uid,
        revision,
        settings,
        status: "PENDING",
        transport: "firestore",
        firestoreUpdateTime: updateTime,
        previousAckRevision: revisions.ackRevision,
        previousEffectiveRevision: revisions.effectiveRevision,
      };
    } catch (error) {
      if (isConcurrencyConflict(error) && attempt + 1 < maxAttempts) continue;
      if (isConcurrencyConflict(error)) {
        throw new HttpError(409, "設定同時被其他控制台更新，請再試一次", "SETTINGS_CONFLICT");
      }
      throw error;
    }
  }
  throw new HttpError(409, "設定同時被其他控制台更新，請再試一次", "SETTINGS_CONFLICT");
}
