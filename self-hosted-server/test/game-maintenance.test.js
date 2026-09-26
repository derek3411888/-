import test from "node:test";
import assert from "node:assert/strict";
import { normalizeGameMaintenance } from "../src/game-maintenance.js";

const now = 1770000001000;
const sample = { schemaVersion: 1, capabilityVersion: 1, phase: "UPDATING", provider: "steam",
  progressPercent: null, observedAt: 1770000000000, observedUtcNow: 1770000000000 };
test("maintenance status keeps unknown progress distinct from zero and rejects unsafe contracts", () => {
  const result = normalizeGameMaintenance(sample, now);
  assert.equal(result.progressPercent, null);
  assert.equal(result.phase, "UPDATING");
  assert.equal(normalizeGameMaintenance({ ...sample, progressPercent: 0 }, now).progressPercent, 0);
  for (const value of [null, [], "bad", { ...sample, phase: "invented" }, { ...sample, capabilityVersion: 2 },
    { ...sample, observedAt: now + 6000 }, { ...sample, observedAt: "1770000000000" }]) {
    assert.equal(normalizeGameMaintenance(value, now), null);
  }
});
test("public maintenance status is bounded and contains neither local paths nor arbitrary links", () => {
  const result = normalizeGameMaintenance({ ...sample, detail: "C:\\private\\game.exe " + "維護".repeat(4000),
    sourceUrl: "javascript:alert(1)", launcherPath: "C:\\private", nonce: 99 }, now);
  assert.ok(Buffer.byteLength(JSON.stringify(result)) <= 4096);
  assert.equal(result.sourceUrl, "");
  assert.equal(result.launcherPath, undefined);
  assert.equal(result.nonce, undefined);
  assert.ok(!result.detail.includes("C:\\private"));
  assert.equal(normalizeGameMaintenance({ ...sample, sourceUrl: "https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5280" }, now).sourceUrl,
    "https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5280");
  assert.equal(normalizeGameMaintenance(JSON.stringify(sample), now).provider, "steam");
  assert.equal(normalizeGameMaintenance("x".repeat(5000), now), null);
});

test("upcoming announcement reaches the API without becoming the active maintenance event", () => {
  const upcomingNotice = { eventId: "wuthering-global-3.7-1790712000", gameVersion: "3.7",
    startsAt: 1790712000000, expectedOpenAt: 1790737200000,
    sourceUrl: "https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5474" };
  const value = { ...sample, phase: "NORMAL", sourceState: "valid", upcomingNotice };
  const result = normalizeGameMaintenance(value, now);
  assert.deepEqual(result.upcomingNotice, upcomingNotice);
  assert.equal(result.eventId, "");
  assert.equal(result.phase, "NORMAL");
  assert.equal(normalizeGameMaintenance(sample, now).upcomingNotice, null, "older clients remain compatible");
  assert.equal(normalizeGameMaintenance(sample, now).noticePreviewSupported, false, "absent field is not confirmed no announcement");
  assert.equal(result.noticePreviewSupported, true);
  for (const invalid of [{ ...upcomingNotice, sourceUrl: "https://evil.example" },
    { ...upcomingNotice, expectedOpenAt: upcomingNotice.startsAt - 1 },
    { ...upcomingNotice, gameVersion: "<script>" }, { ...upcomingNotice, startsAt: "1790712000000" }]) {
    assert.equal(normalizeGameMaintenance({ ...value, upcomingNotice: invalid }, now).upcomingNotice, null);
  }
});
