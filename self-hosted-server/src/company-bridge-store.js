import crypto from 'node:crypto';
import pg from 'pg';
import { assertCompanyUid, validateCompanyRequest } from './company-bridge.js';
import { HttpError } from './utils.js';

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])]));
  return value;
}
const reject = code => { throw new HttpError(409, code, code); };
export function createCompanyStore({ withTransaction, sendCommand, saveSettings }) {
  return {
    async activate(uid, now = Date.now()) {
      assertCompanyUid(uid);
      return withTransaction(async c => {
        await c.query('INSERT INTO company_bridge_state(uid,epoch,activated_at) VALUES($1,$2,$3) ON CONFLICT(uid) DO NOTHING', [uid, crypto.randomUUID(), new Date(now)]);
        const { rows } = await c.query('SELECT epoch,activated_at FROM company_bridge_state WHERE uid=$1', [uid]);
        return { epoch: rows[0].epoch, activatedAt: new Date(rows[0].activated_at).valueOf() };
      });
    },
    async intake(uid, request, now = Date.now()) {
      assertCompanyUid(uid);
      // Untrusted input never becomes a SQL identifier or unbounded receipt key.
      if (!request || JSON.stringify(request).length > 12000 || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(request.id || '')) return { status: 'REJECTED', code: 'COMPANY_INVALID_REQUEST' };
      const digest = crypto.createHash('sha256').update(JSON.stringify(canonical(request))).digest('hex');
      return withTransaction(async c => {
        const state = (await c.query('SELECT epoch,activated_at FROM company_bridge_state WHERE uid=$1 FOR UPDATE', [uid])).rows[0];
        if (!state) reject('COMPANY_NOT_ACTIVE');
        const existing = (await c.query('SELECT digest,receipt FROM company_bridge_receipts WHERE uid=$1 AND request_id=$2', [uid, request.id])).rows[0];
        if (existing) return existing.digest === digest ? existing.receipt : { id: request.id, status: 'REJECTED', code: 'COMPANY_ID_REUSED' };
        let receipt;
        await c.query('SAVEPOINT company_allocation');
        try {
          validateCompanyRequest(uid, request, { epoch: state.epoch, activatedAt: state.activated_at }, now);
          const migration = (await c.query("SELECT value FROM system_settings WHERE key='migration' FOR SHARE")).rows[0]?.value;
          if (migration?.mode !== 'primary' || migration?.writesFrozen === true) reject('COMPANY_NOT_PRIMARY');
          const d = (await c.query('SELECT command_nonce,settings_revision,last_seen,state FROM devices WHERE uid=$1 FOR UPDATE', [uid])).rows[0];
          if (!d || Number(d.command_nonce) !== request.expectedNonce || Number(d.settings_revision) !== request.expectedRevision) reject('COMPANY_STALE_BASELINE');
          if (!d.last_seen || now - new Date(d.last_seen).valueOf() > 300000 || ['STOP','OFFLINE'].includes(d.state)) reject('DEVICE_OFFLINE');
          const tx = callback => callback(c);
          const result = request.kind === 'command'
            ? await sendCommand(uid, { ...request.payload, idempotencyKey: `company:${request.id}` }, true, tx)
            : await saveSettings(uid, request.payload, tx);
          receipt = { id: request.id, kind: request.kind, status: 'ACCEPTED', at: now,
            ...(request.kind === 'command' ? { nonce: Number(result.nonce) } : { revision: Number(result.revision) }) };
        } catch (error) {
          if (!(error.status >= 400 && error.status < 500)) throw error;
          await c.query('ROLLBACK TO SAVEPOINT company_allocation');
          receipt = { id: request.id, kind: request.kind, status: 'REJECTED', code: String(error.code || 'COMPANY_REJECTED').slice(0, 100), at: now };
        }
        await c.query('INSERT INTO company_bridge_receipts(uid,request_id,digest,receipt) VALUES($1,$2,$3,$4)', [uid, request.id, digest, receipt]);
        return receipt;
      });
    },
  };
}

// Dedicated bounded connection. A stalled bridge cannot consume the main
// heartbeat pool; SQL/lock timeouts roll back the entire allocation + receipt.
export function createCompanyDatabase(connectionString) {
  const pool = new pg.Pool({ connectionString, max: 1, connectionTimeoutMillis: 2000, idleTimeoutMillis: 10000,
    statement_timeout: 3000, lock_timeout: 1500, query_timeout: 4000, application_name: 'wuthering-company-bridge' });
  pool.on('error', () => {});
  return { async withTransaction(callback) {
    const c = await pool.connect(); let failed = false;
    try { await c.query('BEGIN'); const result = await callback(c); await c.query('COMMIT'); return result; }
    catch (error) { try { await c.query('ROLLBACK'); } catch { failed = true; } throw error; }
    finally { c.release(failed); }
  }, async readDetails(uid) {
    assertCompanyUid(uid);
    const device = (await pool.query("SELECT *, (state NOT IN ('STOP','OFFLINE') AND last_seen>now()-interval '5 minutes' AND NOT EXISTS (SELECT 1 FROM commands c WHERE c.uid=devices.uid AND c.command='STOP' AND c.status='ACKED' AND c.acked_at>=devices.last_seen)) AS online FROM devices WHERE uid=$1", [uid])).rows[0];
    if (!device) throw new Error('Company device missing');
    const commands = (await pool.query('SELECT nonce,command,payload,status,created_at,acked_at,ack_result,ack_detail,ack_payload FROM commands WHERE uid=$1 ORDER BY nonce DESC LIMIT 30', [uid])).rows;
    const settings = (await pool.query('SELECT revision,settings FROM settings_revisions WHERE uid=$1 ORDER BY revision DESC LIMIT 1', [uid])).rows[0];
    const events = (await pool.query('SELECT event_at,level,name,detail FROM runtime_events WHERE uid=$1 ORDER BY event_at DESC LIMIT 50', [uid])).rows;
    return { device, commands, settings, events };
  }, close: () => pool.end() };
}
