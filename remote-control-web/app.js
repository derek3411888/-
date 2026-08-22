import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.4/firebase-app.js";
import {
  collection,
  doc,
  getDocs,
  getFirestore,
  onSnapshot,
  runTransaction,
} from "https://www.gstatic.com/firebasejs/10.12.4/firebase-firestore.js";

// TODO: 填入你自己的 Firebase 專案設定
const FIREBASE_CONFIG = {
  apiKey: "AIzaSyDqWHdBixVQPt4OiTi50hseInFxPtk0hf0",
  authDomain: "ww-control-a3988.firebaseapp.com",
  projectId: "ww-control-a3988",
};

const COLLECTION = "ahk_clients";
const OFFLINE_THRESHOLD_MS = 5 * 60_000;
const ACK_TIMEOUT_MS = 30_000;
const COMMAND_HISTORY_LIMIT = 30;
const WEB_BUILD = "20260822-2";

const app = initializeApp(FIREBASE_CONFIG);
const db = getFirestore(app);

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

let cache = new Map();
let loadInFlight = false;
let reconcileInFlightFor = "";
let sending = false;
let sendingState = "";
let commandError = null;
let renderedScreenshotKey = "";

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

  statusMsg.textContent = `可見 ${rows.length} 台，在線 ${onlineCount} 台`;
  renderSelectedClient();
}

function refreshMeta() {
  const id = pcDropdown.value;
  clientMeta.innerHTML = "";
  if (!id || !cache.has(id)) return;
  const d = cache.get(id);
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
    `最後畫面: ${fmtTs(readField(d, "latestScreenshotAt", 0))}（${fmtAge(readField(d, "latestScreenshotAt", 0))}）`,
    `最後 ACK: nonce=${readField(d, "lastAckNonce", 0)} state=${readField(d, "lastAckState", "-")} at=${fmtTs(readField(d, "lastAckAt", 0))}`,
  ];
  for (const t of lines) {
    const li = document.createElement("li");
    li.textContent = t;
    clientMeta.appendChild(li);
  }
}

function renderSnapshot() {
  const data = selectedClientData();
  if (!data) {
    renderedScreenshotKey = "";
    latestScreenshot.hidden = true;
    latestScreenshot.removeAttribute("src");
    snapshotPlaceholder.hidden = false;
    snapshotPlaceholder.textContent = "請先選擇一台電腦。";
    snapshotMeta.textContent = "尚未收到快照。";
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
    const snap = await getDocs(collection(db, COLLECTION));
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
    collection(db, COLLECTION),
    (snap) => {
      cache.clear();
      snap.forEach((s) => cache.set(s.id, s.data()));
      renderClients();
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
  renderSelectedClient();
  void reconcileClientHistory(pcDropdown.value);
});
btnRefreshSnapshot.addEventListener("click", () => void loadClients());

statusMsg.textContent = `控制台已就緒（v${WEB_BUILD}）`;
startClientListener();
window.setInterval(renderCommandStatus, 1000);
