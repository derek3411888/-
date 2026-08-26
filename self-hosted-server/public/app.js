const state = {
  me: null,
  devices: [],
  migration: null,
  selectedUid: localStorage.getItem("wuthering.selectedUid") || "",
  details: null,
  recordings: [],
  eventSource: null,
  refreshTimer: 0,
  periodicTimer: 0,
  liveTimer: 0,
  liveRetryTimer: 0,
  liveHls: null,
  liveActive: false,
  liveStartedAt: 0,
  liveHasPlayed: false,
  liveMediaRecoveries: 0,
};

const $ = (id) => document.getElementById(id);
const appView = $("appView");
const deviceSelect = $("deviceSelect");

function escapeText(value) { return String(value ?? ""); }
function formatTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? "—" : date.toLocaleString("zh-TW", { hour12: false });
}
function duration(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  return `${hours ? `${hours} 小時 ` : ""}${minutes} 分`;
}
function setText(id, value) { $(id).textContent = escapeText(value); }
function toast(message) {
  const node = $("toast");
  node.textContent = message;
  node.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { node.hidden = true; }, 4200);
}

async function api(path, options = {}) {
  const method = options.method ?? "GET";
  const headers = { ...(options.headers ?? {}) };
  if (!["GET", "HEAD"].includes(method)) headers["X-Wuthering-CSRF"] = "1";
  if (options.body && !(options.body instanceof Blob) && typeof options.body !== "string") {
    headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(options.body);
  }
  const response = await fetch(path, { credentials: "same-origin", ...options, method, headers });
  if (response.status === 204) return null;
  const payload = response.headers.get("content-type")?.includes("application/json") ? await response.json() : null;
  if (!response.ok) {
    const error = new Error(payload?.error?.message || `HTTP ${response.status}`);
    error.status = response.status;
    error.code = payload?.error?.code;
    error.details = payload?.error?.details;
    throw error;
  }
  return payload;
}

function migrationLabel(mode) {
  return { shadow: "7 天並行驗證", primary: "自架正式控制", fallback: "Firestore 緊急回復", disabled: "自架停用／Firestore" }[mode] || mode || "未知";
}

function selectedDevice() { return state.devices.find((item) => item.uid === state.selectedUid) ?? null; }

function renderDevices() {
  const previous = state.selectedUid;
  deviceSelect.replaceChildren();
  for (const device of state.devices) {
    const option = document.createElement("option");
    option.value = device.uid;
    option.textContent = `${device.display_name || device.uid}｜${device.online ? "在線" : "離線"}｜${device.state}`;
    deviceSelect.append(option);
  }
  if (!state.devices.length) {
    const option = document.createElement("option");
    option.textContent = "無電腦可顯示";
    option.value = "";
    deviceSelect.append(option);
    state.selectedUid = "";
  } else if (state.devices.some((item) => item.uid === previous)) {
    deviceSelect.value = previous;
  } else {
    state.selectedUid = state.devices[0].uid;
    deviceSelect.value = state.selectedUid;
  }
  localStorage.setItem("wuthering.selectedUid", state.selectedUid);
  const migration = state.migration?.mode ?? "shadow";
  setText("migrationBadge", migrationLabel(migration));
  $("migrationBadge").className = `badge ${migration === "primary" ? "ok" : "warning"}`;
}

function appendCell(row, value) {
  const cell = document.createElement("td");
  cell.textContent = escapeText(value);
  row.append(cell);
}

function renderDetails() {
  const wrapper = state.details;
  const device = wrapper?.device;
  if (!device) {
    setText("deviceTitle", "尚未選擇裝置");
    setText("deviceSummary", "無資料");
    return;
  }
  const status = device.status || {};
  setText("deviceTitle", device.display_name || device.uid);
  setText("deviceSummary", `${device.online ? "在線" : "離線"}｜最後心跳 ${formatTime(device.last_seen)}｜${device.state}`);
  setText("flowServer", status.currentServerLabel || status.currentServer || "尚無伺服器資料");
  setText("flowStep", status.currentStep ? `${status.currentStep}${status.currentStepDetail ? `｜${status.currentStepDetail}` : ""}` : "等待流程步驟");
  setText("switchProgress", status.serverSwitchNotifyPending
    ? `切換確認中：${status.pendingServerSwitchName || "下一個伺服器"}`
    : status.lastServerSwitchCompletedAt
      ? `上次切換完成：${status.lastServerSwitchCompletedName || "未命名"}｜${formatTime(status.lastServerSwitchCompletedAt)}${status.lastServerSwitchMailResult ? `｜通知 ${status.lastServerSwitchMailResult}` : ""}`
      : "");
  setText("flowBadge", device.online ? device.state : "離線");
  $("flowBadge").className = `badge ${device.online ? (device.state === "PAUSE" ? "warning" : "ok") : "muted"}`;
  $("deviceMeta").textContent = JSON.stringify({ uid: device.uid, online: device.online, state: device.state, lastSeen: device.last_seen, status }, null, 2);

  const controlEnabled = state.migration?.mode === "primary";
  for (const id of ["pauseButton", "runButton"]) $(id).disabled = !controlEnabled || Boolean(device.pending_nonce);
  // STOP 可依伺服器契約優先取代尚未套用的非 STOP 命令。
  $("stopButton").disabled = !controlEnabled;
  const serverList = Array.isArray(status.serverScheduleList)
    ? status.serverScheduleList
    : String(status.serverScheduleList || "").split(/[\n,;|]+/).map((item) => item.trim()).filter(Boolean);
  $("serverSelect").replaceChildren(new Option("無設定", ""));
  serverList.forEach((name, index) => $("serverSelect").append(new Option(`${index + 1}. ${name}`, JSON.stringify({ index: index + 1, name }))));
  $("switchButton").disabled = !controlEnabled || serverList.length < 2 || Boolean(device.pending_nonce);
  $("completeButton").disabled = !controlEnabled || !serverList.length || Boolean(device.pending_nonce);
  const completedServers = Array.isArray(status.serverCompletedList) ? status.serverCompletedList : [];
  setText("serverProgress", status.serverCycleKey
    ? `${status.serverCycleKey}｜已完成 ${completedServers.length}/${serverList.length || 0}${completedServers.length ? `｜${completedServers.join("、")}` : ""}`
    : "尚未收到今日伺服器進度。");
  if (device.pending_nonce) {
    const unanswered = Date.now() - new Date(device.pending_created_at).valueOf() >= 30_000;
    setText("commandStatus", unanswered
      ? `未回應：${device.pending_command}（nonce=${device.pending_nonce}）。命令仍安全保留，裝置上線後會繼續套用。`
      : `已送出 ${device.pending_command}（nonce=${device.pending_nonce}），等待裝置 ACK…`);
    $("commandStatus").className = `notice ${unanswered ? "warning" : ""}`;
  } else if (device.last_command) {
    setText("commandStatus", `${device.last_command.command} #${device.last_command.nonce}｜${device.last_command.status}${device.last_command.ack_result ? `｜${device.last_command.ack_result}` : ""}`);
    $("commandStatus").className = `notice ${device.last_command.status === "ACKED" ? "ok" : "muted"}`;
  } else {
    setText("commandStatus", state.migration?.mode === "primary" ? "尚未送出命令。" : "並行驗證中：控制命令仍請使用原 Firestore 網站。");
    $("commandStatus").className = "notice muted";
  }

  const snapshot = $("snapshotImage");
  snapshot.src = `/api/v1/devices/${encodeURIComponent(device.uid)}/snapshot?t=${Date.now()}`;
  snapshot.onload = () => { snapshot.hidden = false; $("snapshotEmpty").hidden = true; setText("snapshotMeta", `更新於 ${new Date().toLocaleString("zh-TW", { hour12: false })}`); };
  snapshot.onerror = () => { snapshot.hidden = true; $("snapshotEmpty").hidden = false; setText("snapshotMeta", "尚無快照"); };

  const recording = status.recording || Object.fromEntries(Object.entries(status).filter(([key]) => key.toLowerCase().startsWith("recording")));
  const recordingNode = $("recordingStatus");
  recordingNode.replaceChildren();
  const entries = Object.entries(recording).length ? Object.entries(recording) : [["狀態", "尚未收到錄影資料"]];
  for (const [key, value] of entries) {
    const row = document.createElement("div");
    const label = document.createElement("strong"); label.textContent = key;
    const content = document.createElement("span"); content.textContent = typeof value === "object" ? JSON.stringify(value) : String(value ?? "");
    row.append(label, content); recordingNode.append(row);
  }

  const eventsBody = $("eventsBody"); eventsBody.replaceChildren();
  for (const item of wrapper.events || []) {
    const row = document.createElement("tr");
    [formatTime(item.event_at), item.level, item.name, item.detail].forEach((value) => appendCell(row, value));
    eventsBody.append(row);
  }
  const commandsBody = $("commandsBody"); commandsBody.replaceChildren();
  for (const item of wrapper.commands || []) {
    const row = document.createElement("tr");
    const statusLabel = item.status === "PENDING" && Date.now() - new Date(item.created_at).valueOf() >= 30_000
      ? "PENDING／未回應" : item.status;
    [formatTime(item.created_at), item.command, item.nonce, statusLabel, [item.ack_result, item.ack_detail].filter(Boolean).join("｜")].forEach((value) => appendCell(row, value));
    commandsBody.append(row);
  }
  const displayedSettings = wrapper.settings?.status === "PENDING"
    ? wrapper.settings.settings : (device.settings || {});
  renderSettings(displayedSettings);
}

function renderSettings(settings) {
  $("scheduleEnabled").checked = Boolean(settings.serverScheduleEnabled);
  $("serverList").value = String(settings.serverScheduleList || "").replace(/\s*[;,|]\s*/g, "\n");
  $("maxRestart").value = settings.maxRestartCount ?? 10;
  $("snapshotInterval").value = settings.runtimeDiagnosticsIntervalSec ?? 60;
  $("snapshotKeep").value = settings.runtimeDiagnosticsErrorKeepCount ?? 30;
  $("diagnosticsEnabled").checked = settings.runtimeDiagnosticsEnabled !== false;
  $("mailEnabled").checked = Boolean(settings.mailNotifyEnabled);
  $("saveSettingsButton").disabled = state.migration?.mode !== "primary" || !state.selectedUid;
  setText("settingsMessage", state.migration?.mode === "primary" ? "儲存後等待裝置回報套用結果。" : "並行驗證期間設定仍由原 Firestore 控制台管理。");
}

function renderRecordings() {
  const list = $("recordingList"); list.replaceChildren();
  if (!state.recordings.length) {
    const empty = document.createElement("div"); empty.className = "empty"; empty.style.minHeight = "160px"; empty.textContent = "尚無中央影片副本。"; list.append(empty); return;
  }
  for (const item of state.recordings) {
    const card = document.createElement("div"); card.className = "recording-item";
    const title = document.createElement("strong"); title.textContent = item.base_name;
    const meta = document.createElement("small"); meta.textContent = `${item.state}｜${formatTime(item.completed_at || item.created_at)}${item.duration_seconds ? `｜${duration(item.duration_seconds)}` : ""}`;
    const detail = document.createElement("span"); detail.textContent = item.detail || `片段 ${item.expected_segments ?? "?"}`;
    const button = document.createElement("button"); button.type = "button"; button.textContent = item.playable ? "播放完整影片" : "查看已完成片段";
    button.addEventListener("click", () => openRecording(item));
    card.append(title, meta, detail, button); list.append(card);
  }
}

async function openRecording(recording) {
  const uid = state.selectedUid;
  if (!uid) return;
  $("playbackCard").hidden = false;
  setText("playbackTitle", recording.base_name);
  setText("playbackMeta", `${recording.state}｜${recording.detail || ""}`);
  const video = $("playbackVideo");
  const status = $("playbackStatus");
  const directLink = $("playbackDirectLink");
  const segments = $("segmentList");
  segments.replaceChildren();
  video.pause();
  video.removeAttribute("src");
  video.load();
  directLink.hidden = true;
  status.textContent = "正在讀取可播放影片…";

  const setPlaybackSource = (url, label, selectedButton = null) => {
    for (const button of segments.querySelectorAll("button")) button.classList.toggle("active", button === selectedButton);
    video.pause();
    video.src = url;
    video.load();
    directLink.href = url;
    directLink.hidden = false;
    status.textContent = `${label}正在載入；若瀏覽器阻擋自動播放，請按影片上的播放鍵。`;
    video.play().catch(() => {
      status.textContent = `${label}已選取，請按影片上的播放鍵。`;
    });
  };
  video.onloadedmetadata = () => { status.textContent = `影片已載入（${duration(video.duration)}），可以播放或拖曳進度。`; };
  video.onplaying = () => { status.textContent = "正在播放。"; };
  video.onerror = () => {
    const mediaCode = video.error?.code ? `（錯誤 ${video.error.code}）` : "";
    status.textContent = `影片載入失敗${mediaCode}；請按「直接開啟目前影片」，或稍後重試。`;
  };

  const encodedUid = encodeURIComponent(uid);
  if (recording.playable) {
    setPlaybackSource(`/api/v1/devices/${encodedUid}/recordings/${recording.id}/video`, "完整影片");
  }
  const payload = await api(`/api/v1/devices/${encodedUid}/recordings/${recording.id}/segments`);
  let latestPlayable = null;
  for (const item of payload.segments) {
    const button = document.createElement("button"); button.type = "button"; button.disabled = !item.playable;
    button.textContent = `${item.segment_index + 1}｜${item.state}`;
    const url = `/api/v1/devices/${encodedUid}/recordings/${recording.id}/segments/${item.id}/video`;
    button.addEventListener("click", () => setPlaybackSource(url, `第 ${item.segment_index + 1} 段`, button));
    segments.append(button);
    if (item.playable) latestPlayable = { url, label: `第 ${item.segment_index + 1} 段`, button };
  }
  if (!recording.playable && latestPlayable) {
    setPlaybackSource(latestPlayable.url, latestPlayable.label, latestPlayable.button);
  } else if (!recording.playable) {
    status.textContent = "這場錄影尚未有完成上傳及轉換的片段，請稍後重讀。";
  }
  $("playbackCard").scrollIntoView({ behavior: "smooth", block: "start" });
}

async function refresh() {
  const payload = await api("/api/v1/devices");
  state.devices = payload.devices || [];
  state.migration = payload.migration || {};
  renderDevices();
  if (state.selectedUid) {
    const encoded = encodeURIComponent(state.selectedUid);
    const [details, recordings] = await Promise.all([api(`/api/v1/devices/${encoded}`), api(`/api/v1/devices/${encoded}/recordings`)]);
    state.details = details;
    state.recordings = recordings.recordings || [];
    renderDetails(); renderRecordings();
  }
  await refreshAdmin();
}

function scheduleRefresh() {
  clearTimeout(state.refreshTimer);
  state.refreshTimer = setTimeout(() => refresh().catch((error) => toast(error.message)), 400);
}

async function sendCommand(command, extras = {}) {
  if (!state.selectedUid) return;
  const row = await api(`/api/v1/devices/${encodeURIComponent(state.selectedUid)}/commands`, {
    method: "POST", body: { command, idempotencyKey: crypto.randomUUID(), ...extras },
  });
  toast(`已送出 ${command}（nonce=${row.nonce}）`);
  await refresh();
}

async function refreshAdmin() {
  const [migration, alerts] = await Promise.all([
    api("/api/v1/admin/migration"), api("/api/v1/admin/alerts"),
  ]);
  const node = $("migrationStatus"); node.replaceChildren();
  const rows = [
    ["目前模式", migrationLabel(migration.mode)],
    ["並行起始", formatTime(migration.shadowStartedAt)],
    ["無錯誤驗證起始", formatTime(migration.validationWindowStartedAt)],
    ["經過天數", Number(migration.elapsedDays).toFixed(2)],
    ["待 ACK 命令", migration.pendingCommands],
    ["Firestore 待 ACK", migration.pendingFirestoreAcks],
    ["一致性錯誤", migration.consistencyErrors],
    ["裝置完整流程", migration.devices.map((item) => `${item.display_name || item.uid}: ${item.completed_runs}`).join("；") || "尚無"],
  ];
  for (const [key, value] of rows) { const row = document.createElement("div"); const k = document.createElement("strong"); k.textContent = key; const v = document.createElement("span"); v.textContent = value; row.append(k, v); node.append(row); }
  $("cutoverButton").disabled = !migration.ready || migration.mode !== "shadow";

  const alertsNode = $("alertsList"); alertsNode.replaceChildren();
  for (const item of alerts.alerts) { const row = document.createElement("div"); row.className = "alert-item"; row.textContent = `${formatTime(item.created_at)}｜${item.message}`; alertsNode.append(row); }
}

async function startLive() {
  if (!state.selectedUid || state.liveActive) return;
  const lease = await api(`/api/v1/live/${encodeURIComponent(state.selectedUid)}/lease`, { method: "POST" });
  state.liveActive = true;
  state.liveStartedAt = Date.now();
  state.liveHasPlayed = false;
  state.liveMediaRecoveries = 0;
  $("startLiveButton").disabled = true; $("stopLiveButton").disabled = false;
  setText("liveBadge", "正在等待推流"); $("liveBadge").className = "badge warning";
  setText("liveMessage", "已通知執行端；通常約 10 秒開始，若桌面鎖定會維持不可用。");
  clearInterval(state.liveTimer);
  state.liveTimer = setInterval(() => api(`/api/v1/live/${encodeURIComponent(state.selectedUid)}/lease`, { method: "POST" }).catch(() => {}), 30_000);
  attachLive(lease.playlistUrl, 0);
}

function attachLive(url, attempt) {
  if (!state.liveActive) return;
  clearTimeout(state.liveRetryTimer);
  const video = $("liveVideo");
  if (state.liveHls) { state.liveHls.destroy(); state.liveHls = null; }
  const sourceUrl = `${url}?t=${Date.now()}`;
  // Prefer hls.js whenever Managed Media Source / MSE is available. Modern
  // Safari can report native HLS support but defer the network request or stall
  // on a low-latency startup playlist. hls.js performs the requests itself and
  // gives us deterministic retry handling; older Safari still uses native HLS.
  if (window.Hls?.isSupported()) {
    const hls = new window.Hls({
      lowLatencyMode: true,
      liveSyncDurationCount: 3,
      maxLiveSyncPlaybackRate: 1.5,
      liveDurationInfinity: true,
    });
    state.liveHls = hls;
    hls.loadSource(sourceUrl);
    hls.attachMedia(video);
    hls.on(window.Hls.Events.MANIFEST_PARSED, () => video.play().catch(() => {}));
    hls.on(window.Hls.Events.ERROR, (_, data) => {
      if (!data.fatal) return;
      const httpCode = Number(data.response?.code || data.networkDetails?.status || 0);
      if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR && state.liveMediaRecoveries < 1) {
        state.liveMediaRecoveries += 1;
        setText("liveMessage", "已收到串流但解碼暫停，正在恢復播放器…");
        hls.recoverMediaError();
        return;
      }
      scheduleLiveRetry(url, attempt + 1, httpCode ? `HTTP ${httpCode}` : data.details);
    });
  } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
    video.src = sourceUrl;
    video.load();
    video.play().catch(() => {});
  } else {
    setText("liveMessage", "這個瀏覽器不支援 HLS 播放，請改用最新版 Chrome、Edge 或 Safari。");
    return;
  }
  video.onplaying = () => {
    state.liveHasPlayed = true;
    state.liveMediaRecoveries = 0;
    clearTimeout(state.liveRetryTimer);
    setText("liveBadge", "直播中"); $("liveBadge").className = "badge ok";
    setText("liveMessage", "近即時畫面已連線；保持此頁開啟會自動續期。");
  };
  video.onerror = () => scheduleLiveRetry(url, attempt + 1, "瀏覽器播放器錯誤");
}

function scheduleLiveRetry(url, attempt, reason = "") {
  if (!state.liveActive) return;
  clearTimeout(state.liveRetryTimer);
  const elapsed = Math.max(0, Math.round((Date.now() - state.liveStartedAt) / 1000));
  if (state.liveHasPlayed) {
    setText("liveBadge", "正在重新連線");
    setText("liveMessage", `串流中斷，正在重新連線（${reason || `第 ${attempt} 次`}）…`);
  } else {
    setText("liveBadge", "等待裝置推流");
    setText("liveMessage", `已建立觀看租約，正在等待執行端連入（${elapsed} 秒${reason ? `，${reason}` : ""}）。`);
  }
  $("liveBadge").className = "badge warning";
  state.liveRetryTimer = setTimeout(() => attachLive(url, attempt), Math.min(5000, 2000 + attempt * 100));
}

async function stopLive() {
  if (!state.liveActive) return;
  state.liveActive = false; clearInterval(state.liveTimer); clearTimeout(state.liveRetryTimer);
  state.liveStartedAt = 0; state.liveHasPlayed = false; state.liveMediaRecoveries = 0;
  try { await api(`/api/v1/live/${encodeURIComponent(state.selectedUid)}/lease`, { method: "DELETE" }); } catch {}
  if (state.liveHls) { state.liveHls.destroy(); state.liveHls = null; }
  const video = $("liveVideo"); video.pause(); video.removeAttribute("src"); video.load();
  $("startLiveButton").disabled = false; $("stopLiveButton").disabled = true;
  setText("liveBadge", "未啟動"); $("liveBadge").className = "badge muted";
  setText("liveMessage", "停止觀看；執行端會在租約到期後自動停止推流。");
}

function bindEvents() {
  document.querySelectorAll("[data-tab]").forEach((button) => button.addEventListener("click", () => {
    document.querySelectorAll("[data-tab]").forEach((item) => item.classList.toggle("active", item === button));
    document.querySelectorAll("[data-panel]").forEach((panel) => panel.classList.toggle("active", panel.dataset.panel === button.dataset.tab));
  }));
  deviceSelect.addEventListener("change", async () => { await stopLive(); state.selectedUid = deviceSelect.value; localStorage.setItem("wuthering.selectedUid", state.selectedUid); await refresh(); });
  $("refreshButton").addEventListener("click", () => refresh().catch((error) => toast(error.message)));
  $("pauseButton").addEventListener("click", () => sendCommand("PAUSE").catch((error) => toast(error.message)));
  $("runButton").addEventListener("click", () => sendCommand("RUN").catch((error) => toast(error.message)));
  $("stopButton").addEventListener("click", () => { if (confirm("確定要遠端完整關閉腳本？")) sendCommand("STOP").catch((error) => toast(error.message)); });
  $("switchButton").addEventListener("click", () => { const value = $("serverSelect").value; if (!value) return; const target = JSON.parse(value); sendCommand("SWITCH_SERVER", { serverIndex: target.index, serverName: target.name }).catch((error) => toast(error.message)); });
  $("completeButton").addEventListener("click", () => { const value = $("serverSelect").value; if (!value) return; const target = JSON.parse(value); if (confirm(`把 ${target.name} 標記為今天已完成？`)) sendCommand("COMPLETE_SERVER", { serverIndex: target.index, serverName: target.name }).catch((error) => toast(error.message)); });
  $("settingsForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    try {
      await api(`/api/v1/devices/${encodeURIComponent(state.selectedUid)}/settings`, { method: "PUT", body: {
        serverScheduleEnabled: $("scheduleEnabled").checked,
        serverScheduleList: $("serverList").value.split(/\r?\n/).map((item) => item.trim()).filter(Boolean).join(","),
        maxRestartCount: Number($("maxRestart").value), runtimeDiagnosticsEnabled: $("diagnosticsEnabled").checked,
        runtimeDiagnosticsIntervalSec: Number($("snapshotInterval").value), runtimeDiagnosticsErrorKeepCount: Number($("snapshotKeep").value),
        mailNotifyEnabled: $("mailEnabled").checked,
      }});
      toast("設定已儲存，等待裝置 ACK"); await refresh();
    } catch (error) { toast(error.message); }
  });
  $("startLiveButton").addEventListener("click", () => startLive().catch((error) => toast(error.message)));
  $("stopLiveButton").addEventListener("click", () => stopLive());
  $("cutoverButton").addEventListener("click", async () => { if (!confirm("確認兩台裝置與影片均完成驗證，正式把命令來源切到自架伺服器？")) return; try { await api("/api/v1/admin/migration/cutover", { method: "POST" }); toast("已切換為自架正式控制"); await refresh(); } catch (error) { toast(error.message); } });
  window.addEventListener("beforeunload", () => { clearInterval(state.liveTimer); clearTimeout(state.liveRetryTimer); clearInterval(state.periodicTimer); });
}

async function boot() {
  state.me = await api("/api/v1/auth/me");
  appView.hidden = false;
  bindEvents();
  await refresh();
  clearInterval(state.periodicTimer);
  state.periodicTimer = setInterval(() => refresh().catch((error) => toast(error.message)), 30_000);
  const events = new EventSource("/api/v1/events"); state.eventSource = events;
  ["device", "command", "settings", "snapshot", "live"].forEach((name) => events.addEventListener(name, scheduleRefresh));
  events.onerror = () => setText("deviceSummary", "即時連線暫時中斷，正在自動重連…");
}

boot().catch((error) => {
  appView.hidden = false;
  setText("deviceSummary", `控制台載入失敗：${error.message}`);
  toast(`控制台載入失敗：${error.message}`);
});
