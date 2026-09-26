import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import assert from "node:assert/strict";

const root = path.resolve(import.meta.dirname, "..");
const runtime = process.env.GM_PLAYWRIGHT_MODULE;
if (!runtime) throw new Error("Set GM_PLAYWRIGHT_MODULE to an installed Playwright entrypoint; no dependency download is performed");
const { chromium } = await import(pathToFileURL(runtime).href);
const output = path.join(root, ".dev-runtime", "diagnostics", "game-maintenance", "browser");
await fs.mkdir(output, { recursive: true });
const fixture = `<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/styles.css"><style>body{margin:0;padding:16px;box-sizing:border-box}main{max-width:1100px;margin:auto}input[type=checkbox]{width:auto}</style></head><body><main><h1>測試資料・版本維護</h1><section id="card" class="card game-maintenance"></section><section id="settings" class="card game-maintenance"></section></main><script type="module">
import {attachMaintenanceUI} from '/game-maintenance-view.js';
window.calls=[];window.input={uid:'fixture',deviceFresh:true,effectiveSettings:{maintenanceEnabled:true},ack:{},value:{schemaVersion:1,capabilityVersion:1,phase:'WAIT_OPEN',provider:'steam',eventId:'fixture-1',observedAt:Date.now(),observedUtcNow:Date.now(),expectedOpenAt:Date.now()+120000,checkedAt:Date.now(),detail:'官方公告仍在維護，等待開服後確認更新。'.repeat(20),sourceUrl:'https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5280'}};
window.ui=attachMaintenanceUI({card:document.getElementById('card'),settingsRoot:document.getElementById('settings'),onSave:async(patch,uid)=>{calls.push({patch,uid});return {revision:4};}});ui.update(input);window.ready=true;
</script></body></html>`;
let skin = "self-hosted-server/public";
const server = http.createServer(async (req, res) => {
  try {
    const name = new URL(req.url, "http://localhost").pathname;
    if (name === "/") { res.setHeader("Content-Type", "text/html; charset=utf-8"); res.end(fixture); }
    else if (["/game-maintenance-view.js", "/styles.css"].includes(name)) {
      res.setHeader("Content-Type", name.endsWith(".js") ? "text/javascript; charset=utf-8" : "text/css; charset=utf-8");
      res.end(await fs.readFile(path.join(root, skin, name.slice(1))));
    } else { res.statusCode = 404; res.end(); }
  } catch (error) { res.statusCode = 500; res.end(String(error)); }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
let context;
try {
  context = await chromium.launchPersistentContext(path.join(output, "profile"), { channel: "msedge", headless: true,
    viewport: { width: 390, height: 844 }, downloadsPath: path.join(output, "downloads") });
  await context.route("**/*", (route) => route.request().url().startsWith(origin) ? route.continue() : route.abort());
  const page = context.pages()[0];
  const errors = []; page.on("pageerror", (error) => errors.push(error.message));
  for (const website of ["self-hosted-server/public", "remote-control-web"]) {
    skin = website;
    for (const [label, width, height, zoom] of [["mobile",390,844,1],["desktop",1920,1080,1],["desktop125",1920,1080,1.25],["desktop150",1920,1080,1.5]]) {
      await page.setViewportSize({ width, height });
      await page.goto(origin);
      await page.waitForFunction(() => window.ready === true);
      await page.evaluate((ratio) => { document.body.style.zoom = ratio; }, zoom);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, `${website}/${label}: no horizontal overflow`);
      await page.screenshot({ path: path.join(output, `${website.startsWith("self") ? "self" : "company"}-${label}.png`), fullPage: true });
    }
    await page.getByRole("checkbox").uncheck();
    await page.getByRole("button", { name: "儲存維護開關" }).click();
    await page.waitForFunction(() => document.querySelector('[role="status"]').textContent.includes("已送出"));
    assert.equal(await page.getByRole("button", { name: "儲存維護開關" }).isDisabled(), true);
    assert.deepEqual(await page.evaluate(() => calls), [{ patch: { maintenanceEnabled: false }, uid: "fixture" }]);
    await page.evaluate(() => { input.ack = {desiredRevision:4,ackRevision:4,effectiveRevision:3,applied:false,detail:"測試拒絕"};ui.update(input); });
    assert.ok((await page.getByRole("status").textContent()).includes("拒絕"));
    assert.equal(await page.getByRole("checkbox").isChecked(), false, "draft preserved after rejection");
    await page.evaluate(() => { input.effectiveSettings.maintenanceEnabled=false;input.ack={desiredRevision:4,ackRevision:4,effectiveRevision:4,applied:true};ui.update(input); });
    assert.ok((await page.getByRole("status").textContent()).includes("已套用"));
    await page.evaluate(() => { input.deviceFresh=false;ui.update(input); });
    assert.equal(await page.getByRole("button", { name: "重新查詢公告" }).isDisabled(), true);
    await page.evaluate(() => {
      input = { uid: 'future-fixture', deviceFresh: true, effectiveSettings: {maintenanceEnabled:true}, ack: {},
        value: { schemaVersion:1, capabilityVersion:1, phase:'NORMAL', eventId:'', provider:'kuro', sourceState:'valid',
          observedAt:Date.now(), observedUtcNow:Date.now(), checkedAt:Date.now(), upcomingNotice:{
            eventId:'wuthering-global-3.7-1790712000', gameVersion:'3.7', startsAt:1790712000000,
            expectedOpenAt:1790737200000, sourceUrl:'https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5474'} } };
      ui.update(input);
    });
    assert.equal(await page.getByRole("link", { name: "查看下一次官方維護公告" }).isVisible(), true);
    assert.ok((await page.locator('#card').textContent()).includes('3.7'));
    assert.ok((await page.locator('#card').textContent()).includes('2026/9/30'));
    assert.equal(await page.getByRole('button', { name: '只略過本次時間等待' }).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: '套用延後時間' }).isDisabled(), true);
    for (const [label, width, height] of [['mobile',390,844],['desktop',1920,1080]]) {
      await page.setViewportSize({width,height});
      await page.evaluate(() => { document.body.style.zoom = 1; });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, `${website}/${label}: future preview stays within viewport`);
      await page.screenshot({path:path.join(output,`${website.startsWith('self') ? 'self' : 'company'}-upcoming-${label}.png`),fullPage:true});
    }
    await page.evaluate(() => { input.value.sourceState='unavailable';ui.update(input); });
    assert.ok((await page.locator('#card').textContent()).includes('公告查詢失敗；以下為上次已知公告'));
  }
  assert.deepEqual(errors, []);
  await fs.writeFile(path.join(output, "result.json"), JSON.stringify({ passed: true, layouts: 12, interactions: ["pending", "rejected", "applied", "offline", "draft-preserved", "upcoming-preview", "no-early-skip-or-delay", "source-failure-retains-preview"], zoomMethod: "CSS layout zoom 1.25/1.5; headless Edge", externalRequestsAllowed: false }, null, 2));
  console.log("PASS: both skins, 12 layouts, future preview, source failure, revision ACK transitions, offline guard, preserved draft; all network restricted to fixture server");
} finally { await context?.close(); await new Promise((resolve) => server.close(resolve)); }
