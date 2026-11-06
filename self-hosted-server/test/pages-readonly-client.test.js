import test from 'node:test';
import assert from 'node:assert/strict';
import fsp from 'node:fs/promises';
import vm from 'node:vm';
const source=await fsp.readFile(new URL('../../remote-control-web/tunnel-readonly/app.js',import.meta.url),'utf8');
const {createHandshake,createSseParser,createPilotSession}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
const api='https://ww.sckang.cc', popup={},nonce='a'.repeat(64);
const grant={token:'pr_'+'a'.repeat(43),issuedAt:1000,expiresAt:601000};
test('handshake rejects foreign source origin nonce and unsolicited/replayed grants',()=>{
  const h=createHandshake({popup,nonce,now:()=>1000});
  const message=data=>({origin:api,source:popup,data});
  assert.equal(h.receive(message({type:'grant',nonce,...grant})),undefined);
  for(const e of [{origin:'https://evil.test',source:popup,data:{type:'ready'}},{origin:api,source:{},data:{type:'ready'}}]) assert.equal(h.receive(e),undefined);
  assert.deepEqual(h.receive(message({type:'ready'})),{type:'challenge',nonce});
  assert.equal(h.receive(message({type:'grant',nonce:'b'.repeat(64),...grant})),undefined);
  assert.deepEqual(h.receive(message({type:'grant',nonce,...grant})),{type:'accepted',grant});
  assert.equal(h.receive(message({type:'grant',nonce,...grant})),undefined);
});
test('expired overlong and cancelled grants are never accepted',()=>{
  for(const change of [{expiresAt:1000},{expiresAt:701000},{token:'invalid'}]) {
    const h=createHandshake({popup,nonce,now:()=>1000});h.receive({origin:api,source:popup,data:{type:'ready'}});
    assert.equal(h.receive({origin:api,source:popup,data:{type:'grant',nonce,...grant,...change}}),undefined);
  }
  const h=createHandshake({popup,nonce,now:()=>1000});h.cancel();
  assert.equal(h.receive({origin:api,source:popup,data:{type:'ready'}}),undefined);
});
test('SSE parser handles split UTF8 CRLF and rejects oversized frames',()=>{
  const result=[],p=createSseParser(v=>result.push(v));
  for(const byte of new TextEncoder().encode('event: devices\r\ndata: {"text":"桌機"}\r\n\r\n'))p.feed(new Uint8Array([byte]));
  assert.deepEqual(result,[{event:'devices',data:'{"text":"桌機"}'}]);
  assert.throws(()=>p.feed(new TextEncoder().encode('x'.repeat(65537))),/TOO_LARGE/);
});
test('session uses only fixed read stream bearer in memory and stops on expiry',async()=>{
  let timer,options,request,resolveFetch;
  const states=[],devices=[];
  const s=createPilotSession({clock:()=>1000,setTimer:(fn,ms)=>{if(ms===600000)timer=fn;return 1;},clearTimer:()=>{},
    fetcher:(url,opts)=>{request=url;options=opts;return new Promise(resolve=>resolveFetch=resolve);},
    onDevices:v=>devices.push(v),onConnection:v=>states.push(v)});
  s.connect(grant);await Promise.resolve();
  assert.equal(request,api+'/api/v1/pages-readonly/events');assert.equal(options.credentials,'omit');
  assert.equal(options.headers.Authorization,'Bearer '+grant.token);assert.ok(!request.includes(grant.token));
  timer();assert.equal(options.signal.aborted,true);assert.equal(states.at(-1),'expired');
  resolveFetch(new Response('event: devices\ndata: {"devices":[]}\n\n',{headers:{'Content-Type':'text/event-stream'}}));
  await new Promise(resolve=>setTimeout(resolve,10));assert.equal(devices.length,0);
});
test('disconnect retains snapshot as stale and does not renew grants or submit commands',async()=>{
  const states=[],requests=[];
  const s=createPilotSession({clock:()=>1000,setTimer:()=>1,clearTimer:()=>{},onDevices:()=>{},onConnection:v=>states.push(v),
    fetcher:async(url,options)=>{requests.push({url,method:options.method});throw new Error('offline');}});
  s.connect(grant);await new Promise(resolve=>setTimeout(resolve,10));s.stop();
  assert.ok(states.includes('stale'));assert.equal(requests.length,1);assert.equal(requests[0].method,'GET');
});

test('keepalives do not extend snapshot freshness; stalled data becomes stale and aborts',async()=>{
  const timers=new Map(), states=[];let sequence=0,writer,signal;
  const s=createPilotSession({clock:()=>1000,setTimer:(fn,ms)=>{const id=++sequence;timers.set(id,{fn,ms});return id;},
    clearTimer:id=>timers.delete(id),onDevices:()=>{},onConnection:value=>states.push(value),
    fetcher:async(url,opts)=>{signal=opts.signal;return new Response(new ReadableStream({start(c){writer=c;}}),
      {headers:{'Content-Type':'text/event-stream'}});}});
  s.connect(grant);await new Promise(resolve=>setTimeout(resolve,5));
  writer.enqueue(new TextEncoder().encode('event: devices\ndata: {"devices":[]}\n\n'));
  await new Promise(resolve=>setTimeout(resolve,5));assert.equal(states.at(-1),'live');
  const freshness=[...timers].find(([,timer])=>timer.ms===45000);assert.ok(freshness);
  writer.enqueue(new TextEncoder().encode(': keepalive\n\n'));await new Promise(resolve=>setTimeout(resolve,5));
  assert.equal(timers.get(freshness[0]),freshness[1]);freshness[1].fn();
  assert.equal(states.at(-1),'stale');assert.equal(signal.aborted,true);s.stop();writer.close();
});
test('actual authorize page only enables correct opener challenge and delivers once to fixed origin',async()=>{
  const script=await fsp.readFile(new URL('../public/pages-readonly-authorize.js',import.meta.url),'utf8');
  const handlers={},clicks={},sent=[],calls=[];
  const opener={postMessage:(message,target)=>sent.push({message,target})};
  const nodes=Object.fromEntries(['status','allow','revoke'].map(id=>[id,{disabled:id==='allow',addEventListener:(type,fn)=>clicks[id]=fn}]));
  vm.runInNewContext(script,{window:{opener,addEventListener:(type,fn)=>handlers[type]=fn},location:{origin:api},
    document:{getElementById:id=>nodes[id]},Date,AbortSignal,setTimeout:()=>1,
    fetch:async(url,options)=>{calls.push({url,options});return {ok:true,json:async()=>grant};}});
  assert.deepEqual(JSON.parse(JSON.stringify(sent)),[{message:{type:'ready'},target:'https://derek3411888.github.io'}]);
  for(const e of [{source:{},origin:'https://derek3411888.github.io'},{source:opener,origin:'https://evil.test'}])handlers.message({...e,data:{type:'challenge',nonce}});
  assert.equal(nodes.allow.disabled,true);await clicks.allow();assert.equal(calls.length,0);
  handlers.message({source:opener,origin:'https://derek3411888.github.io',data:{type:'challenge',nonce}});
  assert.equal(nodes.allow.disabled,false);await clicks.allow();await clicks.allow();
  assert.equal(calls.length,1);assert.equal(calls[0].url,'/api/v1/pages-readonly/grants');
  assert.equal(calls[0].options.credentials,'same-origin');assert.equal(calls[0].options.headers['X-Wuthering-CSRF'],'1');
  assert.equal(sent.at(-1).target,'https://derek3411888.github.io');assert.equal(sent.at(-1).message.nonce,nonce);
});
