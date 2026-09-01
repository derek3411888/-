const state = {
  me: null,
  devices: [],
  migration: null,
  selectedUid: localStorage.getItem("wuthering.selectedUid") || "",
  details: null,
  performance: null,
  performanceRange: localStorage.getItem("wuthering.performanceRange") || "6h",
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
  codexSupportData: null,
  codexSupportSending: false,
  codexSupportRecoveryBusy: false,
  codexSupportError: "",
  codexSupportTimer: 0,
  codexSupportRefreshInFlight: false,
  settingsSaving: false,
  settingsSaveStatus: null,
};

const SUPPORTED_SERVERS = ["America", "Europe", "Asia", "HMT(HK,MO,TW)", "SEA"];
const CODEX_SUPPORT_MAX_MESSAGE_LENGTH = 1000;
const CODEX_SUPPORT_COOLDOWN_MS = 5 * 60_000;
const CODEX_BRIDGE_ONLINE_MS = 3 * 60_000;
const CODEX_SUPPORT_PENDING_STATES = ["PENDING", "RECEIVED", "VALIDATING", "QUEUEING", "RETRYING"];
const CODEX_SUPPORT_PRESETS = Object.freeze({
  FIX_SCRIPT: Object.freeze({ label: "找出問題並修正", message: "現在腳本有問題，請你找出問題並修正" }),
  DIAGNOSE_ONLY: Object.freeze({ label: "只分析原因", message: "現在腳本有問題，請找出原因並回報，先不要修改任何檔案。" }),
  CHECK_CURRENT_STATUS: Object.freeze({ label: "檢查目前狀態", message: "請檢查目前腳本執行狀態與最新 Log，告訴我現在發生什麼事；先不要修改。" }),
});

const $ = (id) => document.getElementById(id);
const appView = $("appView");
const deviceSelect = $("deviceSelect");
const codexStages = {
  submitted: $("codexStageSubmitted"),
  received: $("codexStageReceived"),
  validated: $("codexStageValidated"),
  attempted: $("codexStageAttempted"),
  queued: $("codexStageQueued"),
  response: $("codexStageResponse"),
};
const codexDetails = {
  state: $("codexDetailState"), nonce: $("codexDetailNonce"), requestedAt: $("codexDetailRequestedAt"),
  device: $("codexDetailDevice"), message: $("codexDetailMessage"), host: $("codexDetailHost"),
  log: $("codexDetailLog"),
  heartbeat: $("codexDetailHeartbeat"), receivedAt: $("codexDetailReceivedAt"), validatedAt: $("codexDetailValidatedAt"),
  attemptCount: $("codexDetailAttemptCount"), lastAttemptAt: $("codexDetailLastAttemptAt"),
  queuedAt: $("codexDetailQueuedAt"), nextRetryAt: $("codexDetailNextRetryAt"),
  messageHash: $("codexDetailMessageHash"), error: $("codexDetailError"),
};

function escapeText(value) { return String(value ?? ""); }
function formatTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? "—" : date.toLocaleString("zh-TW", { hour12: false });
}
function formatBytes(value) {
  const bytes = Math.max(0, Number(value) || 0);
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(2)} GB`;
  if (bytes >= 1024 ** 2) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${Math.round(bytes)} B`;
}

function metric(value, digits = 1, suffix = "") {
  const number = Number(value);
  return Number.isFinite(number) ? `${number.toFixed(digits)}${suffix}` : "—";
}

function performanceCollectorHealth(collector = {}) {
  const state = String(collector.state || "").trim().toLowerCase();
  const presentMon = String(collector.presentMon || "").trim().toLowerCase();
  const recovered = state === "running"
    && ((presentMon === "capturing" && Boolean(collector.fpsAvailable)) || presentMon === "waiting_game");
  const activeError = recovered ? "" : String(collector.error || "").trim();
  const problem = Boolean(activeError) || ["degraded", "error"].includes(state)
    || ["retry_wait", "error"].includes(presentMon);
  return { state, presentMon, recovered, activeError, problem };
}

function freshestPerformanceSnapshot(primary = null, fallback = null) {
  const timestamp = (value) => Math.max(
    Number.isFinite(Number(value?.current?.at)) ? Number(value.current.at) : 0,
    Number.isFinite(Number(value?.collector?.updatedAt)) ? Number(value.collector.updatedAt) : 0,
  );
  if (!primary) return fallback || {};
  if (!fallback) return primary;
  return timestamp(fallback) > timestamp(primary) ? fallback : primary;
}

function performancePoints() {
  return (state.performance?.points || []).map((row) => ({
    at: new Date(row.bucket_start).valueOf(),
    ...(row.metrics || {}),
    context: row.context || {},
  })).filter((row) => Number.isFinite(row.at));
}

function drawPerformanceChart(canvas, points, series, { fixedMax = 0, suffix = "" } = {}) {
  if (!canvas) return;
  const width = Math.max(300, Math.round(canvas.getBoundingClientRect().width || canvas.clientWidth || 480));
  const height = Math.max(160, Math.round(canvas.getBoundingClientRect().height || canvas.clientHeight || 210));
  const ratio = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = Math.round(width * ratio); canvas.height = Math.round(height * ratio);
  const context = canvas.getContext("2d");
  context.setTransform(ratio, 0, 0, ratio, 0, 0); context.clearRect(0, 0, width, height);
  const padding = { left: 42, right: 12, top: 12, bottom: 25 };
  const plotWidth = width - padding.left - padding.right;
  const plotHeight = height - padding.top - padding.bottom;
  const values = points.flatMap((point) => series.map((item) => Number(point[item.key])).filter(Number.isFinite));
  context.font = '11px system-ui, "Microsoft JhengHei", sans-serif';
  context.fillStyle = "#718391";
  if (!points.length || !values.length) {
    context.textAlign = "center"; context.fillText("尚無這段時間的資料", width / 2, height / 2); return;
  }
  const firstAt = points[0].at; const lastAt = points.at(-1).at;
  const span = Math.max(60_000, lastAt - firstAt);
  const maximum = fixedMax || Math.max(1, Math.max(...values) * 1.12);
  context.strokeStyle = "#e4ebf0"; context.lineWidth = 1; context.textAlign = "right";
  for (let index = 0; index <= 4; index += 1) {
    const y = padding.top + plotHeight * index / 4;
    context.beginPath(); context.moveTo(padding.left, y); context.lineTo(width - padding.right, y); context.stroke();
    context.fillText(`${(maximum * (1 - index / 4)).toFixed(maximum <= 10 ? 1 : 0)}${suffix}`, padding.left - 5, y + 4);
  }
  const errorEvents = (state.details?.events || []).filter((item) => String(item.level).toUpperCase() === "ERROR")
    .map((item) => new Date(item.event_at).valueOf()).filter((at) => at >= firstAt && at <= lastAt);
  context.save(); context.strokeStyle = "rgba(189,61,72,.32)"; context.setLineDash([3, 3]);
  for (const at of errorEvents) {
    const x = padding.left + (at - firstAt) / span * plotWidth;
    context.beginPath(); context.moveTo(x, padding.top); context.lineTo(x, padding.top + plotHeight); context.stroke();
  }
  context.restore();
  for (const item of series) {
    context.beginPath(); context.strokeStyle = item.color; context.lineWidth = 2; context.lineJoin = "round";
    let drawing = false;
    for (const point of points) {
      const value = Number(point[item.key]);
      if (!Number.isFinite(value)) { drawing = false; continue; }
      const x = padding.left + (point.at - firstAt) / span * plotWidth;
      const y = padding.top + plotHeight - Math.max(0, Math.min(1, value / maximum)) * plotHeight;
      if (!drawing) { context.moveTo(x, y); drawing = true; } else context.lineTo(x, y);
    }
    context.stroke();
  }
  context.fillStyle = "#718391"; context.textAlign = "left";
  context.fillText(new Date(firstAt).toLocaleTimeString("zh-TW", { hour: "2-digit", minute: "2-digit", hour12: false }), padding.left, height - 6);
  context.textAlign = "right";
  context.fillText(new Date(lastAt).toLocaleTimeString("zh-TW", { hour: "2-digit", minute: "2-digit", hour12: false }), width - padding.right, height - 6);
}

function renderPerformance(fallback = null) {
  const wrapped = freshestPerformanceSnapshot(state.performance?.current, fallback);
  const current = wrapped.current || {};
  const collector = wrapped.collector || {};
  const collectorHealth = performanceCollectorHealth(collector);
  setText("perfFps", metric(current.fps, 1));
  setText("perfFpsLow", `1% Low ${metric(current.fps1Low, 1)}`);
  setText("perfFrameTime", metric(current.frameTimeMs, 1, " ms"));
  setText("perfFrameP95", `P95 ${metric(current.frameTimeP95Ms, 1, " ms")}`);
  setText("perfCpu", metric(current.cpuTotalPct, 1, "%"));
  setText("perfGameCpu", `遊戲 ${metric(current.cpuGamePct, 1, "%")}`);
  setText("perfGpu", metric(current.gpuPct, 1, "%"));
  setText("perfEncoder", `編碼器 ${metric(current.gpuEncoderPct, 1, "%")}`);
  setText("perfRam", Number.isFinite(Number(current.ramUsedGb)) && Number.isFinite(Number(current.ramTotalGb))
    ? `${Number(current.ramUsedGb).toFixed(1)} / ${Number(current.ramTotalGb).toFixed(1)} GB` : "—");
  setText("perfGameRam", `遊戲 ${metric(current.gameRamMb, 0, " MB")}`);
  setText("perfVram", metric(current.gpuVramMb, 0, " MB"));
  setText("perfTemperature", `溫度 ${metric(current.gpuTempC, 0, "°C")}｜功耗 ${metric(current.gpuPowerW, 0, " W")}`);
  setText("perfDiskWrite", metric(current.diskWriteMbps, 1, " Mbps"));
  setText("perfDiskFree", `可用 ${metric(current.diskFreeGb, 1, " GB")}`);
  setText("perfRecording", current.recordingActive ? `${metric(current.recordingFps, 1)} fps` : "未錄影");
  setText("perfLive", current.liveActive ? `直播 ${metric(current.liveFps, 1)} fps` : "直播未啟動");

  const ageSeconds = current.at ? Math.max(0, Math.floor((Date.now() - Number(current.at)) / 1000)) : null;
  const presentMonText = {
    capturing: collector.fpsAvailable ? "FPS 正常" : "等待遊戲畫面",
    waiting_game: "遊戲未執行，FPS 暫無資料",
    starting: "採集器啟動中",
    retry_wait: "FPS 工具等待權限或稍後重試",
    error: "FPS 工具暫時失敗",
  }[collector.presentMon] || "FPS 工具尚未回報";
  const collectorText = collectorHealth.problem
    ? "效能資料部分可用；遊戲 FPS 採集異常"
    : collectorHealth.state === "running"
      ? "效能採集正常"
      : `採集器：${collector.state || "尚無資料"}`;
  const noticeParts = [collectorText, presentMonText];
  if (ageSeconds !== null) noticeParts.push(`${ageSeconds} 秒前更新`);
  if (collectorHealth.activeError) noticeParts.push(`目前錯誤：${collectorHealth.activeError}`);
  setText("performanceNotice", noticeParts.join("｜"));
  $("performanceNotice").className = `transport-status ${collectorHealth.problem || (ageSeconds !== null && ageSeconds > 30) ? "warning" : "muted"}`;

  const points = performancePoints();
  drawPerformanceChart($("perfFpsChart"), points, [
    { key: "fps", color: "#236f9f" }, { key: "fps1Low", color: "#1c9a70" },
  ]);
  drawPerformanceChart($("perfUsageChart"), points, [
    { key: "cpuTotalPct", color: "#236f9f" }, { key: "gpuPct", color: "#1c9a70" }, { key: "gpuEncoderPct", color: "#d17b2b" },
  ], { fixedMax: 100, suffix: "%" });
  drawPerformanceChart($("perfFrameChart"), points, [
    { key: "frameTimeMs", color: "#1c9a70" }, { key: "frameTimeP95Ms", color: "#d17b2b" },
  ], { suffix: "ms" });
  drawPerformanceChart($("perfIoChart"), points, [
    { key: "diskWriteMbps", color: "#1c9a70" }, { key: "networkUpMbps", color: "#d17b2b" },
  ], { suffix: "M" });
}
function recordingStageLabel(value) {
  return {
    starting: "準備單檔錄影",
    recording: "單檔錄影中",
    stopping: "正在正常封口",
    complete: "單一 MKV 已完成",
    recording_interrupted: "錄影非預期中斷",
    stop_forced: "強制停止，請檢查檔案",
    stop_failed: "錄影停止失敗",
    final_missing: "找不到有效單檔",
    legacy_retained: "舊分段已原地保留",
  }[String(value ?? "")] || String(value || "等待錄影資料");
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

function formatAge(value) {
  const at = Math.max(0, Number(value) || 0);
  if (!at) return "尚未回報";
  const seconds = Math.max(0, Math.floor((Date.now() - at) / 1000));
  if (seconds < 60) return `${seconds} 秒前`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} 分鐘前`;
  return `${Math.floor(minutes / 60)} 小時前`;
}

function normalizeCodexSupportMessage(value) {
  return String(value ?? "")
    .replace(/\r\n?/g, "\n")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "")
    .trim();
}

function selectedCodexSupportMessage() {
  const mode = String($("codexMessagePreset").value || "FIX_SCRIPT");
  if (mode === "CUSTOM") {
    return { mode, label: "自訂訊息", message: normalizeCodexSupportMessage($("codexCustomMessage").value) };
  }
  const preset = CODEX_SUPPORT_PRESETS[mode] || CODEX_SUPPORT_PRESETS.FIX_SCRIPT;
  return { mode, label: preset.label, message: preset.message };
}

function updateCodexMessageControls() {
  const custom = $("codexMessagePreset").value === "CUSTOM";
  $("codexCustomMessageField").hidden = !custom;
  const length = normalizeCodexSupportMessage($("codexCustomMessage").value).length;
  $("codexMessageCharacterCount").textContent = `${length} / ${CODEX_SUPPORT_MAX_MESSAGE_LENGTH}`;
  renderCodexLogSelection();
  renderCodexSupportStatus();
}

function syncCodexLogDeviceOptions(preferCurrent = false) {
  const select = $("codexLogDeviceSelect");
  const previous = preferCurrent ? String(state.selectedUid || "") : String(select.value || "");
  const rows = [...state.devices].sort((a, b) => new Date(b.last_seen || 0) - new Date(a.last_seen || 0));
  select.replaceChildren();
  for (const device of rows) {
    select.append(new Option(`${device.display_name || device.uid}｜${device.uid}`, device.uid));
  }
  if (!rows.length) select.append(new Option("沒有可選裝置", ""));
  select.value = rows.some((device) => device.uid === previous)
    ? previous
    : rows.some((device) => device.uid === state.selectedUid) ? state.selectedUid : rows[0]?.uid || "";
  renderCodexLogSelection();
}

function renderCodexLogSelection() {
  const attach = Boolean($("codexAttachSelectedLog").checked);
  const select = $("codexLogDeviceSelect");
  select.disabled = !attach || select.options.length === 0;
  const device = state.devices.find((item) => item.uid === select.value);
  if (!attach) return setText("codexSelectedLogSummary", "這次不附裝置 Log");
  if (!device) return setText("codexSelectedLogSummary", "尚未選到可用裝置");
  const log = device.status?.diagnosticLog || {};
  setText("codexSelectedLogSummary", log.available
    ? `${device.display_name || device.uid}｜${log.fileName || "最近 Log"}｜${formatTime(log.capturedAt)} 擷取`
    : `${device.display_name || device.uid}｜執行端尚未回報 Log；仍會附上目前狀態與最近流程事件`);
}

function setCodexStage(element, stageState, detail) {
  if (!element) return;
  element.dataset.state = stageState;
  const small = element.querySelector("small");
  if (small) small.textContent = detail;
}

function setCodexSupportMessage(kind, message) {
  for (const element of [$("codexSupportStatus"), $("codexSupportDialogStatus")]) {
    element.className = `support-status ${kind}`;
    element.textContent = message;
  }
}

function renderCodexSupportStatus() {
  const data = state.codexSupportData || {};
  const requestNonce = Math.max(0, Number(data.requestNonce) || 0);
  const statusNonce = Math.max(0, Number(data.statusNonce) || 0);
  const storedState = String(data.state || "").trim().toUpperCase();
  const supportState = requestNonce > statusNonce ? "PENDING" : storedState;
  const detail = String(data.detail || "").trim();
  const heartbeatAt = Math.max(0, Number(data.heartbeatAt) || 0);
  const requestedAt = Math.max(0, Number(data.requestedAt) || 0);
  const receivedAt = Math.max(0, Number(data.receivedAt) || 0);
  const validatedAt = Math.max(0, Number(data.validatedAt) || 0);
  const lastAttemptAt = Math.max(0, Number(data.lastAttemptAt) || 0);
  const nextRetryAt = Math.max(0, Number(data.nextRetryAt) || 0);
  const queuedAt = Math.max(0, Number(data.queuedAt) || 0);
  const attemptCount = Math.max(0, Number(data.attemptCount) || 0);
  const bridgeOnline = heartbeatAt > 0 && Date.now() - heartbeatAt < CODEX_BRIDGE_ONLINE_MS;
  const cooldownRemaining = queuedAt > 0 ? Math.max(0, queuedAt + CODEX_SUPPORT_COOLDOWN_MS - Date.now()) : 0;
  const requestPending = requestNonce > statusNonce || (
    requestNonce === statusNonce && CODEX_SUPPORT_PENDING_STATES.includes(supportState)
  );
  const responseState = String(data.responseState || "NONE").trim().toUpperCase();
  const responsePending = supportState === "QUEUED" && ["WAITING", "IN_PROGRESS"].includes(responseState);
  const safelyCancellable = requestPending && attemptCount === 0
    && ["PENDING", "RECEIVED", "VALIDATING", "RETRYING"].includes(supportState);
  const stalled = safelyCancellable && requestedAt > 0
    && Date.now() - requestedAt >= CODEX_BRIDGE_ONLINE_MS;
  const dispatchResultUnknown = String(data.errorCode || "").trim().toUpperCase() === "DISPATCH_RESULT_UNKNOWN";
  const retryable = !dispatchResultUnknown
    && (["CANCELLED", "REJECTED", "RATE_LIMITED", "FAILED"].includes(supportState) || stalled);
  const selection = selectedCodexSupportMessage();
  $("btnAskCodex").disabled = state.codexSupportSending || state.codexSupportRecoveryBusy || requestPending || responsePending || cooldownRemaining > 0
    || !selection.message || selection.message.length > CODEX_SUPPORT_MAX_MESSAGE_LENGTH;
  $("btnCancelCodexSupport").disabled = state.codexSupportSending || state.codexSupportRecoveryBusy || !safelyCancellable;
  $("btnRetryCodexSupport").disabled = state.codexSupportSending || state.codexSupportRecoveryBusy || !retryable;
  setText("codexRecoveryHint", stalled
    ? "這筆請求已超過 3 分鐘且尚未嘗試，可取消，或取消後用新編號重送。"
    : dispatchResultUnknown
      ? "傳送結果不明，這筆訊息可能已進入 Codex；為避免重複執行，不能直接重送。請先檢查目前 Codex 任務。"
    : safelyCancellable
      ? "請求尚未送進 Codex，可以安全取消。若超過 3 分鐘未動作，會開放新編號重送。"
      : supportState === "QUEUED"
        ? (responsePending ? "這筆請求正在 Codex 處理；完成後回覆會直接顯示在這裡。" : "這筆請求已送進 Codex，不能撤回或重送，避免重複執行。")
        : retryable
          ? "可以保留相同內容與裝置 Log，建立新的請求編號重送。"
          : "一般控制台會直接寫入中央主機，不經 Firestore。只有尚未進入 Codex 的請求可以安全取消。");

  const stateLabels = {
    PENDING: "已送出，等待家中主機", RECEIVED: "家中主機已收到", VALIDATING: "正在驗證訊息",
    QUEUEING: "正在送往 Codex", RETRYING: "Codex 暫未接收，等待重試", QUEUED: "已排入目前 Codex 任務",
    REJECTED: "訊息被主機拒絕", RATE_LIMITED: "送出過於頻繁", FAILED: "傳送失敗",
    CANCELLED: "已取消（未送進 Codex）", READY: "橋接程式待命",
  };
  codexDetails.state.textContent = stateLabels[supportState] || (bridgeOnline ? "橋接程式待命" : "等待家中主機");
  codexDetails.nonce.textContent = requestNonce > 0 ? String(requestNonce) : "-";
  codexDetails.requestedAt.textContent = formatTime(requestedAt);
  codexDetails.device.textContent = String(data.requestedDeviceUid || "未指定");
  codexDetails.log.textContent = data.contextIncluded
    ? `已附上${data.logFileName ? ` ${data.logFileName}` : "裝置狀態／Log"}（${Number(data.contextLength) || 0} 字元）`
    : "未附上";
  codexDetails.message.textContent = String(data.requestMessage || "-");
  codexDetails.host.textContent = [data.host, data.bridgeVersion ? `Bridge ${data.bridgeVersion}` : ""].filter(Boolean).join(" · ") || "-";
  codexDetails.heartbeat.textContent = heartbeatAt ? `${formatTime(heartbeatAt)}（${formatAge(heartbeatAt)}）` : "-";
  codexDetails.receivedAt.textContent = formatTime(receivedAt);
  codexDetails.validatedAt.textContent = formatTime(validatedAt);
  codexDetails.attemptCount.textContent = String(attemptCount);
  codexDetails.lastAttemptAt.textContent = formatTime(lastAttemptAt);
  codexDetails.queuedAt.textContent = formatTime(queuedAt);
  codexDetails.nextRetryAt.textContent = formatTime(nextRetryAt);
  codexDetails.messageHash.textContent = data.messageSha256 ? `SHA-256 ${data.messageSha256}` : "-";
  codexDetails.error.textContent = [data.errorCode, data.errorDetail || detail].filter(Boolean).join("：") || "-";

  const lifecycle = requestNonce > 0 && supportState !== "READY";
  for (const stage of Object.values(codexStages)) setCodexStage(stage, "waiting", "等待前一步完成");
  if (lifecycle) {
    setCodexStage(codexStages.submitted, "done", requestedAt ? `已於 ${formatTime(requestedAt)} 寫入` : "網站已寫入請求");
    setCodexStage(codexStages.received, "active", "等待橋接程式讀取");
  } else {
    setCodexStage(codexStages.submitted, "waiting", "目前沒有新請求");
    setCodexStage(codexStages.received, "waiting", "等待網站送出新請求");
  }
  if (["RECEIVED", "VALIDATING", "QUEUEING", "RETRYING", "QUEUED", "REJECTED", "RATE_LIMITED", "FAILED"].includes(supportState)) {
    setCodexStage(codexStages.received, "done", receivedAt ? `收到於 ${formatTime(receivedAt)}` : "家中主機已讀取");
    setCodexStage(codexStages.validated, "active", "正在檢查訊息");
  }
  if (["QUEUEING", "RETRYING", "QUEUED", "RATE_LIMITED", "FAILED"].includes(supportState)) {
    setCodexStage(codexStages.validated, "done", validatedAt ? `完成於 ${formatTime(validatedAt)}` : "訊息驗證完成");
    setCodexStage(codexStages.attempted, "active", attemptCount > 0 ? `第 ${attemptCount} 次嘗試` : "準備送往 Codex");
  }
  if (supportState === "QUEUED") {
    setCodexStage(codexStages.attempted, "done", `第 ${Math.max(1, attemptCount)} 次送出成功`);
    setCodexStage(codexStages.queued, "done", queuedAt ? `排入於 ${formatTime(queuedAt)}` : "Codex 佇列已接收");
    if (responseState === "COMPLETED") {
      setCodexStage(codexStages.response, "done", data.responseAt ? `完成於 ${formatTime(data.responseAt)}` : "最終回覆已同步");
    } else if (["FAILED", "INTERRUPTED"].includes(responseState)) {
      setCodexStage(codexStages.response, "error", data.replyError || (responseState === "INTERRUPTED" ? "Codex 處理中斷" : "Codex 未產生最終回覆"));
    } else {
      setCodexStage(codexStages.response, "active", responseState === "IN_PROGRESS" ? "Codex 正在處理" : "等待 Codex 開始處理");
    }
  } else if (supportState === "RETRYING") {
    setCodexStage(codexStages.attempted, "active", nextRetryAt ? `第 ${attemptCount} 次未成功；${formatTime(nextRetryAt)} 重試` : "暫未成功，會自動重試");
  } else if (supportState === "REJECTED") {
    setCodexStage(codexStages.validated, "error", data.errorDetail || detail || "訊息未通過驗證");
  } else if (supportState === "RATE_LIMITED") {
    setCodexStage(codexStages.attempted, "error", detail || "仍在五分鐘間隔內");
  } else if (supportState === "FAILED") {
    setCodexStage(codexStages.attempted, "error", data.errorDetail || detail || "無法送進 Codex");
  } else if (supportState === "CANCELLED") {
    setCodexStage(codexStages.received, "error", detail || "已取消，未送進 Codex");
  }

  const responseCard = $("codexResponseCard");
  const responseText = String(data.responseText || "").trim();
  const responseLabels = {
    NONE: ["waiting", "尚未送出", "請求送進 Codex 後，這裡會顯示處理狀態與最後回覆。", "muted"],
    WAITING: ["waiting", "等待 Codex", "已排入目前任務，等待 Codex 開始處理。", "warning"],
    IN_PROGRESS: ["in-progress", "處理中", "Codex 正在處理這筆網站回報；完成後會自動更新。", "warning"],
    COMPLETED: ["completed", "已完成", "已取得這個 Codex turn 的最終回覆。", "ok"],
    FAILED: ["failed", "失敗", data.replyError || "Codex 任務結束但沒有可顯示的最終回覆。", "danger"],
    INTERRUPTED: ["interrupted", "已中斷", data.replyError || "Codex turn 已中斷，沒有最終回覆。", "danger"],
  };
  const responseView = responseLabels[responseState] || responseLabels.NONE;
  responseCard.className = `codex-response-card ${responseView[0]}`;
  $("codexResponseBadge").className = `badge ${responseView[3]}`;
  setText("codexResponseBadge", responseView[1]);
  setText("codexResponseAt", formatTime(data.responseAt));
  setText("codexResponseHint", responseView[2]);
  $("codexResponseText").hidden = !responseText;
  $("codexResponseText").textContent = responseText;

  if (state.codexSupportSending) return setCodexSupportMessage("pending", "正在寫入一般控制台請求…");
  if (state.codexSupportError) return setCodexSupportMessage("error", state.codexSupportError);
  if (requestPending) return setCodexSupportMessage("pending", detail || stateLabels[supportState] || "已送出，等待家中主機接收…");
  if (requestNonce > 0 && requestNonce === statusNonce && supportState === "QUEUED" && responsePending) {
    return setCodexSupportMessage("pending", responseState === "IN_PROGRESS" ? "Codex 正在處理；完成後會在這裡顯示回覆" : "已送進 Codex，等待開始處理");
  }
  if (requestNonce > 0 && requestNonce === statusNonce && supportState === "QUEUED" && responseState === "COMPLETED") {
    return setCodexSupportMessage("ok", "Codex 已完成，最終回覆已同步到網站");
  }
  if (requestNonce > 0 && requestNonce === statusNonce && supportState === "QUEUED" && ["FAILED", "INTERRUPTED"].includes(responseState)) {
    return setCodexSupportMessage("error", data.replyError || "Codex 沒有產生可顯示的最終回覆");
  }
  if (requestNonce > 0 && requestNonce === statusNonce && supportState === "QUEUED") {
    return setCodexSupportMessage("ok", cooldownRemaining > 0
      ? `已送進目前 Codex 任務；${Math.ceil(cooldownRemaining / 1000)} 秒後可再次送出`
      : "已送進目前 Codex 任務");
  }
  if (requestNonce > 0 && requestNonce === statusNonce && ["REJECTED", "RATE_LIMITED", "FAILED", "CANCELLED"].includes(supportState)) {
    return setCodexSupportMessage("error", detail || "本機 Codex 未接收，請稍後重試");
  }
  return setCodexSupportMessage("idle", bridgeOnline
    ? `本機 Codex 已連線（${formatAge(heartbeatAt)}）`
    : "家中主機尚未回報 Codex 連線");
}

function stopCodexSupportPolling() {
  clearTimeout(state.codexSupportTimer);
  state.codexSupportTimer = 0;
}

function scheduleCodexSupportRefresh() {
  stopCodexSupportPolling();
  if (!$("codexSupportDialog").open) return;
  const delay = state.codexSupportData?.pending ? 3_000 : 15_000;
  state.codexSupportTimer = setTimeout(() => refreshCodexSupport().catch(() => {}), delay);
}

async function refreshCodexSupport({ schedule = true } = {}) {
  if (state.codexSupportRefreshInFlight) return;
  state.codexSupportRefreshInFlight = true;
  try {
    state.codexSupportData = await api("/api/v1/codex-support");
    state.codexSupportError = "";
  } catch (error) {
    state.codexSupportError = `無法讀取 Codex 橋接狀態：${error.message}`;
  } finally {
    state.codexSupportRefreshInFlight = false;
    renderCodexSupportStatus();
    if (schedule) scheduleCodexSupportRefresh();
  }
}

async function requestCodexSupport() {
  if (state.codexSupportSending) return;
  const selection = selectedCodexSupportMessage();
  if (!selection.message) {
    state.codexSupportError = "請先輸入要送出的自訂訊息";
    renderCodexSupportStatus();
    $("codexCustomMessage").focus();
    return;
  }
  if (selection.message.length > CODEX_SUPPORT_MAX_MESSAGE_LENGTH) {
    state.codexSupportError = `自訂訊息不可超過 ${CODEX_SUPPORT_MAX_MESSAGE_LENGTH} 個字元`;
    renderCodexSupportStatus();
    return;
  }

  state.codexSupportSending = true;
  state.codexSupportError = "";
  renderCodexSupportStatus();
  try {
    state.codexSupportData = await api("/api/v1/codex-support", {
      method: "POST",
      body: {
        mode: selection.mode,
        message: selection.message,
        deviceUid: $("codexLogDeviceSelect").value || state.selectedUid,
        includeDeviceLog: Boolean($("codexAttachSelectedLog").checked),
      },
    });
  } catch (error) {
    state.codexSupportError = error.message;
  } finally {
    state.codexSupportSending = false;
    renderCodexSupportStatus();
    scheduleCodexSupportRefresh();
  }
}

async function recoverCodexSupport(action) {
  if (state.codexSupportRecoveryBusy) return;
  state.codexSupportRecoveryBusy = true;
  state.codexSupportError = "";
  renderCodexSupportStatus();
  try {
    state.codexSupportData = await api(`/api/v1/codex-support/${action}`, { method: "POST" });
  } catch (error) {
    state.codexSupportError = error.message;
  } finally {
    state.codexSupportRecoveryBusy = false;
    renderCodexSupportStatus();
    scheduleCodexSupportRefresh();
  }
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
    renderPerformance();
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
    setText("recordingSummaryBadge", "尚無資料");
    $("recordingSummaryBadge").className = "badge muted";
  } else {
    const stateLine = document.createElement("div"); stateLine.className = "state-line";
    const badge = document.createElement("span"); badge.className = `badge ${String(recording.state).includes("error") || String(recording.state).includes("waiting") ? "warning" : recording.state === "complete" ? "ok" : "muted"}`;
    badge.textContent = recordingStageLabel(recording.state);
    const name = document.createElement("strong"); name.textContent = recording.baseName || "目前錄影工作";
    stateLine.append(badge, name); recordingCard.append(stateLine);
    const progressValue = Number(recording.progressPercent);
    const progress = Number.isFinite(progressValue) && progressValue >= 0 ? progressValue : null;
    let progressDetail = recording.detail || "等待本機錄影狀態";
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
    setText("recordingSummaryBadge", recordingStageLabel(recording.state));
    $("recordingSummaryBadge").className = badge.className;
  }
  recordingNode.append(recordingCard);

  const live = status.live || {};
  const liveDetail = live.detail || "裝置尚未回報直播傳輸狀態。";
  setText("liveDeviceStatus", `${liveDetail}${/UDP/i.test(liveDetail) ? "；正式錄影只寫入執行端指定位置，不會上傳中央。" : ""}`);
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
  renderSettingsAckStatus(wrapper);
  renderPerformance(status.performance);
}

function settingsSummary(settings = {}) {
  const servers = String(settings.serverScheduleList || "").trim() || "未設定";
  return [
    `排程 ${settings.serverScheduleEnabled ? "開" : "關"}（${servers}）`,
    `重啟上限 ${settings.maxRestartCount ?? "—"}`,
    `診斷 ${settings.runtimeDiagnosticsEnabled === false ? "關" : "開"}/${settings.runtimeDiagnosticsIntervalSec ?? "—"} 秒`,
    `郵件 ${settings.mailNotifyEnabled ? "開" : "關"}`,
    `直播 ${liveQualityLabel(settings.liveQualityProfile)}`,
  ].join("｜");
}

function renderSettingsAckStatus(wrapper = state.details || {}) {
  const box = $("settingsAckStatus");
  if (!box) return;
  const device = wrapper.device || {};
  const version = wrapper.settings || {};
  const ack = device.settings_ack || {};
  const desiredRevision = Math.max(Number(version.revision) || 0, Number(device.settings_revision) || 0,
    Number(state.settingsSaveStatus?.revision) || 0);
  const effectiveRevision = Math.max(0, Number(device.settings_effective_revision) || 0);
  const ackRevision = Math.max(0, Number(ack.revision) || 0);
  const saved = state.settingsSaveStatus;
  let kind = "idle";
  let title = desiredRevision > 0 ? `設定版本 ${desiredRevision}` : "尚未儲存設定";
  let detail = "尚無裝置設定 ACK。";
  let at = Number(ack.at) || (version.acked_at ? new Date(version.acked_at).valueOf() : 0);
  if (saved?.state === "error") {
    kind = "error"; title = "設定儲存失敗"; detail = saved.detail || "請重新嘗試。"; at = Date.now();
  } else if (String(version.status).toUpperCase() === "REJECTED" || (ackRevision === desiredRevision && ack.applied === false)) {
    kind = "rejected"; title = `裝置拒絕設定｜revision ${desiredRevision}`;
    detail = String(version.ack_detail || ack.detail || "裝置未套用這一版設定。");
  } else if (desiredRevision > 0 && effectiveRevision >= desiredRevision
      && (String(version.status).toUpperCase() === "APPLIED" || ackRevision >= desiredRevision)) {
    kind = "applied"; title = `設定已生效｜revision ${desiredRevision}`;
    detail = String(version.ack_detail || ack.detail || "裝置已確認套用。");
  } else if (desiredRevision > 0) {
    kind = "pending"; title = `已送出 revision ${desiredRevision}，等待裝置套用`;
    detail = saved?.detail || "裝置心跳最慢約 90 秒內會更新實際生效狀態。";
    at = Number(saved?.at) || (version.created_at ? new Date(version.created_at).valueOf() : 0);
  }
  box.className = `settings-ack-status ${kind}`;
  setText("settingsAckTitle", title);
  setText("settingsAckTime", at ? formatTime(at) : "—");
  setText("settingsAckDetail", detail);
  setText("settingsEffectiveSummary", `實際生效值（revision ${effectiveRevision || "—"}）：${settingsSummary(device.settings || {})}`);
  if (kind === "applied" && saved && desiredRevision >= Number(saved.revision || 0)) state.settingsSaveStatus = null;
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
  const mode = String(state.migration?.mode || "");
  $("saveSettingsButton").disabled = state.settingsSaving || !["primary", "shadow", "fallback"].includes(mode) || !state.selectedUid;
  const message = mode === "primary"
    ? "設定會直接儲存至中央主機，並等待裝置 ACK。"
    : mode === "shadow"
      ? "並行驗證中：設定會以版本檢查安全轉送 Firestore，並等待裝置 ACK。"
      : mode === "fallback"
        ? "Firestore 備援模式：設定會以版本檢查安全轉送，並等待裝置 ACK。"
        : "目前模式不允許修改設定。";
  setText("settingsMessage", message);
}

function mergeRefreshOptions(left = {}, right = {}) {
  return {
    includeDevices: left.includeDevices !== false || right.includeDevices !== false,
    includeRecordings: false,
    includePerformance: Boolean(left.includePerformance || right.includePerformance),
    reloadSnapshot: Boolean(left.reloadSnapshot || right.reloadSnapshot),
    reloadSettings: Boolean(left.reloadSettings || right.reloadSettings),
    admin: Boolean(left.admin || right.admin),
  };
}

async function refresh(options = {}) {
  const requested = {
    includeDevices: options.includeDevices !== false,
    includeRecordings: false,
    includePerformance: options.includePerformance ?? state.activeTab === "diagnostics",
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
      syncCodexLogDeviceOptions(false);
    }
    const selectedChanged = previousUid !== state.selectedUid;
    if (selectedChanged) state.performance = null;
    if (state.selectedUid) {
      const encoded = encodeURIComponent(state.selectedUid);
      const requests = [api(`/api/v1/devices/${encoded}`)];
      if (requested.includePerformance) requests.push(api(`/api/v1/devices/${encoded}/performance?range=${encodeURIComponent(state.performanceRange)}`));
      const results = await Promise.all(requests);
      const details = results[0];
      let resultIndex = 1;
      const performance = requested.includePerformance ? results[resultIndex++] : null;
      state.details = details;
      if (performance) state.performance = performance;
      renderDetails({
        reloadSnapshot: requested.reloadSnapshot || selectedChanged,
        reloadSettings: requested.reloadSettings,
      });
      if (requested.includePerformance) renderPerformance(details.device?.status?.performance);
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
    ["裝置憑證", migration.devices.map((item) => `${item.display_name || item.uid}: ${item.credential_issued_at ? "已核發" : "等待"}`).join("；") || "尚無"],
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
  $("btnOpenCodexSupport").addEventListener("click", () => {
    state.codexSupportError = "";
    syncCodexLogDeviceOptions(true);
    updateCodexMessageControls();
    const dialog = $("codexSupportDialog");
    if (typeof dialog.showModal === "function") dialog.showModal();
    else dialog.setAttribute("open", "");
    refreshCodexSupport().catch(() => {});
  });
  $("btnCloseCodexSupport").addEventListener("click", () => $("codexSupportDialog").close());
  $("codexSupportDialog").addEventListener("close", stopCodexSupportPolling);
  $("codexMessagePreset").addEventListener("change", () => {
    state.codexSupportError = "";
    updateCodexMessageControls();
    if ($("codexMessagePreset").value === "CUSTOM") $("codexCustomMessage").focus();
  });
  $("codexCustomMessage").addEventListener("input", () => {
    state.codexSupportError = "";
    updateCodexMessageControls();
  });
  $("codexAttachSelectedLog").addEventListener("change", () => {
    state.codexSupportError = "";
    renderCodexLogSelection();
  });
  $("codexLogDeviceSelect").addEventListener("change", () => {
    state.codexSupportError = "";
    renderCodexLogSelection();
  });
  $("btnAskCodex").addEventListener("click", () => requestCodexSupport());
  $("btnCancelCodexSupport").addEventListener("click", () => recoverCodexSupport("cancel"));
  $("btnRetryCodexSupport").addEventListener("click", () => recoverCodexSupport("retry"));
  document.querySelectorAll("[data-tab]").forEach((button) => button.addEventListener("click", () => {
    document.querySelectorAll("[data-tab]").forEach((item) => item.classList.toggle("active", item === button));
    document.querySelectorAll("[data-panel]").forEach((panel) => panel.classList.toggle("active", panel.dataset.panel === button.dataset.tab));
    state.activeTab = button.dataset.tab;
    if (state.activeTab === "settings") refresh({ admin: true, reloadSettings: true }).catch((error) => toast(error.message));
    else if (state.activeTab === "videos") refresh({ includeDevices: false, includeRecordings: false, reloadSettings: false }).catch((error) => toast(error.message));
    else if (state.activeTab === "diagnostics") refresh({ includeDevices: false, includeRecordings: false, includePerformance: true, reloadSettings: false }).catch((error) => toast(error.message));
  }));
  $("performanceRange").addEventListener("change", () => {
    state.performanceRange = $("performanceRange").value;
    localStorage.setItem("wuthering.performanceRange", state.performanceRange);
    refresh({ includeDevices: false, includeRecordings: false, includePerformance: true, reloadSettings: false }).catch((error) => toast(error.message));
  });
  deviceSelect.addEventListener("change", async () => { await stopLive(); state.selectedUid = deviceSelect.value; state.performance = null; localStorage.setItem("wuthering.selectedUid", state.selectedUid); await refresh({ reloadSnapshot: true, admin: state.activeTab === "settings" }); });
  $("refreshButton").addEventListener("click", () => refresh({ reloadSnapshot: true, admin: state.activeTab === "settings" }).catch((error) => toast(error.message)));
  $("pauseButton").addEventListener("click", () => sendCommand("PAUSE").catch((error) => toast(error.message)));
  $("runButton").addEventListener("click", () => sendCommand("RUN").catch((error) => toast(error.message)));
  $("stopButton").addEventListener("click", () => { if (confirm("確定要遠端完整關閉腳本？")) sendCommand("STOP").catch((error) => toast(error.message)); });
  $("switchButton").addEventListener("click", () => { const value = $("serverSelect").value; if (!value) return; const target = JSON.parse(value); sendCommand("SWITCH_SERVER", { serverIndex: target.index, serverName: target.name }).catch((error) => toast(error.message)); });
  $("completeButton").addEventListener("click", () => { const value = $("serverSelect").value; if (!value) return; const target = JSON.parse(value); if (confirm(`把 ${target.name} 標記為今天已完成？`)) sendCommand("COMPLETE_SERVER", { serverIndex: target.index, serverName: target.name }).catch((error) => toast(error.message)); });
  $("settingsForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (state.settingsSaving) return;
    state.settingsSaving = true;
    state.settingsSaveStatus = { state: "pending", revision: 0, at: Date.now(), detail: "正在儲存設定…" };
    $("saveSettingsButton").disabled = true;
    renderSettingsAckStatus();
    try {
      const saved = await api(`/api/v1/devices/${encodeURIComponent(state.selectedUid)}/settings`, { method: "PUT", body: {
        serverScheduleEnabled: $("scheduleEnabled").checked,
        serverScheduleList: selectedServerChoices().join(" | "),
        maxRestartCount: Number($("maxRestart").value), runtimeDiagnosticsEnabled: $("diagnosticsEnabled").checked,
        runtimeDiagnosticsIntervalSec: Number($("snapshotInterval").value), runtimeDiagnosticsErrorKeepCount: Number($("snapshotKeep").value),
        mailNotifyEnabled: $("mailEnabled").checked,
        liveQualityProfile: normalizeLiveQualityProfile($("liveQualityProfile").value),
      }});
      state.settingsSaveStatus = {
        state: "pending", revision: Number(saved?.revision) || 0, at: Date.now(),
        detail: "設定已保存，等待裝置回報實際套用結果。",
      };
      const revision = Number(saved?.revision) > 0 ? `（版本 ${Number(saved.revision)}）` : "";
      toast(saved?.transport === "firestore"
        ? `設定已安全轉送 Firestore${revision}，等待裝置 ACK`
        : `設定已儲存至中央主機${revision}，等待裝置 ACK`);
      await refresh({ reloadSettings: false, admin: true });
    } catch (error) {
      state.settingsSaveStatus = { state: "error", revision: 0, at: Date.now(), detail: error.message };
      toast(error.message);
    } finally {
      state.settingsSaving = false;
      renderSettings(state.details?.device?.settings || {});
      renderSettingsAckStatus();
    }
  });
  $("scheduleEnabled").addEventListener("change", refreshServerChoicesEnabled);
  $("startLiveButton").addEventListener("click", () => startLive().catch((error) => toast(error.message)));
  $("stopLiveButton").addEventListener("click", () => stopLive());
  $("cutoverButton").addEventListener("click", async () => { if (!confirm("確認兩台裝置與直播均完成驗證，正式把命令來源切到自架伺服器？")) return; try { await api("/api/v1/admin/migration/cutover", { method: "POST" }); toast("已切換為自架正式控制"); await refresh(); } catch (error) { toast(error.message); } });
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) refresh({ reloadSettings: state.activeTab === "settings", admin: state.activeTab === "settings" }).catch((error) => toast(error.message));
  });
  let chartResizeTimer = 0;
  window.addEventListener("resize", () => {
    clearTimeout(chartResizeTimer);
    chartResizeTimer = setTimeout(() => { if (state.activeTab === "diagnostics") renderPerformance(state.details?.device?.status?.performance); }, 150);
  });
  window.addEventListener("beforeunload", () => {
    clearInterval(state.liveTimer); clearTimeout(state.liveRetryTimer); clearInterval(state.periodicTimer);
    clearTimeout(state.refreshTimer); clearTimeout(state.selectedRefreshTimer);
    stopCodexSupportPolling();
  });
}

async function boot() {
  renderServerChoices("");
  if (!["15m", "1h", "6h", "24h", "7d", "14d"].includes(state.performanceRange)) state.performanceRange = "6h";
  $("performanceRange").value = state.performanceRange;
  appView.hidden = false;
  bindEvents();
  updateCodexMessageControls();
  state.me = await api("/api/v1/auth/me");
  setText("releaseBadge", `Server ${state.me.serverVersion || "未知"}`);
  $("releaseBadge").className = "badge muted";
  await refresh({ reloadSnapshot: true, admin: true });
  refreshCodexSupport({ schedule: false }).catch(() => {});
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
