import test from 'node:test';
import assert from 'node:assert/strict';
import { COMPANY_UIDS, validateCompanyRequest, projectCompanySnapshot, createCompanyBridge, createCompanyTransport } from '../src/company-bridge.js';
const uid = COMPANY_UIDS[0], now = 1793934000000;
const state = { epoch: 'epoch-new', activatedAt: now - 1000 };
const request = () => ({ version: 1, epoch: state.epoch, id: '12d8cde2-44cc-4892-b3b9-052282ac33cc', kind: 'command', payload: { command: 'PAUSE' }, createdAt: now, expectedNonce: 127, expectedRevision: 4 });
test('company protocol accepts only new versioned bounded allowlisted requests', () => {
  assert.equal(validateCompanyRequest(uid, request(), state, now).kind, 'command');
  for (const bad of [{ ...request(), epoch: 'old' }, { ...request(), createdAt: now - 2000 }, { ...request(), createdAt: now - 400000 }, { ...request(), createdAt: now + 31000 }, { ...request(), expectedNonce: -1 }, { ...request(), kind: 'codex' }, { ...request(), payload: { command: 'RUN', shell: 'bad' } }, { ...request(), payload: { command: 'SHELL' } }, { nonce: 123, desiredState: 'RUN' }]) {
    assert.throws(() => validateCompanyRequest(uid, bad, state, now));
  }
  assert.throws(() => validateCompanyRequest('unapproved', request(), state, now));
  assert.throws(() => validateCompanyRequest(uid, { ...request(), kind: 'settings', payload: { arbitrary: true } }, state, now));
});
test('snapshot replaces legacy state, uses real timestamps and counters, excludes credentials', () => {
  const snapshot = projectCompanySnapshot({ device: { uid, display_name: 'desk', state: 'RUN', online: true, last_seen: new Date(now), command_nonce: '127', last_nonce: '127', settings_revision: '4', settings_effective_revision: '4', token_hash: 'never-copy', status: { currentStep: 'monitor', payloadVersion: '5.42', diagnosticLog: { available: true, excerpt: 'token=abcdefghi', capturedAt: now, fileName: 'new.log' }, secret: 'never-copy' }, settings: { schemaVersion: 1, maxRestartCount: 10 }, settings_ack: { revision: 4, result: 'APPLIED' } }, commands: [], events: [] });
  assert.equal(snapshot.lastHeartbeat, now);
  assert.equal(snapshot.status, 'RUN');
  assert.equal(snapshot.recordingStateDetail, '');
  assert.equal(snapshot.nonce, 127);
  assert.equal(snapshot.lastAckNonce, 127);
  assert.equal(snapshot.effectiveMaxRestartCount, 10);
  assert.equal(snapshot.recentLogFileName, 'new.log');
  assert.match(snapshot.recentLogExcerpt, /REDACTED/);
  assert.doesNotMatch(JSON.stringify(snapshot), /never-copy|token_hash|codex/i);
});
test('tick ignores all legacy requests, persists receipts before CAS, never overlaps', async () => {
  const patches = [], intakes = [];
  let release;
  const gate = new Promise(r => { release = r; });
  const bridge = createCompanyBridge({ store: { activate: async () => state, intake: async (...a) => { intakes.push(a); return { id: a[1].id, status: 'ACCEPTED', nonce: 128 }; } }, transport: { read: async id => { await gate; return { updateTime: 'version', data: id === uid ? { nonce: 129, desiredState: 'STOP', companyRequest: request() } : { nonce: 130, desiredState: 'RUN' } }; }, patch: async (...a) => patches.push(a) }, readDetails: async id => ({ device: { uid: id, state: 'RUN', last_seen: new Date(now), command_nonce: 127, last_nonce: 127 } }), now: () => now });
  const first = bridge.tick();
  assert.equal(await bridge.tick(), false);
  release(); await first;
  assert.equal(intakes.length, 1);
  assert.equal(patches.length, 2);
  assert.deepEqual(patches[0].slice(0, 2), [uid, 'version']);
  assert.equal(patches[0][2].companyReceipt.nonce, 128);
  assert.equal(patches[0][2].companyRequest, undefined);
  assert.equal(patches[0][2].nonce, undefined);
});
test('transport fixes hosts, masks reads/writes, applies CAS and bounds responses', async () => {
  const calls = [];
  const transport = createCompanyTransport({ projectId: 'test-project', collection: 'ahk_clients', fetchImpl: async (url, options) => { calls.push([new URL(url), options]); return new Response(JSON.stringify({ updateTime: 'v1', fields: { companyRequest: { mapValue: { fields: { createdAt: { timestampValue: new Date(now).toISOString() } } } } } })); } });
  assert.equal((await transport.read(uid)).data.companyRequest.createdAt, now);
  await transport.patch(uid, 'v1', { companyBridge: state, companySnapshot: { state: 'RUN' } });
  assert.deepEqual(calls[0][0].searchParams.getAll('mask.fieldPaths'), ['companyRequest']);
  assert.equal(calls[1][0].searchParams.get('currentDocument.updateTime'), 'v1');
  assert.equal(calls[1][0].hostname, 'firestore.googleapis.com');
  assert.ok(calls[1][1].signal);
  await assert.rejects(transport.patch(uid, 'v1', { nonce: 999 }));
  await assert.rejects(transport.read('another-device'));
});

test('transport rejects CAS conflicts and oversized responses without blind retry',async()=>{
 let calls=0;
 const conflict=createCompanyTransport({projectId:'test',fetchImpl:async()=>{calls++;return new Response('',{status:412});}});
 await assert.rejects(conflict.patch(uid,'old',{companySnapshot:{}}),{code:'FIRESTORE_HTTP_412'});
 assert.equal(calls,1);
 const huge=createCompanyTransport({projectId:'test',fetchImpl:async()=>new Response('x'.repeat(65537))});
 await assert.rejects(huge.read(uid),/too large/);
});

test('receipt remains committed when mirror CAS fails; next cycle reuses receipt',async()=>{
 let allocations=0,patches=0; const receipts=new Map();
 const bridge=createCompanyBridge({store:{activate:async()=>state,intake:async(_uid,r)=>{
   if(!receipts.has(r.id))receipts.set(r.id,{id:r.id,nonce:++allocations,status:'ACCEPTED'});return receipts.get(r.id);}},
   transport:{read:async id=>({updateTime:'v',data:id===uid?{companyRequest:request()}:{}}),patch:async()=>{if(++patches===1)throw new Error('conflict');}},
   readDetails:async id=>({device:{uid:id,state:'RUN'}}),now:()=>now});
 await bridge.tick();await bridge.tick();assert.equal(allocations,1);assert.equal(patches,4);
});
