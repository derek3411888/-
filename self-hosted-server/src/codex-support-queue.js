import { timingSafeEqual } from "node:crypto";
import { config } from "./config.js";
import { query, withTransaction } from "./db.js";
import {
  CODEX_SUPPORT_COOLDOWN_MS,
  CODEX_SUPPORT_PENDING_STATES,
  buildDeviceSupportContext,
  resolveCodexSupportMessage,
} from "./codex-support.js";
import { HttpError, boundedText, integer, sha256 } from "./utils.js";

const RETRYABLE_TERMINAL_STATES = new Set(["REJECTED", "RATE_LIMITED", "FAILED", "CANCELLED"]);
const CANCELLABLE_STATES = new Set(["PENDING", "RECEIVED", "VALIDATING", "RETRYING"]);
const PENDING_RESPONSE_STATES = new Set(["WAITING", "IN_PROGRESS"]);
const TERMINAL_RESPONSE_STATES = new Set(["COMPLETED", "FAILED", "INTERRUPTED"]);
const BRIDGE_ONLINE_MS = 3 * 60_000;
export const CODEX_DISPATCH_LEASE_MS = 2 * 60_000;
const CODEX_DISPATCHER_ID_PATTERN = /^[A-Za-z0-9._:@-]{8,160}$/;

const LEGAL_DISPATCH_TRANSITIONS = Object.freeze({
  PENDING: new Set(["PENDING", "RECEIVED", "REJECTED", "RATE_LIMITED", "FAILED"]),
  RECEIVED: new Set(["RECEIVED", "VALIDATING", "QUEUEING", "RETRYING", "QUEUED", "REJECTED", "RATE_LIMITED", "FAILED"]),
  VALIDATING: new Set(["VALIDATING", "QUEUEING", "RETRYING", "QUEUED", "REJECTED", "RATE_LIMITED", "FAILED"]),
  QUEUEING: new Set(["QUEUEING", "RETRYING", "QUEUED", "RATE_LIMITED", "FAILED"]),
  RETRYING: new Set(["RETRYING", "RECEIVED", "QUEUEING", "QUEUED", "RATE_LIMITED", "FAILED"]),
  QUEUED: new Set(["QUEUED"]),
  REJECTED: new Set(["REJECTED"]),
  RATE_LIMITED: new Set(["RATE_LIMITED"]),
  FAILED: new Set(["FAILED"]),
  CANCELLED: new Set(["CANCELLED"]),
});

export function isDirectCodexTransitionAllowed(fromState, toState) {
  const from = String(fromState ?? "").trim().toUpperCase();
  const to = String(toState ?? "").trim().toUpperCase();
  return Boolean(LEGAL_DISPATCH_TRANSITIONS[from]?.has(to));
}

export function isDispatchResultUnknown(row = {}) {
  return String(row.error_code ?? row.errorCode ?? "").trim().toUpperCase() === "DISPATCH_RESULT_UNKNOWN";
}

export function normalizeCodexDispatcherId(value) {
  const dispatcherId = String(value ?? "").trim();
  if (!CODEX_DISPATCHER_ID_PATTERN.test(dispatcherId)) {
    throw new HttpError(400, "Codex 傳送器識別碼格式無效", "CODEX_DISPATCHER_ID_INVALID");
  }
  return dispatcherId;
}

export function matchesDirectCodexClaim(row = {}, claimGeneration = 0, dispatcherId = "") {
  return Number(row.claim_generation) === Number(claimGeneration)
    && String(row.claimed_by || "") === String(dispatcherId || "");
}

function milliseconds(value) {
  if (!value) return 0;
  const number = value instanceof Date ? value.valueOf() : new Date(value).valueOf();
  return Number.isFinite(number) ? number : 0;
}

export function resolveCodexDispatcherPresence(row = null, dispatcher = {}, now = Date.now()) {
  const dispatcherHeartbeatAt = milliseconds(dispatcher.heartbeatAt);
  const rowHeartbeatAt = milliseconds(row?.bridge_heartbeat_at);
  const heartbeatAt = Math.max(dispatcherHeartbeatAt, rowHeartbeatAt);
  const rowIsNewest = rowHeartbeatAt > dispatcherHeartbeatAt;
  return {
    heartbeatAt,
    host: String(rowIsNewest ? (row?.bridge_host || dispatcher.host || "") : (dispatcher.host || row?.bridge_host || "")),
    version: String(rowIsNewest ? (row?.bridge_version || dispatcher.version || "") : (dispatcher.version || row?.bridge_version || "")),
    online: heartbeatAt > 0 && now - heartbeatAt < BRIDGE_ONLINE_MS,
  };
}

function statusFromRow(row = null, dispatcher = {}) {
  const presence = resolveCodexDispatcherPresence(row, dispatcher);
  if (!row) {
    return {
      requestNonce: 0, statusNonce: 0, state: dispatcher.state || "READY", detail: dispatcher.detail || "中央 Codex 傳送器待命",
      requestedAt: 0, requestedDeviceUid: "", requestMode: "", requestLabel: "", requestMessage: "",
      contextIncluded: false, contextLength: 0, logAvailable: false, logFileName: "",
      host: presence.host, heartbeatAt: presence.heartbeatAt, receivedAt: 0, validatedAt: 0, attemptCount: 0,
      lastAttemptAt: 0, nextRetryAt: 0, queuedAt: 0, messageSha256: "", errorCode: "", errorDetail: "",
      bridgeVersion: presence.version, online: presence.online,
      pending: false, responsePending: false, responseState: "NONE", responseText: "", responseAt: 0,
      responseSha256: "", codexTurnId: "", codexTurnStatus: "", replyCheckedAt: 0, replyError: "",
      cooldownRemainingMs: 0, transport: "selfhost",
    };
  }
  const queuedAt = milliseconds(row.queued_at);
  const dispatchPending = CODEX_SUPPORT_PENDING_STATES.includes(String(row.state));
  const responseState = String(row.state) === "QUEUED" ? String(row.response_state || "WAITING") : "NONE";
  const responsePending = String(row.state) === "QUEUED" && PENDING_RESPONSE_STATES.has(responseState);
  return {
    requestNonce: Number(row.id), statusNonce: Number(row.id), state: String(row.state), detail: String(row.detail || ""),
    requestedAt: milliseconds(row.created_at), requestedDeviceUid: String(row.device_uid || ""),
    requestMode: String(row.mode || ""), requestLabel: String(row.label || ""), requestMessage: String(row.message || ""),
    contextIncluded: Boolean(row.context_included), contextLength: Number(row.context_length) || 0,
    logAvailable: Boolean(row.log_available), logFileName: String(row.log_file_name || ""),
    host: presence.host, heartbeatAt: presence.heartbeatAt,
    receivedAt: milliseconds(row.received_at), validatedAt: milliseconds(row.validated_at),
    attemptCount: Number(row.attempt_count) || 0, lastAttemptAt: milliseconds(row.last_attempt_at),
    nextRetryAt: milliseconds(row.next_retry_at), queuedAt, messageSha256: String(row.message_sha256 || ""),
    errorCode: String(row.error_code || ""), errorDetail: String(row.error_detail || ""),
    bridgeVersion: presence.version,
    online: presence.online,
    pending: dispatchPending || responsePending, responsePending, responseState,
    responseText: String(row.codex_response || ""), responseAt: milliseconds(row.codex_response_at),
    responseSha256: String(row.codex_response_sha256 || ""), codexTurnId: String(row.codex_turn_id || ""),
    codexTurnStatus: String(row.codex_turn_status || ""), replyCheckedAt: milliseconds(row.codex_reply_checked_at),
    replyError: String(row.codex_reply_error || ""),
    cooldownRemainingMs: queuedAt ? Math.max(0, queuedAt + CODEX_SUPPORT_COOLDOWN_MS - Date.now()) : 0,
    transport: "selfhost",
  };
}

async function dispatcherStatus(client = null) {
  const executor = client ?? { query };
  const result = await executor.query("SELECT value FROM system_settings WHERE key='codex_dispatcher_status'");
  return result.rows[0]?.value ?? {};
}

async function latestRequest(client = null, lock = false) {
  const executor = client ?? { query };
  const result = await executor.query(
    `SELECT * FROM codex_support_requests ORDER BY id DESC LIMIT 1${lock ? " FOR UPDATE" : ""}`,
  );
  return result.rows[0] ?? null;
}

async function diagnosticDetails(uid) {
  if (!uid) return null;
  const [device, events] = await Promise.all([
    query(`SELECT d.*,(d.state NOT IN ('STOP','OFFLINE') AND d.last_seen>now()-interval '5 minutes') AS online
      FROM devices d WHERE d.uid=$1`, [uid]),
    query("SELECT event_at,level,name,detail FROM runtime_events WHERE uid=$1 ORDER BY event_at DESC LIMIT 50", [uid]),
  ]);
  if (!device.rowCount) throw new HttpError(404, "找不到要附加 Log 的裝置", "DEVICE_NOT_FOUND");
  return { device: device.rows[0], events: events.rows };
}

export function assertCodexDispatcher(req) {
  const supplied = String(req.headers["x-wuthering-codex-bridge"] ?? "");
  const expected = String(config.codexBridgeToken ?? "");
  const a = Buffer.from(supplied);
  const b = Buffer.from(expected);
  if (!expected || a.length !== b.length || !timingSafeEqual(a, b)) {
    throw new HttpError(401, "中央 Codex 傳送器憑證無效", "CODEX_DISPATCHER_UNAUTHORIZED");
  }
  return normalizeCodexDispatcherId(req.headers["x-wuthering-codex-dispatcher-id"]);
}

export async function getDirectCodexSupportStatus() {
  const [row, dispatcher] = await Promise.all([latestRequest(), dispatcherStatus()]);
  return statusFromRow(row, dispatcher);
}

export async function submitDirectCodexSupport(input = {}) {
  const selection = resolveCodexSupportMessage(input);
  const uid = String(input.deviceUid ?? "").trim();
  const includeLog = input.includeDeviceLog !== false && Boolean(uid);
  const context = uid
    ? buildDeviceSupportContext(await diagnosticDetails(uid), { includeLog })
    : { text: "", logAvailable: false, logFileName: "" };
  return withTransaction(async (client) => {
    await client.query("SELECT pg_advisory_xact_lock(1647329011)");
    const current = await latestRequest(client, true);
    if (current && (CODEX_SUPPORT_PENDING_STATES.includes(String(current.state))
        || (String(current.state) === "QUEUED" && PENDING_RESPONSE_STATES.has(String(current.response_state || "WAITING"))))) {
      throw new HttpError(409, "上一筆維修請求仍在處理或等待 Codex 回覆", "CODEX_SUPPORT_PENDING", statusFromRow(current));
    }
    const recent = await client.query(
      "SELECT queued_at FROM codex_support_requests WHERE queued_at IS NOT NULL ORDER BY queued_at DESC LIMIT 1",
    );
    const queuedAt = milliseconds(recent.rows[0]?.queued_at);
    if (queuedAt && Date.now() - queuedAt < CODEX_SUPPORT_COOLDOWN_MS) {
      throw new HttpError(429, "剛剛已送進 Codex，請等候處理結果", "CODEX_SUPPORT_COOLDOWN", {
        cooldownRemainingMs: CODEX_SUPPORT_COOLDOWN_MS - (Date.now() - queuedAt),
      });
    }
    const inserted = await client.query(
      `INSERT INTO codex_support_requests(mode,label,message,message_length,device_uid,context,context_length,
        context_included,log_available,log_file_name,state,detail)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'PENDING','已寫入中央主機佇列，等待 Codex 傳送器接收') RETURNING *`,
      [selection.mode, selection.label, selection.message, selection.message.length, uid || null,
        context.text, context.text.length, Boolean(context.text), context.logAvailable, context.logFileName],
    );
    return { ...statusFromRow(inserted.rows[0]), submitted: true };
  });
}

export async function cancelDirectCodexSupport() {
  return withTransaction(async (client) => {
    await client.query("SELECT pg_advisory_xact_lock(1647329011)");
    const current = await latestRequest(client, true);
    if (!current) throw new HttpError(404, "目前沒有可取消的請求", "CODEX_SUPPORT_NOT_FOUND");
    if (!CANCELLABLE_STATES.has(String(current.state)) || Number(current.attempt_count) > 0) {
      throw new HttpError(409, "這筆請求已開始送往 Codex，不能安全取消", "CODEX_SUPPORT_NOT_CANCELLABLE", statusFromRow(current));
    }
    const updated = await client.query(
      `UPDATE codex_support_requests SET state='CANCELLED',detail='已由網站取消；未送入 Codex',cancelled_at=now(),
       error_code='',error_detail='',claim_expires_at=NULL,updated_at=now()
       WHERE id=$1 AND state=$2 AND attempt_count=0 RETURNING *`, [current.id, current.state],
    );
    if (!updated.rowCount) {
      throw new HttpError(409, "請求狀態已改變，請重新整理後再取消", "CODEX_SUPPORT_STATE_CHANGED");
    }
    return statusFromRow(updated.rows[0]);
  });
}

export async function retryDirectCodexSupport() {
  return withTransaction(async (client) => {
    await client.query("SELECT pg_advisory_xact_lock(1647329011)");
    const current = await latestRequest(client, true);
    if (!current) throw new HttpError(404, "目前沒有可重新送出的請求", "CODEX_SUPPORT_NOT_FOUND");
    // The CLI may already have accepted this message before the bridge died.
    // Treat UNKNOWN as terminal and require an explicitly new request instead
    // of cloning/replaying it through the direct retry endpoint.
    if (isDispatchResultUnknown(current)) {
      throw new HttpError(
        409,
        "上一筆傳送結果不明，可能已進入 Codex；為避免重複執行，禁止直接重送",
        "CODEX_SUPPORT_RESULT_UNKNOWN",
        statusFromRow(current),
      );
    }
    const stalled = CANCELLABLE_STATES.has(String(current.state)) && Number(current.attempt_count) === 0
      && Date.now() - milliseconds(current.created_at) >= BRIDGE_ONLINE_MS;
    if (!RETRYABLE_TERMINAL_STATES.has(String(current.state)) && !stalled) {
      throw new HttpError(409, "這筆請求仍可能正在處理，暫時不能重送", "CODEX_SUPPORT_NOT_RETRYABLE", statusFromRow(current));
    }
    if (stalled) {
      const cancelled = await client.query(
        `UPDATE codex_support_requests SET state='CANCELLED',detail='卡住超過 3 分鐘，已由重送動作取消',
         cancelled_at=now(),claim_expires_at=NULL,updated_at=now()
         WHERE id=$1 AND state=$2 AND attempt_count=0 RETURNING id`,
        [current.id, current.state],
      );
      if (!cancelled.rowCount) {
        throw new HttpError(409, "請求狀態已改變，請重新整理後再重送", "CODEX_SUPPORT_STATE_CHANGED");
      }
    }
    const inserted = await client.query(
      `INSERT INTO codex_support_requests(mode,label,message,message_length,device_uid,context,context_length,
        context_included,log_available,log_file_name,state,detail,retry_of_id)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'PENDING','已建立新的重送編號，等待中央 Codex 傳送器接收',$11) RETURNING *`,
      [current.mode, current.label, current.message, current.message_length, current.device_uid, current.context,
        current.context_length, current.context_included, current.log_available, current.log_file_name, current.id],
    );
    return { ...statusFromRow(inserted.rows[0]), submitted: true, retried: true };
  });
}

export async function dispatcherHeartbeat(input = {}, dispatcherIdValue = "") {
  const dispatcherId = normalizeCodexDispatcherId(dispatcherIdValue);
  if (input.dispatcherId && normalizeCodexDispatcherId(input.dispatcherId) !== dispatcherId) {
    throw new HttpError(409, "Heartbeat 傳送器識別碼不一致", "CODEX_DISPATCHER_ID_MISMATCH");
  }
  const value = {
    state: "READY", detail: "中央 Codex 傳送器待命", host: boundedText(input.host, 160),
    version: boundedText(input.version, 80), dispatcherId, heartbeatAt: Date.now(),
  };
  const updated = await query(
    `INSERT INTO system_settings(key,value) VALUES('codex_dispatcher_status',$1)
     ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value,updated_at=now()
     WHERE CASE
       WHEN (system_settings.value->>'heartbeatAt') ~ '^[0-9]+$'
         THEN (system_settings.value->>'heartbeatAt')::bigint
       ELSE 0
     END <= $2
     RETURNING value`, [value, value.heartbeatAt],
  );
  // A slower, older request must not overwrite a newer committed heartbeat.
  // PostgreSQL returns no row when the conflict WHERE condition rejected it.
  return updated.rows[0]?.value ?? dispatcherStatus();
}

export async function nextDispatcherRequest(dispatcherIdValue = "") {
  const dispatcherId = normalizeCodexDispatcherId(dispatcherIdValue);
  return withTransaction(async (client) => {
    // RECEIVED/VALIDATING/QUEUEING are never reclaimed just because the lease
    // timestamp elapsed. Once Codex may have been invoked, expiry is liveness
    // metadata only; only a known failed RETRYING attempt gets a new generation.
    const candidate = await client.query(
      `SELECT * FROM codex_support_requests
       WHERE (
         state='PENDING'
         OR (state='RETRYING' AND (next_retry_at IS NULL OR next_retry_at<=now()))
       )
       ORDER BY id
       FOR UPDATE SKIP LOCKED
       LIMIT 1`,
    );
    const row = candidate.rows[0];
    if (!row) return { request: null };

    const now = new Date();
    const leaseUntil = new Date(now.valueOf() + CODEX_DISPATCH_LEASE_MS);
    const claimed = await client.query(
      `UPDATE codex_support_requests SET
         state='RECEIVED',detail='中央 Codex 傳送器已原子領取，等待驗證訊息',
         received_at=COALESCE(received_at,$3),next_retry_at=NULL,
         claim_generation=claim_generation+1,claimed_by=$5,claimed_at=$3,claim_expires_at=$4,
         bridge_heartbeat_at=$3,updated_at=now()
       WHERE id=$1 AND state=$2
       RETURNING *`,
      [row.id, row.state, now, leaseUntil, dispatcherId],
    );
    if (!claimed.rowCount) return { request: null };
    const request = claimed.rows[0];
    return { request: {
      nonce: Number(request.id), mode: request.mode, label: request.label, message: request.message,
      context: request.context, contextIncluded: request.context_included, deviceUid: request.device_uid || "",
      attemptCount: Number(request.attempt_count) || 0, state: request.state,
      claimGeneration: Number(request.claim_generation) || 0,
      dispatcherId: String(request.claimed_by || ""),
    } };
  });
}

export async function listPendingCodexResponses(dispatcherIdValue = "") {
  normalizeCodexDispatcherId(dispatcherIdValue);
  const pending = await query(
    `SELECT id,message_sha256,queued_at,response_state,codex_turn_id,codex_turn_status,codex_reply_checked_at
     FROM codex_support_requests
     WHERE state='QUEUED' AND response_state IN ('WAITING','IN_PROGRESS')
     ORDER BY id DESC LIMIT 20`,
  );
  return {
    requests: pending.rows.map((row) => ({
      nonce: Number(row.id), messageSha256: String(row.message_sha256 || ""),
      queuedAt: milliseconds(row.queued_at), responseState: String(row.response_state || "WAITING"),
      codexTurnId: String(row.codex_turn_id || ""), codexTurnStatus: String(row.codex_turn_status || ""),
      replyCheckedAt: milliseconds(row.codex_reply_checked_at),
    })),
  };
}

export async function updateCodexResponse(nonceValue, body = {}, dispatcherIdValue = "") {
  const nonce = integer(nonceValue, 0, 1, Number.MAX_SAFE_INTEGER);
  normalizeCodexDispatcherId(dispatcherIdValue);
  const responseState = String(body.responseState ?? "").trim().toUpperCase();
  if (![...PENDING_RESPONSE_STATES, ...TERMINAL_RESPONSE_STATES].includes(responseState)) {
    throw new HttpError(400, "Codex 回覆狀態無效", "INVALID_CODEX_RESPONSE_STATE");
  }
  const messageSha256 = String(body.messageSha256 ?? "").trim().toLowerCase();
  const responseText = String(body.responseText ?? "").trim();
  const suppliedResponseSha256 = boundedText(body.responseSha256, 128).toLowerCase();
  const responseSha256 = responseText ? sha256(responseText) : "";
  if (suppliedResponseSha256 && suppliedResponseSha256 !== responseSha256) {
    throw new HttpError(409, "Codex 回覆指紋不一致", "CODEX_RESPONSE_HASH_MISMATCH");
  }
  if (responseText.length > 30_000) throw new HttpError(413, "Codex 回覆超過 30000 字元", "CODEX_RESPONSE_TOO_LONG");
  const turnId = boundedText(body.codexTurnId, 200);
  const turnStatus = boundedText(body.codexTurnStatus, 80);
  if (responseState === "COMPLETED" && (!turnId || !responseText)) {
    throw new HttpError(400, "完成狀態必須包含 Codex turn 與最終回覆", "CODEX_RESPONSE_INCOMPLETE");
  }
  return withTransaction(async (client) => {
    const selected = await client.query("SELECT * FROM codex_support_requests WHERE id=$1 FOR UPDATE", [nonce]);
    if (!selected.rowCount) throw new HttpError(404, "找不到 Codex 請求", "CODEX_SUPPORT_NOT_FOUND");
    const current = selected.rows[0];
    if (String(current.state) !== "QUEUED") {
      throw new HttpError(409, "這筆請求尚未送進 Codex", "CODEX_RESPONSE_NOT_QUEUED", statusFromRow(current));
    }
    if (!/^[a-f0-9]{64}$/.test(messageSha256) || messageSha256 !== String(current.message_sha256 || "").toLowerCase()) {
      throw new HttpError(409, "Codex 回覆與原始網站訊息不一致", "CODEX_RESPONSE_MESSAGE_MISMATCH");
    }
    const currentState = String(current.response_state || "WAITING");
    if (TERMINAL_RESPONSE_STATES.has(currentState)) {
      const sameTerminal = currentState === responseState
        && String(current.codex_turn_id || "") === turnId
        && String(current.codex_response || "") === responseText
        && String(current.codex_response_sha256 || "") === responseSha256;
      if (sameTerminal) return statusFromRow(current);
      throw new HttpError(409, "Codex 回覆已是最終狀態，不能覆蓋", "CODEX_RESPONSE_ALREADY_TERMINAL", statusFromRow(current));
    }
    const responseAt = TERMINAL_RESPONSE_STATES.has(responseState)
      ? new Date(Number(body.responseAt) > 0 ? Number(body.responseAt) : Date.now()) : null;
    const updated = await client.query(
      `UPDATE codex_support_requests SET response_state=$2,codex_turn_id=$3,codex_turn_status=$4,
         codex_response=$5,codex_response_sha256=$6,codex_response_at=COALESCE($7,codex_response_at),
         codex_reply_checked_at=now(),codex_reply_error=$8,updated_at=now()
       WHERE id=$1 RETURNING *`,
      [nonce, responseState, turnId, turnStatus, responseText, responseSha256, responseAt,
        boundedText(body.replyError, 500)],
    );
    return statusFromRow(updated.rows[0]);
  });
}

export async function updateDispatcherRequest(nonceValue, body = {}, dispatcherIdValue = "") {
  const nonce = integer(nonceValue, 0, 1, Number.MAX_SAFE_INTEGER);
  const dispatcherId = normalizeCodexDispatcherId(dispatcherIdValue);
  const echoedDispatcherId = normalizeCodexDispatcherId(body.dispatcherId);
  const rawClaimGeneration = String(body.claimGeneration ?? "").trim();
  const claimGeneration = Number(rawClaimGeneration);
  if (!/^[1-9][0-9]*$/.test(rawClaimGeneration)
      || !Number.isSafeInteger(claimGeneration)
      || claimGeneration > 2_147_483_647) {
    throw new HttpError(400, "Codex claim generation 缺失或無效", "CODEX_CLAIM_GENERATION_INVALID");
  }
  if (echoedDispatcherId !== dispatcherId) {
    throw new HttpError(409, "狀態回報的傳送器識別碼不一致", "CODEX_SUPPORT_STALE_CLAIM");
  }
  const state = String(body.state ?? "").trim().toUpperCase();
  const allowed = new Set(["RECEIVED", "VALIDATING", "QUEUEING", "RETRYING", "QUEUED", "REJECTED", "RATE_LIMITED", "FAILED"]);
  if (!allowed.has(state)) throw new HttpError(400, "Codex 傳送狀態無效", "INVALID_CODEX_DISPATCH_STATE");
  return withTransaction(async (client) => {
    const currentResult = await client.query(
      "SELECT * FROM codex_support_requests WHERE id=$1 FOR UPDATE",
      [nonce],
    );
    if (!currentResult.rowCount) throw new HttpError(404, "找不到 Codex 請求", "CODEX_SUPPORT_NOT_FOUND");
    const current = currentResult.rows[0];
    if (!matchesDirectCodexClaim(current, claimGeneration, dispatcherId)) {
      throw new HttpError(
        409,
        "這個狀態回報來自已失效的 Codex claim，已拒絕套用",
        "CODEX_SUPPORT_STALE_CLAIM",
        statusFromRow(current),
      );
    }
    if (!isDirectCodexTransitionAllowed(current.state, state)) {
      const code = current.state === "CANCELLED" ? "CODEX_SUPPORT_CANCELLED" : "CODEX_SUPPORT_INVALID_TRANSITION";
      throw new HttpError(
        409,
        current.state === "CANCELLED" ? "這筆請求已取消" : `拒絕過期狀態更新：${current.state} → ${state}`,
        code,
        statusFromRow(current),
      );
    }

    const now = new Date();
    const nextRetryAt = Number(body.nextRetryAt) > 0 ? new Date(Number(body.nextRetryAt)) : null;
    const leaseUntil = ["RECEIVED", "VALIDATING", "QUEUEING"].includes(state)
      ? new Date(now.valueOf() + CODEX_DISPATCH_LEASE_MS)
      : null;
    const updated = await client.query(
      `UPDATE codex_support_requests SET state=$2,detail=$3,
        received_at=CASE WHEN $2 IN ('RECEIVED','VALIDATING','QUEUEING','RETRYING','QUEUED','FAILED','REJECTED','RATE_LIMITED') THEN COALESCE(received_at,$4) ELSE received_at END,
        validated_at=CASE WHEN $2 IN ('QUEUEING','RETRYING','QUEUED','FAILED','RATE_LIMITED') THEN COALESCE(validated_at,$4) ELSE validated_at END,
        attempt_count=GREATEST(attempt_count,$5),
        last_attempt_at=CASE WHEN $5>0 THEN COALESCE($6,last_attempt_at,$4) ELSE last_attempt_at END,
        next_retry_at=$7,queued_at=CASE WHEN $2='QUEUED' THEN COALESCE(queued_at,$4) ELSE queued_at END,
        message_sha256=$8,error_code=$9,error_detail=$10,bridge_host=$11,bridge_version=$12,
        bridge_heartbeat_at=$4,claim_expires_at=$13,updated_at=now()
        WHERE id=$1 AND state=$14 AND claim_generation=$15 AND claimed_by=$16 RETURNING *`,
      [nonce, state, boundedText(body.detail, 500), now, integer(body.attemptCount, 0, 0, 1000),
        Number(body.lastAttemptAt) > 0 ? new Date(Number(body.lastAttemptAt)) : null, nextRetryAt,
        boundedText(body.messageSha256, 128), boundedText(body.errorCode, 160), boundedText(body.errorDetail, 500),
        boundedText(body.host, 160), boundedText(body.version, 80), leaseUntil, current.state,
        claimGeneration, dispatcherId],
    );
    if (!updated.rowCount) {
      throw new HttpError(409, "請求狀態已被其他傳送器更新，請重新讀取", "CODEX_SUPPORT_STATE_CHANGED");
    }
    return statusFromRow(updated.rows[0]);
  });
}
