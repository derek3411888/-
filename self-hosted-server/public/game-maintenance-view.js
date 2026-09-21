const phaseLabels = Object.freeze({ NORMAL: "一般流程", CHECKING_NOTICE: "查詢官方公告", WAIT_NOTICE: "等待有效公告",
  WAIT_OPEN: "等待官方開服", CHECKING_INSTALL: "辨識安裝來源", CHECKING_UPDATE: "確認更新狀態", UPDATING: "遊戲更新中",
  CHECKING_LOGIN: "驗證遊戲登入", WAIT_SERVER: "遊戲仍顯示維護中", READY: "主畫面已就緒", NEEDS_ATTENTION: "需要人工確認", STOPPED: "已停止" });
const plain = (value, limit = 400) => typeof value === "string" ? value.replace(/[\x00-\x1f\x7f]/g, " ").slice(0, limit) : "";

export function maintenanceViewModel(value, nowMs = Date.now(), deviceFresh = false) {
  if (typeof value === "string") { try { value = value.length <= 4096 ? JSON.parse(value) : null; } catch { value = null; } }
  const supported = Boolean(value && value.schemaVersion === 1 && value.capabilityVersion === 1 && Object.hasOwn(phaseLabels, value.phase));
  const data = supported ? value : {};
  const stale = !deviceFresh || !Number.isSafeInteger(data.observedAt) || nowMs - data.observedAt > 180000 || data.observedAt > nowMs + 5000;
  const phase = supported ? data.phase : "";
  const progress = typeof data.progressPercent === "number" && data.progressPercent >= 0 && data.progressPercent <= 100 ? data.progressPercent : null;
  const sourceUrl = /^https:\/\/wutheringwaves\.kurogames\.com\/zh-tw\/main\/news\/detail\/\d+$/.test(data.sourceUrl || "") ? data.sourceUrl : "";
  const expectedOpenAt = Number.isSafeInteger(data.expectedOpenAt) ? data.expectedOpenAt : 0;
  return { supported, visible: supported && !(["NORMAL", "READY"].includes(phase) && !data.eventId), stale,
    phase, title: phaseLabels[phase] || "裝置版本尚未支援維護排程", eventId: plain(data.eventId, 180),
    provider: { steam: "Steam（自動判定）", kuro: "官方啟動器（自動判定）", ambiguous: "安裝來源有衝突" }[data.provider] || "來源尚未確認",
    progressText: progress === null ? "進度未知" : `${progress.toFixed(1)}%（${plain(data.progressStage, 40) || "目前階段"}）`,
    canClaimReady: phase === "READY" && !stale, canOperate: supported && !stale,
    remainingSeconds: Math.max(0, Math.ceil((expectedOpenAt - nowMs) / 1000)), expectedOpenAt,
    checkedAt: Number(data.checkedAt) || 0, sourceUrl, detail: plain(data.detail), errorCode: plain(data.errorCode, 100),
    overlay: data.overlay === "PAUSE" ? "遠端暫停；到時不會自動開始" : data.overlay === "WAIT_DESKTOP" ? "桌面已鎖定；等待解鎖" : "",
    targetServer: plain(data.targetServer, 80), gameVersion: plain(data.gameVersion, 32) };
}

export function maintenanceSettingsAck({ desiredRevision = 0, ackRevision = 0, effectiveRevision = 0, applied, detail = "" } = {}) {
  if (desiredRevision > 0 && ackRevision >= desiredRevision && applied === false)
    return { kind: "rejected", text: `裝置拒絕｜版本 ${desiredRevision}｜${plain(detail) || "未套用，請修正後重試"}` };
  if (desiredRevision > 0 && ackRevision >= desiredRevision && effectiveRevision >= desiredRevision && applied === true)
    return { kind: "applied", text: `裝置已套用｜版本 ${desiredRevision}｜${plain(detail)}` };
  if (desiredRevision > 0) return { kind: "pending", text: `已送出｜版本 ${desiredRevision}，等待裝置 ACK；尚未確認套用` };
  return { kind: "idle", text: "設定使用既有版本與 ACK；送出成功不代表裝置已套用。" };
}

export function buildMaintenancePatch(action, model, values = {}, nowMs = Date.now()) {
  if (!model.canOperate) throw new Error("裝置離線、資料過期或版本尚未支援，請等候新心跳。");
  if (action === "enabled") return { maintenanceEnabled: Boolean(values.enabled) };
  if (action === "refresh") return { maintenanceRefreshRequestId: values.requestId };
  if (!model.eventId) throw new Error("目前沒有可調整的維護事件。");
  if (action === "skip") return { maintenanceSkipEventId: model.eventId };
  if (action === "delay") {
    const until = Number(values.until);
    if (!Number.isSafeInteger(until) || until <= nowMs || until > nowMs + 172800000)
      throw new Error("請選擇晚於現在、48 小時內的時間。");
    return { maintenanceOverrideEventId: model.eventId, maintenanceDelayUntilUtc: until };
  }
  throw new Error("不支援的維護設定操作");
}

function element(document, tag, text = "", className = "") {
  const node = document.createElement(tag);
  node.textContent = text;
  if (className) node.className = className;
  return node;
}
function dateText(value) { return value ? new Date(value).toLocaleString("zh-TW", { hour12: false }) : "尚未確認"; }

export function renderMaintenanceCard(root, model) {
  const doc = root.ownerDocument;
  const expanded = root.querySelector("details")?.open || false;
  root.hidden = !model.visible;
  if (!model.visible) { root.replaceChildren(); return; }
  const title = element(doc, "h3", `${model.stale ? "最後已知／資料過期｜" : ""}${model.title}`);
  const summary = element(doc, "p", `${model.provider}${model.gameVersion ? `｜版本 ${model.gameVersion}` : ""}${model.targetServer ? `｜目標 ${model.targetServer}` : ""}`);
  const timing = model.phase === "WAIT_OPEN"
    ? `官方預計開服 ${dateText(model.expectedOpenAt)}｜${model.stale ? "暫停倒數" : `剩餘 ${Math.floor(model.remainingSeconds / 3600)} 小時 ${Math.floor(model.remainingSeconds % 3600 / 60)} 分 ${model.remainingSeconds % 60} 秒`}`
    : model.phase === "UPDATING" ? model.progressText : model.canClaimReady ? "遊戲主畫面已通過驗證" : "此狀態尚不代表鋤地已開始";
  const details = element(doc, "details"); details.open = expanded;
  details.append(element(doc, "summary", "公告與診斷詳情"), element(doc, "p", model.detail || "尚無補充說明"),
    element(doc, "p", `最後查詢：${dateText(model.checkedAt)}${model.errorCode ? `｜${model.errorCode}` : ""}`));
  if (model.sourceUrl) {
    const link = element(doc, "a", "官方維護公告"); link.href = model.sourceUrl; link.target = "_blank"; link.rel = "noopener noreferrer"; details.append(link);
  }
  root.replaceChildren(title, summary, element(doc, "p", timing), element(doc, "p", model.overlay, "maintenance-warning"), details);
}

// Only renders local state and counts down; all network writes use the caller's
// existing settings revision pipeline. No extra polling or Firestore listeners.
export function attachMaintenanceUI({ card, settingsRoot, onSave }) {
  const doc = settingsRoot.ownerDocument;
  const heading = element(doc, "h3", "版本維護與自動更新");
  const help = element(doc, "p", "自動判定 Steam／官方版。版本日等官方開服後才發起更新；Steam 自行下載不受腳本控制。");
  const provider = element(doc, "p");
  const enabledLabel = element(doc, "label", "啟用官方維護排程 ");
  const enabled = element(doc, "input"); enabled.type = "checkbox"; enabledLabel.append(enabled);
  const enabledButton = element(doc, "button", "儲存維護開關"); enabledButton.type = "button";
  const refresh = element(doc, "button", "重新查詢公告"); refresh.type = "button";
  const untilLabel = element(doc, "label", "只延後本次開服等待時間（48 小時內）");
  const until = element(doc, "input"); until.type = "datetime-local"; untilLabel.append(until);
  const delay = element(doc, "button", "套用延後時間"); delay.type = "button";
  const skip = element(doc, "button", "只略過本次時間等待"); skip.type = "button";
  const warning = element(doc, "p", "略過仍會檢查公告、版本、桌面鎖定和遊戲維護畫面，不會強行登入。");
  const status = element(doc, "p", "", "maintenance-settings-status"); status.setAttribute("role", "status");
  const row = element(doc, "div", "", "maintenance-actions"); row.append(enabledButton, refresh, delay, skip);
  settingsRoot.replaceChildren(heading, help, provider, enabledLabel, untilLabel, row, warning, status);
  let data = {}, model = maintenanceViewModel(null), dirty = false, busy = false, submitted = 0, failure = "", receivedAt = 0, clockKey = "";
  const render = () => {
    const raw = typeof data.value === "string" ? (() => { try { return JSON.parse(data.value); } catch { return null; } })() : data.value;
    const key = `${data.uid || ""}|${raw?.observedAt || 0}|${raw?.observedUtcNow || 0}`;
    if (key !== clockKey) { receivedAt = Date.now(); clockKey = key; }
    const now = Number(raw?.observedUtcNow) > 0 ? Number(raw.observedUtcNow) + Math.max(0, Date.now() - receivedAt) : Date.now();
    model = maintenanceViewModel(raw, now, Boolean(data.deviceFresh));
    renderMaintenanceCard(card, model);
    provider.textContent = `${model.provider}${!model.supported ? "｜請先更新裝置程式" : model.stale ? "｜等待新心跳" : ""}`;
    if (!dirty) enabled.checked = data.effectiveSettings?.maintenanceEnabled !== false;
    const ack = maintenanceSettingsAck({ ...data.ack, desiredRevision: Math.max(submitted, Number(data.ack?.desiredRevision) || 0) });
    status.textContent = busy ? "送出中…" : failure || ack.text;
    const disabled = busy || !model.canOperate || ack.kind === "pending" || data.writable === false;
    for (const button of [enabledButton, refresh, delay, skip]) button.disabled = disabled;
    delay.disabled ||= !model.eventId; skip.disabled ||= !model.eventId;
    enabled.disabled = busy || !model.canOperate; until.disabled = busy || !model.canOperate || !model.eventId;
  };
  enabled.addEventListener("change", () => { dirty = true; });
  until.addEventListener("input", () => { dirty = true; });
  async function submit(action) {
    if (busy) return;
    const uid = data.uid;
    try {
      const values = { enabled: enabled.checked, until: new Date(until.value).valueOf(), requestId: globalThis.crypto.randomUUID() };
      const patch = buildMaintenancePatch(action, model, values);
      if (action === "skip" && !globalThis.confirm("只略過本次公告時間等待？仍會驗證遊戲是否可登入。")) return;
      busy = true; failure = ""; render();
      const saved = await onSave(patch, uid);
      if (data.uid !== uid) return;
      submitted = Number(saved?.revision) || 0;
      if (!submitted) throw new Error("未收到設定版本，無法確認已送出。");
    } catch (error) { if (data.uid === uid) failure = `送出失敗（保留輸入）：${error.message}`; }
    finally { if (data.uid === uid) { busy = false; render(); } }
  }
  enabledButton.addEventListener("click", () => void submit("enabled"));
  refresh.addEventListener("click", () => void submit("refresh"));
  delay.addEventListener("click", () => void submit("delay"));
  skip.addEventListener("click", () => void submit("skip"));
  let timer;
  const tick = () => { if (!doc.hidden) render(); timer = setTimeout(tick, doc.hidden ? 15000 : 1000); };
  timer = setTimeout(tick, 1000);
  return { update(next) {
    if (next.uid !== data.uid) { dirty = false; busy = false; submitted = 0; failure = ""; until.value = ""; }
    data = next; render();
  }, dispose() { clearTimeout(timer); } };
}
