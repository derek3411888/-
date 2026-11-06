import { HttpError } from './utils.js';
import { redactCodexSupportContext as redact } from './codex-support.js';
import { MAINTENANCE_SETTINGS, normalizeGameMaintenance } from './game-maintenance.js';
import { normalizePerformancePayload } from './performance.js';

export const COMPANY_UIDS = Object.freeze(['MYDESKPC_60cf84ad1ea2', 'MYTUFPC_4e8bb5ec68f3']);
export const COMPANY_INTERVAL_MS = 60000;
const settingsKeys = ['schemaVersion', 'serverScheduleEnabled', 'serverScheduleList', 'mailNotifyEnabled',
  'runtimeDiagnosticsEnabled', 'runtimeDiagnosticsIntervalSec', 'runtimeDiagnosticsErrorKeepCount',
  'maxRestartCount', 'liveQualityProfile', ...Object.keys(MAINTENANCE_SETTINGS)];
const commands = ['RUN', 'PAUSE', 'STOP', 'SWITCH_SERVER', 'COMPLETE_SERVER', 'RESTART_UPDATE'];
const object = v => v && typeof v === 'object' && !Array.isArray(v);
const text = (v, limit = 1200) => redact(typeof v === 'string' ? v : '').slice(0, limit);
const millis = v => typeof v === 'number' ? v : new Date(v || 0).valueOf() || 0;
const number = v => Math.max(0, Number(v) || 0);
function reject(code) { throw new HttpError(409, code, code); }
function commandStatus(c) {
  if (c.status === 'PENDING') return 'WAITING_ACK';
  const result = String(c.ack_result || '').toUpperCase();
  const rejected = ['REJECTED', 'ERROR', 'NO_SERVER_CONFIG', 'INVALID_TARGET', 'CONFIG_CHANGED', 'ALREADY_CURRENT',
    'BUSY', 'CONFIG_WRITE_FAILED', 'UNSUPPORTED_CLIENT', 'HANDLER_ERROR', 'NO_HANDLER'].includes(result) ||
    (c.command === 'SWITCH_SERVER' && result === 'ALREADY_COMPLETED_TODAY');
  return c.status === 'ACKED' && rejected ? 'REJECTED' : text(c.status, 40);
}
export function assertCompanyUid(uid) { if (!COMPANY_UIDS.includes(uid)) reject('COMPANY_UID_DENIED'); }
export function validateCompanyRequest(uid, raw, state, now = Date.now()) {
  assertCompanyUid(uid);
  if (!object(raw) || JSON.stringify(raw).length > 12000 || raw.version !== 1 ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(raw.id || '') ||
      !object(raw.payload) || !['command', 'settings'].includes(raw.kind)) reject('COMPANY_INVALID_REQUEST');
  if (raw.epoch !== state.epoch) reject('COMPANY_OLD_EPOCH');
  if (!Number.isSafeInteger(raw.createdAt) || raw.createdAt < millis(state.activatedAt) ||
      now - raw.createdAt > 300000 || raw.createdAt > now + 30000) reject('COMPANY_REQUEST_EXPIRED');
  if (![raw.expectedNonce, raw.expectedRevision].every(v => Number.isSafeInteger(v) && v >= 0)) reject('COMPANY_INVALID_BASELINE');
  const allowed = raw.kind === 'command' ? ['command', 'serverIndex', 'serverName'] : settingsKeys;
  if (Object.keys(raw.payload).some(key => !allowed.includes(key))) reject('COMPANY_INVALID_FIELDS');
  if (raw.kind === 'command' && !commands.includes(raw.payload.command)) reject('COMPANY_INVALID_COMMAND');
  return raw;
}

// Explicit projection: never copy the legacy document, credential fields, live
// tokens, arbitrary status properties or Codex data into the company document.
export function projectCompanySnapshot({ device: d, commands: history = [], events = [], settings = null }) {
  assertCompanyUid(d.uid);
  const s = d.status || {}, ack = history.find(c => c.status === 'ACKED'), log = s.diagnosticLog || {};
  const out = { uid: d.uid, schemaVersion: 5, displayName: text(d.display_name, 160), deviceAlias: text(d.device_alias, 120),
    state: text(d.state, 40), status: text(d.state, 40), online: d.online === true, lastHeartbeat: millis(d.last_seen),
    nonce: number(d.command_nonce), lastAckNonce: number(ack?.nonce), desiredState: text(history[0]?.command, 40),
    lastAckState: text(ack?.command, 40), lastAckResult: text(ack?.ack_result, 120), lastAckDetail: text(ack?.ack_detail, 2000), lastAckAt: millis(ack?.acked_at),
    lastAckServerIndex: number(ack?.ack_payload?.serverIndex ?? ack?.payload?.serverIndex),
    lastAckServerName: text(ack?.ack_payload?.serverName ?? ack?.payload?.serverName, 80),
    remoteSettingsSchemaVersion: number(d.settings?.schemaVersion), desiredSettingsRevision: number(d.settings_revision),
    effectiveSettingsRevision: number(d.settings_effective_revision), lastSettingsAckRevision: number(d.settings_ack?.revision),
    lastSettingsAckResult: text(d.settings_ack?.result, 120), lastSettingsAckDetail: text(d.settings_ack?.detail, 2000), lastSettingsAckAt: millis(d.settings_ack?.at),
    recentLogAvailable: log.available === true, recentLogFileName: text(log.fileName, 240), recentLogExcerpt: text(log.excerpt, 12000), recentLogCapturedAt: millis(log.capturedAt),
    serverProgressSchemaVersion: Array.isArray(s.serverCompletedList) ? 1 : 0,
    serverScheduleJson: JSON.stringify(Array.isArray(s.serverScheduleList) ? s.serverScheduleList.map(x => text(x, 80)).slice(0, 5) : []),
    serverCompletedCycleJson: JSON.stringify(Array.isArray(s.serverCompletedList) ? s.serverCompletedList.map(x => text(x, 80)).slice(0, 5) : []),
    gameMaintenanceJson: JSON.stringify(normalizeGameMaintenance(s.gameMaintenance)),
    recentEventsJson: JSON.stringify(events.slice(0, 50).reverse().map(e => ({ at: millis(e.event_at), name: text(e.name, 160), level: text(e.level, 20), detail: text(e.detail, 1000) }))),
    commandHistory: history.slice(0, 30).map(c => ({ commandId: String(c.nonce), commandNonce: number(c.nonce), requestedState: text(c.command, 40),
      targetServerIndex: number(c.payload?.serverIndex), targetServerName: text(c.payload?.serverName, 80), sentAt: millis(c.created_at),
      status: commandStatus(c),
      ackAt: millis(c.acked_at), ackResult: text(c.ack_result, 120), ackDetail: text(c.ack_detail, 2000) })),
  };
  for (const key of ['currentStep', 'currentStepLevel', 'currentStepDetail', 'payloadVersion', 'currentServer', 'currentServerLabel', 'serverCycleKey',
    'remoteRestartVersion', 'pendingServerSwitchName', 'pendingServerSwitchSource', 'lastServerSwitchMailDetail', 'lastServerSwitchMailResult', 'lastServerSwitchCompletedName']) out[key] = text(s[key]);
  for (const key of ['currentServerIndex', 'currentServerTotal', 'serverCompletedCount', 'pendingServerSwitchIndex', 'lastServerSwitchCompletedIndex', 'lastServerSwitchCompletedAt']) out[key] = number(s[key]);
  for (const key of ['serverScheduleEnabled', 'serverAllCompletedToday', 'remoteRestartSupported', 'serverSwitchNotifyPending']) out[key] = s[key] === true;
  for (const [prefix, source] of [['effective', d.settings], ['desired', settings?.settings || d.settings]]) {
    for (const key of settingsKeys) if (Object.hasOwn(source || {}, key)) {
      const v = source[key];
      if (['string', 'boolean', 'number'].includes(typeof v)) out[`${prefix}${key[0].toUpperCase()}${key.slice(1)}`] = typeof v === 'string' ? text(v) : v;
    }
  }
  for (const key of ['state', 'detail', 'baseName', 'resultPath', 'failureStorage', 'progressUnit']) out[`recording${key[0].toUpperCase()}${key.slice(1)}`] = text(s.recording?.[key]);
  for (const key of ['active', 'enabled']) out[`recording${key[0].toUpperCase()}${key.slice(1)}`] = s.recording?.[key] === true;
  for (const key of ['progressTotal', 'progressCurrent', 'progressPercent']) out[`recording${key[0].toUpperCase()}${key.slice(1)}`] = number(s.recording?.[key]);
  out.recordingStatusAvailable = !!s.recording;
  out.recordingStateDetail = text(s.recording?.detail);
  out.recordingStateUpdatedAt = millis(d.last_seen);
  const performance = normalizePerformancePayload(s.performance);
  out.performanceSchemaVersion = performance ? 1 : 0;
  out.performanceStatusAvailable = !!performance?.current;
  out.performanceJson = performance ? redact(JSON.stringify({ collector: performance.collector, current: performance.current,
    points: performance.minutes.map(m => ({ at: m.bucketStart, ...m.metrics })) })) : '';
  return out;
}

function decode(value) {
  if (!value || typeof value !== 'object') return null;
  if ('mapValue' in value) return Object.fromEntries(Object.entries(value.mapValue.fields || {}).map(([k, v]) => [k, decode(v)]));
  if ('arrayValue' in value) return (value.arrayValue.values || []).map(decode);
  if ('timestampValue' in value) return millis(value.timestampValue);
  if ('integerValue' in value) return Number(value.integerValue);
  return value.stringValue ?? value.booleanValue ?? value.doubleValue ?? null;
}
function encode(value) {
  if (value === null || value === undefined) return { nullValue: null };
  if (Array.isArray(value)) return { arrayValue: { values: value.map(encode) } };
  if (typeof value === 'object') return { mapValue: { fields: Object.fromEntries(Object.entries(value).map(([k, v]) => [k, encode(v)])) } };
  if (typeof value === 'boolean') return { booleanValue: value };
  if (typeof value === 'number') return Number.isSafeInteger(value) ? { integerValue: String(value) } : { doubleValue: value };
  return { stringValue: String(value) };
}
export function createCompanyTransport({ projectId, collection = 'ahk_clients', fetchImpl = fetch }) {
  if (!/^[a-z0-9-]+$/.test(projectId) || collection !== 'ahk_clients') throw new Error('Invalid company Firestore target');
  const base = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/${collection}/`;
  async function request(uid, patch, version) {
    assertCompanyUid(uid);
    const url = new URL(base + uid), headers = { 'Content-Type': 'application/json' };
    url.searchParams.append('mask.fieldPaths', 'companyRequest');
    if (patch) {
      if (!version || Object.keys(patch).some(k => !['companyBridge', 'companySnapshot', 'companyReceipt'].includes(k))) reject('COMPANY_PATCH_DENIED');
      for (const key of Object.keys(patch)) url.searchParams.append('updateMask.fieldPaths', key);
      url.searchParams.set('currentDocument.updateTime', version);
    }
    const response = await fetchImpl(url, { method: patch ? 'PATCH' : 'GET', headers, redirect: 'error', signal: AbortSignal.timeout(10000),
      ...(patch ? { body: JSON.stringify({ fields: Object.fromEntries(Object.entries(patch).map(([k, v]) => [k, encode(v)])) }) } : {}) });
    if (!response.ok) { await response.body?.cancel(); throw Object.assign(new Error('Company Firestore request failed'), { code: `FIRESTORE_HTTP_${response.status}` }); }
    const reader = response.body.getReader(), chunks = []; let size = 0;
    try { for (;;) { const { done, value } = await reader.read(); if (done) break; size += value.byteLength;
      if (size > 65536) throw new Error('Company response too large'); chunks.push(value); } }
    finally { await reader.cancel(); }
    const document = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    return { updateTime: document.updateTime, data: decode({ mapValue: { fields: document.fields } }) };
  }
  return { read: uid => request(uid), patch: (uid, version, fields) => request(uid, fields, version) };
}
export function createCompanyBridge({ store, transport, readDetails, now = Date.now, onError = () => {} }) {
  let inFlight = null, closed = false, timer;
  async function run() {
    for (const uid of COMPANY_UIDS) {
      if (closed) break;
      try {
        const state = await store.activate(uid, now());
        const document = await transport.read(uid);
        const receipt = document.data?.companyRequest ? await store.intake(uid, document.data.companyRequest, now()) : null;
        const snapshot = projectCompanySnapshot(await readDetails(uid));
        await transport.patch(uid, document.updateTime, { companyBridge: { version: 1, enabled: true, ...state, heartbeatAt: now() }, companySnapshot: snapshot,
          ...(receipt ? { companyReceipt: receipt } : {}) });
      } catch (error) { onError(uid, error.code || 'COMPANY_BRIDGE_FAILED'); }
    }
  }
  function tick() {
    if (closed || inFlight) return Promise.resolve(false);
    inFlight = run().finally(() => { inFlight = null; });
    return inFlight;
  }
  return { tick, start() { if (!timer && !closed) { tick(); timer = setInterval(tick, COMPANY_INTERVAL_MS); } },
    async close() { closed = true; clearInterval(timer); await inFlight; } };
}
