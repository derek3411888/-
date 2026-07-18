import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.4/firebase-app.js";
import { getFirestore, collection, doc, getDocs, updateDoc, getDoc } from "https://www.gstatic.com/firebasejs/10.12.4/firebase-firestore.js";

// TODO: 填入你自己的 Firebase 專案設定
const FIREBASE_CONFIG = {
  apiKey: "AIzaSyDqWHdBixVQPt4OiTi50hseInFxPtk0hf0",
  authDomain: "ww-control-a3988.firebaseapp.com",
  projectId: "ww-control-a3988",
};

const COLLECTION = "ahk_clients";
const OFFLINE_THRESHOLD_MS = 5 * 60_000;
const REFRESH_MS = 5_000;
const WEB_BUILD = "20260718-1";

const app = initializeApp(FIREBASE_CONFIG);
const db = getFirestore(app);

const pcDropdown = document.getElementById("pcDropdown");
const btnPause = document.getElementById("btnPause");
const btnRun = document.getElementById("btnRun");
const btnStop = document.getElementById("btnStop");
const statusMsg = document.getElementById("statusMsg");
const clientMeta = document.getElementById("clientMeta");

let cache = new Map();

function fmtTs(ms) {
  if (!ms) return "-";
  const d = new Date(Number(ms));
  return d.toLocaleString("zh-TW", { hour12: false });
}

function fmtAge(ms) {
  if (!ms) return "-";
  const ageMs = Math.max(0, Date.now() - Number(ms));
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
      nonce: Number(readField(data, "nonce", 0)),
      lastAckNonce: Number(readField(data, "lastAckNonce", 0)),
      lastAckState: readField(data, "lastAckState", ""),
      lastAckAt: Number(readField(data, "lastAckAt", 0)),
      currentStep: readField(data, "currentStep", ""),
      currentStepDetail: readField(data, "currentStepDetail", ""),
      currentStepLevel: readField(data, "currentStepLevel", ""),
      currentServer: readField(data, "currentServer", ""),
      currentServerLabel: readField(data, "currentServerLabel", ""),
      currentServerIndex: Number(readField(data, "currentServerIndex", 0)),
      currentServerTotal: Number(readField(data, "currentServerTotal", 0)),
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
  refreshMeta();
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
    `最後 ACK: nonce=${readField(d, "lastAckNonce", 0)} state=${readField(d, "lastAckState", "-")} at=${fmtTs(readField(d, "lastAckAt", 0))}`,
  ];
  for (const t of lines) {
    const li = document.createElement("li");
    li.textContent = t;
    clientMeta.appendChild(li);
  }
}

async function loadClients() {
  try {
    const snap = await getDocs(collection(db, COLLECTION));
    cache.clear();
    snap.forEach((s) => cache.set(s.id, s.data()));
    renderClients();
  } catch (e) {
    statusMsg.textContent = `讀取失敗：${e.message}`;
  }
}

async function sendCommand(state) {
  const id = pcDropdown.value;
  if (!id) {
    statusMsg.textContent = "請先選擇一台在線電腦";
    return;
  }

  try {
    const ref = doc(db, COLLECTION, id);
    const current = await getDoc(ref);
    const curNonce = Number(current.data()?.nonce || 0);
    const nextNonce = curNonce + 1;

    await updateDoc(ref, {
      desiredState: state,
      nonce: nextNonce,
      commandUpdatedAt: Date.now(),
    });

    statusMsg.textContent = `已送出 ${state} 指令（nonce=${nextNonce}）`;
    setTimeout(loadClients, 1200);
  } catch (e) {
    statusMsg.textContent = `下發失敗：${e.message}`;
  }
}

btnPause.addEventListener("click", () => sendCommand("PAUSE"));
btnRun.addEventListener("click", () => sendCommand("RUN"));
btnStop.addEventListener("click", () => {
  if (!confirm("確定要遠端關閉腳本並完整關閉遊戲/OKWW/LRMCAI？")) return;
  sendCommand("STOP");
});
pcDropdown.addEventListener("change", refreshMeta);

statusMsg.textContent = `控制台已就緒（v${WEB_BUILD}）`;
loadClients();
setInterval(loadClients, REFRESH_MS);
