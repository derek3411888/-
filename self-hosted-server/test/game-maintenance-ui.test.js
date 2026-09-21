import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
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
  assert.equal(maintenanceViewModel({ ...sample, phase: "NORMAL", eventId: "" }, now, true).visible, false);
  assert.equal(maintenanceViewModel({ ...sample, phase: "WAIT_NOTICE" }, now, true).canClaimReady, false);
  assert.equal(maintenanceViewModel({ ...sample, phase: "WAIT_OPEN" }, now + 1000, true).remainingSeconds, 119);
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
