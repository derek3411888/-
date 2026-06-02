import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.4/firebase-app.js";
import { getFirestore, collection, doc, getDocs, updateDoc, getDoc } from "https://www.gstatic.com/firebasejs/10.12.4/firebase-firestore.js";

// TODO: 填入你自己的 Firebase 專案設定
const FIREBASE_CONFIG = {
  apiKey: "AIzaSyDqWHdBixVQPt4OiTi50hseInFxPtk0hf0",
  authDomain: "ww-control-a3988.firebaseapp.com",
  projectId: "ww-control-a3988",
};

const CONTROL_PASSWORD = "okww-control-2026";
const CONTROL_SECRET = "ww-control-a3988-shared-2026";
const COLLECTION = "ahk_clients";
const OFFLINE_THRESHOLD_MS = 10 * 60_000;
const REFRESH_MS = 5_000;

const app = initializeApp(FIREBASE_CONFIG);
const db = getFirestore(app);

const gateCard = document.getElementById("gateCard");
const controlCard = document.getElementById("controlCard");
const gatePwd = document.getElementById("gatePwd");
const gateMsg = document.getElementById("gateMsg");
const btnUnlock = document.getElementById("btnUnlock");

const pcDropdown = document.getElementById("pcDropdown");
const btnPause = document.getElementById("btnPause");
const btnRun = document.getElementById("btnRun");
const statusMsg = document.getElementById("statusMsg");
const clientMeta = document.getElementById("clientMeta");

let unlocked = false;
let cache = new Map();

function fmtTs(ms) {
  if (!ms) return "-";
  const d = new Date(Number(ms));
  return d.toLocaleString("zh-TW", { hour12: false });
}

function readField(docData, key, def = "") {
  if (!(key in docData)) return def;
  return docData[key];
}

function lockUi(flag) {
  controlCard.classList.toggle("locked", flag);
}

function renderClients() {
  const now = Date.now();
  const rows = [];
  let onlineCount = 0;

  for (const [id, data] of cache.entries()) {
    const hb = Number(readField(data, "lastHeartbeat", 0));
    const online = now - hb <= OFFLINE_THRESHOLD_MS;
    if (online) onlineCount += 1;

    rows.push({
      id,
      online,
      displayName: readField(data, "displayName", id),
      computerName: readField(data, "computerName", ""),
      status: readField(data, "status", "UNKNOWN"),
      lastHeartbeat: hb,
      nonce: Number(readField(data, "nonce", 0)),
      lastAckNonce: Number(readField(data, "lastAckNonce", 0)),
      lastAckState: readField(data, "lastAckState", ""),
      lastAckAt: Number(readField(data, "lastAckAt", 0)),
    });
  }

  rows.sort((a, b) => b.lastHeartbeat - a.lastHeartbeat);

  const keep = pcDropdown.value;
  pcDropdown.innerHTML = "";
  for (const r of rows) {
    const opt = document.createElement("option");
    opt.value = r.id;
    const onlineTag = r.online ? "在線" : "離線";
    opt.textContent = `${r.displayName} (${r.status} / ${onlineTag})`;
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
    `電腦: ${readField(d, "computerName", "-")}`,
    `狀態: ${readField(d, "status", "-")}`,
    `最後心跳: ${fmtTs(readField(d, "lastHeartbeat", 0))}`,
    `最後 ACK: nonce=${readField(d, "lastAckNonce", 0)} state=${readField(d, "lastAckState", "-")} at=${fmtTs(readField(d, "lastAckAt", 0))}`,
  ];
  for (const t of lines) {
    const li = document.createElement("li");
    li.textContent = t;
    clientMeta.appendChild(li);
  }
}

async function loadClients() {
  if (!unlocked) return;
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
      controlSecret: CONTROL_SECRET,
      commandUpdatedAt: Date.now(),
    });

    statusMsg.textContent = `已送出 ${state} 指令（nonce=${nextNonce}）`;
    setTimeout(loadClients, 1200);
  } catch (e) {
    statusMsg.textContent = `下發失敗：${e.message}`;
  }
}

btnUnlock.addEventListener("click", () => {
  if (gatePwd.value !== CONTROL_PASSWORD) {
    gateMsg.textContent = "密碼錯誤";
    return;
  }
  unlocked = true;
  gateMsg.textContent = "已解鎖";
  lockUi(false);
  loadClients();
});

btnPause.addEventListener("click", () => sendCommand("PAUSE"));
btnRun.addEventListener("click", () => sendCommand("RUN"));
pcDropdown.addEventListener("change", refreshMeta);

lockUi(true);
setInterval(loadClients, REFRESH_MS);
