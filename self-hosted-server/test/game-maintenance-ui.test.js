import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { maintenanceViewModel, maintenanceSettingsAck, buildMaintenancePatch } from "../public/game-maintenance-view.js";

const now = 1770000000000;
const sample = { schemaVersion: 1, capabilityVersion: 1, phase: "UPDATING", provider: "steam", eventId: "event-1",
  progressPercent: null, expectedOpenAt: now + 120000, observedAt: now, observedUtcNow: now };
test("updating is not farming, unknown progress is not zero and stale state cannot be operated", () => {
  const model = maintenanceViewModel(sample, now, true);
  assert.equal(model.progressText, "進度未知");
  assert.equal(model.canClaimReady, false);
  assert.equal(model.canOperate, true);
  assert.equal(maintenanceViewModel(sample, now, false).canOperate, false);
  assert.equal(maintenanceViewModel(sample, now + 180001, true).stale, true);
  assert.equal(maintenanceViewModel({}, now, true).supported, false);
  assert.equal(maintenanceViewModel({ ...sample, phase: "NORMAL", eventId: "" }, now, true).visible, true);
  assert.equal(maintenanceViewModel({ ...sample, phase: "WAIT_NOTICE" }, now, true).canClaimReady, false);
  assert.equal(maintenanceViewModel({ ...sample, phase: "WAIT_OPEN" }, now + 1000, true).remainingSeconds, 119);
});

test("announced future maintenance is visible without enabling skip/delay or claiming today is blocked", () => {
  const today = 1790380800000;
  const value = { ...sample, phase: "NORMAL", eventId: "", sourceState: "valid", checkedAt: today,
    observedAt: today, upcomingNotice: { eventId: "wuthering-global-3.7-1790712000", gameVersion: "3.7",
      startsAt: 1790712000000, expectedOpenAt: 1790737200000,
      sourceUrl: "https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5474" } };
  const model = maintenanceViewModel(value, today, true);
  assert.equal(model.visible, true);
  assert.equal(model.noticeSummary, "已公告下次維護；今天照常執行");
  assert.equal(model.upcomingNotice.gameVersion, "3.7");
  assert.equal(model.eventId, "");
  assert.throws(() => buildMaintenancePatch("skip", model, {}, today));
  assert.throws(() => buildMaintenancePatch("delay", model, { until: today + 3600000 }, today));
  assert.equal(maintenanceViewModel({ ...value, sourceState: "unavailable" }, today, true).noticeSummary,
    "公告查詢失敗；以下為上次已知公告");
  assert.equal(maintenanceViewModel({ ...value, upcomingNotice: null }, today, true).noticeSummary,
    "今日無維護；尚無下一次維護公告");
  assert.equal(maintenanceViewModel({ ...value, upcomingNotice: null, sourceState: "unavailable" }, today, true).noticeSummary,
    "公告查詢失敗，無法確認維護安排");
  assert.equal(maintenanceViewModel({ ...value, checkedAt: today - 86400000 }, today, true).noticeSummary,
    "公告資料待更新；以下為上次已知公告");
  assert.equal(maintenanceViewModel({ ...value, upcomingNotice: { ...value.upcomingNotice, sourceUrl: "javascript:alert(1)" } }, today, true).upcomingNotice, null);
  const legacy = { ...value }; delete legacy.upcomingNotice;
  assert.equal(maintenanceViewModel(legacy, today, true).noticeSummary, "今日無維護；裝置版本尚未回報下一次公告");
  assert.equal(maintenanceViewModel({ ...legacy, upcomingNotice:null, noticePreviewSupported:false }, today, true).noticeSummary,
    "今日無維護；裝置版本尚未回報下一次公告", "API normalization must not invent legacy preview support");
});
test("maintenance settings UI distinguishes pending, ACKed and rejected, not HTTP success", () => {
  assert.equal(maintenanceSettingsAck({ desiredRevision: 4, ackRevision: 3, effectiveRevision: 3 }).kind, "pending");
  assert.equal(maintenanceSettingsAck({ desiredRevision: 4, ackRevision: 4, effectiveRevision: 3, applied: false }).kind, "rejected");
  assert.equal(maintenanceSettingsAck({ desiredRevision: 4, ackRevision: 4, effectiveRevision: 4, applied: true }).kind, "applied");
  assert.equal(maintenanceSettingsAck({ desiredRevision: 4, ackRevision: 4, effectiveRevision: 3, applied: true }).kind, "pending");
});
test("maintenance actions do not accidentally change timing with the enabled checkbox", () => {
  const model = maintenanceViewModel(sample, now, true);
  assert.deepEqual(buildMaintenancePatch("enabled", model, { enabled: false }, now), { maintenanceEnabled: false });
  assert.deepEqual(buildMaintenancePatch("delay", model, { until: now + 3600000 }, now),
    { maintenanceOverrideEventId: "event-1", maintenanceDelayUntilUtc: now + 3600000 });
  assert.deepEqual(buildMaintenancePatch("skip", model, {}, now), { maintenanceSkipEventId: "event-1" });
  assert.throws(() => buildMaintenancePatch("delay", model, { until: now - 1 }, now));
  assert.throws(() => buildMaintenancePatch("skip", maintenanceViewModel(sample, now, false), {}, now));
  assert.equal(maintenanceViewModel({ ...sample, sourceUrl: "javascript:alert(1)" }, now, true).sourceUrl, "");
  assert.equal(maintenanceViewModel({ ...sample, sourceUrl: "https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5280" }, now, true).sourceUrl,
    "https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5280");
});
test("both website maintenance modules are byte-identical", async () => {
  const original = await readFile(new URL("../public/game-maintenance-view.js", import.meta.url));
  const company = await readFile(new URL("../../remote-control-web/game-maintenance-view.js", import.meta.url));
  assert.deepEqual(company, original);
});
test("every relative browser module import has an explicit JavaScript HTTP route", async () => {
  const appSource = await readFile(new URL("../src/app.js", import.meta.url), "utf8");
  const mapSource = appSource.match(/const staticFiles = new Map\(\[.*?\]\);/s)?.[0];
  assert.ok(mapSource, "static asset routing map must exist");
  const routes = vm.runInNewContext(`${mapSource}; staticFiles`);
  const browserSource = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const imports = [...browserSource.matchAll(/from\s+["'](\.\/[^"']+)["']/g)].map((match) => match[1]);
  assert.ok(imports.length > 0);
  for (const imported of imports) {
    const pathname = new URL(imported, "https://fixture.invalid/app.js").pathname;
    assert.ok(routes.has(pathname), `Browser import is not served: ${pathname}`);
    assert.match(routes.get(pathname)[1], /^text\/javascript/);
  }
});
