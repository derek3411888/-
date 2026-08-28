import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { config } from "../src/config.js";
import { closeDatabase, query } from "../src/db.js";
import { forceMigrationMode } from "../src/firestore-bridge.js";
import { repairStalledMediaJobs } from "../src/media.js";

const base = process.env.SMOKE_BASE_URL ?? "http://127.0.0.1:3000";
const uid = `smoke-device-${Date.now()}`;
const deviceToken = crypto.randomBytes(48).toString("base64url");
let cookie = "";
let originalMigrationMode = "";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function request(path, { method = "GET", body, headers = {}, browser = false, device = false, raw = false } = {}) {
  const finalHeaders = { Accept: "application/json", ...headers };
  if (browser) finalHeaders.Cookie = cookie;
  if (device) finalHeaders.Authorization = `Bearer ${deviceToken}`;
  if (!["GET", "HEAD"].includes(method) && browser) {
    finalHeaders.Origin = config.publicUrl;
    finalHeaders["X-Wuthering-CSRF"] = "1";
  }
  let payload = body;
  if (body !== undefined && !Buffer.isBuffer(body)) {
    finalHeaders["Content-Type"] = "application/json; charset=utf-8";
    payload = JSON.stringify(body);
  }
  const response = await fetch(`${base}${path}`, { method, headers: finalHeaders, body: payload });
  if (!response.ok) {
    throw new Error(`${method} ${path} -> ${response.status}: ${(await response.text()).slice(0, 2000)}`);
  }
  if (raw) return response;
  if (response.status === 204) return null;
  return response.json();
}

async function waitFor(check, message, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    try {
      last = await check();
      if (last) return last;
    } catch (error) { last = error; }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`${message}; last=${last instanceof Error ? last.message : JSON.stringify(last)}`);
}

async function main() {
  assert((await request("/health/ready")).ok, "ready endpoint failed");
  const migration = await query("SELECT value->>'mode' AS mode FROM system_settings WHERE key='migration'");
  originalMigrationMode = String(migration.rows[0]?.mode ?? "");
  await query("UPDATE system_settings SET value=jsonb_build_object('openUntil',NULL),updated_at=now() WHERE key='enrollment'");
  const directAccess = await fetch(`${base}/api/v1/auth/me`);
  assert(directAccess.ok, `direct browser access failed: ${directAccess.status}`);
  cookie = String(directAccess.headers.get("set-cookie") ?? "").split(";")[0];
  assert(cookie.includes("="), "automatic browser cookie missing");
  const directAccessBody = await directAccess.json();
  assert(directAccessBody.accessMode === "direct", "browser access mode is not direct");
  const directDeviceList = await request("/api/v1/devices", { browser: true });
  assert(Array.isArray(directDeviceList.devices), "direct browser could not list devices");
  const rejectedCrossSiteMutation = await fetch(`${base}/api/v1/admin/migration/mode`, {
    method: "PUT", headers: { Cookie: cookie, "Content-Type": "application/json" },
    body: JSON.stringify({ mode: "primary" }),
  });
  assert(rejectedCrossSiteMutation.status === 403, "mutation without CSRF confirmation was accepted");

  const automaticEnrollment = await fetch(`${base}/api/v1/device/enroll`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ uid, displayName: "整合測試裝置", deviceAlias: "smoke",
      lastNonce: 0, settingsRevision: 0, deviceToken }),
  });
  assert(automaticEnrollment.ok, `automatic device enrollment failed: ${automaticEnrollment.status}`);
  const forgedUid = await fetch(`${base}/api/v1/device/enroll`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ uid: `${uid}-forged`, deviceToken }),
  });
  assert(forgedUid.status === 409, "device token could be reused for a forged UID");
  const unauthorizedDevice = await fetch(`${base}/api/v1/device/control`, {
    headers: { Authorization: `Bearer ${crypto.randomBytes(48).toString("base64url")}` },
  });
  assert(unauthorizedDevice.status === 401, "forged device credential reached control API");
  await request("/api/v1/device/heartbeat", {
    method: "PUT", device: true,
    body: { state: "RUN", displayName: "整合測試裝置", lastNonce: 0, settingsRevision: 0,
      status: { currentStep: "smoke", currentServerLabel: "1/2 | HMT", serverScheduleList: ["HMT", "Asia"] },
      events: [{ at: Date.now(), level: "INFO", name: "測試啟動", detail: "integration smoke" }] },
  });
  const backgroundRecordingStatus = await request("/api/v1/device/recording/status", {
    method: "PUT", device: true,
    body: { state: "merging", detail: "本機無損合併 25%", active: false,
      baseName: "wuthering_auto_recording_20260825_151700", progressCurrent: 25,
      progressTotal: 100, progressUnit: "bytes" },
  });
  assert(backgroundRecordingStatus.progressPercent === 25
    && backgroundRecordingStatus.source === "background-worker",
  "background recording worker status was not accepted");
  await request("/api/v1/admin/migration/mode", { method: "PUT", body: { mode: "primary" }, browser: true });

  const pause = await request(`/api/v1/devices/${encodeURIComponent(uid)}/commands`, {
    method: "POST", browser: true, body: { command: "PAUSE", idempotencyKey: crypto.randomUUID() },
  });
  const conflict = await fetch(`${base}/api/v1/devices/${encodeURIComponent(uid)}/commands`, {
    method: "POST",
    headers: { Cookie: cookie, Origin: config.publicUrl, "X-Wuthering-CSRF": "1", "Content-Type": "application/json" },
    body: JSON.stringify({ command: "RUN", idempotencyKey: crypto.randomUUID() }),
  });
  assert(conflict.status === 409, "non-STOP command overwrote pending command");
  const stop = await request(`/api/v1/devices/${encodeURIComponent(uid)}/commands`, {
    method: "POST", browser: true, body: { command: "STOP", idempotencyKey: crypto.randomUUID() },
  });
  assert(Number(stop.nonce) > Number(pause.nonce), "STOP nonce did not advance");
  const control = await request("/api/v1/device/control?format=firestore", { device: true });
  assert(control.fields.desiredState.stringValue === "STOP", "device did not receive STOP");
  assert(control.fields.selfHostedServerUrl.stringValue === config.publicUrl,
    "primary device control did not publish the fixed API URL");
  await request("/api/v1/device/commands/ack", {
    method: "POST", device: true,
    body: { nonce: Number(stop.nonce), state: "STOP", result: "APPLIED", detail: "smoke ACK" },
  });
  const stoppedDevice = await request(`/api/v1/devices/${encodeURIComponent(uid)}`, { browser: true });
  assert(stoppedDevice.device.online === false,
    "STOP device remained online during the heartbeat grace window");

  const setting = await request(`/api/v1/devices/${encodeURIComponent(uid)}/settings`, {
    method: "PUT", browser: true,
    body: { serverScheduleEnabled: true, serverScheduleList: "HMT,Asia", maxRestartCount: 10,
      runtimeDiagnosticsEnabled: true, runtimeDiagnosticsIntervalSec: 60,
      runtimeDiagnosticsErrorKeepCount: 30, mailNotifyEnabled: false,
      liveQualityProfile: "smooth" },
  });
  await request("/api/v1/device/settings/ack", {
    method: "POST", device: true,
    body: { revision: Number(setting.revision), applied: true, result: "APPLIED", detail: "smoke settings" },
  });
  const appliedLiveSettings = await request("/api/v1/device/control", { device: true });
  assert(appliedLiveSettings.settings.liveQualityProfile === "smooth",
    "device control lost the ACKed live quality profile");
  const rejectedSetting = await request(`/api/v1/devices/${encodeURIComponent(uid)}/settings`, {
    method: "PUT", browser: true,
    body: { serverScheduleEnabled: false, serverScheduleList: "Asia", maxRestartCount: 9,
      runtimeDiagnosticsEnabled: true, runtimeDiagnosticsIntervalSec: 60,
      runtimeDiagnosticsErrorKeepCount: 30, mailNotifyEnabled: false,
      liveQualityProfile: "economy" },
  });
  const rejectedAck = {
    revision: Number(rejectedSetting.revision), applied: false, result: "REJECTED", detail: "smoke rejection",
  };
  await request("/api/v1/device/settings/ack", { method: "POST", device: true, body: rejectedAck });
  await request("/api/v1/device/settings/ack", { method: "POST", device: true, body: rejectedAck });
  const mismatchedSettingsAck = await fetch(`${base}/api/v1/device/settings/ack`, {
    method: "POST", headers: { Authorization: `Bearer ${deviceToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ ...rejectedAck, detail: "different" }),
  });
  assert(mismatchedSettingsAck.status === 409, "mismatched duplicate settings ACK was accepted");
  const effectiveAfterReject = await request(`/api/v1/devices/${encodeURIComponent(uid)}`, { browser: true });
  assert(Number(effectiveAfterReject.device.settings.maxRestartCount) === 10,
    "rejected setting replaced the last ACKed effective setting");
  assert(effectiveAfterReject.device.settings.liveQualityProfile === "smooth",
    "live quality profile was not preserved by exact settings ACK semantics");

  const jpeg = Buffer.alloc(200, 0x22); jpeg[0] = 0xff; jpeg[1] = 0xd8;
  await request(`/api/v1/device/snapshot?capturedAt=${Date.now()}&width=1&height=1&reason=smoke`, {
    method: "PUT", device: true, body: jpeg, headers: { "Content-Type": "image/jpeg" },
  });
  const snapshot = await request(`/api/v1/devices/${encodeURIComponent(uid)}/snapshot`, { browser: true, raw: true });
  assert((await snapshot.arrayBuffer()).byteLength === jpeg.length, "snapshot round-trip failed");

  const mediaPath = `/tmp/${uid}.mkv`;
  const ffmpeg = spawnSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
    "-i", "testsrc=size=320x180:rate=12", "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p",
    "-f", "matroska", mediaPath], { encoding: "utf8" });
  assert(ffmpeg.status === 0, `fixture ffmpeg failed: ${ffmpeg.stderr}`);
  const media = await fs.readFile(mediaPath);
  const clientSessionId = `wuthering_auto_recording_20260825_151700_${Date.now()}`;
  const recording = await request("/api/v1/device/recordings/sessions", {
    method: "POST", device: true,
    body: { clientSessionId, baseName: "wuthering_auto_recording_20260825_151700",
      startedAt: new Date().toISOString(), expectedSegments: 1, expectedBytes: media.length },
  });
  const segment = await request(`/api/v1/device/recordings/sessions/${recording.id}/segments`, {
    method: "POST", device: true,
    body: { index: 0, name: "segment_00000.mkv", sizeBytes: media.length,
      sha256: crypto.createHash("sha256").update(media).digest("hex") },
  });
  const duplicateSegment = await request(`/api/v1/device/recordings/sessions/${recording.id}/segments`, {
    method: "POST", device: true,
    body: { index: 0, name: "segment_00000.mkv", sizeBytes: media.length,
      sha256: crypto.createHash("sha256").update(media).digest("hex") },
  });
  assert(duplicateSegment.id === segment.id, "identical duplicate segment was not idempotent");
  const conflictingSegment = await fetch(`${base}/api/v1/device/recordings/sessions/${recording.id}/segments`, {
    method: "POST", headers: { Authorization: `Bearer ${deviceToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ index: 0, name: "segment_00000.mkv", sizeBytes: media.length, sha256: "0".repeat(64) }),
  });
  assert(conflictingSegment.status === 409, "conflicting duplicate segment was accepted");

  const corrupted = Buffer.from(media);
  corrupted[corrupted.length - 1] ^= 0xff;
  const corruptedUpload = await fetch(`${base}/api/v1/device/recordings/segments/${segment.id}`, {
    method: "PUT",
    headers: { Authorization: `Bearer ${deviceToken}`, "Content-Type": "application/octet-stream",
      "Content-Range": `bytes 0-${corrupted.length - 1}/${corrupted.length}` },
    body: corrupted,
  });
  assert(corruptedUpload.status === 422, "corrupted segment did not fail SHA-256 validation");
  const resetState = await request(`/api/v1/device/recordings/segments/${segment.id}`, { device: true });
  assert(Number(resetState.received_bytes) === 0, "corrupted segment did not reset resumable offset");

  const middle = Math.floor(media.length / 2);
  await request(`/api/v1/device/recordings/segments/${segment.id}`, {
    method: "PUT", device: true, body: media.subarray(0, middle),
    headers: { "Content-Type": "application/octet-stream", "Content-Range": `bytes 0-${middle - 1}/${media.length}` },
  });
  const interruptedState = await request(`/api/v1/device/recordings/segments/${segment.id}`, { device: true });
  assert(Number(interruptedState.received_bytes) === middle, "resumable offset was not persisted");
  const wrongOffset = await fetch(`${base}/api/v1/device/recordings/segments/${segment.id}`, {
    method: "PUT",
    headers: { Authorization: `Bearer ${deviceToken}`, "Content-Type": "application/octet-stream",
      "Content-Range": `bytes 0-${middle - 1}/${media.length}` },
    body: media.subarray(0, middle),
  });
  assert(wrongOffset.status === 409, "overlapping upload offset was accepted");
  await request(`/api/v1/device/recordings/segments/${segment.id}`, {
    method: "PUT", device: true, body: media.subarray(middle),
    headers: { "Content-Type": "application/octet-stream",
      "Content-Range": `bytes ${middle}-${media.length - 1}/${media.length}` },
  });
  await waitFor(async () => (await request(`/api/v1/device/recordings/segments/${segment.id}`, { device: true })).state === "READY",
    "segment remux did not finish");
  await query(
    `UPDATE recording_sessions SET state='ERROR',detail='smoke forced stale error',
       updated_at=now()-interval '3 minutes' WHERE id=$1`, [recording.id],
  );
  const repair = await repairStalledMediaJobs();
  assert(repair.repairedSessions === 1, "stale recording session was not auto-repaired");
  await waitFor(async () => (await request(`/api/v1/device/recordings/sessions/${recording.id}`, { device: true })).state === "COMPLETE",
    "auto-repaired recording merge did not finish");
  const recordingList = await request(`/api/v1/devices/${encodeURIComponent(uid)}/recordings`, { browser: true });
  const completedRecording = recordingList.recordings.find((item) => item.id === recording.id);
  assert(completedRecording?.progress_percent === 100
    && Number(completedRecording.expected_bytes) === media.length
    && Number(completedRecording.received_bytes) === media.length,
  "recording list did not expose complete progress and byte totals");
  const video = await request(`/api/v1/devices/${encodeURIComponent(uid)}/recordings/${recording.id}/video`, {
    browser: true, raw: true, headers: { Range: "bytes=0-99" },
  });
  assert(video.status === 206 && (await video.arrayBuffer()).byteLength === 100, "HTTP Range playback failed");
  const videoHead = await request(`/api/v1/devices/${encodeURIComponent(uid)}/recordings/${recording.id}/video`, {
    method: "HEAD", browser: true, raw: true,
  });
  assert(videoHead.status === 200 && Number(videoHead.headers.get("content-length")) > 0,
    "HTTP HEAD playback probe failed");

  const lease = await request(`/api/v1/live/${encodeURIComponent(uid)}/lease`, { method: "POST", browser: true, body: {} });
  const liveHeartbeat = await request("/api/v1/device/heartbeat", {
    method: "PUT", device: true, body: { state: "RUN", displayName: "整合測試裝置", lastNonce: Number(stop.nonce) },
  });
  assert(liveHeartbeat.fields?.selfHostedLiveEnabled?.booleanValue === true
    && Number(liveHeartbeat.fields?.selfHostedLiveExpiresAt?.integerValue)
      >= new Date(lease.expiresAt).valueOf() + config.livePublisherGraceSeconds * 1000,
  "heartbeat response lost the active live lease");
  const liveControl = await request("/api/v1/device/control", { device: true });
  assert(liveControl.selfHostedServerUrl === config.publicUrl,
    "JSON device control did not publish the fixed API URL");
  assert(liveControl.live.active && liveControl.live.publishUrl.includes("passphrase="), "encrypted live URL missing");
  assert(Array.isArray(liveControl.live.publishUrls)
    && liveControl.live.publishUrls[0] === liveControl.live.publishUrl,
  "ordered live publish candidates missing");
  assert(new Date(liveControl.live.publisherExpiresAt).valueOf()
    >= new Date(liveControl.live.expiresAt).valueOf() + config.livePublisherGraceSeconds * 1000,
  "publisher fail-safe deadline did not include heartbeat grace");
  if (config.localSrtHost) {
    assert(liveControl.live.publishUrl.startsWith(`srt://${config.localSrtHost}:`),
      "LAN SRT address was not preferred");
  }
  const rejectedSrtRead = await fetch(`${base}/internal/media-auth`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "read", protocol: "srt", path: uid }),
  });
  assert(rejectedSrtRead.status === 401, "direct SRT playback bypassed browser authorization");
  const internalSrt = liveControl.live.publishUrl.replace(/^srt:\/\/[^:]+:\d+/, "srt://mediamtx:8890");
  const invalidSrt = internalSrt.replace(/passphrase=[^&]+/, `passphrase=${"x".repeat(32)}`);
  const rejectedPublisher = spawnSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
    "testsrc=size=160x90:rate=6", "-t", "1", "-c:v", "libx264", "-preset", "ultrafast",
    "-f", "mpegts", invalidSrt], { encoding: "utf8", timeout: 15_000 });
  assert(rejectedPublisher.status !== 0, "publisher with the wrong SRT passphrase was accepted");
  const publisher = spawn("ffmpeg", ["-hide_banner", "-loglevel", "error", "-re", "-f", "lavfi", "-i",
    "testsrc=size=320x180:rate=12", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
    "-g", "24", "-f", "mpegts", internalSrt], { stdio: "ignore" });
  try {
    const masterText = await waitFor(async () => {
      const response = await fetch(`${base}${lease.playlistUrl}`, { headers: { Cookie: cookie } });
      if (!response.ok) return null;
      const text = await response.text();
      return text.includes("#EXTM3U") ? text : null;
    }, "HLS live playlist did not become ready", 45_000);
    const child = masterText.split(/\r?\n/).find((line) => line && !line.startsWith("#") && line.includes(".m3u8"));
    assert(child, "HLS master playlist did not contain a media playlist");
    const mediaUrl = new URL(child, `${base}${lease.playlistUrl}`).href;
    const mediaText = await waitFor(async () => {
      const response = await fetch(mediaUrl, { headers: { Cookie: cookie } });
      if (!response.ok) return null;
      const text = await response.text();
      return text.includes("#EXTM3U") ? text : null;
    }, "HLS media playlist did not become ready", 20_000);
    const resources = [
      ...[...mediaText.matchAll(/URI="([^"]+)"/g)].map((match) => match[1]),
      ...mediaText.split(/\r?\n/).filter((line) => line && !line.startsWith("#")),
    ];
    assert(resources.length, "HLS media playlist did not contain playable resources");
    const resource = await fetch(new URL(resources.at(-1), mediaUrl), { headers: { Cookie: cookie } });
    assert(resource.ok && (await resource.arrayBuffer()).byteLength > 0, "HLS media resource could not be read");
  } finally {
    publisher.kill("SIGTERM");
  }
  await request(`/api/v1/live/${encodeURIComponent(uid)}/lease`, { method: "DELETE", browser: true, body: {} });
  await fs.rm(mediaPath, { force: true });

  const details = await request(`/api/v1/devices/${encodeURIComponent(uid)}`, { browser: true });
  assert(details.device.pending_nonce == null, "ACKed command still pending");
  assert(details.events.some((event) => event.name === "測試啟動"), "runtime event missing");
  const serverLog = await fs.stat(`${config.serverLogRoot}/server.log`);
  assert(serverLog.isFile() && serverLog.size > 0, "mounted rotating server log was not written");
  console.log(JSON.stringify({ ok: true, uid, commandNonce: Number(stop.nonce), recordingId: recording.id,
    directBrowserAccess: true, automaticEnrollment: true, csrfRejected: true,
    videoRange: true, recordingProgress: true, mediaAutoRepair: true, liveHls: true, liveHlsResources: true,
    invalidSrtRejected: true, serverLog: true }));
}

async function cleanup() {
  await query("DELETE FROM devices WHERE uid=$1", [uid]).catch(() => {});
  if (["shadow", "primary", "fallback", "disabled"].includes(originalMigrationMode)) {
    await forceMigrationMode(originalMigrationMode);
  }
  const token = decodeURIComponent(cookie.split("=", 2)[1] ?? "");
  if (token) {
    const tokenHash = crypto.createHash("sha256").update(token).digest("hex");
    await query("DELETE FROM browser_sessions WHERE token_hash=$1", [tokenHash]).catch(() => {});
  }
  await fs.rm(path.join(config.mediaRoot, uid), { recursive: true, force: true }).catch(() => {});
  await fs.rm(path.join(config.snapshotRoot, uid), { recursive: true, force: true }).catch(() => {});
}

try { await main(); }
finally {
  await cleanup();
  await closeDatabase();
}
