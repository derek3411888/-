import fsp from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { config, assertChildPath } from "./config.js";
import { closeDatabase, migrate, query, withTransaction } from "./db.js";
import { installFileLogger } from "./logger.js";
import { analyzeServerSchedule } from "./server-names.js";
import {
  browserCookie,
  ensureBrowser,
  enrollDevice,
  requireDevice,
  requireSameOrigin,
} from "./auth.js";
import {
  cutoverToPrimary,
  forceMigrationMode,
  getMigrationState,
  importFirestoreDevices,
  migrationReadiness,
  publishDiscovery,
} from "./firestore-bridge.js";
import {
  ensureMediaRoots,
  getSegmentUploadState,
  listRecordingSegments,
  listRecordings,
  pruneMedia,
  receiveSegmentChunk,
  recordingSessionState,
  registerSegment,
  retrySegment,
  requestSessionFinalize,
  resolvePlayable,
  resumeMediaJobs,
  streamVideo,
  upsertRecordingSession,
} from "./media.js";
import {
  EventHub,
  HttpError,
  RateLimiter,
  bearerToken,
  boundedText,
  clientIp,
  hmac,
  integer,
  normalizeUid,
  readBuffer,
  readJson,
  sendEmpty,
  sendJson,
  sha256,
  timingSafeTextEqual,
} from "./utils.js";

const eventHub = new EventHub();
const limiter = new RateLimiter();
const liveLeaseTouches = new Map();
const liveHlsSessions = new Map();
const startedAt = Date.now();
const staticFiles = new Map([
  ["/", ["index.html", "text/html; charset=utf-8"]],
  ["/index.html", ["index.html", "text/html; charset=utf-8"]],
  ["/app.js", ["app.js", "text/javascript; charset=utf-8"]],
  ["/styles.css", ["styles.css", "text/css; charset=utf-8"]],
  ["/vendor/hls.min.js", ["../node_modules/hls.js/dist/hls.min.js", "text/javascript; charset=utf-8"]],
]);

function routeMatch(pathname, pattern) {
  const keys = [];
  const source = pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/:([A-Za-z0-9_]+)/g, (_, key) => {
    keys.push(key);
    return "([^/]+)";
  });
  const match = new RegExp(`^${source}$`).exec(pathname);
  if (!match) return null;
  return Object.fromEntries(keys.map((key, index) => [key, decodeURIComponent(match[index + 1])]));
}

function commandPayload(body) {
  const payload = {};
  const serverIndex = integer(body.serverIndex, 0, 0, 100);
  const serverName = boundedText(body.serverName, 160);
  if (serverIndex) payload.serverIndex = serverIndex;
  if (serverName) payload.serverName = serverName;
  return payload;
}

async function migrationMode() {
  return (await getMigrationState()).mode ?? "shadow";
}

async function sendCommand(uid, body) {
  const command = String(body.command ?? "").trim().toUpperCase();
  if (!["RUN", "PAUSE", "STOP", "SWITCH_SERVER", "COMPLETE_SERVER"].includes(command)) {
    throw new HttpError(400, "命令不在允許清單", "INVALID_COMMAND");
  }
  if ((await migrationMode()) !== "primary") throw new HttpError(423, "並行驗證期間命令仍由 Firestore 控制", "SHADOW_MODE");
  const idempotencyKey = boundedText(body.idempotencyKey, 100) || null;
  const payload = commandPayload(body);
  return withTransaction(async (client) => {
    const device = await client.query("SELECT * FROM devices WHERE uid=$1 FOR UPDATE", [uid]);
    if (!device.rowCount) throw new HttpError(404, "找不到裝置", "DEVICE_NOT_FOUND");
    if (idempotencyKey) {
      const duplicate = await client.query("SELECT * FROM commands WHERE uid=$1 AND idempotency_key=$2", [uid, idempotencyKey]);
      if (duplicate.rowCount) return duplicate.rows[0];
    }
    const pending = await client.query("SELECT * FROM commands WHERE uid=$1 AND status='PENDING' FOR UPDATE", [uid]);
    if (pending.rowCount && command !== "STOP") {
      throw new HttpError(409, "上一筆命令尚未 ACK，不能覆蓋", "COMMAND_PENDING", pending.rows[0]);
    }
    if (pending.rowCount && command === "STOP" && pending.rows[0].command === "STOP") {
      return pending.rows[0];
    }
    if (pending.rowCount) {
      await client.query("UPDATE commands SET status='SUPERSEDED',ack_detail='由 STOP 優先取代' WHERE id=$1", [pending.rows[0].id]);
    }
    const nonce = Number(device.rows[0].command_nonce) + 1;
    const inserted = await client.query(
      `INSERT INTO commands(uid,nonce,command,payload,idempotency_key)
       VALUES($1,$2,$3,$4,$5) RETURNING *`,
      [uid, nonce, command, payload, idempotencyKey],
    );
    await client.query("UPDATE devices SET command_nonce=$2,updated_at=now() WHERE uid=$1", [uid, nonce]);
    return inserted.rows[0];
  });
}

function firestoreString(value) { return { stringValue: String(value ?? "") }; }
function firestoreInteger(value) { return { integerValue: String(Math.max(0, Number(value) || 0)) }; }
function firestoreBoolean(value) { return { booleanValue: Boolean(value) }; }

function normalizeLiveQualityProfile(value) {
  const profile = String(value ?? "").trim().toLowerCase();
  return ["economy", "balanced", "smooth"].includes(profile) ? profile : "balanced";
}

function livePublishUrl(uid, token, host) {
  return `srt://${host}:${config.publicSrtPort}?streamid=publish:${uid}:device:${token}`
    + `&pkt_size=1316&latency=200000&passphrase=${encodeURIComponent(config.liveSrtPassphrase)}&pbkeylen=32`;
}

async function deviceControl(uid, firestoreFormat) {
  const [deviceResult, commandResult, ackResult, settingsResult, liveResult, migration] = await Promise.all([
    query("SELECT * FROM devices WHERE uid=$1", [uid]),
    query("SELECT * FROM commands WHERE uid=$1 AND status='PENDING' ORDER BY nonce DESC LIMIT 1", [uid]),
    query("SELECT * FROM commands WHERE uid=$1 AND status='ACKED' ORDER BY nonce DESC LIMIT 1", [uid]),
    query("SELECT * FROM settings_revisions WHERE uid=$1 ORDER BY revision DESC LIMIT 1", [uid]),
    query("SELECT max(expires_at) AS expires_at FROM live_leases WHERE uid=$1 AND expires_at>now()", [uid]),
    getMigrationState(),
  ]);
  if (!deviceResult.rowCount) throw new HttpError(404, "找不到裝置", "DEVICE_NOT_FOUND");
  const device = deviceResult.rows[0];
  const command = commandResult.rows[0];
  const ack = ackResult.rows[0];
  const settingsRow = settingsResult.rows[0];
  const liveExpiresAt = liveResult.rows[0]?.expires_at ?? null;
  const liveActive = Boolean(liveExpiresAt);
  // The browser lease still expires 90 seconds after the final viewer leaves.
  // Devices can report only every 90 seconds when a workflow is busy, so the
  // local FFmpeg deadline needs extra margin. An explicit inactive response
  // still stops it immediately and does not wait for this fail-safe deadline.
  const livePublisherExpiresAt = liveExpiresAt
    ? new Date(liveExpiresAt.valueOf() + config.livePublisherGraceSeconds * 1000) : null;
  const liveToken = liveActive ? hmac(config.liveSecret, `publish:${uid}`) : "";
  // Most devices are on the same LAN as the always-on Docker host. Routers
  // often support HTTPS NAT loopback but not UDP/SRT NAT loopback, so the LAN
  // address must be preferred. New payloads retain the public URL as fallback.
  const liveHosts = [...new Set([config.localSrtHost, config.publicSrtHost].filter(Boolean))];
  const liveUrls = liveActive ? liveHosts.map((host) => livePublishUrl(uid, liveToken, host)) : [];
  const liveUrl = liveUrls[0] ?? "";
  const desired = command?.command ?? (device.state === "PAUSE" ? "PAUSE" : "RUN");
  const payload = command?.payload ?? {};
  const settings = settingsRow?.settings ?? device.settings ?? {};
  const normalizedSettings = {
    ...settings,
    liveQualityProfile: normalizeLiveQualityProfile(settings.liveQualityProfile),
  };
  const fallbackUntilMs = migration.fallbackUntil ? new Date(migration.fallbackUntil).valueOf() : 0;
  const result = {
    migrationMode: migration.mode ?? "shadow",
    selfHostedServerUrl: config.publicUrl,
    selfHostedMode: migration.mode ?? "shadow",
    selfHostedEpoch: migration.epoch ?? "selfhost-v1",
    selfHostedFirestoreFallbackUntil: fallbackUntilMs,
    command: command ? {
      nonce: Number(command.nonce), state: command.command, serverIndex: Number(payload.serverIndex ?? 0), serverName: payload.serverName ?? "",
    } : null,
    lastAck: ack ? {
      nonce: Number(ack.nonce), state: ack.command, result: ack.ack_result ?? "", detail: ack.ack_detail ?? "",
      serverIndex: Number(ack.ack_payload?.serverIndex ?? ack.payload?.serverIndex ?? 0),
      serverName: ack.ack_payload?.serverName ?? ack.payload?.serverName ?? "", at: ack.acked_at?.valueOf?.() ?? 0,
    } : null,
    settings: settingsRow ? { revision: Number(settingsRow.revision), ...normalizedSettings } : null,
    live: {
      active: liveActive,
      publishUrl: liveUrl,
      publishUrls: liveUrls,
      expiresAt: liveExpiresAt,
      publisherExpiresAt: livePublisherExpiresAt,
    },
  };
  if (!firestoreFormat) return result;
  const fields = {
    desiredState: firestoreString(desired),
    nonce: firestoreInteger(command?.nonce ?? device.last_nonce),
    requestedServerIndex: firestoreInteger(payload.serverIndex ?? 0),
    requestedServerName: firestoreString(payload.serverName ?? ""),
    lastAckNonce: firestoreInteger(ack?.nonce ?? 0),
    lastAckState: firestoreString(ack?.command ?? ""),
    lastAckResult: firestoreString(ack?.ack_result ?? ""),
    lastAckDetail: firestoreString(ack?.ack_detail ?? ""),
    lastAckServerIndex: firestoreInteger(ack?.ack_payload?.serverIndex ?? ack?.payload?.serverIndex ?? 0),
    lastAckServerName: firestoreString(ack?.ack_payload?.serverName ?? ack?.payload?.serverName ?? ""),
    lastAckAt: firestoreInteger(ack?.acked_at?.valueOf?.() ?? 0),
    desiredSettingsRevision: firestoreInteger(settingsRow?.revision ?? 0),
    desiredSettingsSchemaVersion: firestoreInteger(normalizedSettings.schemaVersion ?? 1),
    desiredServerScheduleEnabled: firestoreBoolean(normalizedSettings.serverScheduleEnabled ?? false),
    desiredServerScheduleList: firestoreString(normalizedSettings.serverScheduleList ?? ""),
    desiredMailNotifyEnabled: firestoreBoolean(normalizedSettings.mailNotifyEnabled ?? false),
    desiredRuntimeDiagnosticsEnabled: firestoreBoolean(normalizedSettings.runtimeDiagnosticsEnabled ?? true),
    desiredRuntimeDiagnosticsIntervalSec: firestoreInteger(normalizedSettings.runtimeDiagnosticsIntervalSec ?? 60),
    desiredRuntimeDiagnosticsErrorKeepCount: firestoreInteger(normalizedSettings.runtimeDiagnosticsErrorKeepCount ?? 30),
    desiredMaxRestartCount: firestoreInteger(normalizedSettings.maxRestartCount ?? 10),
    desiredLiveQualityProfile: firestoreString(normalizedSettings.liveQualityProfile),
    selfHostedServerUrl: firestoreString(config.publicUrl),
    selfHostedMode: firestoreString(migration.mode ?? "shadow"),
    selfHostedEpoch: firestoreString(migration.epoch ?? "selfhost-v1"),
    selfHostedFirestoreFallbackUntil: firestoreInteger(fallbackUntilMs),
    selfHostedLiveEnabled: firestoreBoolean(liveActive),
    selfHostedLivePublishUrl: firestoreString(liveUrl),
    selfHostedLivePublishUrls: firestoreString(liveUrls.join("|")),
    selfHostedLiveExpiresAt: firestoreInteger(livePublisherExpiresAt?.valueOf?.() ?? 0),
  };
  return { fields };
}

async function updateHeartbeat(uid, body) {
  const state = ["RUN", "PAUSE", "OFFLINE"].includes(String(body.state).toUpperCase()) ? String(body.state).toUpperCase() : "RUN";
  const lastNonce = integer(body.lastNonce, 0, 0, Number.MAX_SAFE_INTEGER);
  const settingsRevision = integer(body.settingsRevision, 0, 0, Number.MAX_SAFE_INTEGER);
  const displayName = boundedText(body.displayName, 160);
  const alias = boundedText(body.deviceAlias, 120);
  const status = typeof body.status === "object" && body.status ? body.status : {};
  await query(
    `UPDATE devices SET display_name=COALESCE(NULLIF($2,''),display_name),device_alias=COALESCE(NULLIF($3,''),device_alias),
      state=$4,status=$5,last_seen=now(),last_nonce=GREATEST(last_nonce,$6),command_nonce=GREATEST(command_nonce,$6),
      settings_revision=GREATEST(settings_revision,$7),updated_at=now() WHERE uid=$1`,
    [uid, displayName, alias, state, status, lastNonce, settingsRevision],
  );
  if (Array.isArray(body.events)) {
    for (const item of body.events.slice(-50)) {
      const atMs = integer(item.at, Date.now(), 0, Number.MAX_SAFE_INTEGER);
      const name = boundedText(item.name, 200) || "事件";
      const detail = boundedText(item.detail, 1200);
      const level = ["WARN", "ERROR"].includes(String(item.level).toUpperCase()) ? String(item.level).toUpperCase() : "INFO";
      const eventKey = sha256(`${atMs}|${level}|${name}|${detail}`);
      await query(
        `INSERT INTO runtime_events(uid,event_key,event_at,level,name,detail)
         VALUES($1,$2,to_timestamp($3/1000.0),$4,$5,$6) ON CONFLICT(uid,event_key) DO NOTHING`,
        [uid, eventKey, atMs, level, name, detail],
      );
    }
  }
  eventHub.emit("device", { uid, state, at: Date.now() });
}

async function updateRecordingWorkerStatus(uid, body) {
  const state = boundedText(body.state, 80) || "unknown";
  const detail = boundedText(body.detail, 1200);
  const baseName = boundedText(body.baseName, 160);
  const resultPath = boundedText(body.resultPath, 1200);
  const failureStorage = boundedText(body.failureStorage, 1200);
  const progressCurrent = integer(body.progressCurrent, 0, 0, Number.MAX_SAFE_INTEGER);
  const progressTotal = integer(body.progressTotal, 0, 0, Number.MAX_SAFE_INTEGER);
  const progressPercent = progressTotal > 0
    ? Math.min(100, Math.floor(progressCurrent / progressTotal * 100)) : null;
  const progressUnit = ["bytes", "segments"].includes(String(body.progressUnit))
    ? String(body.progressUnit) : "";
  const recording = {
    enabled: true,
    active: Boolean(body.active),
    state,
    detail,
    baseName,
    resultPath,
    failureStorage,
    progressCurrent,
    progressTotal,
    progressPercent,
    progressUnit,
    updatedAt: Date.now(),
    source: "background-worker",
  };
  const result = await query(
    `UPDATE devices SET status=jsonb_set(COALESCE(status,'{}'::jsonb),'{recording}',$2::jsonb,true),
      updated_at=now() WHERE uid=$1 RETURNING uid`,
    [uid, JSON.stringify(recording)],
  );
  if (!result.rowCount) throw new HttpError(404, "找不到裝置", "DEVICE_NOT_FOUND");
  eventHub.emit("recording", { uid, state, progressPercent, at: Date.now() });
  return recording;
}

async function ackCommand(uid, body) {
  const nonce = integer(body.nonce, 0, 1, Number.MAX_SAFE_INTEGER);
  const state = String(body.state ?? "").toUpperCase();
  const result = boundedText(body.result, 120);
  const detail = boundedText(body.detail, 2000);
  const ackPayload = commandPayload(body);
  const updated = await withTransaction(async (client) => {
    const command = await client.query("SELECT * FROM commands WHERE uid=$1 AND nonce=$2 FOR UPDATE", [uid, nonce]);
    if (!command.rowCount) throw new HttpError(404, "找不到對應命令", "COMMAND_NOT_FOUND");
    if (command.rows[0].command !== state) throw new HttpError(409, "ACK 命令身分不一致", "ACK_IDENTITY_MISMATCH");
    if (command.rows[0].status === "ACKED") {
      const existingPayload = command.rows[0].ack_payload ?? {};
      if (String(command.rows[0].ack_result ?? "") !== result
        || String(command.rows[0].ack_detail ?? "") !== detail
        || Number(existingPayload.serverIndex ?? 0) !== Number(ackPayload.serverIndex ?? 0)
        || String(existingPayload.serverName ?? "") !== String(ackPayload.serverName ?? "")) {
        throw new HttpError(409, "重複 ACK 與既有結果不一致", "ACK_RESULT_MISMATCH");
      }
      return command.rows[0];
    }
    if (command.rows[0].status !== "PENDING") throw new HttpError(409, "命令已被取消或取代", "COMMAND_NOT_PENDING");
    const row = await client.query(
      `UPDATE commands SET status='ACKED',acked_at=now(),ack_result=$3,ack_detail=$4,ack_payload=$5
       WHERE uid=$1 AND nonce=$2 RETURNING *`,
      [uid, nonce, result, detail, ackPayload],
    );
    await client.query("UPDATE devices SET last_nonce=GREATEST(last_nonce,$2),updated_at=now() WHERE uid=$1", [uid, nonce]);
    return row.rows[0];
  });
  eventHub.emit("command", { uid, nonce, status: "ACKED", result, at: Date.now() });
  return updated;
}

async function saveSettings(uid, body) {
  if ((await migrationMode()) !== "primary") throw new HttpError(423, "並行驗證期間設定仍由 Firestore 控制", "SHADOW_MODE");
  const serverSchedule = analyzeServerSchedule(body.serverScheduleList);
  if (serverSchedule.invalid.length) {
    throw new HttpError(400, `只允許 America、Europe、Asia、HMT(HK,MO,TW)、SEA；無效項目：${serverSchedule.invalid.join("、")}`, "INVALID_SERVER_LIST");
  }
  if (serverSchedule.duplicates.length) {
    throw new HttpError(400, `伺服器不可重複：${serverSchedule.duplicates.join("、")}`, "DUPLICATE_SERVER");
  }
  if (Boolean(body.serverScheduleEnabled) && !serverSchedule.servers.length) {
    throw new HttpError(400, "啟用排程時至少要選擇一個伺服器", "EMPTY_SERVER_LIST");
  }
  const settings = {
    schemaVersion: 1,
    serverScheduleEnabled: Boolean(body.serverScheduleEnabled),
    serverScheduleList: boundedText(serverSchedule.servers.join(" | "), 1200),
    mailNotifyEnabled: Boolean(body.mailNotifyEnabled),
    runtimeDiagnosticsEnabled: body.runtimeDiagnosticsEnabled !== false,
    runtimeDiagnosticsIntervalSec: integer(body.runtimeDiagnosticsIntervalSec, 60, 60, 600),
    runtimeDiagnosticsErrorKeepCount: integer(body.runtimeDiagnosticsErrorKeepCount, 30, 5, 200),
    maxRestartCount: integer(body.maxRestartCount, 10, 1, 50),
    liveQualityProfile: normalizeLiveQualityProfile(body.liveQualityProfile),
  };
  return withTransaction(async (client) => {
    const device = await client.query("SELECT settings_revision FROM devices WHERE uid=$1 FOR UPDATE", [uid]);
    if (!device.rowCount) throw new HttpError(404, "找不到裝置", "DEVICE_NOT_FOUND");
    const pending = await client.query(
      "SELECT revision,created_at FROM settings_revisions WHERE uid=$1 AND status='PENDING' ORDER BY revision DESC LIMIT 1 FOR UPDATE",
      [uid],
    );
    if (pending.rowCount) {
      throw new HttpError(409, "上一版設定尚未收到 ACK，不能覆蓋", "SETTINGS_PENDING", pending.rows[0]);
    }
    const revision = Number(device.rows[0].settings_revision) + 1;
    const inserted = await client.query(
      "INSERT INTO settings_revisions(uid,revision,settings) VALUES($1,$2,$3) RETURNING *",
      [uid, revision, settings],
    );
    // devices.settings 代表最後已成功套用的有效設定；待 ACK 的內容只存在版本表。
    await client.query("UPDATE devices SET settings_revision=$2,updated_at=now() WHERE uid=$1", [uid, revision]);
    return inserted.rows[0];
  });
}

async function ackSettings(uid, body) {
  const revision = integer(body.revision, 0, 1, Number.MAX_SAFE_INTEGER);
  const status = Boolean(body.applied) ? "APPLIED" : "REJECTED";
  const resultCode = boundedText(body.result, 120);
  const detail = boundedText(body.detail, 2000);
  const normalizedAck = { revision, applied: status === "APPLIED", result: resultCode, detail, at: Date.now() };
  const row = await withTransaction(async (client) => {
    const current = await client.query(
      "SELECT * FROM settings_revisions WHERE uid=$1 AND revision=$2 FOR UPDATE",
      [uid, revision],
    );
    if (!current.rowCount) throw new HttpError(404, "找不到設定版本", "SETTINGS_NOT_FOUND");
    if (current.rows[0].status !== "PENDING") {
      if (current.rows[0].status !== status
        || String(current.rows[0].ack_result ?? "") !== resultCode
        || String(current.rows[0].ack_detail ?? "") !== detail) {
        throw new HttpError(409, "設定 ACK 與既有結果不一致", "SETTINGS_ACK_IDENTITY_MISMATCH");
      }
    } else {
      const updated = await client.query(
        `UPDATE settings_revisions SET status=$3,acked_at=now(),ack_result=$4,ack_detail=$5
         WHERE uid=$1 AND revision=$2 RETURNING *`,
        [uid, revision, status, resultCode, detail],
      );
      current.rows[0] = updated.rows[0];
    }
    if (status === "APPLIED") {
      await client.query(
        `UPDATE devices d SET settings=s.settings,settings_ack=$3,updated_at=now()
         FROM settings_revisions s WHERE d.uid=$1 AND s.uid=d.uid AND s.revision=$2`,
        [uid, revision, normalizedAck],
      );
    } else {
      await client.query("UPDATE devices SET settings_ack=$2,updated_at=now() WHERE uid=$1", [uid, normalizedAck]);
    }
    return current.rows[0];
  });
  eventHub.emit("settings", { uid, revision, status, at: Date.now() });
  return row;
}

async function saveSnapshot(uid, req, url) {
  const capturedAt = new Date(integer(url.searchParams.get("capturedAt"), Date.now(), 0, Number.MAX_SAFE_INTEGER));
  const width = integer(url.searchParams.get("width"), 0, 0, 10_000);
  const height = integer(url.searchParams.get("height"), 0, 0, 10_000);
  const level = String(url.searchParams.get("level") ?? "INFO").toUpperCase();
  const reason = boundedText(url.searchParams.get("reason"), 300);
  const image = await readBuffer(req, 1024 * 1024);
  if (image.length < 100 || image[0] !== 0xff || image[1] !== 0xd8) throw new HttpError(400, "快照不是有效 JPEG", "INVALID_SNAPSHOT");
  const directory = assertChildPath(config.snapshotRoot, path.join(config.snapshotRoot, uid));
  await fsp.mkdir(directory, { recursive: true });
  const latest = assertChildPath(config.snapshotRoot, path.join(directory, "latest.jpg"));
  const temporary = `${latest}.tmp`;
  await fsp.writeFile(temporary, image);
  await fsp.rename(temporary, latest);
  const relative = path.relative(config.snapshotRoot, latest).split(path.sep).join("/");
  await query(
    `INSERT INTO snapshots(uid,relative_path,captured_at,width,height,reason)
     VALUES($1,$2,$3,$4,$5,$6)
     ON CONFLICT(uid) DO UPDATE SET relative_path=EXCLUDED.relative_path,captured_at=EXCLUDED.captured_at,
      width=EXCLUDED.width,height=EXCLUDED.height,reason=EXCLUDED.reason,updated_at=now()`,
    [uid, relative, capturedAt, width, height, reason],
  );
  if (["WARN", "ERROR"].includes(level)) {
    const diagnosticName = `${capturedAt.toISOString().replace(/[:.]/g, "-")}_${level}.jpg`;
    const diagnostic = assertChildPath(config.snapshotRoot, path.join(directory, diagnosticName));
    await fsp.copyFile(latest, diagnostic);
    await query(
      "INSERT INTO diagnostic_snapshots(uid,relative_path,captured_at,level,reason) VALUES($1,$2,$3,$4,$5)",
      [uid, path.relative(config.snapshotRoot, diagnostic).split(path.sep).join("/"), capturedAt, level, reason],
    );
  }
  eventHub.emit("snapshot", { uid, capturedAt: capturedAt.toISOString() });
}

async function serveSnapshot(res, uid) {
  const result = await query("SELECT * FROM snapshots WHERE uid=$1", [uid]);
  if (!result.rowCount) throw new HttpError(404, "尚無快照", "SNAPSHOT_NOT_FOUND");
  const filePath = assertChildPath(config.snapshotRoot, path.join(config.snapshotRoot, result.rows[0].relative_path));
  let data;
  try {
    data = await fsp.readFile(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") throw new HttpError(404, "快照正在更新，請稍後重試", "SNAPSHOT_NOT_FOUND");
    throw error;
  }
  res.writeHead(200, {
    "Content-Type": "image/jpeg", "Content-Length": data.length,
    "Cache-Control": "private, no-store", "X-Captured-At": result.rows[0].captured_at.toISOString(),
  });
  res.end(data);
}

async function listDevices() {
  const result = await query(
    `SELECT d.*,
      (d.last_seen IS NOT NULL AND d.last_seen > now()-interval '5 minutes') AS online,
      c.nonce AS pending_nonce,c.command AS pending_command,c.created_at AS pending_created_at,
      (SELECT row_to_json(x) FROM (
        SELECT nonce,command,status,ack_result,ack_detail,created_at,acked_at FROM commands h
        WHERE h.uid=d.uid ORDER BY created_at DESC LIMIT 1
      ) x) AS last_command
     FROM devices d LEFT JOIN commands c ON c.uid=d.uid AND c.status='PENDING'
     ORDER BY d.display_name,d.uid`,
  );
  return result.rows;
}

async function deviceDetails(uid) {
  const [device, events, commands, settings] = await Promise.all([
    query(
      `SELECT d.*,(d.last_seen>now()-interval '5 minutes') AS online,
        c.nonce AS pending_nonce,c.command AS pending_command,c.created_at AS pending_created_at,
        (SELECT row_to_json(x) FROM (
          SELECT nonce,command,status,ack_result,ack_detail,created_at,acked_at FROM commands h
          WHERE h.uid=d.uid ORDER BY created_at DESC LIMIT 1
        ) x) AS last_command
       FROM devices d LEFT JOIN commands c ON c.uid=d.uid AND c.status='PENDING'
       WHERE d.uid=$1`,
      [uid],
    ),
    query("SELECT event_at,level,name,detail FROM runtime_events WHERE uid=$1 ORDER BY event_at DESC LIMIT 50", [uid]),
    query("SELECT nonce,command,payload,status,created_at,acked_at,ack_result,ack_detail,ack_payload FROM commands WHERE uid=$1 ORDER BY created_at DESC LIMIT 30", [uid]),
    query("SELECT revision,settings,status,created_at,acked_at,ack_result,ack_detail FROM settings_revisions WHERE uid=$1 ORDER BY revision DESC LIMIT 1", [uid]),
  ]);
  if (!device.rowCount) throw new HttpError(404, "找不到裝置", "DEVICE_NOT_FOUND");
  return { device: device.rows[0], events: events.rows, commands: commands.rows, settings: settings.rows[0] ?? null };
}

async function createLiveLease(uid, browserSession) {
  const expiresAt = new Date(Date.now() + config.liveLeaseSeconds * 1000);
  const device = await query("SELECT uid,last_seen FROM devices WHERE uid=$1", [uid]);
  if (!device.rowCount) throw new HttpError(404, "找不到裝置", "DEVICE_NOT_FOUND");
  await query(
    `INSERT INTO live_leases(uid,browser_session_id,expires_at) VALUES($1,$2,$3)
     ON CONFLICT(uid,browser_session_id) DO UPDATE SET expires_at=EXCLUDED.expires_at,updated_at=now()`,
    [uid, browserSession.id, expiresAt],
  );
  liveLeaseTouches.set(`${uid}:${browserSession.id}`, Date.now());
  eventHub.emit("live", { uid, active: true, expiresAt });
  return { uid, active: true, expiresAt, playlistUrl: `/live/${encodeURIComponent(uid)}/index.m3u8` };
}

async function touchLiveLease(uid, browserSessionId) {
  const key = `${uid}:${browserSessionId}`;
  const now = Date.now();
  if (now - (liveLeaseTouches.get(key) ?? 0) < 20_000) return;
  const expiresAt = new Date(now + config.liveLeaseSeconds * 1000);
  const result = await query(
    `UPDATE live_leases SET expires_at=GREATEST(expires_at,$3),updated_at=now()
     WHERE uid=$1 AND browser_session_id=$2 AND expires_at>now() RETURNING expires_at`,
    [uid, browserSessionId, expiresAt],
  );
  if (!result.rowCount) {
    liveLeaseTouches.delete(key);
    throw new HttpError(410, "即時畫面觀看已到期，請重新按下開啟", "LIVE_LEASE_EXPIRED");
  }
  liveLeaseTouches.set(key, now);
}

function rememberHlsCookies(headers, jar) {
  const values = typeof headers.getSetCookie === "function"
    ? headers.getSetCookie() : [headers.get("set-cookie")];
  for (const value of values) {
    const match = /^([^=;\s]+)=([^;]*)/.exec(String(value ?? ""));
    if (match) jar.set(match[1], match[2]);
  }
}

function hlsCookieHeader(jar) {
  return [...jar].map(([name, value]) => `${name}=${value}`).join("; ");
}

async function fetchHlsWithCookies(upstreamUrl, rangeHeader, jar, signal) {
  const headers = {};
  if (rangeHeader) headers.Range = rangeHeader;
  if (jar.size) headers.Cookie = hlsCookieHeader(jar);
  let upstream = await fetch(upstreamUrl, { headers, redirect: "manual", signal });
  rememberHlsCookies(upstream.headers, jar);
  const location = upstream.headers.get("location");
  if (upstream.status >= 300 && upstream.status < 400 && location) {
    const redirectedUrl = new URL(location, upstreamUrl);
    if (redirectedUrl.origin !== upstreamUrl.origin) {
      await upstream.body?.cancel().catch(() => {});
      throw new HttpError(502, "直播服務回傳不安全的重新導向", "LIVE_UPSTREAM_REDIRECT");
    }
    await upstream.body?.cancel().catch(() => {});
    if (jar.size) headers.Cookie = hlsCookieHeader(jar);
    upstream = await fetch(redirectedUrl, { headers, redirect: "manual", signal });
    rememberHlsCookies(upstream.headers, jar);
  }
  return upstream;
}

async function fetchHlsUpstream(upstreamUrl, rangeHeader, sessionKey) {
  let session = liveHlsSessions.get(sessionKey);
  if (!session) {
    session = { cookies: new Map(), touchedAt: Date.now() };
    liveHlsSessions.set(sessionKey, session);
  }
  const signal = AbortSignal.timeout(15_000);
  let hadHlsSession = session.cookies.has("hlsSession");
  let upstream = await fetchHlsWithCookies(upstreamUrl, rangeHeader, session.cookies, signal);
  if (upstream.status === 401 && hadHlsSession) {
    await upstream.body?.cancel().catch(() => {});
    session.cookies.clear();
    upstream = await fetchHlsWithCookies(upstreamUrl, rangeHeader, session.cookies, signal);
  }
  session.touchedAt = Date.now();
  return upstream;
}

async function proxyHls(req, res, uid, suffix, searchParams, browserSessionId) {
  await touchLiveLease(uid, browserSessionId);
  const safeSuffix = suffix.split("/").filter((part) => part && part !== "." && part !== "..").map(encodeURIComponent).join("/");
  const upstreamUrl = new URL(`http://mediamtx:8888/${encodeURIComponent(uid)}/${safeSuffix}`);
  for (const [name, value] of searchParams) {
    if (name !== "t") upstreamUrl.searchParams.append(name, value);
  }
  const upstream = await fetchHlsUpstream(upstreamUrl, req.headers.range, `${uid}:${browserSessionId}`);
  if (!upstream.ok || !upstream.body) throw new HttpError(upstream.status === 404 ? 404 : 502, "直播畫面尚未就緒", "LIVE_NOT_READY");
  const headers = {
    "Content-Type": upstream.headers.get("content-type") ?? "application/octet-stream",
    "Cache-Control": "private, no-store",
  };
  const length = upstream.headers.get("content-length");
  if (length) headers["Content-Length"] = length;
  for (const name of ["content-range", "accept-ranges"]) {
    const value = upstream.headers.get(name);
    if (value) headers[name] = value;
  }
  res.writeHead(upstream.status, headers);
  await pipeline(Readable.fromWeb(upstream.body), res);
}

async function mediaAuthorization(body) {
  const action = String(body.action ?? "");
  // HLS 只由未公開的 8888 埠經 API Cookie 代理讀取。公開的 UDP 8890
  // 不提供 SRT 拉流，避免知道 UID 的外部使用者繞過網站授權。
  if (action === "read") return String(body.protocol ?? "") === "hls";
  if (action === "playback") return false;
  if (action !== "publish" || String(body.protocol ?? "") !== "srt") return false;
  const uid = String(body.path ?? "");
  if (!/^[A-Za-z0-9._@-]{3,160}$/.test(uid)) return false;
  const supplied = String(body.password ?? body.token ?? "");
  const expected = hmac(config.liveSecret, `publish:${uid}`);
  if (!timingSafeTextEqual(supplied, expected)) return false;
  const lease = await query("SELECT 1 FROM live_leases WHERE uid=$1 AND expires_at>now() LIMIT 1", [uid]);
  return Boolean(lease.rowCount);
}

async function serveStatic(res, pathname) {
  const item = staticFiles.get(pathname);
  if (!item) return false;
  const [relative, contentType] = item;
  const root = relative.startsWith("../node_modules") ? path.dirname(config.staticRoot) : config.staticRoot;
  const filePath = assertChildPath(root, path.resolve(config.staticRoot, relative));
  const data = await fsp.readFile(filePath);
  res.writeHead(200, {
    "Content-Type": contentType, "Content-Length": data.length,
    "Cache-Control": pathname === "/vendor/hls.min.js" ? "public, max-age=86400" : "no-cache",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(data);
  return true;
}

async function handleRequest(req, res) {
  const url = new URL(req.url, config.publicUrl);
  const pathname = url.pathname;
  if (req.method === "GET" && staticFiles.has(pathname)) {
    await serveStatic(res, pathname);
    return;
  }
  if (pathname === "/health/live" && req.method === "GET") {
    sendJson(res, 200, { ok: true, uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000) });
    return;
  }
  if (pathname === "/health/ready" && req.method === "GET") {
    const db = await query("SELECT now() AS now");
    sendJson(res, 200, { ok: true, database: true, at: db.rows[0].now });
    return;
  }
  if (pathname === "/internal/media-auth" && req.method === "POST") {
    const body = await readJson(req, 64 * 1024);
    if (await mediaAuthorization(body)) sendEmpty(res, 200);
    else sendJson(res, 401, { error: "media unauthorized" });
    return;
  }
  if (pathname === "/api/v1/device/enroll" && req.method === "POST") {
    const ip = clientIp(req);
    if (!limiter.check(`enroll:${ip}`, 60, 10 * 60_000)) throw new HttpError(429, "裝置註冊嘗試過多", "RATE_LIMITED");
    const body = await readJson(req, config.maxJsonBytes);
    sendJson(res, 200, await enrollDevice(body));
    return;
  }

  const deviceIdentity = pathname.startsWith("/api/v1/device/") ? await requireDevice(req) : null;
  if (deviceIdentity) {
    const uid = deviceIdentity.uid;
    if (pathname === "/api/v1/device/control" && req.method === "GET") {
      sendJson(res, 200, await deviceControl(uid, url.searchParams.get("format") === "firestore"));
      return;
    }
    if (pathname === "/api/v1/device/heartbeat" && req.method === "PUT") {
      const body = await readJson(req, config.maxJsonBytes);
      await updateHeartbeat(uid, body);
      sendJson(res, 200, await deviceControl(uid, true));
      return;
    }
    if (pathname === "/api/v1/device/recording/status" && req.method === "PUT") {
      sendJson(res, 200, await updateRecordingWorkerStatus(uid, await readJson(req, config.maxJsonBytes)));
      return;
    }
    if (pathname === "/api/v1/device/commands/ack" && req.method === "POST") {
      sendJson(res, 200, await ackCommand(uid, await readJson(req, config.maxJsonBytes)));
      return;
    }
    if (pathname === "/api/v1/device/settings/ack" && req.method === "POST") {
      sendJson(res, 200, await ackSettings(uid, await readJson(req, config.maxJsonBytes)));
      return;
    }
    if (pathname === "/api/v1/device/snapshot" && req.method === "PUT") {
      await saveSnapshot(uid, req, url);
      sendEmpty(res);
      return;
    }
    if (pathname === "/api/v1/device/recordings/sessions" && req.method === "POST") {
      sendJson(res, 200, await upsertRecordingSession(uid, await readJson(req, config.maxJsonBytes)));
      return;
    }
    let params = routeMatch(pathname, "/api/v1/device/recordings/sessions/:sessionId/segments");
    if (params && req.method === "POST") {
      sendJson(res, 200, await registerSegment(uid, params.sessionId, await readJson(req, config.maxJsonBytes)));
      return;
    }
    params = routeMatch(pathname, "/api/v1/device/recordings/segments/:segmentId");
    if (params && req.method === "GET") {
      sendJson(res, 200, await getSegmentUploadState(uid, params.segmentId));
      return;
    }
    if (params && req.method === "PUT") {
      sendJson(res, 200, await receiveSegmentChunk(uid, params.segmentId, req.headers["content-range"], req));
      return;
    }
    params = routeMatch(pathname, "/api/v1/device/recordings/segments/:segmentId/retry");
    if (params && req.method === "POST") {
      sendJson(res, 200, await retrySegment(uid, params.segmentId));
      return;
    }
    params = routeMatch(pathname, "/api/v1/device/recordings/sessions/:sessionId/complete");
    if (params && req.method === "POST") {
      const state = await requestSessionFinalize(uid, params.sessionId, await readJson(req, config.maxJsonBytes));
      sendJson(res, state.state === "COMPLETE" ? 200 : 202, state);
      return;
    }
    params = routeMatch(pathname, "/api/v1/device/recordings/sessions/:sessionId");
    if (params && req.method === "GET") {
      sendJson(res, 200, await recordingSessionState(uid, params.sessionId));
      return;
    }
    throw new HttpError(404, "找不到裝置 API", "NOT_FOUND");
  }

  const browserAccess = await ensureBrowser(req);
  const browser = browserAccess.session;
  if (browserAccess.token) res.setHeader("Set-Cookie", browserCookie(browserAccess.token, browser.expires_at));
  if (!["GET", "HEAD"].includes(req.method)) requireSameOrigin(req);
  if (pathname === "/api/v1/auth/me" && req.method === "GET") {
    sendJson(res, 200, { session: browser, publicUrl: config.publicUrl, accessMode: "direct" });
    return;
  }
  let params;
  if (pathname === "/api/v1/events" && req.method === "GET") {
    res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive", "X-Accel-Buffering": "no" });
    res.write(`event: ready\ndata: ${JSON.stringify({ at: Date.now() })}\n\n`);
    const remove = eventHub.add(res);
    req.once("close", remove);
    return;
  }
  if (pathname === "/api/v1/devices" && req.method === "GET") {
    sendJson(res, 200, { devices: await listDevices(), migration: await getMigrationState() });
    return;
  }
  params = routeMatch(pathname, "/api/v1/devices/:uid");
  if (params && req.method === "GET") {
    sendJson(res, 200, await deviceDetails(normalizeUid(params.uid)));
    return;
  }
  params = routeMatch(pathname, "/api/v1/devices/:uid/commands");
  if (params && req.method === "POST") {
    const row = await sendCommand(normalizeUid(params.uid), await readJson(req, config.maxJsonBytes));
    eventHub.emit("command", { uid: params.uid, nonce: Number(row.nonce), status: row.status, at: Date.now() });
    sendJson(res, 201, row);
    return;
  }
  params = routeMatch(pathname, "/api/v1/devices/:uid/settings");
  if (params && req.method === "PUT") {
    sendJson(res, 201, await saveSettings(normalizeUid(params.uid), await readJson(req, config.maxJsonBytes)));
    return;
  }
  params = routeMatch(pathname, "/api/v1/devices/:uid/snapshot");
  if (params && req.method === "GET") {
    await serveSnapshot(res, normalizeUid(params.uid));
    return;
  }
  params = routeMatch(pathname, "/api/v1/devices/:uid/recordings");
  if (params && req.method === "GET") {
    sendJson(res, 200, { recordings: await listRecordings(normalizeUid(params.uid)) });
    return;
  }
  params = routeMatch(pathname, "/api/v1/devices/:uid/recordings/:sessionId/segments");
  if (params && req.method === "GET") {
    sendJson(res, 200, { segments: await listRecordingSegments(normalizeUid(params.uid), params.sessionId) });
    return;
  }
  params = routeMatch(pathname, "/api/v1/devices/:uid/recordings/:sessionId/video");
  if (params && ["GET", "HEAD"].includes(req.method)) {
    await streamVideo(req, res, await resolvePlayable(normalizeUid(params.uid), params.sessionId));
    return;
  }
  params = routeMatch(pathname, "/api/v1/devices/:uid/recordings/:sessionId/segments/:segmentId/video");
  if (params && ["GET", "HEAD"].includes(req.method)) {
    await streamVideo(req, res, await resolvePlayable(normalizeUid(params.uid), params.sessionId, params.segmentId));
    return;
  }
  params = routeMatch(pathname, "/api/v1/live/:uid/lease");
  if (params && req.method === "POST") {
    sendJson(res, 200, await createLiveLease(normalizeUid(params.uid), browser));
    return;
  }
  if (params && req.method === "DELETE") {
    const uid = normalizeUid(params.uid);
    await query("DELETE FROM live_leases WHERE uid=$1 AND browser_session_id=$2", [uid, browser.id]);
    liveLeaseTouches.delete(`${uid}:${browser.id}`);
    liveHlsSessions.delete(`${uid}:${browser.id}`);
    eventHub.emit("live", { uid: params.uid, active: false, at: Date.now() });
    sendEmpty(res);
    return;
  }
  const liveMatch = /^\/live\/([^/]+)\/(.+)$/.exec(pathname);
  if (liveMatch && req.method === "GET") {
    await proxyHls(req, res, normalizeUid(decodeURIComponent(liveMatch[1])), liveMatch[2], url.searchParams, browser.id);
    return;
  }
  if (pathname === "/api/v1/admin/migration" && req.method === "GET") {
    sendJson(res, 200, await migrationReadiness());
    return;
  }
  if (pathname === "/api/v1/admin/migration/cutover" && req.method === "POST") {
    sendJson(res, 200, await cutoverToPrimary());
    return;
  }
  if (pathname === "/api/v1/admin/migration/mode" && req.method === "PUT") {
    sendJson(res, 200, await forceMigrationMode(String((await readJson(req, config.maxJsonBytes)).mode ?? "")));
    return;
  }
  if (pathname === "/api/v1/admin/alerts" && req.method === "GET") {
    const alerts = await query("SELECT * FROM server_alerts WHERE cleared_at IS NULL ORDER BY created_at DESC LIMIT 100");
    sendJson(res, 200, { alerts: alerts.rows });
    return;
  }
  throw new HttpError(404, "找不到資源", "NOT_FOUND");
}

async function cleanupRuntimeData() {
  await query("DELETE FROM live_leases WHERE expires_at<now()");
  await query("DELETE FROM browser_sessions WHERE expires_at<now() OR revoked_at<now()-interval '30 days'");
  await query("DELETE FROM activation_tokens WHERE expires_at<now() OR used_at<now()-interval '7 days'");
  await query("DELETE FROM runtime_events WHERE event_at<now()-interval '30 days'");
  await query("DELETE FROM commands WHERE created_at<now()-interval '90 days' AND status<>'PENDING'");
  await query("DELETE FROM server_alerts WHERE created_at<now()-interval '90 days'");
  const oldSnapshots = await query("DELETE FROM snapshots s USING devices d WHERE s.uid=d.uid AND d.last_seen<now()-interval '7 days' RETURNING s.relative_path");
  for (const row of oldSnapshots.rows) {
    try { await fsp.rm(assertChildPath(config.snapshotRoot, path.join(config.snapshotRoot, row.relative_path)), { force: true }); } catch {}
  }
  const offlineDiagnostics = await query(
    `DELETE FROM diagnostic_snapshots ds USING devices d
     WHERE ds.uid=d.uid AND d.last_seen<now()-interval '7 days' RETURNING ds.relative_path`,
  );
  for (const row of offlineDiagnostics.rows) {
    try { await fsp.rm(assertChildPath(config.snapshotRoot, path.join(config.snapshotRoot, row.relative_path)), { force: true }); } catch {}
  }
  const excess = await query(
    `SELECT id,relative_path FROM (
      SELECT id,relative_path,row_number() OVER(PARTITION BY uid ORDER BY captured_at DESC) AS n
      FROM diagnostic_snapshots
    ) x WHERE n>30`,
  );
  for (const row of excess.rows) {
    try { await fsp.rm(assertChildPath(config.snapshotRoot, path.join(config.snapshotRoot, row.relative_path)), { force: true }); } catch {}
    await query("DELETE FROM diagnostic_snapshots WHERE id=$1", [row.id]);
  }
  await query("UPDATE devices SET state='OFFLINE',status='{}'::jsonb,updated_at=now() WHERE last_seen<now()-interval '7 days'");
  const staleTouchBefore = Date.now() - config.liveLeaseSeconds * 2_000;
  for (const [key, touchedAt] of liveLeaseTouches) {
    if (touchedAt < staleTouchBefore) liveLeaseTouches.delete(key);
  }
  for (const [key, session] of liveHlsSessions) {
    if (session.touchedAt < staleTouchBefore) liveHlsSessions.delete(key);
  }
  await pruneMedia();
}

async function start() {
  await ensureMediaRoots();
  installFileLogger(config.serverLogRoot, { keep: 15 });
  await migrate();
  await resumeMediaJobs();
  if (config.firestore.enabled) {
    importFirestoreDevices().catch((error) => console.error("Firestore import failed", error));
  }
  const server = http.createServer((req, res) => {
    handleRequest(req, res).catch((error) => {
      if (res.headersSent) {
        res.destroy(error);
        return;
      }
      const status = error instanceof HttpError ? error.status : 500;
      if (status >= 500) console.error(error);
      sendJson(res, status, {
        error: { code: error.code ?? "INTERNAL_ERROR", message: status >= 500 ? "伺服器內部錯誤" : error.message, details: error.details },
      });
    });
  });
  server.headersTimeout = 65_000;
  server.requestTimeout = 0;
  server.listen(config.port, "0.0.0.0", () => console.log(`Wuthering control API listening on :${config.port}`));
  const heartbeatTimer = setInterval(() => eventHub.heartbeat(), 20_000);
  const cleanupTimer = setInterval(() => cleanupRuntimeData().catch(console.error), 60 * 60_000);
  const discoveryTimer = setInterval(() => {
    const work = config.firestore.enabled ? importFirestoreDevices() : publishDiscovery();
    work.catch(console.error);
  }, 15 * 60_000);
  const rateTimer = setInterval(() => limiter.prune(), 10 * 60_000);
  cleanupRuntimeData().catch(console.error);

  const shutdown = async (signal) => {
    console.log(`Received ${signal}, shutting down`);
    clearInterval(heartbeatTimer); clearInterval(cleanupTimer); clearInterval(discoveryTimer); clearInterval(rateTimer);
    await new Promise((resolve) => server.close(resolve));
    await closeDatabase();
    process.exit(0);
  };
  process.once("SIGTERM", () => shutdown("SIGTERM"));
  process.once("SIGINT", () => shutdown("SIGINT"));
}

start().catch((error) => {
  console.error(error);
  process.exit(1);
});
