import { config } from "./config.js";
import { query, withTransaction } from "./db.js";
import { buildFallbackCommandBaseline } from "./migration-baseline.js";
import { firestoreSettingsImportState, forwardSettingsWithFirestoreCas } from "./settings.js";
import {
  CODEX_SUPPORT_ACTION,
  codexSupportCooldownRemaining,
  isCodexSupportPending,
  resolveCodexSupportMessage,
} from "./codex-support.js";
import { HttpError, boundedText, integer } from "./utils.js";

const CODEX_SUPPORT_DOCUMENT_ID = "__codex_support";
const CODEX_SUPPORT_STATUS_FIELDS = Object.freeze([
  "supportRequestNonce",
  "supportRequestAction",
  "supportRequestMode",
  "supportRequestLabel",
  "supportRequestMessage",
  "supportRequestMessageLength",
  "supportRequestedAt",
  "supportRequestedDeviceUid",
  "bridgeState",
  "bridgeStatusNonce",
  "bridgeDetail",
  "bridgeUpdatedAt",
  "bridgeHost",
  "bridgeHeartbeatAt",
  "bridgeReceivedAt",
  "bridgeValidatedAt",
  "bridgeAttemptCount",
  "bridgeLastAttemptAt",
  "bridgeNextRetryAt",
  "bridgeQueuedAt",
  "bridgeMessageSha256",
  "bridgeErrorCode",
  "bridgeErrorDetail",
  "bridgeVersion",
]);
const CODEX_SUPPORT_CACHE_MS = 2_000;
let codexSupportCache = { at: 0, status: null };

function firestoreBase() {
  const { projectId } = config.firestore;
  return `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/databases/(default)/documents`;
}

function field(document, name, fallback = undefined) {
  const value = document?.fields?.[name];
  if (!value) return fallback;
  if ("stringValue" in value) return value.stringValue;
  if ("integerValue" in value) return Number(value.integerValue);
  if ("booleanValue" in value) return Boolean(value.booleanValue);
  return fallback;
}

async function firestoreFetch(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: { "Content-Type": "application/json; charset=utf-8", ...(options.headers ?? {}) },
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) {
    const text = await response.text();
    const error = new Error(`Firestore HTTP ${response.status}: ${text.slice(0, 1000)}`);
    error.status = response.status;
    try {
      const payload = JSON.parse(text);
      error.firestoreStatus = String(payload?.error?.status ?? "");
      error.firestoreCode = Number(payload?.error?.code ?? 0);
    } catch {}
    throw error;
  }
  return response.status === 204 ? {} : response.json();
}

export async function getMigrationState() {
  const result = await query("SELECT value,updated_at FROM system_settings WHERE key='migration'");
  const value = result.rows[0]?.value ?? { mode: "shadow", shadowStartedAt: new Date().toISOString(), consistencyErrors: 0 };
  return { ...value, updatedAt: result.rows[0]?.updated_at ?? null };
}

export async function importFirestoreDevices({ publish = true } = {}) {
  if (!config.firestore.enabled) return { enabled: false, imported: 0 };
  const { projectId, apiKey, collection } = config.firestore;
  if (!projectId || !apiKey) throw new Error("已啟用 Firestore 匯入，但缺少 project ID 或 API key");
  let pageToken = "";
  let imported = 0;
  do {
    const url = new URL(`${firestoreBase()}/${encodeURIComponent(collection)}`);
    url.searchParams.set("key", apiKey);
    url.searchParams.set("pageSize", "100");
    if (pageToken) url.searchParams.set("pageToken", pageToken);
    const payload = await firestoreFetch(url);
    for (const document of payload.documents ?? []) {
      const uid = String(field(document, "uid", "")).trim();
      if (!/^[A-Za-z0-9._@-]{3,160}$/.test(uid)) continue;
      const displayName = boundedText(field(document, "displayName", ""), 160);
      const deviceAlias = boundedText(field(document, "deviceAlias", ""), 120);
      const nonce = integer(field(document, "nonce", 0), 0, 0, Number.MAX_SAFE_INTEGER);
      const lastAck = integer(field(document, "lastAckNonce", 0), 0, 0, Number.MAX_SAFE_INTEGER);
      const importedSettings = firestoreSettingsImportState(document);
      const settingsAck = importedSettings.ackRevision > 0 ? {
        revision: importedSettings.ackRevision,
        applied: importedSettings.ackApplied,
        result: importedSettings.ackResult,
        detail: importedSettings.ackDetail,
        at: importedSettings.ackAt,
        source: "firestore",
      } : {};
      await withTransaction(async (client) => {
        await client.query(
          `INSERT INTO devices(uid,display_name,device_alias,last_nonce,command_nonce,settings_revision,
             settings_effective_revision,settings,settings_ack,
             imported_from_firestore,firestore_observed_nonce,firestore_observed_ack_nonce,
             firestore_observed_settings_revision,firestore_observed_settings_ack_revision,firestore_observed_at)
           VALUES($1,$2,$3,$4,$4,$5,$6,$7,$8,true,$9,$10,$11,$12,now())
           ON CONFLICT(uid) DO UPDATE SET
             display_name=COALESCE(NULLIF(EXCLUDED.display_name,''),devices.display_name),
             device_alias=COALESCE(NULLIF(EXCLUDED.device_alias,''),devices.device_alias),
             last_nonce=GREATEST(devices.last_nonce,EXCLUDED.last_nonce),
             command_nonce=GREATEST(devices.command_nonce,EXCLUDED.command_nonce),
             settings_revision=GREATEST(devices.settings_revision,EXCLUDED.settings_revision),
             settings=CASE WHEN EXCLUDED.settings_effective_revision>=devices.settings_effective_revision
               THEN EXCLUDED.settings ELSE devices.settings END,
             settings_effective_revision=GREATEST(devices.settings_effective_revision,EXCLUDED.settings_effective_revision),
             settings_ack=CASE
               WHEN COALESCE((EXCLUDED.settings_ack->>'revision')::bigint,0)
                 >=COALESCE((devices.settings_ack->>'revision')::bigint,0)
               THEN EXCLUDED.settings_ack ELSE devices.settings_ack END,
             firestore_observed_nonce=EXCLUDED.firestore_observed_nonce,
             firestore_observed_ack_nonce=EXCLUDED.firestore_observed_ack_nonce,
             firestore_observed_settings_revision=EXCLUDED.firestore_observed_settings_revision,
             firestore_observed_settings_ack_revision=EXCLUDED.firestore_observed_settings_ack_revision,
             firestore_observed_at=now(),
             imported_from_firestore=true,updated_at=now()`,
          [uid, displayName, deviceAlias, Math.max(nonce, lastAck), importedSettings.maxRevision,
            importedSettings.effectiveRevision, importedSettings.effectiveSettings, settingsAck,
            nonce, lastAck, importedSettings.desiredRevision, importedSettings.ackRevision],
        );
        if (importedSettings.effectiveRevision > 0) {
          const effectiveAckAt = importedSettings.ackRevision === importedSettings.effectiveRevision
            && importedSettings.ackAt > 0 ? new Date(importedSettings.ackAt) : new Date();
          await client.query(
            `INSERT INTO settings_revisions(uid,revision,settings,status,acked_at,ack_result,ack_detail)
             VALUES($1,$2,$3,'APPLIED',$4,$5,$6)
             ON CONFLICT(uid,revision) DO UPDATE SET settings=EXCLUDED.settings,status='APPLIED',
               acked_at=EXCLUDED.acked_at,ack_result=EXCLUDED.ack_result,ack_detail=EXCLUDED.ack_detail`,
            [uid, importedSettings.effectiveRevision, importedSettings.effectiveSettings, effectiveAckAt,
              importedSettings.ackRevision === importedSettings.effectiveRevision
                ? importedSettings.ackResult || "APPLIED" : "IMPORTED_EFFECTIVE",
              importedSettings.ackRevision === importedSettings.effectiveRevision
                ? importedSettings.ackDetail || "Firestore 已套用設定" : "Firestore 有效設定鏡像"],
          );
        }
        if (importedSettings.desiredRevision > 0
          && importedSettings.desiredRevision !== importedSettings.effectiveRevision) {
          const pending = importedSettings.desiredRevision > importedSettings.ackRevision;
          const desiredStatus = pending ? "PENDING" : importedSettings.ackApplied ? "APPLIED" : "REJECTED";
          const ackedAt = pending ? null : new Date(importedSettings.ackAt || Date.now());
          await client.query(
            `INSERT INTO settings_revisions(uid,revision,settings,status,acked_at,ack_result,ack_detail)
             VALUES($1,$2,$3,$4,$5,$6,$7)
             ON CONFLICT(uid,revision) DO UPDATE SET settings=EXCLUDED.settings,status=EXCLUDED.status,
               acked_at=EXCLUDED.acked_at,ack_result=EXCLUDED.ack_result,ack_detail=EXCLUDED.ack_detail`,
            [uid, importedSettings.desiredRevision, importedSettings.desiredSettings, desiredStatus, ackedAt,
              pending ? null : importedSettings.ackResult || desiredStatus,
              pending ? null : importedSettings.ackDetail || "Firestore 設定 ACK"],
          );
        }
        await client.query(
          `INSERT INTO enrollment_allowlist(uid,source) VALUES($1,'firestore')
           ON CONFLICT(uid) DO NOTHING`,
          [uid],
        );
      });
      imported += 1;
    }
    pageToken = payload.nextPageToken ?? "";
  } while (pageToken);
  await updateShadowConsistencyWindow();
  if (publish) await publishDiscovery();
  return { enabled: true, imported };
}

async function updateShadowConsistencyWindow() {
  const mismatch = await query(
    `SELECT count(*)::int AS count FROM devices WHERE imported_from_firestore=true
      AND credential_issued_at IS NOT NULL AND firestore_observed_at IS NOT NULL
      AND firestore_observed_nonce=firestore_observed_ack_nonce
      AND last_nonce<>firestore_observed_ack_nonce`,
  );
  const count = Number(mismatch.rows[0].count);
  if (count > 0) {
    await query(
      `UPDATE system_settings SET value=jsonb_set(
        jsonb_set(value,'{consistencyErrors}',to_jsonb($1::int),true),
        '{lastConsistencyErrorAt}',to_jsonb(now()),true),updated_at=now()
       WHERE key='migration'`,
      [count],
    );
  } else {
    await query(
      `UPDATE system_settings SET value=jsonb_set(value,'{consistencyErrors}','0'::jsonb,true),updated_at=now()
       WHERE key='migration'`,
    );
  }
}

function firestoreFieldsForDiscovery(mode, epoch, fallbackUntil = "", writesFrozen = false) {
  return {
    fields: {
      selfHostedServerUrl: { stringValue: config.publicUrl },
      selfHostedMode: { stringValue: mode },
      selfHostedEpoch: { stringValue: epoch },
      selfHostedFirestoreFallbackUntil: { integerValue: String(fallbackUntil ? new Date(fallbackUntil).valueOf() : 0) },
      selfHostedWritesFrozen: { booleanValue: Boolean(writesFrozen) },
      selfHostedUpdatedAt: { integerValue: String(Date.now()) },
    },
  };
}

async function patchFirestoreDocument(documentId, fields) {
  const { apiKey, collection } = config.firestore;
  const url = new URL(`${firestoreBase()}/${encodeURIComponent(collection)}/${encodeURIComponent(documentId)}`);
  url.searchParams.set("key", apiKey);
  for (const fieldName of Object.keys(fields.fields)) url.searchParams.append("updateMask.fieldPaths", fieldName);
  url.searchParams.append("mask.fieldPaths", "selfHostedUpdatedAt");
  await firestoreFetch(url, { method: "PATCH", body: JSON.stringify(fields) });
}

async function getFirestoreDocument(documentId, fieldNames = []) {
  const { apiKey, collection } = config.firestore;
  const url = new URL(`${firestoreBase()}/${encodeURIComponent(collection)}/${encodeURIComponent(documentId)}`);
  url.searchParams.set("key", apiKey);
  for (const fieldName of fieldNames) url.searchParams.append("mask.fieldPaths", fieldName);
  return firestoreFetch(url);
}

async function patchFirestoreDocumentAtVersion(documentId, fields, precondition, responseMask = ["lastAckNonce"]) {
  const { apiKey, collection } = config.firestore;
  const url = new URL(`${firestoreBase()}/${encodeURIComponent(collection)}/${encodeURIComponent(documentId)}`);
  url.searchParams.set("key", apiKey);
  for (const fieldName of Object.keys(fields.fields)) url.searchParams.append("updateMask.fieldPaths", fieldName);
  if (typeof precondition === "string" && precondition) {
    url.searchParams.set("currentDocument.updateTime", precondition);
  } else if (precondition?.exists === false) {
    url.searchParams.set("currentDocument.exists", "false");
  }
  for (const fieldName of responseMask) url.searchParams.append("mask.fieldPaths", fieldName);
  return firestoreFetch(url, { method: "PATCH", body: JSON.stringify(fields) });
}

function isFirestoreConcurrencyConflict(error) {
  return [409, 412].includes(Number(error?.status))
    || ["ABORTED", "FAILED_PRECONDITION"].includes(String(error?.firestoreStatus ?? ""));
}

function assertFirestoreSettingsAvailable() {
  const { enabled, projectId, apiKey, collection } = config.firestore;
  if (!enabled || !projectId || !apiKey || !collection) {
    throw new HttpError(503, "Firestore 設定轉送目前未設定", "FIRESTORE_SETTINGS_UNAVAILABLE");
  }
}

export async function saveFirestoreSettings(uid, settings) {
  assertFirestoreSettingsAvailable();
  const localDevice = await query("SELECT uid FROM devices WHERE uid=$1", [uid]);
  if (!localDevice.rowCount) throw new HttpError(404, "找不到裝置", "DEVICE_NOT_FOUND");
  try {
    const forwarded = await forwardSettingsWithFirestoreCas({
      uid,
      settings,
      readDocument: getFirestoreDocument,
      patchDocument: (documentId, fields, updateTime) => (
        patchFirestoreDocumentAtVersion(documentId, fields, updateTime, [])
      ),
      isConcurrencyConflict: isFirestoreConcurrencyConflict,
    });
    await withTransaction(async (client) => {
      await client.query(
        `INSERT INTO settings_revisions(uid,revision,settings,status,ack_result,ack_detail)
         VALUES($1,$2,$3,'PENDING',NULL,NULL)
         ON CONFLICT(uid,revision) DO UPDATE SET settings=EXCLUDED.settings
         WHERE settings_revisions.status='PENDING'`,
        [uid, forwarded.revision, settings],
      );
      await client.query(
        `UPDATE devices SET settings_revision=GREATEST(settings_revision,$2),
           firestore_observed_settings_revision=GREATEST(firestore_observed_settings_revision,$2),
           firestore_observed_settings_ack_revision=GREATEST(firestore_observed_settings_ack_revision,$3),
           firestore_observed_at=now(),updated_at=now() WHERE uid=$1`,
        [uid, forwarded.revision, forwarded.previousAckRevision],
      );
    });
    return forwarded;
  } catch (error) {
    if (Number(error?.status) === 404) {
      throw new HttpError(404, "找不到裝置", "DEVICE_NOT_FOUND");
    }
    throw error;
  }
}

function assertCodexSupportAvailable() {
  const { enabled, projectId, apiKey, collection } = config.firestore;
  if (!enabled || !projectId || !apiKey || !collection) {
    throw new HttpError(503, "Codex 橋接目前未設定", "CODEX_SUPPORT_UNAVAILABLE");
  }
}

function normalizedCodexSupportStatus(document = null) {
  const requestNonce = integer(field(document, "supportRequestNonce", 0), 0, 0, Number.MAX_SAFE_INTEGER);
  const statusNonce = integer(field(document, "bridgeStatusNonce", 0), 0, 0, Number.MAX_SAFE_INTEGER);
  const storedState = String(field(document, "bridgeState", "") ?? "").trim().toUpperCase();
  const state = requestNonce > statusNonce ? "PENDING" : storedState;
  const heartbeatAt = integer(field(document, "bridgeHeartbeatAt", 0), 0, 0, Number.MAX_SAFE_INTEGER);
  const queuedAt = integer(field(document, "bridgeQueuedAt", 0), 0, 0, Number.MAX_SAFE_INTEGER);
  return {
    requestNonce,
    statusNonce,
    state,
    detail: String(field(document, "bridgeDetail", "") ?? ""),
    requestedAt: integer(field(document, "supportRequestedAt", 0), 0, 0, Number.MAX_SAFE_INTEGER),
    requestedDeviceUid: String(field(document, "supportRequestedDeviceUid", "") ?? ""),
    requestMode: String(field(document, "supportRequestMode", "") ?? ""),
    requestLabel: String(field(document, "supportRequestLabel", "") ?? ""),
    requestMessage: String(field(document, "supportRequestMessage", "") ?? ""),
    host: String(field(document, "bridgeHost", "") ?? ""),
    heartbeatAt,
    receivedAt: integer(field(document, "bridgeReceivedAt", 0), 0, 0, Number.MAX_SAFE_INTEGER),
    validatedAt: integer(field(document, "bridgeValidatedAt", 0), 0, 0, Number.MAX_SAFE_INTEGER),
    attemptCount: integer(field(document, "bridgeAttemptCount", 0), 0, 0, Number.MAX_SAFE_INTEGER),
    lastAttemptAt: integer(field(document, "bridgeLastAttemptAt", 0), 0, 0, Number.MAX_SAFE_INTEGER),
    nextRetryAt: integer(field(document, "bridgeNextRetryAt", 0), 0, 0, Number.MAX_SAFE_INTEGER),
    queuedAt,
    messageSha256: String(field(document, "bridgeMessageSha256", "") ?? ""),
    errorCode: String(field(document, "bridgeErrorCode", "") ?? ""),
    errorDetail: String(field(document, "bridgeErrorDetail", "") ?? ""),
    bridgeVersion: String(field(document, "bridgeVersion", "") ?? ""),
    online: heartbeatAt > 0 && Date.now() - heartbeatAt < 3 * 60_000,
    pending: isCodexSupportPending(requestNonce, statusNonce, state),
    cooldownRemainingMs: codexSupportCooldownRemaining(queuedAt),
  };
}

async function readCodexSupportDocument(fieldNames = CODEX_SUPPORT_STATUS_FIELDS) {
  try {
    return await getFirestoreDocument(CODEX_SUPPORT_DOCUMENT_ID, fieldNames);
  } catch (error) {
    if (Number(error.status) === 404) return null;
    throw error;
  }
}

export async function getCodexSupportStatus({ force = false } = {}) {
  assertCodexSupportAvailable();
  if (!force && codexSupportCache.status && Date.now() - codexSupportCache.at < CODEX_SUPPORT_CACHE_MS) {
    return { ...codexSupportCache.status, cached: true };
  }
  const document = await readCodexSupportDocument();
  const status = normalizedCodexSupportStatus(document);
  codexSupportCache = { at: Date.now(), status };
  return { ...status, cached: false };
}

export async function submitCodexSupportMessage(input = {}) {
  assertCodexSupportAvailable();
  const selection = resolveCodexSupportMessage(input);
  const requestedDeviceUid = String(input.deviceUid ?? "").trim();

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const document = await readCodexSupportDocument([]);
    const current = normalizedCodexSupportStatus(document);
    if (current.pending) {
      throw new HttpError(409, "上一筆維修請求仍在等待家中主機接收", "CODEX_SUPPORT_PENDING", current);
    }
    const cooldownRemainingMs = codexSupportCooldownRemaining(current.queuedAt);
    if (cooldownRemainingMs > 0) {
      throw new HttpError(429, "剛剛已送進 Codex，請等候處理結果", "CODEX_SUPPORT_COOLDOWN", {
        cooldownRemainingMs,
      });
    }

    const nextNonce = current.requestNonce + 1;
    const requestedAt = Date.now();
    const fields = {
      fields: {
        supportRequestNonce: { integerValue: String(nextNonce) },
        supportRequestAction: { stringValue: CODEX_SUPPORT_ACTION },
        supportRequestMode: { stringValue: selection.mode },
        supportRequestLabel: { stringValue: selection.label },
        supportRequestMessage: { stringValue: selection.message },
        supportRequestMessageLength: { integerValue: String(selection.message.length) },
        supportRequestedAt: { integerValue: String(requestedAt) },
        supportRequestedDeviceUid: { stringValue: requestedDeviceUid },
        bridgeState: { stringValue: "PENDING" },
        bridgeStatusNonce: { integerValue: String(nextNonce) },
        bridgeDetail: { stringValue: "已由一般控制台送出，等待家中主機接收" },
        bridgeUpdatedAt: { integerValue: String(requestedAt) },
        bridgeReceivedAt: { integerValue: "0" },
        bridgeValidatedAt: { integerValue: "0" },
        bridgeAttemptCount: { integerValue: "0" },
        bridgeLastAttemptAt: { integerValue: "0" },
        bridgeNextRetryAt: { integerValue: "0" },
        bridgeQueuedAt: { integerValue: "0" },
        bridgeMessageSha256: { stringValue: "" },
        bridgeErrorCode: { stringValue: "" },
        bridgeErrorDetail: { stringValue: "" },
      },
    };

    try {
      await patchFirestoreDocumentAtVersion(
        CODEX_SUPPORT_DOCUMENT_ID,
        fields,
        document?.updateTime ? document.updateTime : { exists: false },
        [],
      );
      const status = normalizedCodexSupportStatus({
        fields: { ...(document?.fields ?? {}), ...fields.fields },
      });
      codexSupportCache = { at: Date.now(), status };
      return { ...status, submitted: true, cached: false };
    } catch (error) {
      if (isFirestoreConcurrencyConflict(error) && attempt < 4) continue;
      throw error;
    }
  }
  throw new HttpError(409, "Codex 維修請求同時更新，請再試一次", "CODEX_SUPPORT_CONFLICT");
}

export async function syncFallbackCommandBaselines() {
  if (!config.firestore.enabled) return { enabled: false, synced: 0, skipped: 0 };
  const pendingSettings = await query("SELECT count(*)::int AS count FROM settings_revisions WHERE status='PENDING'");
  if (Number(pendingSettings.rows[0]?.count ?? 0) > 0) {
    throw new HttpError(409, "仍有設定等待 ACK，不可切回 Firestore", "PENDING_SELFHOST_SETTINGS");
  }
  const pending = await query("SELECT count(*)::int AS count FROM commands WHERE status='PENDING'");
  if (Number(pending.rows[0]?.count ?? 0) > 0) {
    throw new HttpError(409, "仍有自架命令等待 ACK，不可切回 Firestore", "PENDING_SELFHOST_COMMANDS");
  }

  const devices = await query(
    `SELECT uid,state,last_nonce,command_nonce FROM devices
     WHERE imported_from_firestore=true ORDER BY uid`,
  );
  let synced = 0;
  let skipped = 0;
  for (const device of devices.rows) {
    let completed = false;
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const document = await getFirestoreDocument(device.uid, ["nonce", "lastAckNonce"]);
      const baseline = buildFallbackCommandBaseline({
        state: device.state,
        lastNonce: Number(device.last_nonce),
        commandNonce: Number(device.command_nonce),
        remoteNonce: field(document, "nonce", 0),
        remoteAckNonce: field(document, "lastAckNonce", 0),
      });
      if (!baseline) {
        skipped += 1;
        completed = true;
        break;
      }

      const fields = {
        fields: {
          desiredState: { stringValue: baseline.desiredState },
          nonce: { integerValue: String(baseline.nonce) },
          requestedServerIndex: { integerValue: "0" },
          requestedServerName: { stringValue: "" },
          commandUpdatedAt: { integerValue: String(baseline.at) },
          lastAckNonce: { integerValue: String(baseline.nonce) },
          lastAckState: { stringValue: baseline.desiredState },
          lastAckResult: { stringValue: "MIGRATION_BASELINE" },
          lastAckDetail: { stringValue: "切回 Firestore 前已對齊裝置處理游標；這不是新指令" },
          lastAckServerIndex: { integerValue: "0" },
          lastAckServerName: { stringValue: "" },
          lastAckAt: { integerValue: String(baseline.at) },
        },
      };
      try {
        await patchFirestoreDocumentAtVersion(device.uid, fields, document.updateTime);
        await query(
          `UPDATE devices SET firestore_observed_nonce=GREATEST(firestore_observed_nonce,$2),
             firestore_observed_ack_nonce=GREATEST(firestore_observed_ack_nonce,$2),
             firestore_observed_at=now(),updated_at=now() WHERE uid=$1`,
          [device.uid, baseline.nonce],
        );
        synced += 1;
        completed = true;
        break;
      } catch (error) {
        if (isFirestoreConcurrencyConflict(error) && attempt < 4) continue;
        throw error;
      }
    }
    if (!completed) throw new Error(`無法對齊 ${device.uid} 的 Firestore 命令游標`);
  }
  return { enabled: true, synced, skipped };
}

export async function publishDiscovery(options = {}) {
  const strict = Boolean(options.strict);
  if (!config.firestore.enabled) {
    if (strict) throw new HttpError(503, "Firestore 未啟用，無法安全發布遷移模式", "FIRESTORE_DISCOVERY_UNAVAILABLE");
    return { published: 0, failed: 0 };
  }
  const migration = await getMigrationState();
  const mode = String(options.mode ?? migration.mode ?? "shadow");
  const epoch = String(options.epoch ?? migration.epoch ?? "selfhost-v1");
  const fallbackUntil = options.fallbackUntil ?? migration.fallbackUntil;
  const writesFrozen = options.writesFrozen ?? migration.writesFrozen ?? false;
  const fields = firestoreFieldsForDiscovery(mode, epoch, fallbackUntil, writesFrozen);
  const devices = await query("SELECT uid FROM devices WHERE imported_from_firestore=true");
  let published = 0;
  const failures = [];
  for (const { uid } of devices.rows) {
    try {
      await patchFirestoreDocument(uid, fields);
      published += 1;
    } catch (error) {
      failures.push({ uid, error: error.message });
      await query(
        `INSERT INTO server_alerts(level,code,message,details)
         SELECT 'WARN','FIRESTORE_DISCOVERY_FAILED',$1,$2
         WHERE NOT EXISTS (SELECT 1 FROM server_alerts WHERE code='FIRESTORE_DISCOVERY_FAILED'
           AND message=$1 AND created_at>now()-interval '24 hours')`,
        [`無法向 ${uid} 發布自架伺服器資訊`, JSON.stringify({ error: error.message })],
      );
    }
  }
  try {
    await patchFirestoreDocument("__selfhost_migration", {
    fields: {
      selfHostedServerUrl: { stringValue: config.publicUrl },
      selfHostedMode: { stringValue: mode },
      selfHostedEpoch: { stringValue: epoch },
      selfHostedFirestoreFallbackUntil: { integerValue: String(fallbackUntil ? new Date(fallbackUntil).valueOf() : 0) },
      selfHostedWritesFrozen: { booleanValue: Boolean(writesFrozen) },
      selfHostedUpdatedAt: { integerValue: String(Date.now()) },
    },
    });
  } catch (error) {
    failures.push({ uid: "__selfhost_migration", error: error.message });
  }
  if (strict && failures.length) {
    throw new HttpError(503, "遷移模式未能發布到所有 Firestore 裝置", "FIRESTORE_DISCOVERY_PARTIAL", {
      published,
      expected: devices.rows.length + 1,
      failures,
    });
  }
  return { published, failed: failures.length, failures };
}

export async function migrationReadiness() {
  const migration = await getMigrationState();
  const shadowStartedAt = new Date(migration.shadowStartedAt ?? migration.updatedAt ?? Date.now());
  const lastConsistencyErrorAt = migration.lastConsistencyErrorAt ? new Date(migration.lastConsistencyErrorAt) : null;
  const startedAt = lastConsistencyErrorAt && lastConsistencyErrorAt > shadowStartedAt
    ? lastConsistencyErrorAt : shadowStartedAt;
  const elapsedDays = Math.max(0, (Date.now() - startedAt.valueOf()) / 86_400_000);
  const devices = await query(
    `SELECT d.uid,d.display_name,d.last_seen,d.credential_issued_at
     FROM devices d WHERE d.imported_from_firestore=true ORDER BY d.uid`,
  );
  const pending = await query("SELECT count(*)::int AS count FROM commands WHERE status='PENDING'");
  const firestorePending = await query(
    `SELECT count(*)::int AS count FROM devices WHERE imported_from_firestore=true AND
      (firestore_observed_nonce>firestore_observed_ack_nonce OR
       firestore_observed_settings_revision>firestore_observed_settings_ack_revision)`,
  );
  const shadowMismatch = await query(
    `SELECT count(*)::int AS count FROM devices WHERE imported_from_firestore=true
      AND credential_issued_at IS NOT NULL AND firestore_observed_at IS NOT NULL
      AND firestore_observed_nonce=firestore_observed_ack_nonce
      AND last_nonce<>firestore_observed_ack_nonce`,
  );
  const consistencyErrors = Math.max(Number(migration.consistencyErrors ?? 0), Number(shadowMismatch.rows[0].count));
  const ready = elapsedDays >= 7
    && devices.rows.length >= 1
    && devices.rows.every((row) => row.credential_issued_at)
    && Number(pending.rows[0].count) === 0
    && Number(firestorePending.rows[0].count) === 0
    && consistencyErrors === 0;
  return {
    ready,
    mode: migration.mode ?? "shadow",
    shadowStartedAt: shadowStartedAt.toISOString(),
    validationWindowStartedAt: startedAt.toISOString(),
    lastConsistencyErrorAt: lastConsistencyErrorAt?.toISOString() ?? null,
    elapsedDays,
    consistencyErrors,
    pendingCommands: Number(pending.rows[0].count),
    pendingFirestoreAcks: Number(firestorePending.rows[0].count),
    devices: devices.rows,
  };
}

function migrationValue(state) {
  const { updatedAt: _updatedAt, ...value } = state ?? {};
  return value;
}

async function replaceMigrationValue(value) {
  await query("UPDATE system_settings SET value=$1::jsonb,updated_at=now() WHERE key='migration'", [value]);
}

async function commitFrozenPrimaryValue(value, epoch) {
  await withTransaction(async (client) => {
    const current = await client.query(
      "SELECT value FROM system_settings WHERE key='migration' FOR UPDATE",
    );
    const currentValue = current.rows[0]?.value ?? {};
    if (currentValue.mode !== "cutover"
      || currentValue.epoch !== epoch
      || currentValue.writesFrozen !== true) {
      throw new HttpError(409, "遷移狀態已變更，拒絕提交 primary", "MIGRATION_MODE_CHANGED", {
        mode: currentValue.mode,
        epoch: currentValue.epoch,
        writesFrozen: currentValue.writesFrozen,
      });
    }
    await client.query(
      "UPDATE system_settings SET value=$1::jsonb,updated_at=now() WHERE key='migration'",
      [value],
    );
  });
}

let migrationTransitionTail = Promise.resolve();

function serializeMigrationTransition(callback) {
  const running = migrationTransitionTail.then(callback, callback);
  migrationTransitionTail = running.catch(() => {});
  return running;
}

export async function runCutoverSequence({ freeze, reconcile, readiness, publishPrimary, commitPrimary, restore }) {
  let committed = false;
  try {
    await freeze();
    await reconcile();
    const state = await readiness();
    if (!state.ready) {
      throw new HttpError(409, "尚未符合 7 天並行切換條件", "MIGRATION_NOT_READY", state);
    }
    await publishPrimary();
    const result = await commitPrimary();
    committed = true;
    return result;
  } catch (error) {
    if (!committed) {
      try {
        await restore();
      } catch (restoreError) {
        throw new HttpError(503, "遷移失敗，且無法完整恢復 shadow 發布狀態", "MIGRATION_ROLLBACK_FAILED", {
          cause: error.message,
          restore: restoreError.message,
        });
      }
    }
    throw error;
  }
}

export async function cutoverToPrimary() {
  return serializeMigrationTransition(async () => {
    const original = await getMigrationState();
    if ((original.mode ?? "shadow") !== "shadow") {
      throw new HttpError(409, "只有 shadow 模式可以正式切換", "MIGRATION_MODE_CHANGED", { mode: original.mode });
    }
    const originalValue = migrationValue(original);
    const epoch = `selfhost-${Date.now()}`;
    const fallbackUntil = new Date(Date.now() + 7 * 86_400_000).toISOString();
    const frozenValue = { ...originalValue, mode: "cutover", epoch, writesFrozen: true };
    const primaryValue = {
      ...originalValue,
      mode: "primary",
      epoch,
      writesFrozen: false,
      cutoverAt: new Date().toISOString(),
      fallbackUntil,
    };
    return runCutoverSequence({
      freeze: async () => {
        await replaceMigrationValue(frozenValue);
        await publishDiscovery({ strict: true, mode: "cutover", epoch, fallbackUntil, writesFrozen: true });
      },
      reconcile: () => importFirestoreDevices({ publish: false }),
      readiness: migrationReadiness,
      publishPrimary: () => publishDiscovery({
        strict: true,
        mode: "primary",
        epoch,
        fallbackUntil,
        writesFrozen: false,
      }),
      commitPrimary: async () => {
        await commitFrozenPrimaryValue(primaryValue, epoch);
        return getMigrationState();
      },
      restore: async () => {
        await replaceMigrationValue(originalValue);
        await publishDiscovery({
          strict: true,
          mode: originalValue.mode ?? "shadow",
          epoch: originalValue.epoch ?? "selfhost-v1",
          fallbackUntil: originalValue.fallbackUntil,
          writesFrozen: false,
        });
      },
    });
  });
}

export async function forceMigrationMode(mode) {
  if (!["shadow", "primary", "fallback", "disabled"].includes(mode)) {
    throw new HttpError(400, "遷移模式無效", "INVALID_MIGRATION_MODE");
  }
  return serializeMigrationTransition(async () => {
    const original = await getMigrationState();
    if (original.mode === "cutover") throw new HttpError(409, "正式切換正在進行中", "MIGRATION_TRANSITION_BUSY");
    const pendingSettings = await query("SELECT count(*)::int AS count FROM settings_revisions WHERE status='PENDING'");
    if (mode !== "primary" && Number(pendingSettings.rows[0]?.count ?? 0) > 0) {
      throw new HttpError(409, "仍有設定等待 ACK，不可離開自架控制", "PENDING_SELFHOST_SETTINGS");
    }
    const fallbackBaseline = mode === "fallback" ? await syncFallbackCommandBaselines() : null;
    const epoch = `selfhost-${Date.now()}`;
    const nextValue = { ...migrationValue(original), mode, epoch, writesFrozen: false };
    await replaceMigrationValue(nextValue);
    try {
      await publishDiscovery({ strict: true, mode, epoch, fallbackUntil: nextValue.fallbackUntil, writesFrozen: false });
    } catch (error) {
      await replaceMigrationValue(migrationValue(original));
      await publishDiscovery({
        strict: true,
        mode: original.mode ?? "shadow",
        epoch: original.epoch ?? "selfhost-v1",
        fallbackUntil: original.fallbackUntil,
        writesFrozen: false,
      });
      throw error;
    }
    return { ...(await getMigrationState()), ...(fallbackBaseline ? { fallbackBaseline } : {}) };
  });
}
