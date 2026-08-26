const state = {
  me: null,
  devices: [],
  migration: null,
  selectedUid: localStorage.getItem("wuthering.selectedUid") || "",
  details: null,
  recordings: [],
  eventSource: null,
  refreshTimer: 0,
  selectedRefreshTimer: 0,
  periodicTimer: 0,
  refreshInFlight: false,
  refreshQueued: null,
  activeTab: "overview",
  liveTimer: 0,
  liveRetryTimer: 0,
  liveHls: null,
  liveActive: false,
  liveStartedAt: 0,
  liveHasPlayed: false,
  liveMediaRecoveries: 0,
};

const SUPPORTED_SERVERS = ["America", "Europe", "Asia", "HMT(HK,MO,TW)", "SEA"];

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
function formatBytes(value) {
  const bytes = Math.max(0, Number(value) || 0);
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(2)} GB`;
  if (bytes >= 1024 ** 2) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${Math.round(bytes)} B`;
}
function recordingStageLabel(value) {
  return {
    DEVICE_UPLOAD: "執行端續傳中央影片",
    SEGMENT_PROCESSING: "中央轉換封口片段",
    SERVER_MERGE: "中央無重編碼合併",
    VERIFYING: "中央驗證完整影片",
    COMPLETE: "完整影片已完成",
    central_uploading: "執行端正在續傳中央影片",
    central_processing: "中央正在轉換與合併",
    copying_segments: "複製封口片段到設定位置",
    merging: "本機無損合併",
    copying_final: "複製完整影片到設定位置",
    complete_upload_pending: "本機完成，中央仍待續傳",
    finalize_waiting: "收尾等待中",
    complete: "本機錄影收尾完成",
  }[String(value ?? "")] || String(value || "等待錄影資料");
}
function centralRecordingProgress(item) {
  if (item.state === "COMPLETE") return { percent: 100, stage: "COMPLETE" };
  const expectedBytes = Number(item.expected_bytes) || 0;
  const receivedBytes = Number(item.received_bytes) || 0;
  const expectedSegments = Number(item.expected_segments) || 0;
  const readySegments = Number(item.ready_segments) || 0;
  if (expectedBytes > 0 && receivedBytes < expectedBytes) {
    return { percent: Math.min(79, Math.floor(receivedBytes / expectedBytes * 80)), stage: "DEVICE_UPLOAD" };
  }
  if (expectedSegments > 0 && readySegments < expectedSegments) {
    return { percent: Math.min(89, 80 + Math.floor(readySegments / expectedSegments * 10)), stage: "SEGMENT_PROCESSING" };
  }
  const stored = Number(item.progress_percent);
  return {
    percent: Number.isFinite(stored) && stored >= 0 ? Math.min(100, stored) : null,
    stage: item.progress_stage || item.state,
  };
}
function appendProgress(parent, percent, label, detail = "") {
  const block = document.createElement("div"); block.className = "progress-block";
  const summary = document.createElement("div"); summary.className = "progress-summary";
  const stage = document.createElement("strong"); stage.textContent = label;
  const value = document.createElement("span"); value.textContent = percent == null ? "處理中" : `${percent}%`;
  summary.append(stage, value);
  const track = document.createElement("div"); track.className = `progress-track${percent == null ? " indeterminate" : ""}`;
  const fill = document.createElement("div"); fill.className = "progress-fill";
  if (percent != null) fill.style.width = `${Math.max(0, Math.min(100, percent))}%`;
  track.append(fill); block.append(summary, track);
  if (detail) { const text = document.createElement("small"); text.textContent = detail; block.append(text); }
  parent.append(block);
}
function setText(id, value) { $(id).textContent = escapeText(value); }
function normalizeLiveQualityProfile(value) {
  const profile = String(value ?? "").trim().toLowerCase();
  return ["economy", "balanced", "smooth"].includes(profile) ? profile : "balanced";
}

function canonicalServerName(value) {
  const key = String(value ?? "").trim().toLocaleLowerCase("zh-TW")
    .replaceAll("（", "(").replaceAll("）", ")").replaceAll("，", ",")
    .replace(/[\s　_\-－—]/gu, "");
  if (["america", "美洲", "美服", "美洲服"].includes(key)) return "America";
  if (["europe", "歐洲", "欧洲", "歐服", "欧服", "歐洲服", "欧洲服"].includes(key)) return "Europe";
  if (["asia", "亞洲", "亚洲", "亞服", "亚服", "亞洲服", "亚洲服"].includes(key)) return "Asia";
  if (["sea", "東南亞", "东南亚", "東南亞服", "东南亚服"].includes(key)) return "SEA";
  if (["hmt", "hmt(hk,mo,tw)", "hmt(hkmotw)", "hmt(hk/mo/tw)", "港澳台", "港澳台服"].includes(key)) return "HMT(HK,MO,TW)";
  return "";
}

function splitServerSchedule(value) {
  const text = String(value ?? "").replaceAll("\r", "\n");
  const result = [];
  let token = "";
  let depth = 0;
  for (const character of text) {
    if (["(", "（"].includes(character)) depth += 1;
    if ([")", "）"].includes(character) && depth > 0) depth -= 1;
    if ([",", ";", "；", "|", "\n"].includes(character) && depth === 0) {
      if (token.trim()) result.push(token.trim());
      token = "";
    } else token += character;
  }
  if (token.trim()) result.push(token.trim());
  return result;
}

function configuredServers(value) {
  const result = [];
  for (const item of splitServerSchedule(value)) {
    const canonical = canonicalServerName(item);
    if (canonical && !result.includes(canonical)) result.push(canonical);
  }
  return result.slice(0, SUPPORTED_SERVERS.length);
}

function renderServerChoices(value) {
  const selected = configuredServers(value);
  const grid = $("serverChoiceGrid");
  grid.replaceChildren();
  for (let index = 0; index < SUPPORTED_SERVERS.length; index += 1) {
    const label = document.createElement("label");
    label.textContent = `${index + 1}.`;
    const select = document.createElement("select");
    select.dataset.serverChoice = "true";
    select.setAttribute("aria-label", `第 ${index + 1} 個伺服器`);
    select.append(new Option("未設定", ""));
    SUPPORTED_SERVERS.forEach((server) => select.append(new Option(server, server)));
    select.value = selected[index] ?? "";
    label.append(select);
    grid.append(label);
  }
  refreshServerChoicesEnabled();
}

function refreshServerChoicesEnabled() {
  const enabled = $("scheduleEnabled").checked;
  document.querySelectorAll("select[data-server-choice]").forEach((select) => { select.disabled = !enabled; });
}

function selectedServerChoices() {
  const servers = [...document.querySelectorAll("select[data-server-choice]")]
    .map((select) => select.value).filter(Boolean);
  const duplicates = servers.filter((server, index) => servers.indexOf(server) !== index);
  if (duplicates.length) throw new Error(`同一個伺服器不可重複：${[...new Set(duplicates)].join("、")}`);
  if ($("scheduleEnabled").checked && !servers.length) throw new Error("啟用排程時至少要選擇一個伺服器");
  return servers;
}
function liveQualityLabel(value) {
  return {
    economy: "省流量｜720p／12fps／1.5 Mbps",
    balanced: "平衡｜720p／30fps／3.5 Mbps",
    smooth: "流暢｜720p／60fps／6 Mbps",
  }[normalizeLiveQualityProfile(value)];
}
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

function refreshSnapshot(device = state.details?.device) {
  if (!device) return;
  const snapshot = $("snapshotImage");
  snapshot.src = `/api/v1/devices/${encodeURIComponent(device.uid)}/snapshot?t=${Date.now()}`;
  snapshot.onload = () => { snapshot.hidden = false; $("snapshotEmpty").hidden = true; setText("snapshotMeta", `更新於 ${new Date().toLocaleString("zh-TW", { hour12: false })}`); };
  snapshot.onerror = () => { snapshot.hidden = true; $("snapshotEmpty").hidden = false; setText("snapshotMeta", "尚無快照"); };
}

function renderDetails({ reloadSnapshot = false, reloadSettings = true } = {}) {
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

  if (reloadSnapshot) refreshSnapshot(device);

  const healing = status.selfHealing || {};
  const healingState = String(healing.state || "healthy").toLowerCase();
  const retrySeconds = healing.nextRetryAt
    ? Math.max(0, Math.ceil((Number(healing.nextRetryAt) - Date.now()) / 1000)) : 0;
  const healingLabel = {
    healthy: "正常", idle: "正常", restart_scheduled: "準備修復",
    repairing: "正在修復", cooldown: "冷卻等待", retrying: "正在重試",
    circuit_open: "已抑制重啟迴圈", halted: "已停止並等待處理", cancelled: "已取消",
  }[healingState] || healingState;
  const healingParts = [`自動偵錯：${healingLabel}`];
  if (healing.code) healingParts.push(`${healing.code}${healing.consecutive ? `（連續 ${healing.consecutive} 次）` : ""}`);
  if (healing.action) healingParts.push(healing.action);
  if (retrySeconds) healingParts.push(`${retrySeconds} 秒後再試`);
  if (healing.detail && !healing.action) healingParts.push(healing.detail);
  setText("selfHealingStatus", healingParts.join("｜"));
  $("selfHealingStatus").className = `notice ${["halted", "circuit_open"].includes(healingState)
    ? "danger" : ["repairing", "cooldown", "retrying", "restart_scheduled"].includes(healingState) ? "warning" : "ok"}`;

  const recording = status.recording || Object.fromEntries(Object.entries(status).filter(([key]) => key.toLowerCase().startsWith("recording")));
  const recordingNode = $("recordingStatus"); recordingNode.replaceChildren();
  const recordingCard = document.createElement("div"); recordingCard.className = "recording-status-card";
  if (!Object.keys(recording).length) {
    recordingCard.textContent = "尚未收到錄影資料。";
  } else {
    const stateLine = document.createElement("div"); stateLine.className = "state-line";
    const badge = document.createElement("span"); badge.className = `badge ${String(recording.state).includes("error") || String(recording.state).includes("waiting") ? "warning" : recording.state === "complete" ? "ok" : "muted"}`;
    badge.textContent = recordingStageLabel(recording.state);
    const name = document.createElement("strong"); name.textContent = recording.baseName || "目前錄影工作";
    stateLine.append(badge, name); recordingCard.append(stateLine);
    const progressValue = Number(recording.progressPercent);
    const progress = Number.isFinite(progressValue) && progressValue >= 0 ? progressValue : null;
    let progressDetail = recording.detail || "等待背景工具回報";
    if (Number(recording.progressTotal) > 0) {
      const unitDetail = recording.progressUnit === "segments"
        ? `${recording.progressCurrent}/${recording.progressTotal} 段`
        : `${formatBytes(recording.progressCurrent)}/${formatBytes(recording.progressTotal)}`;
      progressDetail = `${progressDetail}｜${unitDetail}`;
    }
    appendProgress(recordingCard, progress, recordingStageLabel(recording.state), progressDetail);
    const paths = document.createElement("div"); paths.className = "recording-paths";
    if (recording.resultPath) { const row = document.createElement("span"); row.textContent = `完成位置：${recording.resultPath}`; paths.append(row); }
    if (recording.failureStorage && recording.state !== "complete") { const row = document.createElement("span"); row.textContent = `失敗保留：${recording.failureStorage}`; paths.append(row); }
    recordingCard.append(paths);
  }
  recordingNode.append(recordingCard);

  const live = status.live || {};
  const liveDetail = live.detail || "裝置尚未回報直播傳輸狀態。";
  setText("liveDeviceStatus", `${liveDetail}${/UDP/i.test(liveDetail) ? "；正式錄影仍會走 HTTPS 續傳，不影響鋤地。" : ""}`);
  $("liveDeviceStatus").className = `transport-status ${["error"].includes(live.state) ? "danger" : ["retrying"].includes(live.state) ? "warning" : "muted"}`;

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
  if (reloadSettings && !$("settingsForm").contains(document.activeElement)) renderSettings(displayedSettings);
  setText("liveProfileSummary", `${liveQualityLabel(displayedSettings.liveQualityProfile)}；有人觀看時才推流。`);
}

function renderSettings(settings) {
  $("scheduleEnabled").checked = Boolean(settings.serverScheduleEnabled);
  renderServerChoices(settings.serverScheduleList || "");
  $("maxRestart").value = settings.maxRestartCount ?? 10;
  $("snapshotInterval").value = settings.runtimeDiagnosticsIntervalSec ?? 60;
  $("snapshotKeep").value = settings.runtimeDiagnosticsErrorKeepCount ?? 30;
  $("diagnosticsEnabled").checked = settings.runtimeDiagnosticsEnabled !== false;
  $("mailEnabled").checked = Boolean(settings.mailNotifyEnabled);
  $("liveQualityProfile").value = normalizeLiveQualityProfile(settings.liveQualityProfile);
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
    card.append(title, meta);
    const progress = centralRecordingProgress(item);
    const transfer = item.expected_bytes
      ? `${formatBytes(item.received_bytes)}/${formatBytes(item.expected_bytes)}`
      : item.expected_segments
        ? `已收到 ${item.segment_count || 0}/${item.expected_segments} 段`
        : `${item.ready_segments || 0}/${item.segment_count || 0} 段已可播放；尚待執行端回報總段數`;
    appendProgress(card, progress.percent, recordingStageLabel(progress.stage),
      `${item.detail || "中央錄影處理中"}｜${transfer}｜可播放 ${item.ready_segments || 0}/${item.expected_segments ?? "?"} 段`);
    const button = document.createElement("button"); button.type = "button"; button.textContent = item.playable ? "播放完整影片" : "查看已完成片段";
    button.addEventListener("click", () => openRecording(item));
    card.append(button); list.append(card);
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

function mergeRefreshOptions(left = {}, right = {}) {
  return {
    includeDevices: left.includeDevices !== false || right.includeDevices !== false,
    includeRecordings: left.includeRecordings !== false || right.includeRecordings !== false,
    reloadSnapshot: Boolean(left.reloadSnapshot || right.reloadSnapshot),
    reloadSettings: Boolean(left.reloadSettings || right.reloadSettings),
    admin: Boolean(left.admin || right.admin),
  };
}

async function refresh(options = {}) {
  const requested = {
    includeDevices: options.includeDevices !== false,
    includeRecordings: options.includeRecordings !== false,
    reloadSnapshot: Boolean(options.reloadSnapshot),
    reloadSettings: options.reloadSettings !== false,
    admin: Boolean(options.admin),
  };
  if (state.refreshInFlight) {
    state.refreshQueued = mergeRefreshOptions(state.refreshQueued || {
      includeDevices: false, includeRecordings: false, reloadSettings: false,
    }, requested);
    return;
  }
  state.refreshInFlight = true;
  try {
    const previousUid = state.selectedUid;
    if (requested.includeDevices) {
      const payload = await api("/api/v1/devices");
      state.devices = payload.devices || [];
      state.migration = payload.migration || {};
      renderDevices();
    }
    const selectedChanged = previousUid !== state.selectedUid;
    if (state.selectedUid) {
      const encoded = encodeURIComponent(state.selectedUid);
      const requests = [api(`/api/v1/devices/${encoded}`)];
      if (requested.includeRecordings) requests.push(api(`/api/v1/devices/${encoded}/recordings`));
      const [details, recordings] = await Promise.all(requests);
      state.details = details;
      if (recordings) state.recordings = recordings.recordings || [];
      renderDetails({
        reloadSnapshot: requested.reloadSnapshot || selectedChanged,
        reloadSettings: requested.reloadSettings,
      });
      if (requested.includeRecordings) renderRecordings();
    }
    if (requested.admin) await refreshAdmin();
  } finally {
    state.refreshInFlight = false;
    if (state.refreshQueued) {
      const queued = state.refreshQueued;
      state.refreshQueued = null;
      setTimeout(() => refresh(queued).catch((error) => toast(error.message)), 0);
    }
  }
}

function scheduleFullRefresh() {
  clearTimeout(state.refreshTimer);
  state.refreshTimer = setTimeout(() => refresh({ reloadSettings: true }).catch((error) => toast(error.message)), 500);
}

function scheduleSelectedRefresh(includeRecordings = false) {
  clearTimeout(state.selectedRefreshTimer);
  state.selectedRefreshTimer = setTimeout(() => refresh({
    includeDevices: false, includeRecordings, reloadSettings: false,
  }).catch((error) => toast(error.message)), 650);
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
    const deviceLive = state.details?.device?.status?.live || {};
    const explicitFailure = ["retrying", "error"].includes(deviceLive.state) ? deviceLive.detail : "";
    setText("liveMessage", explicitFailure
      ? `${explicitFailure}（已等待 ${elapsed} 秒）`
      : `已建立觀看租約，正在等待執行端連入（${elapsed} 秒${reason ? `，${reason}` : ""}）。`);
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
    state.activeTab = button.dataset.tab;
    if (state.activeTab === "settings") refresh({ admin: true, reloadSettings: true }).catch((error) => toast(error.message));
    else if (state.activeTab === "videos") refresh({ includeDevices: false, includeRecordings: true, reloadSettings: false }).catch((error) => toast(error.message));
  }));
  deviceSelect.addEventListener("change", async () => { await stopLive(); state.selectedUid = deviceSelect.value; localStorage.setItem("wuthering.selectedUid", state.selectedUid); await refresh({ reloadSnapshot: true, admin: state.activeTab === "settings" }); });
  $("refreshButton").addEventListener("click", () => refresh({ reloadSnapshot: true, admin: state.activeTab === "settings" }).catch((error) => toast(error.message)));
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
        serverScheduleList: selectedServerChoices().join(" | "),
        maxRestartCount: Number($("maxRestart").value), runtimeDiagnosticsEnabled: $("diagnosticsEnabled").checked,
        runtimeDiagnosticsIntervalSec: Number($("snapshotInterval").value), runtimeDiagnosticsErrorKeepCount: Number($("snapshotKeep").value),
        mailNotifyEnabled: $("mailEnabled").checked,
        liveQualityProfile: normalizeLiveQualityProfile($("liveQualityProfile").value),
      }});
      toast("設定已儲存，等待裝置 ACK"); await refresh();
    } catch (error) { toast(error.message); }
  });
  $("scheduleEnabled").addEventListener("change", refreshServerChoicesEnabled);
  $("startLiveButton").addEventListener("click", () => startLive().catch((error) => toast(error.message)));
  $("stopLiveButton").addEventListener("click", () => stopLive());
  $("cutoverButton").addEventListener("click", async () => { if (!confirm("確認兩台裝置與影片均完成驗證，正式把命令來源切到自架伺服器？")) return; try { await api("/api/v1/admin/migration/cutover", { method: "POST" }); toast("已切換為自架正式控制"); await refresh(); } catch (error) { toast(error.message); } });
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) refresh({ reloadSettings: state.activeTab === "settings", admin: state.activeTab === "settings" }).catch((error) => toast(error.message));
  });
  window.addEventListener("beforeunload", () => {
    clearInterval(state.liveTimer); clearTimeout(state.liveRetryTimer); clearInterval(state.periodicTimer);
    clearTimeout(state.refreshTimer); clearTimeout(state.selectedRefreshTimer);
  });
}

async function boot() {
  renderServerChoices("");
  appView.hidden = false;
  bindEvents();
  state.me = await api("/api/v1/auth/me");
  setText("releaseBadge", `Server ${state.me.serverVersion || "未知"}`);
  $("releaseBadge").className = "badge muted";
  await refresh({ reloadSnapshot: true, admin: true });
  clearInterval(state.periodicTimer);
  state.periodicTimer = setInterval(() => {
    if (!document.hidden) refresh({ reloadSettings: state.activeTab === "settings", admin: state.activeTab === "settings" }).catch((error) => toast(error.message));
  }, 60_000);
  const events = new EventSource("/api/v1/events"); state.eventSource = events;
  ["device", "command", "settings"].forEach((name) => events.addEventListener(name, scheduleFullRefresh));
  events.addEventListener("live", () => scheduleSelectedRefresh(false));
  events.addEventListener("recording", () => scheduleSelectedRefresh(true));
  events.addEventListener("snapshot", (event) => {
    try {
      const payload = JSON.parse(event.data || "{}");
      if (!payload.uid || payload.uid === state.selectedUid) refreshSnapshot();
    } catch { refreshSnapshot(); }
  });
  events.onerror = () => setText("deviceSummary", "即時連線暫時中斷，正在自動重連…");
}

boot().catch((error) => {
  appView.hidden = false;
  setText("deviceSummary", `控制台載入失敗：${error.message}`);
  toast(`控制台載入失敗：${error.message}`);
});
