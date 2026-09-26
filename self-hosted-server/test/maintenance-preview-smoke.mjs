// Scoped post-deploy acceptance. Never changes real devices or global settings.
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { query, closeDatabase } from "../src/db.js";
import { maintenanceViewModel } from "../public/game-maintenance-view.js";

const base = "http://127.0.0.1:3000";
const uid = `smoke-device-maintenance-${crypto.randomUUID()}`;
const deviceToken = crypto.randomBytes(48).toString("base64url");
let cookie = "";
async function json(path, options = {}) {
  const response = await fetch(`${base}${path}`, options);
  assert.equal(response.ok, true, `${path}: HTTP ${response.status}`);
  return response.json();
}
async function heartbeat(value) {
  await json("/api/v1/device/heartbeat", { method: "PUT",
    headers: { Authorization: `Bearer ${deviceToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ state: "RUN", displayName: "維護公告發布驗收（暫時裝置）",
      status: { currentStep: "maintenance preview smoke", gameMaintenance: value } }) });
  const result = await json(`/api/v1/devices/${encodeURIComponent(uid)}`, { headers: { Cookie: cookie } });
  return result.device.status.gameMaintenance;
}
try {
  const ready = await json("/health/ready");
  assert.equal(ready.ok, true);
  for (const pathname of ["/app.js", "/game-maintenance-view.js?v=maintenance-preview-v2"]) {
    const module = await fetch(`${base}${pathname}`);
    assert.equal(module.status, 200, `${pathname}: static JavaScript must actually be served`);
    assert.match(module.headers.get("content-type"), /^text\/javascript/);
    assert((await module.text()).includes("attachMaintenanceUI"));
  }
  const auth = await fetch(`${base}/api/v1/auth/me`);
  assert.equal(auth.ok, true);
  cookie = (auth.headers.get("set-cookie") ?? "").split(";")[0];
  assert(cookie.includes("="));
  await json("/api/v1/device/enroll", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ uid, deviceToken, displayName: "維護公告發布驗收（暫時裝置）" }) });
  const now = Date.now();
  const value = { schemaVersion: 1, capabilityVersion: 1, phase: "NORMAL", observedAt: now,
    observedUtcNow: now, sourceState: "valid", checkedAt: now, eventId: "",
    upcomingNotice: { eventId: "smoke-future-98.1", gameVersion: "98.1", startsAt: now + 172800000,
      expectedOpenAt: now + 198000000, sourceUrl: "https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5474" } };
  const normal = await heartbeat(value);
  assert.deepEqual(normal.upcomingNotice, value.upcomingNotice);
  assert.equal(normal.eventId, "");
  assert.equal(normal.phase, "NORMAL");
  assert.equal(maintenanceViewModel(normal, now, true).noticeSummary, "已公告下次維護；今天照常執行");
  const failed = await heartbeat({ ...value, sourceState: "unavailable", errorCode: "SOURCE_UNAVAILABLE" });
  assert.match(maintenanceViewModel(failed, now, true).noticeSummary, /查詢失敗.*上次已知公告/);
  const legacy = { ...value }; delete legacy.upcomingNotice;
  const oldClient = await heartbeat(legacy);
  assert.equal(oldClient.noticePreviewSupported, false);
  assert.match(maintenanceViewModel(oldClient, now, true).noticeSummary, /裝置版本尚未回報下一次公告/);
  console.log(JSON.stringify({ ok: true, serverVersion: ready.version, staticModuleHttp: true, futurePreviewRoundTrip: true,
    normalFlowPreserved: true, failedQueryRetainsEvidence: true, legacyCapabilityHonest: true }));
} finally {
  await query("DELETE FROM devices WHERE uid=$1", [uid]);
  const token = decodeURIComponent(cookie.split("=", 2)[1] ?? "");
  if (token) await query("DELETE FROM browser_sessions WHERE token_hash=$1",
    [crypto.createHash("sha256").update(token).digest("hex")]);
  await closeDatabase();
}
