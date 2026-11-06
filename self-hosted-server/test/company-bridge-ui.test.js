import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
const source = await fs.readFile(new URL('../../remote-control-web/company-bridge-client.js', import.meta.url), 'utf8');
const {companyView, assertCompanyReady, companyRequestUpdate, companyRequestStatus} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const uid='MYTUFPC_4e8bb5ec68f3', now=1793934000000;
const raw=()=>({state:'STOP',nonce:3,controlSecret:'never', companyBridge:{version:1,enabled:true,epoch:'new',heartbeatAt:now}, companySnapshot:{uid,state:'RUN',online:true,lastHeartbeat:now,nonce:149,desiredSettingsRevision:4}, companyRequest:null});
test('company view never merges old legacy fields into authoritative snapshot',()=>{
 const view=companyView(raw()); assert.equal(view.state,'RUN');assert.equal(view.nonce,149);assert.equal(view.controlSecret,undefined);
 assert.equal(companyView({...raw(),companySnapshot:null}).state,'OFFLINE');
});
test('requests write only companyRequest, no local nonce or settings revision allocation',()=>{
 const update=companyRequestUpdate(uid,raw(),{id:'test-id',kind:'command',payload:{command:'PAUSE'}},()=>({sentinel:'serverTimestamp'}),now);
 assert.deepEqual(Object.keys(update),['companyRequest']);
 assert.equal(update.companyRequest.expectedNonce,149);assert.equal(update.companyRequest.expectedRevision,4);assert.equal(update.companyRequest.epoch,'new');
 assert.deepEqual(update.companyRequest.createdAt,{sentinel:'serverTimestamp'});
});
test('stale/disabled/wrong uid/offline/pending bridge fails closed, same request can retry',()=>{
 for(const changed of [{companyBridge:{...raw().companyBridge,heartbeatAt:now-150001}},{companyBridge:{...raw().companyBridge,enabled:false}},{companySnapshot:{...raw().companySnapshot,lastHeartbeat:now-300001,online:false}}]) assert.throws(()=>assertCompanyReady(uid,companyView({...raw(),...changed}),now));
 assert.throws(()=>assertCompanyReady('other',companyView(raw()),now));
 const pending={...raw(),companyRequest:{id:'old',kind:'command'}};
 assert.throws(()=>companyRequestUpdate(uid,pending,{id:'new'},()=>now,now));
 assert.equal(companyRequestUpdate(uid,pending,{id:'old',kind:'command',payload:{}},()=>now,now).companyRequest.id,'old');
});
test('bridge receipt is not device ACK and rejection is visible',()=>{
 let data=companyView({...raw(),companyRequest:{id:'request',kind:'command'}});
 assert.equal(companyRequestStatus(data).state,'waiting');
 data.companyReceipt={id:'request',status:'REJECTED',code:'COMPANY_STALE_BASELINE'};
 assert.equal(companyRequestStatus(data).state,'rejected');
 data.companyReceipt={id:'request',status:'ACCEPTED',nonce:150};
 assert.equal(companyRequestStatus(data).state,'waiting');
 data.commandHistory=[{commandNonce:150}];
 assert.equal(companyRequestStatus(data),null);
});

test('real company settings handler writes only versioned request and preserves maintenance fields', async()=>{
 const app=await fs.readFile(new URL('../../remote-control-web/app.js',import.meta.url),'utf8');
 const fn=app.match(/async function saveRemoteSettings\([^]*?\n\}/)[0];
 const document=raw(); document.companyBridge.heartbeatAt=Date.now();
 Object.assign(document.companySnapshot,{lastHeartbeat:Date.now(),remoteSettingsSchemaVersion:1,lastSettingsAckRevision:4,effectiveSettingsRevision:4,
   effectiveMaintenanceEnabled:false,effectiveMaintenanceDelayUntilUtc:0,effectiveLiveQualityProfile:'balanced'});
 const writes=[];
 const context=vm.createContext({ Date,Math,Object,String,Number,Error, crypto:{randomUUID:()=> 'test-id'},
   companyView,assertCompanyReady,companyRequestUpdate,companyRequestStatus,serverTimestamp:()=>123,
   pcDropdown:{value:uid}, selectedClientData:()=>companyView(document), readField:(d,k,f)=>d[k]??f,
   validateSettingsForm:()=>({serverScheduleList:['Asia'],serverScheduleEnabled:true,mailNotifyEnabled:true,runtimeDiagnosticsEnabled:true,
     runtimeDiagnosticsIntervalSec:60,runtimeDiagnosticsErrorKeepCount:30,maxRestartCount:10}),
   assertFirestoreControlWritable:()=>{},toInteger:(v,f)=>Number(v)||f,SETTINGS_SCHEMA_VERSION:1,
   MAINTENANCE_SETTING_KEYS:['maintenanceEnabled','maintenanceDelayUntilUtc','maintenanceOverrideEventId','maintenanceSkipEventId','maintenanceRefreshRequestId'],
   db:{},COLLECTION:'ahk_clients',doc:()=>({}),cache:new Map(),renderSettingsPage:()=>{},renderSelectedClient:()=>{},
   settingsSaving:false,settingsError:'',settingsDirty:true,settingsPreferEffective:false,settingsFormSourceKey:'',
   runTransaction:async(_db,callback)=>callback({get:async()=>({exists:()=>true,data:()=>document}),update:(_ref,patch)=>writes.push(patch)}),
 });
 vm.runInContext(fn,context);
 const result=await context.saveRemoteSettings({preventDefault(){}});
 assert.equal(writes.length,1,context.settingsError);
 assert.deepEqual(Object.keys(writes[0]),['companyRequest']);
 assert.equal(writes[0].companyRequest.payload.maintenanceEnabled,false);
 assert.equal(writes[0].companyRequest.payload.serverScheduleList,'Asia');
 assert.equal(result.revision,null);
});
