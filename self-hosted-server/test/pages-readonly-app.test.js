import test from 'node:test';
import assert from 'node:assert/strict';
// Isolated module test; no production database or credentials are used.
for (const key of ['SESSION_SECRET','CODEX_BRIDGE_TOKEN','LIVE_TOKEN_SECRET','LIVE_SRT_PASSPHRASE']) process.env[key]='unit-test-only-not-a-production-secret';
process.env.DATABASE_URL='postgres://test:test@127.0.0.1:1/not_used';
process.env.PAGES_READONLY_ENABLED='false';
const { handleRequest } = await import('../src/app.js');

test('actual app routes reject pilot capabilities before ordinary anonymous control middleware',async()=>{
  for(const url of ['/api/v1/devices','/api/v1/events','/api/v1/codex-support','/api/v1/admin/migration','/api/v1/devices/MYTUFPC_4e8bb5ec68f3/commands']) {
    await assert.rejects(handleRequest({url,method:'POST',headers:{authorization:'Bearer pr_'+'a'.repeat(43)}},{}),error=>error.status===403&&error.code==='PILOT_SCOPE_ONLY');
  }
});
test('actual app feature defaults off before session and database work',async()=>{
  await assert.rejects(handleRequest({url:'/api/v1/pages-readonly/grants',method:'POST',headers:{}},{}),error=>error.status===404);
});
