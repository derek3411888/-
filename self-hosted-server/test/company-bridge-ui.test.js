import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import { projectCompanySnapshot } from '../src/company-bridge.js';
const appSource = await fs.readFile(new URL('../../remote-control-web/app.js',import.meta.url),'utf8');
function functions(names) { return names.map(name => appSource.match(new RegExp(`(?:async )?function ${name}\\([^]*?\\n\\}`))[0]).join('\n'); }
function historyContext() {
 const context=vm.createContext({Date,Set,Math,String,Number,ACK_TIMEOUT_MS:30000,
  readField:(d,k,f)=>d[k]??f,toInteger:v=>Number(v)||0,toMillis:v=>Number(v)||0});
 vm.runInContext(functions(['normalizeCommandState','isServerTargetCommand','normalizeHistoryEntry','deriveHistoryEntry']),context);
 return context;
}
const source = await fs.readFile(new URL('../../remote-control-web/company-bridge-client.js', import.meta.url), 'utf8');
const {companyView, assertCompanyReady, companyRequestUpdate, companyRequestStatus} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const uid='MYTUFPC_4e8bb5ec68f3', now=1793934000000;
const raw=()=>({state:'STOP',nonce:3,controlSecret:'never', companyBridge:{version:1,enabled:true,epoch:'new',heartbeatAt:now}, companySnapshot:{uid,state:'RUN',online:true,lastHeartbeat:now,nonce:149,desiredSettingsRevision:4}, companyRequest:null});
test('heartbeat cursor ahead of precise ACK cannot mark a pending command successful',()=>{
 const snapshot=projectCompanySnapshot({device:{uid,state:'RUN',command_nonce:128,last_nonce:128},commands:[
  {nonce:128,command:'PAUSE',status:'PENDING',created_at:now},
  {nonce:127,command:'PAUSE',status:'ACKED',ack_result:'APPLIED',acked_at:now-1000}]});
 assert.equal(historyContext().deriveHistoryEntry(snapshot.commandHistory[0],snapshot,now).status,'WAITING_ACK');
 assert.equal(snapshot.lastAckNonce,127);
 const target=projectCompanySnapshot({device:{uid},commands:[{nonce:129,command:'SWITCH_SERVER',status:'ACKED',payload:{serverIndex:1,serverName:'HMT(HK,MO,TW)'},ack_payload:{serverIndex:2,serverName:'Asia'}}]});
 assert.equal(target.lastAckServerIndex,2);assert.equal(target.lastAckServerName,'Asia');
});
test('all rejected central ACK outcomes render as rejected, preserving completion semantics',()=>{
 const context=historyContext();
 for(const result of ['REJECTED','ERROR','NO_SERVER_CONFIG','INVALID_TARGET','CONFIG_CHANGED','ALREADY_CURRENT','BUSY','CONFIG_WRITE_FAILED','UNSUPPORTED_CLIENT','HANDLER_ERROR','NO_HANDLER','ALREADY_COMPLETED_TODAY']) {
  const snapshot=projectCompanySnapshot({device:{uid},commands:[{nonce:9,command:'SWITCH_SERVER',status:'ACKED',ack_result:result,created_at:now}]});
  assert.equal(context.deriveHistoryEntry(snapshot.commandHistory[0],snapshot,now).status,'REJECTED',result);
 }
 const snapshot=projectCompanySnapshot({device:{uid},commands:[{nonce:9,command:'COMPLETE_SERVER',status:'ACKED',ack_result:'ALREADY_COMPLETED_TODAY'}]});
 assert.equal(context.deriveHistoryEntry(snapshot.commandHistory[0],snapshot,now).status,'ACKED');
});
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

function settingsHarness() {
 const document=raw(); document.companyBridge.heartbeatAt=Date.now();
 Object.assign(document.companySnapshot,{lastHeartbeat:Date.now(),remoteSettingsSchemaVersion:1,lastSettingsAckRevision:4,effectiveSettingsRevision:4,
  effectiveMailNotifyEnabled:true,effectiveServerScheduleEnabled:true,effectiveServerScheduleList:'Asia',effectiveMaxRestartCount:10});
 const writes=[],summary={textContent:'previous device'};
 const context=vm.createContext({Date,Set,Math,Object,String,Number,Boolean,Error,crypto:{randomUUID:()=> 'test-id'},
  companyView,assertCompanyReady,companyRequestUpdate,companyRequestStatus,serverTimestamp:()=>123,
  pcDropdown:{value:uid},selectedClientData:()=>companyView(document),readField:(d,k,f)=>d[k]??f,
  toInteger:(v,f)=>Number.isFinite(Number(v))?Number(v):f,toBoolean:(v,f=false)=>v??f,toMillis:v=>Number(v)||0,
  SETTINGS_SCHEMA_VERSION:1,MAX_REMOTE_SERVERS:5,SUPPORTED_SERVERS:['Asia','HMT(HK,MO,TW)'],MAINTENANCE_SETTING_KEYS:[],
  canonicalServerSchedule:s=>String(s).split('|').map(x=>x.trim()).filter(Boolean),currentServerOrderValues:()=>['Asia'],renderSettingsServerRows:()=>{},
  settingsServerEnabled:{checked:true},settingsMailEnabled:{checked:true},settingsDiagnosticsEnabled:{checked:true},
  settingsDiagnosticsInterval:{value:'60'},settingsDiagnosticsKeepCount:{value:'30'},settingsMaxRestartCount:{value:'10'},
  settingsSaving:false,settingsError:'',settingsDirty:false,settingsPreferEffective:false,settingsFormSourceKey:'',settingsFormClientId:'',
  db:{},COLLECTION:'ahk_clients',doc:()=>({}),cache:new Map(),renderSettingsPage:()=>{},renderSelectedClient:()=>{},
  document:{getElementById:()=>summary},setSettingsStatus:()=>{},isClientOnline:()=>true,fmtTs:()=>'',
  runTransaction:async(_db,cb)=>cb({get:async()=>({exists:()=>true,data:()=>document}),update:(_ref,p)=>writes.push(p)})});
 vm.runInContext(functions(['readRemoteSettings','settingsSourceKey','populateSettingsForm','validateSettingsForm','assertFirestoreControlWritable','saveRemoteSettings','renderSettingsStatus']),context);
 context.populateSettingsForm(context.readRemoteSettings(companyView(document)),uid);
 return {context,document,writes,summary};
}
test('unknown company SMTP capability permits preserving enabled mail, not falsely disabling it',async()=>{
 const {context,writes,document}=settingsHarness();
 const result=await context.saveRemoteSettings({preventDefault(){}});
 assert.equal(writes.length,1,context.settingsError);assert.equal(result.revision,null);
 assert.equal(writes[0].companyRequest.payload.mailNotifyEnabled,true);
 document.companySnapshot.effectiveMailNotifyEnabled=false;
 assert.throws(()=>context.validateSettingsForm(companyView(document)),/SMTP/);
 document.companySnapshot.mailNotifyConfigured=false;
 document.companySnapshot.effectiveMailNotifyEnabled=true;
 assert.throws(()=>context.validateSettingsForm(companyView(document)),/SMTP/);
});
test('dirty company form keeps its original baseline and refuses a newer acknowledged revision',async()=>{
 const {context,writes,document}=settingsHarness(); document.companySnapshot.mailNotifyConfigured=true;
 context.settingsDirty=true;context.settingsMaxRestartCount.value='12';
 Object.assign(document.companySnapshot,{desiredSettingsRevision:5,effectiveSettingsRevision:5,lastSettingsAckRevision:5,effectiveServerScheduleEnabled:false});
 await context.saveRemoteSettings({preventDefault(){}});
 assert.equal(writes.length,0);assert.match(context.settingsError,/設定.*變更|重新載入/);
 assert.equal(context.settingsDirty,true);
});
test('pending company settings refresh effective summary when selecting another device',()=>{
 const {context,document,summary}=settingsHarness();
 document.companyRequest={id:'pending',kind:'settings'};
 context.renderSettingsStatus();
 assert.match(summary.textContent,/revision 4/);assert.match(summary.textContent,/Asia/);
});

test('real company settings handler writes only versioned request and preserves maintenance fields', async()=>{
 const {context,document,writes}=settingsHarness();
 context.MAINTENANCE_SETTING_KEYS=['maintenanceEnabled','maintenanceDelayUntilUtc','maintenanceOverrideEventId','maintenanceSkipEventId','maintenanceRefreshRequestId'];
 Object.assign(document.companySnapshot,{effectiveMaintenanceEnabled:false,effectiveMaintenanceDelayUntilUtc:0,effectiveLiveQualityProfile:'balanced'});
 const result=await context.saveRemoteSettings({preventDefault(){}});
 assert.equal(writes.length,1,context.settingsError);
 assert.deepEqual(Object.keys(writes[0]),['companyRequest']);
 assert.equal(writes[0].companyRequest.payload.maintenanceEnabled,false);
 assert.equal(writes[0].companyRequest.payload.serverScheduleList,'Asia');
 assert.equal(result.revision,null);
});
