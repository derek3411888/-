import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { createPagesReadonly } from '../src/pages-readonly.js';
import { requireAllowedOrigin } from '../src/access-auth.js';
import { sendJson } from '../src/utils.js';

const pages = 'https://derek3411888.github.io';
const origin = 'https://ww.sckang.cc';
const prefix = '/api/v1/pages-readonly/';
const uid = 'MYDESKPC_60cf84ad1ea2';
const uid2 = 'MYTUFPC_4e8bb5ec68f3';
const initial = [{uid,display_name:'桌機',state:'RUN',online:true,last_seen:new Date('2026-11-06T02:00:00Z'),
  status:{currentStep:'監測',currentServerLabel:'Asia',payloadVersion:'5.42',secret:'NEVER'},token_hash:'NEVER'},
  {uid:uid2,display_name:'MYTUF',state:'RUN',online:true,last_seen:new Date('2026-11-06T02:00:00Z'),status:{}},
  {uid:'UNAPPROVED',state:'RUN',token_hash:'NEVER'}];

async function fixture(t, overrides={}) {
  let now=Date.now(), rows=structuredClone(initial), browserCalls=0;
  const api=createPagesReadonly({enabled:true,publicUrl:origin,clock:()=>now,readDevices:async()=>rows,
    ensureBrowser:async()=>{browserCalls++;return {id:'test-session'};},
    requireSameOrigin:req=>requireAllowedOrigin(req,[origin]),...overrides});
  const server=http.createServer((req,res)=>{
    api.handle(req,res,new URL(req.url,origin)).then(handled=>{
      if(!handled) sendJson(res,404,{error:{code:'FALLTHROUGH'}});
    }).catch(error=>sendJson(res,error.status||500,{error:{code:error.code||'ERROR'}}));
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(async()=>{api.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));});
  const base=`http://127.0.0.1:${server.address().port}`;
  const call=(route,options={})=>fetch(base+route,{redirect:'error',signal:AbortSignal.timeout(5000),...options});
  const issue=async(nonce=randomBytes(32).toString('hex'))=>{
    const response=await call(prefix+'grants',{method:'POST',headers:{Origin:origin,'X-Wuthering-CSRF':'1','Content-Type':'application/json'},body:JSON.stringify({nonce})});
    return {response,body:await response.json(),nonce};
  };
  const read=(token,route='devices',extra={})=>call(prefix+route,{headers:{Origin:pages,Authorization:'Bearer '+token,...extra}});
  return {api,call,issue,read,advance:ms=>now+=ms,setRows:v=>rows=v,browserCalls:()=>browserCalls};
}

test('pilot disabled routes do not issue a session or reveal data',async t=>{
  const f=await fixture(t,{enabled:false});
  assert.equal((await f.issue()).response.status,404);
  assert.equal((await f.call(prefix+'devices')).status,404);
  assert.equal(f.browserCalls(),0);
});
test('grant issuance requires same-origin CSRF and rejects cross-origin or replayed nonce',async t=>{
  const f=await fixture(t);
  for(const headers of [{Origin:pages,'X-Wuthering-CSRF':'1'},{Origin:origin},{'X-Wuthering-CSRF':'1'}]) {
    const r=await f.call(prefix+'grants',{method:'POST',headers,body:JSON.stringify({nonce:'a'.repeat(64)})});
    assert.equal(r.status,403);
  }
  const first=await f.issue();assert.equal(first.response.status,201);
  assert.match(first.body.token,/^pr_[A-Za-z0-9_-]{43}$/);
  assert.equal(first.body.expiresAt-first.body.issuedAt,600000);
  assert.equal(first.response.headers.get('cache-control'),'no-store');
  assert.equal((await f.issue(first.nonce)).response.status,409);
});
test('read returns only approved device fields without creating ordinary browser session',async t=>{
  const f=await fixture(t);const g=await f.issue();assert.equal(g.response.status,201);
  const r=await f.read(g.body.token);assert.equal(r.status,200);
  const data=await r.json();assert.equal(data.devices.length,2);
  assert.deepEqual(data.devices[0],{uid,displayName:'桌機',state:'RUN',online:true,lastSeen:'2026-11-06T02:00:00.000Z',step:'監測',server:'Asia',payloadVersion:'5.42'});
  assert.ok(!JSON.stringify(data).includes('NEVER'));
  assert.equal(f.browserCalls(),1);
  assert.equal(r.headers.get('access-control-allow-origin'),pages);
  assert.equal(r.headers.get('access-control-allow-credentials'),null);
});
test('reads deny absent unknown expired grant and malformed query without leaking token in error',async t=>{
  const f=await fixture(t);const g=await f.issue();assert.equal(g.response.status,201);
  for(const token of ['', 'pr_'+'x'.repeat(43)]) assert.equal((await f.read(token)).status,401);
  const query=await f.read(g.body.token,'devices?token='+encodeURIComponent(g.body.token));
  assert.equal(query.status,400);assert.ok(!(await query.text()).includes(g.body.token));
  f.advance(600000);assert.equal((await f.read(g.body.token)).status,401);
});
test('exact preflight only allows read paths GET Authorization and never wildcard',async t=>{
  const f=await fixture(t);
  const options={method:'OPTIONS',headers:{Origin:pages,'Access-Control-Request-Method':'GET','Access-Control-Request-Headers':'authorization'}};
  const r=await f.call(prefix+'events',options);assert.equal(r.status,204);
  assert.equal(r.headers.get('access-control-allow-origin'),pages);
  assert.equal(r.headers.get('access-control-allow-methods'),'GET');
  assert.equal(r.headers.get('access-control-allow-headers'),'Authorization');
  for(const header of ['content-type','authorization,x-wuthering-csrf']) {
    assert.equal((await f.call(prefix+'events',{...options,headers:{...options.headers,'Access-Control-Request-Headers':header}})).status,403);
  }
  assert.equal(f.browserCalls(),0);
});
test('untrusted origins opaque null and lookalikes rejected even with valid grant',async t=>{
  const f=await fixture(t);const g=await f.issue();assert.equal(g.response.status,201);
  for(const value of ['null','https://other.github.io',pages+'.evil.test',origin]) {
    const r=await f.read(g.body.token,'devices',{Origin:value});assert.equal(r.status,403);
    assert.equal(r.headers.get('access-control-allow-origin'),null);
  }
});
test('pilot grant cannot fall through to any normal API or device-control route',async t=>{
  const f=await fixture(t);const g=await f.issue();assert.equal(g.response.status,201);
  for(const route of ['/api/v1/devices','/api/v1/events','/api/v1/admin/status','/api/v1/codex-support','/api/v1/devices/'+uid+'/commands']) {
    const r=await f.call(route,{headers:{Origin:origin,Authorization:'Bearer '+g.body.token}});
    assert.equal(r.status,403);
  }
  for(const method of ['POST','PUT','PATCH','DELETE']) {
    assert.equal((await f.call(prefix+'devices',{method,headers:{Origin:pages,Authorization:'Bearer '+g.body.token}})).status,405);
  }
});
test('revoke closes existing stream',async t=>{
  const f=await fixture(t);const g=await f.issue();assert.equal(g.response.status,201);
  const r=await f.read(g.body.token,'events');assert.equal(r.status,200);
  const reader=r.body.getReader();const first=new TextDecoder().decode((await reader.read()).value);
  assert.match(first,/event: devices/);assert.ok(!first.includes('NEVER'));
  const revoked=await f.call(prefix+'revoke',{method:'POST',headers:{Origin:origin,'X-Wuthering-CSRF':'1'}});
  assert.equal(revoked.status,200);assert.equal((await reader.read()).done,true);
  assert.equal((await f.read(g.body.token)).status,401);
});
test('capacity is bounded and expired grants release slots',async t=>{
  const f=await fixture(t); const g=await f.issue();
  for(let i=0;i<3;i++) assert.equal((await f.issue()).response.status,201);
  assert.equal((await f.issue()).response.status,429);
  const a=await f.read(g.body.token,'events'), b=await f.read(g.body.token,'events');
  assert.equal((await f.read(g.body.token,'events')).status,429);
  await a.body.cancel(); await b.body.cancel();
  f.advance(600000);assert.equal((await f.issue()).response.status,201);
});
test('expiry during database read cannot return a snapshot',async t=>{
  let release;const pending=new Promise(resolve=>release=resolve);
  const f=await fixture(t,{readDevices:()=>pending}); const g=await f.issue();
  const request=f.read(g.body.token); await new Promise(resolve=>setTimeout(resolve,20));
  f.advance(600000);release(initial);
  assert.equal((await request).status,401);
});
test('issuer refuses malformed nonce and feature never activates on another host',async t=>{
  const f=await fixture(t);
  assert.equal((await f.issue('invalid')).response.status,400);
  const other=await fixture(t,{publicUrl:'https://direct.sckang.cc'});
  assert.equal((await other.issue()).response.status,404);
});
test('SSE rechecks expiry before subsequent data and closes without leaking new snapshot',async t=>{
  const f=await fixture(t);const g=await f.issue();assert.equal(g.response.status,201);
  const r=await f.read(g.body.token,'events');const reader=r.body.getReader();await reader.read();
  f.advance(600001);f.api.notify();
  assert.equal((await reader.read()).done,true);
});
test('SSE events contain new projected heartbeats and are not ordinary settings/log events',async t=>{
  const f=await fixture(t);const g=await f.issue();assert.equal(g.response.status,201);
  const r=await f.read(g.body.token,'events');const reader=r.body.getReader();await reader.read();
  f.setRows([{...initial[0],last_seen:new Date('2026-11-06T02:00:10Z')}]);f.api.notify();
  const next=new TextDecoder().decode((await reader.read()).value);
  assert.match(next,/02:00:10.000Z/);assert.ok(!next.includes('NEVER'));await reader.cancel();
});

test('stalled refresh closes stream by deadline and shared GETs never start another read',async t=>{
  let calls=0, release;
  const f=await fixture(t,{readTimeoutMs:40,readDevices:()=>{
    calls++;return calls===1?Promise.resolve(initial):new Promise(resolve=>release=resolve);
  }});
  const g=await f.issue(), r=await f.read(g.body.token,'events'), reader=r.body.getReader();await reader.read();
  f.api.notify();await new Promise(resolve=>setTimeout(resolve,110));
  const responses=await Promise.all(Array.from({length:8},()=>f.read(g.body.token)));
  assert.ok(responses.every(response=>response.status===503));
  assert.equal(calls,2);assert.equal((await reader.read()).done,true);
  assert.equal((await f.read(g.body.token)).status,503);assert.equal(calls,2);
  f.advance(600001);release(initial);assert.equal((await f.read(g.body.token)).status,401);
});

test('snapshot consumer capacity is bounded and disconnected readers free slots',async t=>{
  let calls=0,release;
  const f=await fixture(t,{readTimeoutMs:1000,readDevices:()=>{calls++;return new Promise(resolve=>release=resolve);}});
  const g=await f.issue(), controllers=Array.from({length:16},()=>new AbortController());
  const requests=controllers.map(controller=>f.call(prefix+'devices',{signal:controller.signal,
    headers:{Origin:pages,Authorization:'Bearer '+g.body.token}}).catch(()=>null));
  await new Promise(resolve=>setTimeout(resolve,60));
  assert.equal((await f.read(g.body.token)).status,429);assert.equal(calls,1);
  controllers[0].abort();await new Promise(resolve=>setTimeout(resolve,30));
  const replacement=f.read(g.body.token);await new Promise(resolve=>setTimeout(resolve,30));release(initial);
  assert.equal((await replacement).status,200);assert.equal(calls,1);
  assert.equal((await Promise.all(requests)).filter(Boolean).length,15);
});
