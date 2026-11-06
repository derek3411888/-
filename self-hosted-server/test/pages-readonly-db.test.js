import test from 'node:test';
import assert from 'node:assert/strict';
import { createPagesDeviceReader } from '../src/pages-readonly-db.js';

test('pilot uses isolated single connection with real server statement deadline and fixed SQL',async()=>{
  let config, sql, params, ended=false;
  class Pool {
    constructor(options){config=options;}
    on(){}
    async query(text, values){sql=text;params=values;return {rows:[{uid:'allowed'}]};}
    async end(){ended=true;}
  }
  const reader=createPagesDeviceReader('unit-only',Pool);
  assert.equal(config.max,1);assert.equal(config.statement_timeout,3000);
  assert.equal(config.query_timeout,4000);assert.equal(config.connectionTimeoutMillis,2000);
  assert.equal(config.application_name,'wuthering-pages-readonly');
  assert.deepEqual(await reader.read(['allowed']),[{uid:'allowed'}]);
  assert.match(sql,/WHERE d.uid=ANY\(\$1::text\[\]\)/);assert.deepEqual(params,[['allowed']]);
  await reader.close();assert.equal(ended,true);
});
