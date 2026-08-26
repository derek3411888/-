import { config } from "./config.js";
import { query, withTransaction } from "./db.js";
import { HttpError, boundedText, integer } from "./utils.js";

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
    throw new Error(`Firestore HTTP ${response.status}: ${text.slice(0, 1000)}`);
  }
  return response.status === 204 ? {} : response.json();
}

export async function getMigrationState() {
  const result = await query("SELECT value,updated_at FROM system_settings WHERE key='migration'");
  const value = result.rows[0]?.value ?? { mode: "shadow", shadowStartedAt: new Date().toISOString(), consistencyErrors: 0 };
  return { ...value, updatedAt: result.rows[0]?.updated_at ?? null };
}

export async function importFirestoreDevices() {
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
      const effectiveSettingsRevision = integer(field(document, "effectiveSettingsRevision", 0), 0);
      const desiredSettingsRevision = integer(field(document, "desiredSettingsRevision", 0), 0);
      const settingsAckRevision = integer(field(document, "lastSettingsAckRevision", 0), 0);
      const settingsRevision = Math.max(
        desiredSettingsRevision,
        settingsAckRevision,
        effectiveSettingsRevision,
      );
      const settings = {
        schemaVersion: 1,
        serverScheduleEnabled: Boolean(field(document, "effectiveServerScheduleEnabled", false)),
        serverScheduleList: boundedText(field(document, "effectiveServerScheduleList", ""), 1200),
        mailNotifyEnabled: Boolean(field(document, "effectiveMailNotifyEnabled", false)),
        runtimeDiagnosticsEnabled: Boolean(field(document, "effectiveRuntimeDiagnosticsEnabled", true)),
        runtimeDiagnosticsIntervalSec: integer(field(document, "effectiveRuntimeDiagnosticsIntervalSec", 60), 60, 60, 600),
        runtimeDiagnosticsErrorKeepCount: integer(field(document, "effectiveRuntimeDiagnosticsErrorKeepCount", 30), 30, 5, 200),
        maxRestartCount: integer(field(document, "effectiveMaxRestartCount", 10), 10, 1, 50),
        liveQualityProfile: ["economy", "balanced", "smooth"].includes(
          String(field(document, "effectiveLiveQualityProfile", "balanced")).trim().toLowerCase(),
        ) ? String(field(document, "effectiveLiveQualityProfile", "balanced")).trim().toLowerCase() : "balanced",
      };
      await withTransaction(async (client) => {
        await client.query(
          `INSERT INTO devices(uid,display_name,device_alias,last_nonce,command_nonce,settings_revision,settings,
             imported_from_firestore,firestore_observed_nonce,firestore_observed_ack_nonce,
             firestore_observed_settings_revision,firestore_observed_settings_ack_revision,firestore_observed_at)
           VALUES($1,$2,$3,$4,$4,$5,$6,true,$7,$8,$9,$10,now())
           ON CONFLICT(uid) DO UPDATE SET
             display_name=COALESCE(NULLIF(EXCLUDED.display_name,''),devices.display_name),
             device_alias=COALESCE(NULLIF(EXCLUDED.device_alias,''),devices.device_alias),
             last_nonce=GREATEST(devices.last_nonce,EXCLUDED.last_nonce),
             command_nonce=GREATEST(devices.command_nonce,EXCLUDED.command_nonce),
             settings_revision=GREATEST(devices.settings_revision,EXCLUDED.settings_revision),
             settings=CASE WHEN EXCLUDED.settings_revision>=devices.settings_revision THEN EXCLUDED.settings ELSE devices.settings END,
             firestore_observed_nonce=EXCLUDED.firestore_observed_nonce,
             firestore_observed_ack_nonce=EXCLUDED.firestore_observed_ack_nonce,
             firestore_observed_settings_revision=EXCLUDED.firestore_observed_settings_revision,
             firestore_observed_settings_ack_revision=EXCLUDED.firestore_observed_settings_ack_revision,
             firestore_observed_at=now(),
             imported_from_firestore=true,updated_at=now()`,
          [uid, displayName, deviceAlias, Math.max(nonce, lastAck), settingsRevision, settings,
            nonce, lastAck, desiredSettingsRevision, settingsAckRevision],
        );
        if (settingsRevision > 0) {
          await client.query(
            `INSERT INTO settings_revisions(uid,revision,settings,status,acked_at,ack_result,ack_detail)
             VALUES($1,$2,$3,'APPLIED',now(),'IMPORTED','Firestore 並行期已套用值')
             ON CONFLICT(uid,revision) DO UPDATE SET settings=EXCLUDED.settings`,
            [uid, settingsRevision, settings],
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
  await publishDiscovery();
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

function firestoreFieldsForDiscovery(mode, epoch, fallbackUntil = "") {
  return {
    fields: {
      selfHostedServerUrl: { stringValue: config.publicUrl },
      selfHostedMode: { stringValue: mode },
      selfHostedEpoch: { stringValue: epoch },
      selfHostedFirestoreFallbackUntil: { integerValue: String(fallbackUntil ? new Date(fallbackUntil).valueOf() : 0) },
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

export async function publishDiscovery() {
  if (!config.firestore.enabled) return { published: 0 };
  const migration = await getMigrationState();
  const epoch = String(migration.epoch ?? "selfhost-v1");
  const fields = firestoreFieldsForDiscovery(migration.mode ?? "shadow", epoch, migration.fallbackUntil);
  const devices = await query("SELECT uid FROM devices WHERE imported_from_firestore=true");
  let published = 0;
  for (const { uid } of devices.rows) {
    try {
      await patchFirestoreDocument(uid, fields);
      published += 1;
    } catch (error) {
      await query(
        `INSERT INTO server_alerts(level,code,message,details)
         SELECT 'WARN','FIRESTORE_DISCOVERY_FAILED',$1,$2
         WHERE NOT EXISTS (SELECT 1 FROM server_alerts WHERE code='FIRESTORE_DISCOVERY_FAILED'
           AND message=$1 AND created_at>now()-interval '24 hours')`,
        [`無法向 ${uid} 發布自架伺服器資訊`, JSON.stringify({ error: error.message })],
      );
    }
  }
  await patchFirestoreDocument("__selfhost_migration", {
    fields: {
      selfHostedServerUrl: { stringValue: config.publicUrl },
      selfHostedMode: { stringValue: migration.mode ?? "shadow" },
      selfHostedEpoch: { stringValue: epoch },
      selfHostedFirestoreFallbackUntil: { integerValue: String(migration.fallbackUntil ? new Date(migration.fallbackUntil).valueOf() : 0) },
      selfHostedUpdatedAt: { integerValue: String(Date.now()) },
    },
  }).catch(() => {});
  return { published };
}

export async function migrationReadiness() {
  const migration = await getMigrationState();
  const shadowStartedAt = new Date(migration.shadowStartedAt ?? migration.updatedAt ?? Date.now());
  const lastConsistencyErrorAt = migration.lastConsistencyErrorAt ? new Date(migration.lastConsistencyErrorAt) : null;
  const startedAt = lastConsistencyErrorAt && lastConsistencyErrorAt > shadowStartedAt
    ? lastConsistencyErrorAt : shadowStartedAt;
  const elapsedDays = Math.max(0, (Date.now() - startedAt.valueOf()) / 86_400_000);
  const devices = await query(
    `SELECT d.uid,d.display_name,d.last_seen,d.credential_issued_at,
      count(rs.id) FILTER (WHERE rs.state='COMPLETE' AND rs.completed_at >= $1)::int AS completed_runs
     FROM devices d LEFT JOIN recording_sessions rs ON rs.uid=d.uid
     WHERE d.imported_from_firestore=true
     GROUP BY d.uid ORDER BY d.uid`,
    [startedAt],
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
    && devices.rows.every((row) => row.credential_issued_at && Number(row.completed_runs) >= 1)
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

export async function cutoverToPrimary() {
  const readiness = await migrationReadiness();
  if (!readiness.ready) throw new HttpError(409, "尚未符合 7 天並行切換條件", "MIGRATION_NOT_READY", readiness);
  const epoch = `selfhost-${Date.now()}`;
  await query(
    `UPDATE system_settings SET value=jsonb_build_object(
       'mode','primary','shadowStartedAt',COALESCE(value->'shadowStartedAt',to_jsonb(now())),
       'cutoverAt',to_jsonb(now()),'fallbackUntil',to_jsonb(now() + interval '7 days'),
       'consistencyErrors',COALESCE(value->'consistencyErrors','0'::jsonb),'epoch',$1::text
     ),updated_at=now() WHERE key='migration'`,
    [epoch],
  );
  await publishDiscovery();
  return getMigrationState();
}

export async function forceMigrationMode(mode) {
  if (!["shadow", "primary", "fallback", "disabled"].includes(mode)) {
    throw new HttpError(400, "遷移模式無效", "INVALID_MIGRATION_MODE");
  }
  await query(
    `UPDATE system_settings SET value=jsonb_set(jsonb_set(value,'{mode}',to_jsonb($1::text),true),
      '{epoch}',to_jsonb($2::text),true),updated_at=now() WHERE key='migration'`,
    [mode, `selfhost-${Date.now()}`],
  );
  await publishDiscovery();
  return getMigrationState();
}
