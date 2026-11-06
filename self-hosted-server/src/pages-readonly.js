import { bearerToken, HttpError, randomToken, readJson, sendEmpty, sendJson, sha256 } from './utils.js';

const API = 'https://ww.sckang.cc';
const PAGES = 'https://derek3411888.github.io';
const PREFIX = '/api/v1/pages-readonly/';
export const pagesReadonlyUids = Object.freeze(['MYDESKPC_60cf84ad1ea2', 'MYTUFPC_4e8bb5ec68f3']);
const TTL = 600_000;

function project(rows) {
  const text = value => typeof value === 'string' ? value.slice(0, 160) : '';
  const seen = new Set();
  return rows.filter(row => pagesReadonlyUids.includes(row.uid) && !seen.has(row.uid) && seen.add(row.uid)).map(row => ({
    uid: row.uid, displayName: text(row.display_name), state: text(row.state), online: row.online === true,
    lastSeen: row.last_seen ? new Date(row.last_seen).toISOString() : null,
    step: text(row.status?.currentStep), server: text(row.status?.currentServerLabel || row.status?.currentServer),
    payloadVersion: text(row.status?.payloadVersion),
  }));
}

// Independent, memory-only capabilities. Never attach the ordinary event bus.
export function createPagesReadonly({ enabled, publicUrl, readDevices, ensureBrowser, requireSameOrigin, clock = Date.now,
  readTimeoutMs = 5000 }) {
  const active = enabled && publicUrl.replace(/\/$/, '') === API;
  const grants = new Map(), nonces = new Map(), streams = new Set();
  let closed = false, refreshing = false, dirty = false, timer;
  let inFlight, consumers = 0;
  const fail = (status, code) => { throw new HttpError(status, code, code); };
  const valid = grant => !closed && grant.expiresAt > clock() && grants.get(grant.hash) === grant;
  const end = stream => {
    clearTimeout(stream.expiry); clearInterval(stream.keepalive);
    streams.delete(stream); stream.res.end();
  };
  const prune = () => {
    for (const [key, grant] of grants) if (!valid(grant)) grants.delete(key);
    for (const [key, expiry] of nonces) if (expiry <= clock()) nonces.delete(key);
    for (const stream of streams) if (!valid(stream.grant)) end(stream);
  };
  const write = (stream, frame) => {
    if (!valid(stream.grant) || stream.res.destroyed || stream.res.writableEnded) { end(stream); return; }
    // Do not accumulate an unbounded response queue for a slow reader.
    if (!stream.res.write(frame)) end(stream);
  };
  function snapshot() {
    if (inFlight) return inFlight;
    let deadline;
    const operation = Promise.resolve().then(() => readDevices(pagesReadonlyUids)).then(project);
    const bounded = Promise.race([operation, new Promise((resolve, reject) => {
      deadline = setTimeout(() => reject(new HttpError(503, 'SNAPSHOT_TIMEOUT', 'SNAPSHOT_TIMEOUT')), readTimeoutMs);
      deadline.unref?.();
    })]);
    inFlight = bounded;
    // Keep the gate closed even after timeout until the underlying operation settles.
    // The production reader additionally enforces a PostgreSQL statement deadline.
    const settled = () => { clearTimeout(deadline); if (inFlight === bounded) inFlight = undefined; };
    operation.then(settled, settled);
    return bounded;
  }
  async function refresh() {
    timer = undefined;
    prune();
    if (closed || refreshing || !streams.size) return;
    refreshing = true; dirty = false;
    try {
      const devices = await snapshot();
      const frame = `event: devices\ndata: ${JSON.stringify({ devices })}\n\n`;
      for (const stream of streams) write(stream, frame);
    } catch {
      for (const stream of streams) end(stream);
    } finally {
      refreshing = false;
      if (dirty) notify();
    }
  }
  function notify() {
    prune();
    if (closed || !streams.size) return;
    dirty = true;
    if (!timer && !refreshing) { timer = setTimeout(refresh, 100); timer.unref?.(); }
  }
  async function handle(req, res, url) {
    const route = url.pathname;
    const token = bearerToken(req);
    if (!route.startsWith(PREFIX)) {
      if (token.startsWith('pr_')) fail(403, 'PILOT_SCOPE_ONLY');
      return false;
    }
    if (!active || closed) fail(404, 'NOT_FOUND');
    if (url.search) fail(400, 'QUERY_NOT_ALLOWED');
    const resource = route.slice(PREFIX.length);
    if (!['grants', 'revoke', 'devices', 'events'].includes(resource)) fail(404, 'NOT_FOUND');
    if (resource === 'grants' || resource === 'revoke') {
      if (req.method !== 'POST') fail(405, 'METHOD_NOT_ALLOWED');
      if (req.headers.origin !== API) fail(403, 'ORIGIN_REJECTED');
      requireSameOrigin(req);
      if (token.startsWith('pr_')) fail(403, 'PILOT_SCOPE_ONLY');
      const body = await readJson(req, 1024);
      if (resource === 'grants' && (typeof body?.nonce !== 'string' || !/^[a-f0-9]{64}$/.test(body.nonce))) fail(400, 'INVALID_NONCE');
      const browser = await ensureBrowser(req, res);
      prune();
      if (resource === 'revoke') {
        for (const [key, grant] of grants) if (grant.owner === browser.id) grants.delete(key);
        prune(); sendJson(res, 200, { revoked: true }); return true;
      }
      const nonceKey = sha256(browser.id + ':' + body.nonce);
      if (nonces.has(nonceKey)) fail(409, 'NONCE_USED');
      if (grants.size >= 128 || nonces.size >= 512 || [...grants.values()].filter(g => g.owner === browser.id).length >= 4) fail(429, 'GRANT_LIMIT');
      const value = 'pr_' + randomToken(32), issuedAt = clock(), expiresAt = issuedAt + TTL;
      const hash = sha256(value);
      grants.set(hash, { hash, owner: browser.id, issuedAt, expiresAt });
      nonces.set(nonceKey, expiresAt);
      sendJson(res, 201, { token: value, issuedAt, expiresAt });
      return true;
    }
    if (req.headers.origin !== PAGES) fail(403, 'ORIGIN_REJECTED');
    res.setHeader('Access-Control-Allow-Origin', PAGES);
    res.setHeader('Vary', 'Origin');
    if (req.method === 'OPTIONS') {
      const names = String(req.headers['access-control-request-headers'] || '').split(',').map(v => v.trim().toLowerCase()).filter(Boolean);
      if (req.headers['access-control-request-method'] !== 'GET' || names.some(v => v !== 'authorization')) fail(403, 'PREFLIGHT_REJECTED');
      sendEmpty(res, 204, { 'Access-Control-Allow-Methods': 'GET', 'Access-Control-Allow-Headers': 'Authorization',
        Vary: 'Origin, Access-Control-Request-Method, Access-Control-Request-Headers' });
      return true;
    }
    if (req.method !== 'GET') fail(405, 'METHOD_NOT_ALLOWED');
    prune();
    const grant = /^pr_[A-Za-z0-9_-]{43}$/.test(token) ? grants.get(sha256(token)) : undefined;
    if (!grant || !valid(grant)) fail(401, 'GRANT_REQUIRED');
    if (resource === 'devices') {
      if (consumers >= 16) fail(429, 'SNAPSHOT_LIMIT');
      consumers++;
      let onClose;
      try {
        const disconnected = new Promise(resolve => { onClose = () => resolve(null); res.once('close', onClose); });
        const devices = await Promise.race([snapshot(), disconnected]);
        if (devices === null || res.destroyed) return true;
        if (!valid(grant)) fail(401, 'GRANT_REQUIRED');
        sendJson(res, 200, { devices }); return true;
      } finally { consumers--; res.off('close', onClose); }
    }
    if (streams.size >= 16 || [...streams].filter(s => s.grant === grant).length >= 2) fail(429, 'STREAM_LIMIT');
    res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' });
    const stream = { res, grant };
    streams.add(stream);
    stream.expiry = setTimeout(() => end(stream), Math.max(0, grant.expiresAt - clock()));
    stream.keepalive = setInterval(() => write(stream, ': keepalive\n\n'), 15_000);
    stream.expiry.unref?.(); stream.keepalive.unref?.();
    res.once('close', () => { clearTimeout(stream.expiry); clearInterval(stream.keepalive); streams.delete(stream); });
    notify();
    return true;
  }
  return { handle, notify, close() {
    closed = true; clearTimeout(timer); grants.clear(); nonces.clear();
    for (const stream of streams) end(stream);
  } };
}
