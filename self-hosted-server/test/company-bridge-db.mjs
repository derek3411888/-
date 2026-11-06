// Explicit opt-in isolated database test. Never run against the service database.
import assert from 'node:assert/strict';
if (process.env.COMPANY_ISOLATED_TEST !== 'yes' || !process.env.DATABASE_URL?.endsWith('/company_bridge_isolated')) throw new Error('Isolated DB only');
for (const name of ['SESSION_SECRET','CODEX_BRIDGE_TOKEN','LIVE_TOKEN_SECRET','LIVE_SRT_PASSPHRASE']) process.env[name] = 'isolated-test-not-a-production-secret-0123456789';
const { migrate, query, withTransaction, closeDatabase } = await import('../src/db.js');
const { sendCommand, savePrimarySettings } = await import('../src/app.js');
const { createCompanyStore } = await import('../src/company-bridge-store.js');
const uid = 'MYDESKPC_60cf84ad1ea2';
const store = createCompanyStore({ withTransaction, sendCommand, saveSettings: savePrimarySettings });
await migrate();
await query("UPDATE system_settings SET value='{\"mode\":\"primary\"}' WHERE key='migration'");
await query('DELETE FROM devices WHERE uid=$1', [uid]);
await query("INSERT INTO devices(uid,state,last_seen,command_nonce,last_nonce,settings_revision,settings_effective_revision,settings) VALUES($1,'RUN',now(),127,127,4,4,'{\"schemaVersion\":1}')", [uid]);
let checks = 0;
try {
  const now = Date.now(), state = await store.activate(uid, now);
  const req = (extra = {}) => ({ version: 1, epoch: state.epoch, id: crypto.randomUUID(), kind: 'command', payload: { command: 'PAUSE' }, createdAt: now + 1, expectedNonce: 127, expectedRevision: 4, ...extra });
  assert.equal((await store.activate(uid, now + 1000)).epoch, state.epoch); checks++;
  const first = req();
  const responses = await Promise.all(Array.from({length: 8}, () => store.intake(uid, first, now + 2)));
  assert.ok(responses.every(r => r.status === 'ACCEPTED' && r.nonce === 128));
  assert.equal((await query('SELECT count(*) FROM commands')).rows[0].count, '1'); checks++;
  assert.equal((await store.intake(uid, first, now + 999999)).nonce, 128); checks++; // Lost Firestore response / process restart.
  assert.equal((await store.intake(uid, { ...first, payload: {command:'STOP'} }, now + 3)).code, 'COMPANY_ID_REUSED'); checks++;
  assert.equal((await store.intake(uid, req({epoch:'old'}), now + 3)).status, 'REJECTED'); checks++;
  assert.equal((await store.intake(uid, req({createdAt:now - 10000}), now + 3)).status, 'REJECTED'); checks++;
  assert.equal((await store.intake(uid, req(), now + 3)).code, 'COMPANY_STALE_BASELINE'); checks++;
  assert.equal((await store.intake(uid, req({expectedNonce:128}), now + 3)).code, 'COMMAND_PENDING'); checks++;
  await query("UPDATE commands SET status='ACKED',acked_at=now() WHERE uid=$1", [uid]);
  await query('UPDATE devices SET last_nonce=128 WHERE uid=$1', [uid]);
  let fail = true;
  const failingStore = createCompanyStore({ withTransaction, sendCommand: async (...args) => { const result = await sendCommand(...args); if (fail) throw new Error('simulated crash before receipt commit'); return result; }, saveSettings: savePrimarySettings });
  const retry = req({expectedNonce:128});
  await assert.rejects(failingStore.intake(uid, retry, now + 4));
  assert.equal((await query('SELECT command_nonce FROM devices WHERE uid=$1',[uid])).rows[0].command_nonce,'128');
  fail = false;
  assert.equal((await failingStore.intake(uid,retry,now+5)).nonce,129); checks++;
  const settings = req({expectedNonce:129,kind:'settings',payload:{schemaVersion:1,serverScheduleEnabled:false,serverScheduleList:'',mailNotifyEnabled:true}});
  assert.equal((await store.intake(uid,settings,now+6)).revision,5);
  assert.equal((await store.intake(uid,settings,now+7)).revision,5); checks++;
  const nextSettings = req({expectedNonce:129,expectedRevision:5,kind:'settings',payload:{serverScheduleEnabled:false}});
  assert.equal((await store.intake(uid,nextSettings,now+7)).code,'SETTINGS_PENDING'); checks++;
  await query("UPDATE settings_revisions SET status='APPLIED' WHERE uid=$1",[uid]);
  for (const offline of [{state:'RUN',last_seen:new Date(now-300001)}, {state:'STOP',last_seen:new Date(now)}]) {
    await query('UPDATE devices SET state=$2,last_seen=$3,settings_effective_revision=5 WHERE uid=$1',[uid,offline.state,offline.last_seen]);
    const response=await store.intake(uid,req({expectedNonce:129,expectedRevision:5,kind:'settings',payload:{serverScheduleEnabled:false}}),now+8);
    assert.equal(response.code,'DEVICE_OFFLINE');
    assert.equal((await query('SELECT settings_revision FROM devices WHERE uid=$1',[uid])).rows[0].settings_revision,'5');checks++;
  }
  await query("UPDATE devices SET state='RUN',last_seen=now() WHERE uid=$1",[uid]);
  await query("UPDATE system_settings SET value='{\"mode\":\"cutover\"}' WHERE key='migration'");
  assert.equal((await store.intake(uid,req({expectedNonce:129,expectedRevision:5}),now+8)).code,'COMPANY_NOT_PRIMARY'); checks++;
  console.log(JSON.stringify({ isolated:true, checks, passed:true, deviceCommandsSent:0 }));
} finally { await closeDatabase(); }
