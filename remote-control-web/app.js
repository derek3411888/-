import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.4/firebase-app.js";
import {
  collection,
  doc,
  getDocs,
  getFirestore,
  onSnapshot,
  query,
  runTransaction,
  where,
} from "https://www.gstatic.com/firebasejs/10.12.4/firebase-firestore.js";

// TODO: 填入你自己的 Firebase 專案設定
const FIREBASE_CONFIG = {
  apiKey: "AIzaSyDqWHdBixVQPt4OiTi50hseInFxPtk0hf0",
  authDomain: "ww-control-a3988.firebaseapp.com",
  projectId: "ww-control-a3988",
};

const COLLECTION = "ahk_clients";
const MEDIA_DOC_SUFFIX = "__media";
const OFFLINE_THRESHOLD_MS = 5 * 60_000;
const STALE_CLIENT_RETENTION_MS = 7 * 24 * 60 * 60_000;
const STALE_CLIENT_STABILITY_MS = 10 * 60_000;
const STALE_CLEANUP_RETRY_MS = 60 * 60_000;
const ACK_TIMEOUT_MS = 30_000;
const COMMAND_HISTORY_LIMIT = 30;
const WEB_BUILD = "20260823-1";

const app = initializeApp(FIREBASE_CONFIG);
const db = getFirestore(app);
// uid 是新舊控制文件都有、media 文件沒有的欄位，可同時相容舊 client。
const clientsQuery = query(collection(db, COLLECTION), where("uid", "!=", ""));

const pcDropdown = document.getElementById("pcDropdown");
const btnPause = document.getElementById("btnPause");
const btnRun = document.getElementById("btnRun");
const btnStop = document.getElementById("btnStop");
const statusMsg = document.getElementById("statusMsg");
const commandStatus = document.getElementById("commandStatus");
const commandStatusTitle = document.getElementById("commandStatusTitle");
const commandStatusDetail = document.getElementById("commandStatusDetail");
const clientMeta = document.getElementById("clientMeta");
const historyBody = document.getElementById("historyBody");
const historyNote = document.getElementById("historyNote");
const latestScreenshot = document.getElementById("latestScreenshot");
const snapshotPlaceholder = document.getElementById("snapshotPlaceholder");
const snapshotMeta = document.getElementById("snapshotMeta");
const btnRefreshSnapshot = document.getElementById("btnRefreshSnapshot");
const runtimeEventsBody = document.getElementById("runtimeEventsBody");
const runtimeEventsNote = document.getElementById("runtimeEventsNote");
const recordingStatusBadge = document.getElementById("recordingStatusBadge");
const recordingStatusUpdated = document.getElementById("recordingStatusUpdated");
const recordingStatusNote = document.getElementById("recordingStatusNote");
const recordingPaths = document.getElementById("recordingPaths");

let cache = new Map();
let loadInFlight = false;
let reconcileInFlightFor = "";
let sending = false;
let sendingState = "";
let commandError = null;
let renderedScreenshotKey = "";
let selectedMediaClientId = "";
let selectedMediaData = null;
let stopSelectedMediaListener = null;
let staleCleanupSweepRunning = false;
let maintenanceNotice = "";
const clientLastObservedChangeAt = new Map();
const staleCleanupRetryAfter = new Map();

function toInteger(value, fallback = 0) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.trunc(n);
}

function toMillis(value) {
  if (!value) return 0;
  if (typeof value?.toMillis === "function") return value.toMillis();
  if (typeof value?.seconds === "number") {
    return value.seconds * 1000 + Math.floor(Number(value.nanoseconds || 0) / 1_000_000);
  }
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function fmtTs(value) {
  const ms = toMillis(value);
  if (!ms) return "-";
  const d = new Date(ms);
  return d.toLocaleString("zh-TW", { hour12: false });
}

function fmtAge(value) {
  const ms = toMillis(value);
  if (!ms) return "-";
  const ageMs = Math.max(0, Date.now() - ms);
  const sec = Math.floor(ageMs / 1000);
  if (sec < 60) return `${sec} 秒前`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min} 分鐘前`;
  const hr = Math.floor(min / 60);
  const remMin = min % 60;
  return `${hr} 小時 ${remMin} 分鐘前`;
}

function readField(docData, key, def = "") {
  if (!(key in docData)) return def;
  return docData[key];
}

function normalizeStatus(v) {
  const s = String(v ?? "UNKNOWN").toUpperCase().replace(/[^A-Z]/g, "");
  if (s === "RUN" || s === "PAUSE" || s === "STOP" || s === "OFFLINE") return s;
  return "UNKNOWN";
}

function isPastStaleClientRetention(data, nowMs = Date.now()) {
  const heartbeat = toMillis(readField(data, "lastHeartbeat", 0));
  if (!heartbeat || heartbeat > nowMs) return false;
  return nowMs - heartbeat >= STALE_CLIENT_RETENTION_MS;
}

async function cleanupStaleClients() {
  if (staleCleanupSweepRunning) return;
  staleCleanupSweepRunning = true;
  let deletedCount = 0;

  try {
    const now = Date.now();
    for (const [id, data] of cache.entries()) {
      if (!isPastStaleClientRetention(data, now)) continue;

      // 網頁剛開啟時先觀察 10 分鐘。若裝置只是系統時鐘錯誤但仍持續心跳，
      // listener 會更新此時間，因而不會誤刪仍活著的裝置。
      const observedAt = clientLastObservedChangeAt.get(id) || now;
      if (now - observedAt < STALE_CLIENT_STABILITY_MS) continue;
      if ((staleCleanupRetryAfter.get(id) || 0) > now) continue;

      const clientRef = doc(db, COLLECTION, id);
      const mediaRef = doc(db, COLLECTION, `${id}${MEDIA_DOC_SUFFIX}`);
      try {
        const deleted = await runTransaction(db, async (transaction) => {
          const current = await transaction.get(clientRef);
          if (!current.exists()) return false;

          const currentData = current.data();
          if (String(readField(currentData, "uid", "")) !== id) return false;
          if (!isPastStaleClientRetention(currentData)) return false;

          transaction.delete(mediaRef);
          transaction.delete(clientRef);
          return true;
        });

        if (deleted) {
          deletedCount += 1;
          cache.delete(id);
          clientLastObservedChangeAt.delete(id);
          staleCleanupRetryAfter.delete(id);
        }
      } catch (e) {
        staleCleanupRetryAfter.set(id, Date.now() + STALE_CLEANUP_RETRY_MS);
        maintenanceNotice = `7 天離線資料清理失敗：${e?.message || String(e)}`;
        console.warn("stale client cleanup failed", id, e);
      }
    }

    if (deletedCount > 0) {
      maintenanceNotice = `已清除 ${deletedCount} 台離線超過 7 天的舊裝置資料`;
      renderClients();
    }
  } finally {
    staleCleanupSweepRunning = false;
  }
}

function normalizeCommandState(value) {
  const state = String(value ?? "").toUpperCase().replace(/[^A-Z]/g, "");
  if (state === "RUN" || state === "PAUSE" || state === "STOP") return state;
  return "UNKNOWN";
}

function normalizeHistoryEntry(raw) {
  const entry = raw && typeof raw === "object" ? raw : {};
  return {
    commandId: String(entry.commandId ?? ""),
    commandNonce: Math.max(0, toInteger(entry.commandNonce, 0)),
    requestedState: normalizeCommandState(entry.requestedState),
    sentAt: toMillis(entry.sentAt),
    status: String(entry.status ?? "WAITING_ACK").toUpperCase(),
    ackAt: toMillis(entry.ackAt),
    statusUpdatedAt: toMillis(entry.statusUpdatedAt),
    statusReason: String(entry.statusReason ?? ""),
  };
}

function readCommandHistory(data) {
  const raw = Array.isArray(data?.commandHistory) ? data.commandHistory : [];
  return raw
    .map(normalizeHistoryEntry)
    .filter((entry) => entry.commandNonce > 0 && entry.requestedState !== "UNKNOWN")
    .sort((a, b) => b.commandNonce - a.commandNonce)
    .slice(0, COMMAND_HISTORY_LIMIT);
}

function readRuntimeEvents(data) {
  const raw = String(readField(data, "recentEventsJson", "") || "");
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .map((entry) => ({
        at: toMillis(entry?.at),
        name: String(entry?.name ?? "事件"),
        detail: String(entry?.detail ?? ""),
        level: String(entry?.level ?? "INFO").toUpperCase(),
      }))
      .filter((entry) => entry.at > 0 || entry.name || entry.detail)
      .slice(-50)
      .reverse();
  } catch {
    return [];
  }
}

function deriveHistoryEntry(entry, clientData, nowMs = Date.now()) {
  const current = normalizeHistoryEntry(entry);
  const ackNonce = Math.max(0, toInteger(readField(clientData, "lastAckNonce", 0), 0));
  const ackState = normalizeCommandState(readField(clientData, "lastAckState", ""));
  const reportedAckAt = toMillis(readField(clientData, "lastAckAt", 0));
  const previousStatus = current.status;

  let nextStatus = "WAITING_ACK";
  let nextAckAt = current.ackAt;
  let nextReason = "";

  // 一旦看過這筆精確 ACK，就永久保留；後續 ACK 前進不應把成功紀錄改成「被跨過」。
  if (previousStatus === "ACKED") {
    nextStatus = "ACKED";
    nextReason = current.statusReason || "EXACT_ACK";
  } else if (ackNonce === current.commandNonce && ackState === current.requestedState) {
    nextStatus = "ACKED";
    nextAckAt = reportedAckAt || current.ackAt;
    nextReason = "EXACT_ACK";
  } else if (ackNonce > current.commandNonce) {
    nextStatus = "SUPERSEDED";
    nextReason = "ACK_NONCE_ADVANCED";
  } else if (current.sentAt > 0 && nowMs - current.sentAt >= ACK_TIMEOUT_MS) {
    nextStatus = "UNRESPONSIVE";
    nextReason =
      ackNonce === current.commandNonce && ackState !== current.requestedState
        ? "ACK_STATE_MISMATCH"
        : "ACK_TIMEOUT";
  }

  const changed =
    nextStatus !== current.status ||
    nextAckAt !== current.ackAt ||
    nextReason !== current.statusReason;

  return {
    ...current,
    status: nextStatus,
    ackAt: nextAckAt,
    statusReason: nextReason,
    statusUpdatedAt: changed ? nowMs : current.statusUpdatedAt,
  };
}

function deriveCommandHistory(data, nowMs = Date.now()) {
  return readCommandHistory(data).map((entry) => deriveHistoryEntry(entry, data, nowMs));
}

function historyStatusChanged(before, after) {
  if (before.length !== after.length) return true;
  for (let i = 0; i < before.length; i += 1) {
    const a = before[i];
    const b = after[i];
    if (
      a.commandId !== b.commandId ||
      a.commandNonce !== b.commandNonce ||
      a.status !== b.status ||
      a.ackAt !== b.ackAt ||
      a.statusReason !== b.statusReason ||
      a.statusUpdatedAt !== b.statusUpdatedAt
    ) {
      return true;
    }
  }
  return false;
}

function selectedClientData() {
  const id = pcDropdown.value;
  if (!id || !cache.has(id)) return null;
  return cache.get(id);
}

function currentMediaData() {
  const id = pcDropdown.value;
  if (!id || selectedMediaClientId !== id) return null;
  return selectedMediaData;
}

function startSelectedMediaSubscription(force = false) {
  const id = pcDropdown.value;
  if (!force && id && selectedMediaClientId === id && stopSelectedMediaListener) return;

  if (stopSelectedMediaListener) stopSelectedMediaListener();
  stopSelectedMediaListener = null;
  selectedMediaClientId = id || "";
  selectedMediaData = null;
  renderedScreenshotKey = "";

  if (!id) {
    renderSnapshot();
    return;
  }

  const mediaRef = doc(db, COLLECTION, `${id}${MEDIA_DOC_SUFFIX}`);
  stopSelectedMediaListener = onSnapshot(
    mediaRef,
    (snap) => {
      if (pcDropdown.value !== id) return;
      selectedMediaData = snap.exists() ? snap.data() : null;
      refreshMeta();
      renderSnapshot();
    },
    (e) => {
      if (pcDropdown.value !== id) return;
      selectedMediaData = null;
      renderedScreenshotKey = "";
      renderSnapshot();
      snapshotMeta.textContent = `讀取快照失敗：${e.message}`;
    },
  );
}

function setButtonsDisabled(disabled) {
  const noClient = !pcDropdown.value || !cache.has(pcDropdown.value);
  const value = Boolean(disabled || noClient);
  pcDropdown.disabled = Boolean(disabled || cache.size === 0);
  btnPause.disabled = value;
  btnRun.disabled = value;
  btnStop.disabled = value;
}

function renderClients() {
  const now = Date.now();
  const rows = [];
  let onlineCount = 0;

  for (const [id, data] of cache.entries()) {
    const hb = Number(readField(data, "lastHeartbeat", 0));
    const status = normalizeStatus(readField(data, "status", "UNKNOWN"));
    const onlineByHeartbeat = now - hb <= OFFLINE_THRESHOLD_MS;
    const online = status !== "OFFLINE" && status !== "STOP" && onlineByHeartbeat;
    if (online) onlineCount += 1;

    rows.push({
      id,
      online,
      computerName: readField(data, "computerName", ""),
      displayName: readField(data, "displayName", id),
      status,
      lastHeartbeat: hb,
      nonce: toInteger(readField(data, "nonce", 0), 0),
      lastAckNonce: toInteger(readField(data, "lastAckNonce", 0), 0),
      lastAckState: readField(data, "lastAckState", ""),
      lastAckAt: toMillis(readField(data, "lastAckAt", 0)),
      currentStep: readField(data, "currentStep", ""),
      currentStepDetail: readField(data, "currentStepDetail", ""),
      currentStepLevel: readField(data, "currentStepLevel", ""),
      currentServer: readField(data, "currentServer", ""),
      currentServerLabel: readField(data, "currentServerLabel", ""),
      currentServerIndex: toInteger(readField(data, "currentServerIndex", 0), 0),
      currentServerTotal: toInteger(readField(data, "currentServerTotal", 0), 0),
    });
  }

  rows.sort((a, b) => b.lastHeartbeat - a.lastHeartbeat);

  const keep = pcDropdown.value;
  pcDropdown.innerHTML = "";
  for (const r of rows) {
    const opt = document.createElement("option");
    opt.value = r.id;
    const onlineTag = r.online ? "在線" : "離線";
    const labelName = r.displayName || r.computerName || r.id;
    const stepTag = r.currentStep ? ` | STEP ${r.currentStep}` : "";
    const serverTag = r.currentServerLabel ? ` | ${r.currentServerLabel}` : (r.currentServer ? ` | ${r.currentServer}` : "");
    opt.textContent = `${labelName} (${r.status} / ${onlineTag}${serverTag}${stepTag})`;
    pcDropdown.appendChild(opt);
  }

  if (rows.length === 0) {
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "無可見電腦";
    pcDropdown.appendChild(opt);
  } else if (rows.some((r) => r.id === keep)) {
    pcDropdown.value = keep;
  }

  statusMsg.textContent = `可見 ${rows.length} 台，在線 ${onlineCount} 台`
    + (maintenanceNotice ? `｜${maintenanceNotice}` : "");
  startSelectedMediaSubscription();
  renderSelectedClient();
}

function refreshMeta() {
  const id = pcDropdown.value;
  clientMeta.innerHTML = "";
  if (!id || !cache.has(id)) return;
  const d = cache.get(id);
  const media = currentMediaData() || {};
  const lines = [
    `UID: ${id}`,
    `顯示名稱: ${readField(d, "displayName", "-")}`,
    `電腦: ${readField(d, "computerName", "-")}`,
    `狀態: ${readField(d, "status", "-")}`,
    `目前步驟: ${readField(d, "currentStep", "-")}${readField(d, "currentStepDetail", "") ? ` | ${readField(d, "currentStepDetail", "")}` : ""}`,
    `目前步驟等級: ${readField(d, "currentStepLevel", "-")}`,
    `目前伺服器: ${readField(d, "currentServerLabel", readField(d, "currentServer", "-"))}`,
    `最後心跳: ${fmtTs(readField(d, "lastHeartbeat", 0))}`,
    `距今: ${fmtAge(readField(d, "lastHeartbeat", 0))}`,
    `最後畫面: ${fmtTs(readField(media, "latestScreenshotAt", 0))}（${fmtAge(readField(media, "latestScreenshotAt", 0))}）`,
    `錄影狀態: ${recordingStateLabel(String(readField(d, "recordingState", "") || ""))}`,
    `最後 ACK: nonce=${readField(d, "lastAckNonce", 0)} state=${readField(d, "lastAckState", "-")} at=${fmtTs(readField(d, "lastAckAt", 0))}`,
  ];
  for (const t of lines) {
    const li = document.createElement("li");
    li.textContent = t;
    clientMeta.appendChild(li);
  }
}

function renderSnapshot() {
  const client = selectedClientData();
  if (!client) {
    renderedScreenshotKey = "";
    latestScreenshot.hidden = true;
    latestScreenshot.removeAttribute("src");
    snapshotPlaceholder.hidden = false;
    snapshotPlaceholder.textContent = "請先選擇一台電腦。";
    snapshotMeta.textContent = "尚未收到快照。";
    return;
  }

  const data = currentMediaData();
  if (!data) {
    renderedScreenshotKey = "";
    latestScreenshot.hidden = true;
    latestScreenshot.removeAttribute("src");
    snapshotPlaceholder.hidden = false;
    snapshotPlaceholder.textContent = "等待這台裝置的獨立快照資料；控制狀態不會夾帶圖片。";
    snapshotMeta.textContent = "尚未收到新版快照。";
    return;
  }

  const dataUri = String(readField(data, "latestScreenshotDataUri", "") || "");
  const capturedAt = toMillis(readField(data, "latestScreenshotAt", 0));
  const reason = String(readField(data, "latestScreenshotReason", "") || "定時快照");
  const width = toInteger(readField(data, "latestScreenshotWidth", 0), 0);
  const height = toInteger(readField(data, "latestScreenshotHeight", 0), 0);

  if (!dataUri.startsWith("data:image/jpeg;base64,")) {
    renderedScreenshotKey = "";
    latestScreenshot.hidden = true;
    latestScreenshot.removeAttribute("src");
    snapshotPlaceholder.hidden = false;
    snapshotPlaceholder.textContent = "裝置尚未上傳畫面；請確認即時診斷已啟用。";
    snapshotMeta.textContent = "尚未收到快照。";
    return;
  }

  const nextKey = `${pcDropdown.value}:${capturedAt}:${dataUri.length}`;
  if (renderedScreenshotKey !== nextKey) {
    latestScreenshot.src = dataUri;
    renderedScreenshotKey = nextKey;
  }
  latestScreenshot.hidden = false;
  snapshotPlaceholder.hidden = true;
  snapshotMeta.textContent = `${fmtTs(capturedAt)}（${fmtAge(capturedAt)}）｜${reason}${width && height ? `｜${width}×${height}` : ""}`;
}

function recordingStateLabel(state) {
  const labels = {
    starting: "準備啟動錄影",
    recording: "錄影中",
    segments_synced: "錄影中（分段已同步）",
    sync_waiting: "目的端暫時不可用",
    stopping: "正在停止並封口",
    finalize_pending: "等待背景收尾",
    finalize_waiting: "收尾等待中",
    merging: "正在無損合併",
    merge_waiting: "合併失敗／等待處理",
    copying_final: "正在複製完整影片",
    copy_waiting: "目的端複製失敗／等待重試",
    complete: "已成功完成",
    start_failed: "錄影啟動失敗",
    stop_failed: "錄影停止失敗",
    worker_missing: "缺少背景收尾工具",
    worker_start_failed: "背景收尾工具啟動失敗",
    worker_error: "背景收尾發生錯誤",
  };
  return labels[state] || (state ? state : "尚無資料");
}

function recordingStateClass(state, active) {
  if (active || ["starting", "recording", "segments_synced", "stopping", "finalize_pending", "merging", "copying_final"].includes(state)) {
    return "running";
  }
  if (state === "complete") return "success";
  if (["start_failed", "stop_failed", "worker_missing", "worker_start_failed", "worker_error"].includes(state)) {
    return "error";
  }
  if (state.includes("waiting")) return "warning";
  return "idle";
}

async function copyPathToClipboard(path, button) {
  const original = button.textContent;
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(path);
    } else {
      const input = document.createElement("textarea");
      input.value = path;
      input.setAttribute("readonly", "");
      input.style.position = "fixed";
      input.style.opacity = "0";
      document.body.appendChild(input);
      input.select();
      if (!document.execCommand("copy")) throw new Error("瀏覽器不允許複製");
      input.remove();
    }
    button.textContent = "已複製";
  } catch {
    button.textContent = "複製失敗";
  }
  window.setTimeout(() => { button.textContent = original; }, 1800);
}

function addRecordingPath(label, path, hint = "") {
  const value = String(path || "").trim();
  if (!value) return;
  const row = document.createElement("div");
  row.className = "recording-path-row";
  const content = document.createElement("div");
  const title = document.createElement("strong");
  title.textContent = label;
  const code = document.createElement("code");
  code.textContent = value;
  code.title = value;
  content.append(title, code);
  if (hint) {
    const small = document.createElement("span");
    small.textContent = hint;
    content.appendChild(small);
  }
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "複製路徑";
  button.addEventListener("click", () => void copyPathToClipboard(value, button));
  row.append(content, button);
  recordingPaths.appendChild(row);
}

function renderRecordingStatus() {
  recordingPaths.replaceChildren();
  const data = selectedClientData();
  if (!data) {
    recordingStatusBadge.className = "recording-status-badge idle";
    recordingStatusBadge.textContent = "尚無資料";
    recordingStatusUpdated.textContent = "請先選擇一台電腦。";
    recordingStatusNote.textContent = "選擇電腦後會顯示成功、失敗原因與實際保留位置。";
    return;
  }

  const available = Boolean(readField(data, "recordingStatusAvailable", false));
  const enabled = Boolean(readField(data, "recordingEnabled", false));
  const active = Boolean(readField(data, "recordingActive", false));
  const state = String(readField(data, "recordingState", "") || "");
  const detail = String(readField(data, "recordingStateDetail", "") || "");
  const updatedAt = toMillis(readField(data, "recordingStateUpdatedAt", 0));
  const autoMerge = Boolean(readField(data, "recordingAutoMerge", true));

  if (!available && !state) {
    recordingStatusBadge.className = "recording-status-badge idle";
    recordingStatusBadge.textContent = enabled ? "尚未開始" : "錄影已停用";
    recordingStatusUpdated.textContent = "尚未收到任何錄影工作階段。";
    recordingStatusNote.textContent = enabled
      ? "首次開始錄影後，這裡會持續保留最後一次成功或失敗結果。"
      : "可在啟動器設定中啟用螢幕錄影。";
    return;
  }

  const stateClass = recordingStateClass(state, active);
  recordingStatusBadge.className = `recording-status-badge ${stateClass}`;
  recordingStatusBadge.textContent = recordingStateLabel(state);
  recordingStatusUpdated.textContent = updatedAt
    ? `最後更新：${fmtTs(updatedAt)}（${fmtAge(updatedAt)}）`
    : "狀態時間未知";
  recordingStatusNote.textContent = detail || (state === "complete"
    ? "目的端檔案已完成驗證。"
    : "背景工具尚未提供詳細說明。");

  const resultPath = readField(data, "recordingResultPath", "");
  const finalPath = readField(data, "recordingFinalPath", "");
  const segmentPath = readField(data, "recordingDestinationSegmentsDir", "");
  const destinationDir = readField(data, "recordingDestinationDir", "");
  const failureStorage = readField(data, "recordingFailureStorage", readField(data, "recordingLocalSessionDir", ""));
  const workerLogPath = readField(data, "recordingWorkerLogPath", "");
  const completed = state === "complete";

  addRecordingPath(
    autoMerge ? (completed ? "成功的完整影片" : "預定完整影片") : (completed ? "成功的分段資料夾" : "預定分段資料夾"),
    resultPath || (autoMerge ? finalPath : segmentPath),
    completed ? "背景工具已驗證完成" : "尚未顯示完成前，請勿當成最終成品",
  );
  addRecordingPath("設定的輸出資料夾", destinationDir);
  if (autoMerge && segmentPath && segmentPath !== resultPath) {
    addRecordingPath("目的端五分鐘分段", segmentPath, "合併成功後會自動清理；失敗時可逐段播放");
  }
  if (!completed) {
    addRecordingPath("本機暫存／失敗保留位置", failureStorage, "網路、合併或複製失敗時，分段會保留在這裡");
  }
  addRecordingPath("錄影背景工具 log", workerLogPath);
}

function runtimeLevelClass(level) {
  if (level === "ERROR") return "error";
  if (level === "WARN") return "warn";
  return "info";
}

function renderRuntimeEvents() {
  runtimeEventsBody.replaceChildren();
  const data = selectedClientData();
  if (!data) {
    runtimeEventsNote.textContent = "請先選擇一台電腦。";
    return;
  }

  const events = readRuntimeEvents(data);
  if (events.length === 0) {
    runtimeEventsNote.textContent = "尚未收到新版流程事件。";
    return;
  }
  runtimeEventsNote.textContent = `顯示最近 ${events.length} 筆，最新事件在最上方。`;

  for (const entry of events) {
    const row = document.createElement("tr");
    const timeCell = document.createElement("td");
    timeCell.textContent = fmtTs(entry.at);
    const levelCell = document.createElement("td");
    const badge = document.createElement("span");
    badge.className = `event-level ${runtimeLevelClass(entry.level)}`;
    badge.textContent = entry.level;
    levelCell.appendChild(badge);
    const nameCell = document.createElement("td");
    nameCell.textContent = entry.name;
    const detailCell = document.createElement("td");
    detailCell.textContent = entry.detail || "-";
    row.append(timeCell, levelCell, nameCell, detailCell);
    runtimeEventsBody.appendChild(row);
  }
}

function historyStatusLabel(entry) {
  if (entry.status === "ACKED") return "已 ACK";
  if (entry.status === "SUPERSEDED") return "被後續命令跨過";
  if (entry.status === "UNRESPONSIVE") return "未回應";
  return "等待 ACK";
}

function historyStatusClass(entry) {
  if (entry.status === "ACKED") return "acked";
  if (entry.status === "SUPERSEDED") return "superseded";
  if (entry.status === "UNRESPONSIVE") return "unresponsive";
  return "waiting";
}

function historyStatusDetail(entry, clientData) {
  if (entry.status === "ACKED") {
    return entry.ackAt ? `ACK：${fmtTs(entry.ackAt)}` : "已收到 nonce 與狀態完全相符的 ACK";
  }
  if (entry.status === "SUPERSEDED") {
    return `ACK 已前進至 nonce=${toInteger(readField(clientData, "lastAckNonce", 0), 0)}，本筆沒有逐筆 ACK`;
  }
  if (entry.status === "UNRESPONSIVE") {
    if (entry.statusReason === "ACK_STATE_MISMATCH") {
      return `收到相同 nonce，但 ACK 狀態不是 ${entry.requestedState}`;
    }
    return `送出超過 ${ACK_TIMEOUT_MS / 1000} 秒仍沒有對應 ACK`;
  }
  return `等待 nonce=${entry.commandNonce}、state=${entry.requestedState} 的精確 ACK`;
}

function renderHistory() {
  historyBody.replaceChildren();
  const data = selectedClientData();
  if (!data) {
    historyNote.textContent = "請先選擇一台電腦。";
    return;
  }

  const history = deriveCommandHistory(data);
  if (history.length === 0) {
    historyNote.textContent = "這台電腦尚無新版命令紀錄。";
    return;
  }

  historyNote.textContent = `顯示最近 ${history.length} 筆；最多保留 ${COMMAND_HISTORY_LIMIT} 筆。`;
  for (const entry of history) {
    const row = document.createElement("tr");

    const sentCell = document.createElement("td");
    sentCell.textContent = fmtTs(entry.sentAt);

    const stateCell = document.createElement("td");
    stateCell.textContent = entry.requestedState;

    const nonceCell = document.createElement("td");
    nonceCell.textContent = String(entry.commandNonce);

    const statusCell = document.createElement("td");
    const badge = document.createElement("span");
    badge.className = `status-badge ${historyStatusClass(entry)}`;
    badge.textContent = historyStatusLabel(entry);
    statusCell.appendChild(badge);

    const detailCell = document.createElement("td");
    detailCell.textContent = historyStatusDetail(entry, data);

    row.append(sentCell, stateCell, nonceCell, statusCell, detailCell);
    historyBody.appendChild(row);
  }
}

function setCommandStatus(kind, title, detail) {
  commandStatus.dataset.status = kind;
  commandStatusTitle.textContent = title;
  commandStatusDetail.textContent = detail;
}

function renderCommandStatus() {
  if (sending) {
    setCommandStatus("sending", `正在送出 ${sendingState}…`, "Firestore 交易提交中，尚未宣告成功。");
    return;
  }

  if (commandError && commandError.clientId === pcDropdown.value) {
    setCommandStatus("error", `下發 ${commandError.state} 失敗`, commandError.message);
    return;
  }

  const data = selectedClientData();
  if (!data) {
    setCommandStatus("idle", "尚未選擇電腦", "選擇裝置後才能送出命令。");
    return;
  }

  const latest = deriveCommandHistory(data)[0];
  if (!latest) {
    setCommandStatus("idle", "尚未送出新版命令", "只有收到精確 ACK 才會顯示成功。");
    return;
  }

  if (latest.status === "ACKED") {
    setCommandStatus(
      "acked",
      `已 ACK：${latest.requestedState}（nonce=${latest.commandNonce}）`,
      latest.ackAt ? `裝置回覆時間：${fmtTs(latest.ackAt)}` : "nonce 與狀態均已確認相符。",
    );
    return;
  }

  if (latest.status === "SUPERSEDED") {
    setCommandStatus(
      "superseded",
      `未逐筆 ACK：${latest.requestedState}（nonce=${latest.commandNonce}）`,
      historyStatusDetail(latest, data),
    );
    return;
  }

  if (latest.status === "UNRESPONSIVE") {
    setCommandStatus(
      "unresponsive",
      `未回應：${latest.requestedState}（nonce=${latest.commandNonce}）`,
      historyStatusDetail(latest, data),
    );
    return;
  }

  const elapsed = Math.max(0, Date.now() - latest.sentAt);
  const secondsLeft = Math.max(0, Math.ceil((ACK_TIMEOUT_MS - elapsed) / 1000));
  setCommandStatus(
    "waiting",
    `已送出 ${latest.requestedState}（nonce=${latest.commandNonce}），等待 ACK`,
    `尚未確認成功；${secondsLeft} 秒後若仍沒有精確 ACK，會標示未回應。`,
  );
}

function renderSelectedClient() {
  refreshMeta();
  renderRecordingStatus();
  renderSnapshot();
  renderRuntimeEvents();
  renderHistory();
  renderCommandStatus();
  setButtonsDisabled(sending);
}

async function reconcileClientHistory(id) {
  if (!id || reconcileInFlightFor) return;
  const cachedData = cache.get(id);
  if (!cachedData) return;
  const cachedBefore = readCommandHistory(cachedData);
  if (cachedBefore.length === 0) return;
  const cachedAfter = cachedBefore.map((entry) => deriveHistoryEntry(entry, cachedData));
  if (!historyStatusChanged(cachedBefore, cachedAfter)) return;

  reconcileInFlightFor = id;

  try {
    const ref = doc(db, COLLECTION, id);
    const result = await runTransaction(db, async (transaction) => {
      const snap = await transaction.get(ref);
      if (!snap.exists()) return null;

      const data = snap.data();
      const before = readCommandHistory(data);
      if (before.length === 0) return { data, changed: false };

      const after = before.map((entry) => deriveHistoryEntry(entry, data));
      const changed = historyStatusChanged(before, after);
      if (changed) {
        transaction.update(ref, { commandHistory: after.slice(0, COMMAND_HISTORY_LIMIT) });
      }
      return {
        data: changed ? { ...data, commandHistory: after } : data,
        changed,
      };
    });

    if (result?.data) {
      cache.set(id, result.data);
      if (pcDropdown.value === id) renderSelectedClient();
    }
  } catch (e) {
    if (pcDropdown.value === id) {
      historyNote.textContent = `命令狀態同步失敗：${e.message}`;
    }
  } finally {
    reconcileInFlightFor = "";
  }
}

async function loadClients() {
  if (loadInFlight) return;
  loadInFlight = true;
  try {
    const snap = await getDocs(clientsQuery);
    cache.clear();
    snap.forEach((s) => cache.set(s.id, s.data()));
    renderClients();
    const selectedId = pcDropdown.value;
    if (selectedId) void reconcileClientHistory(selectedId);
  } catch (e) {
    statusMsg.textContent = `讀取失敗：${e.message}`;
  } finally {
    loadInFlight = false;
  }
}

function startClientListener() {
  return onSnapshot(
    clientsQuery,
    (snap) => {
      const observedNow = Date.now();
      snap.docChanges().forEach((change) => {
        if (change.type === "removed") {
          clientLastObservedChangeAt.delete(change.doc.id);
          staleCleanupRetryAfter.delete(change.doc.id);
        } else {
          clientLastObservedChangeAt.set(change.doc.id, observedNow);
        }
      });
      cache.clear();
      snap.forEach((s) => cache.set(s.id, s.data()));
      renderClients();
      void cleanupStaleClients();
      const selectedId = pcDropdown.value;
      if (selectedId) void reconcileClientHistory(selectedId);
    },
    (e) => {
      statusMsg.textContent = `即時監聽失敗：${e.message}`;
    },
  );
}

async function sendCommand(state) {
  const id = pcDropdown.value;
  if (!id) {
    statusMsg.textContent = "請先選擇一台在線電腦";
    return;
  }

  const commandState = normalizeCommandState(state);
  if (commandState === "UNKNOWN") {
    setCommandStatus("error", "命令無效", `不支援的狀態：${state}`);
    return;
  }

  sending = true;
  sendingState = commandState;
  commandError = null;
  renderSelectedClient();

  try {
    const ref = doc(db, COLLECTION, id);
    const sentAt = Date.now();
    const result = await runTransaction(db, async (transaction) => {
      const current = await transaction.get(ref);
      if (!current.exists()) throw new Error("選取的電腦文件不存在");

      const data = current.data();
      const currentNonce = Math.max(0, toInteger(readField(data, "nonce", 0), 0));
      const nextNonce = currentNonce + 1;
      const reconciled = deriveCommandHistory(data, sentAt);
      const newEntry = {
        commandId: String(nextNonce),
        commandNonce: nextNonce,
        requestedState: commandState,
        sentAt,
        status: "WAITING_ACK",
        ackAt: 0,
        statusUpdatedAt: sentAt,
        statusReason: "",
      };
      const commandHistory = [newEntry, ...reconciled]
        .filter((entry, index, all) =>
          all.findIndex((other) => other.commandNonce === entry.commandNonce) === index)
        .sort((a, b) => b.commandNonce - a.commandNonce)
        .slice(0, COMMAND_HISTORY_LIMIT);

      // nonce、desiredState 與歷史在同一筆交易提交；多個頁面同時操作時交易會重試，
      // 因而不會再產生相同 nonce。歷史內刻意使用 commandNonce/requestedState，
      // 避免 AHK REST 端的欄位 regex 誤抓巢狀資料。
      transaction.update(ref, {
        desiredState: commandState,
        nonce: nextNonce,
        commandUpdatedAt: sentAt,
        commandHistory,
      });

      return {
        nextNonce,
        data: {
          ...data,
          desiredState: commandState,
          nonce: nextNonce,
          commandUpdatedAt: sentAt,
          commandHistory,
        },
      };
    });

    cache.set(id, result.data);
    sending = false;
    sendingState = "";
    commandError = null;
    renderSelectedClient();
    window.setTimeout(() => void loadClients(), 1200);
  } catch (e) {
    sending = false;
    sendingState = "";
    commandError = {
      clientId: id,
      state: commandState,
      message: e?.message || String(e),
    };
    renderSelectedClient();
  }
}

btnPause.addEventListener("click", () => void sendCommand("PAUSE"));
btnRun.addEventListener("click", () => void sendCommand("RUN"));
btnStop.addEventListener("click", () => {
  if (!confirm("確定要遠端關閉腳本並完整關閉遊戲/OKWW/LRMCAI？")) return;
  void sendCommand("STOP");
});
pcDropdown.addEventListener("change", () => {
  renderedScreenshotKey = "";
  startSelectedMediaSubscription(true);
  renderSelectedClient();
  void reconcileClientHistory(pcDropdown.value);
});
btnRefreshSnapshot.addEventListener("click", () => {
  startSelectedMediaSubscription(true);
});

statusMsg.textContent = `控制台已就緒（v${WEB_BUILD}）`;
startClientListener();
window.setInterval(renderCommandStatus, 1000);
window.setInterval(() => void cleanupStaleClients(), 60_000);
