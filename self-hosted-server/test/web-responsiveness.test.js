import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import test from "node:test";

const companySource = readFileSync(new URL("../../remote-control-web/app.js", import.meta.url), "utf8");
const publicSource = readFileSync(new URL("../public/app.js", import.meta.url), "utf8");
const queueSource = readFileSync(new URL("../src/codex-support-queue.js", import.meta.url), "utf8");
const bridgeSource = readFileSync(new URL("../src/firestore-bridge.js", import.meta.url), "utf8");
function functionSource(source, name) {
  return source.match(new RegExp(`(?:export )?(?:async )?function ${name}\\([^]*?\\n\\}`))?.[0].replace(/^export /, "") || "";
}
function runFunctions(source, names, globals) {
  const context = vm.createContext(globals);
  vm.runInContext(names.map((name) => functionSource(source, name)).join("\n"), context);
  return context;
}
const now = 1_800_000;
const queuedAt = now - 10_000;
const completedCompany = {
  supportRequestNonce: 9, bridgeStatusNonce: 9, bridgeState: "QUEUED",
  bridgeQueuedAt: queuedAt, codexResponseNonce: 9, codexResponseState: "COMPLETED",
  codexResponseAt: now - 1_000, codexResponseTurnId: "turn-9", codexResponseText: "完成了",
};
function elementFactory() {
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, {
      textContent: "", className: "", disabled: false, hidden: false, dataset: {},
      classList: { add() {}, remove() {}, toggle() {} }, setAttribute() {},
    });
    return elements.get(id);
  };
  return { elements, element };
}
const fixedDate = class extends Date { static now() { return now; } };
function renderSupport(source, company, data) {
  const { elements, element } = elementFactory();
  const context = runFunctions(source, ["toInteger", "toMillis", "toBoolean", "readField", "isCodexSupportCompleted", "renderCodexSupportStatus"], {
    Date: fixedDate, document: { getElementById: element }, $: element,
    setText: (id, text) => { element(id).textContent = text; },
    state: { codexSupportData: data }, codexSupportData: data,
    codexSupportSending: false, codexSupportRecoveryBusy: false, codexSupportError: "",
    CODEX_SUPPORT_COOLDOWN_MS: 300_000, CODEX_BRIDGE_ONLINE_MS: 180_000,
    CODEX_SUPPORT_MAX_MESSAGE_LENGTH: 1_000,
    CODEX_SUPPORT_PENDING_STATES: ["PENDING", "RECEIVED", "VALIDATING", "QUEUEING", "RETRYING"],
    selectedCodexSupportMessage: () => ({ message: "下一筆" }),
    btnAskCodex: element("btnAskCodex"), btnCancelCodexSupport: element("btnCancelCodexSupport"),
    btnRetryCodexSupport: element("btnRetryCodexSupport"), codexRecoveryHint: element("codexRecoveryHint"),
    codexDetails: Object.fromEntries(["state", "nonce", "requestedAt", "device", "log", "message", "host", "heartbeat", "receivedAt", "validatedAt", "attemptCount", "lastAttemptAt", "queuedAt", "nextRetryAt", "messageHash", "error"].map((key) => [key, element(key)])),
    codexStages: {}, setCodexStage() {}, renderCodexProgressOverview() {}, setCodexSupportMessage() {},
    fmtTs: String, fmtAge: String, formatTime: String, formatAge: String,
  });
  context.renderCodexSupportStatus();
  return elements.get("btnAskCodex").disabled;
}

test("company send button unlocks immediately after the current final reply", () => {
  assert.equal(renderSupport(companySource, true, completedCompany), false);
});
test("general send button unlocks immediately after the current final reply", () => {
  assert.equal(renderSupport(publicSource, false, {
    requestNonce: 9, statusNonce: 9, state: "QUEUED", queuedAt,
    responseState: "COMPLETED", responseAt: now - 1_000, codexTurnId: "turn-9", responseText: "完成了",
  }), false);
});
test("company pending, mismatched and stale replies still cannot bypass cooldown", () => {
  for (const patch of [
    { codexResponseState: "WAITING" }, { codexResponseState: "IN_PROGRESS" },
    { codexResponseNonce: 8 }, { codexResponseAt: queuedAt - 1 },
    { codexResponseTurnId: "" }, { codexResponseText: "" },
  ]) assert.equal(renderSupport(companySource, true, { ...completedCompany, ...patch }), true);
});

async function submitCompany(data) {
  let written;
  const context = runFunctions(companySource, ["toInteger", "toMillis", "readField", "isCodexSupportCompleted", "requestCodexSupport"], {
    Date: fixedDate, CODEX_SUPPORT_COOLDOWN_MS: 300_000, CODEX_SUPPORT_ACTION: "QUEUE_MESSAGE_V1",
    CODEX_SUPPORT_DOC_ID: "__codex_support", COLLECTION: "clients", db: {}, doc: () => "support-ref",
    codexSupportSending: false, codexSupportError: "", renderCodexSupportStatus() {},
    selectedCodexSupportMessage: () => ({ mode: "CUSTOM", label: "自訂訊息", message: "下一筆" }),
    selectedCodexLogDevice: () => ({ uid: "MYDESK", data: {} }),
    codexAttachSelectedLog: { checked: false }, pcDropdown: { value: "MYDESK" },
    runTransaction: async (_db, callback) => callback({
      get: async () => ({ exists: () => true, data: () => data }),
      set: (_ref, payload) => { written = payload; },
    }),
  });
  await context.requestCodexSupport();
  return { written, error: context.codexSupportError };
}
test("company transaction accepts a new nonce after verified completion", async () => {
  const result = await submitCompany(completedCompany);
  assert.equal(result.error, "");
  assert.equal(result.written?.supportRequestNonce, 10);
  assert.equal(result.written?.codexResponseState, "WAITING");
  assert.equal(result.written?.codexResponseText, "");
});
test("company transaction rereads and blocks when the previous response is still pending", async () => {
  const result = await submitCompany({ ...completedCompany, codexResponseState: "IN_PROGRESS" });
  assert.equal(result.written, undefined);
  assert.match(result.error, /等待 Codex 完成/);
});

test("central queue admits the next report under its lock after final reply", async () => {
  const row = {
    id: 9, state: "QUEUED", response_state: "COMPLETED", queued_at: new Date(queuedAt),
    codex_response_at: new Date(now - 1_000), codex_turn_id: "turn-9", codex_response: "完成了",
  };
  let inserted = false;
  const client = { query: async (sql) => {
    if (/INSERT INTO codex_support_requests/.test(sql)) {
      inserted = true;
      return { rows: [{ id: 10, state: "PENDING" }] };
    }
    if (/SELECT/.test(sql) && /FROM codex_support_requests/.test(sql)) return { rows: [row] };
    return { rows: [] };
  } };
  const context = runFunctions(queueSource, ["milliseconds", "isCodexResponseChronologicallyValid", "hasCompletedCodexResponse", "latestRequest", "submitDirectCodexSupport"], {
    Date: fixedDate, CODEX_SUPPORT_COOLDOWN_MS: 300_000,
    CODEX_SUPPORT_PENDING_STATES: ["PENDING", "RECEIVED", "VALIDATING", "QUEUEING", "RETRYING"],
    PENDING_RESPONSE_STATES: new Set(["WAITING", "IN_PROGRESS"]), TERMINAL_RESPONSE_STATES: new Set(["COMPLETED", "FAILED", "INTERRUPTED"]),
    resolveCodexSupportMessage: () => ({ mode: "CUSTOM", label: "自訂訊息", message: "下一筆" }),
    withTransaction: (callback) => callback(client), statusFromRow: (value) => ({ requestNonce: value.id }),
    HttpError: class extends Error { constructor(_status, message) { super(message); } },
  });
  const result = await context.submitDirectCodexSupport({});
  assert.equal(inserted, true);
  assert.equal(result.requestNonce, 10);
});

test("overview does not rebuild hidden diagnostics and switching to diagnostics renders them", () => {
  const calls = [];
  const names = ["renderGameMaintenance", "renderDeviceSummary", "renderFlowServerStatus", "refreshMeta", "renderPerformance", "renderRecordingStatus", "renderSnapshot", "renderRuntimeEvents", "renderHistory", "renderCommandStatus", "renderServerProgress", "renderServerSwitch", "renderSettingsPage", "setButtonsDisabled"];
  const context = runFunctions(companySource, ["renderSelectedClient"], {
    activeView: "overview", sending: false,
    ...Object.fromEntries(names.map((name) => [name, () => calls.push(name)])),
  });
  context.renderSelectedClient();
  for (const name of ["renderPerformance", "renderRecordingStatus", "renderRuntimeEvents", "renderHistory"])
    assert.equal(calls.includes(name), false, `${name} must wait until diagnostics is visible`);
  calls.length = 0;
  context.activeView = "diagnostics";
  context.renderSelectedClient();
  for (const name of ["renderPerformance", "renderRecordingStatus", "renderRuntimeEvents", "renderHistory"])
    assert.equal(calls.includes(name), true, `${name} must remain available on diagnostics`);
});
test("unchanged performance JSON is parsed once and refreshed on changed data", () => {
  let parses = 0;
  const context = runFunctions(companySource, ["toInteger", "toMillis", "toBoolean", "readField", "readPerformanceSnapshot"], {
    performanceSnapshotCache: null,
    JSON: { parse: (text) => { parses++; return JSON.parse(text); } },
  });
  const data = { performanceSchemaVersion: 1, performanceStatusAvailable: true, performanceJson: '{"current":{"fps":60},"points":[{"at":1000,"fps":60}]}' };
  assert.equal(context.readPerformanceSnapshot(data).current.fps, 60);
  assert.equal(context.readPerformanceSnapshot({ ...data }).current.fps, 60);
  assert.equal(parses, 1);
  assert.equal(context.readPerformanceSnapshot({ ...data, performanceJson: '{"current":{"fps":45}}' }).current.fps, 45);
  assert.equal(parses, 2);
});
test("client listener applies only changed documents and does not touch unrelated cached clients", () => {
  const selected = { uid: "selected", status: "RUN" };
  let subscribe;
  let renderedSelected;
  const cache = new Map([["selected", selected]]);
  const context = runFunctions(companySource, ["startClientListener"], {
    Date: fixedDate, clientsQuery: {}, onSnapshot: (_query, callback) => { subscribe = callback; },
    cache, clientLastObservedChangeAt: new Map(), staleCleanupRetryAfter: new Map(),
    pcDropdown: { value: "selected" }, renderClients: (refreshSelected) => { renderedSelected = refreshSelected; },
    syncCodexLogDeviceOptions() {}, cleanupStaleClients() {}, reconcileClientHistory() {},
  });
  context.startClientListener();
  subscribe({
    docChanges: () => [{ type: "added", doc: { id: "other", data: () => ({ uid: "other" }) } }],
    forEach: (callback) => { callback({ id: "selected", data: () => ({ ...selected }) }); callback({ id: "other", data: () => ({ uid: "other" }) }); },
  });
  assert.equal(cache.get("selected"), selected);
  assert.equal(cache.get("other").uid, "other");
  assert.equal(renderedSelected, false);
});

test("unrelated client changes still refresh selected-device age-dependent summaries", () => {
  const calls = [];
  const dropdown = { value: "selected", appendChild() {}, innerHTML: "" };
  const context = runFunctions(companySource, ["toInteger", "toMillis", "readField", "normalizeStatus", "renderClients"], {
    Date: fixedDate, OFFLINE_THRESHOLD_MS: 300_000,
    cache: new Map([["selected", { status: "RUN", lastHeartbeat: 1 }]]), pcDropdown: dropdown,
    document: { createElement: () => ({}) }, statusMsg: {}, maintenanceNotice: "",
    startSelectedMediaSubscription() {}, renderSelectedClient: () => calls.push("full"),
    renderDeviceSummary: () => calls.push("summary"), renderFlowServerStatus: () => calls.push("flow"),
  });
  context.renderClients(false);
  assert.equal(calls.includes("full"), false);
  assert.equal(calls.includes("summary"), true);
  assert.equal(calls.includes("flow"), true);
});

test("unchanged canvas skips repaint but resize and error events repaint the same visual", () => {
  let paints = 0;
  let width = 480;
  let eventsJson = "[]";
  const canvas = {
    getBoundingClientRect: () => ({ width, height: 210 }),
    getContext: () => new Proxy({}, { get: (_target, key) => key === "clearRect"
      ? () => { paints++; } : () => {} }),
  };
  const context = runFunctions(companySource, ["readField", "drawPerformanceChart"], {
    window: { devicePixelRatio: 1 }, performanceChartCache: new WeakMap(),
    selectedClientData: () => ({ recentEventsJson: eventsJson }), readRuntimeEvents: () => [],
  });
  const points = [{ at: 1000, fps: 60 }];
  const series = [{ key: "fps", color: "#236f9f" }];
  context.drawPerformanceChart(canvas, points, series);
  context.drawPerformanceChart(canvas, points, series);
  assert.equal(paints, 1);
  width = 600;
  context.drawPerformanceChart(canvas, points, series);
  assert.equal(paints, 2);
  eventsJson = '[{"at":1000,"level":"ERROR","name":"新錯誤"}]';
  context.drawPerformanceChart(canvas, points, series);
  assert.equal(paints, 3);
});

test("Firestore compatibility status recognizes the current reply and unlocks without losing pending protection", () => {
  const context = runFunctions(bridgeSource, ["field", "normalizedCodexSupportStatus"], {
    Date: fixedDate,
    integer: (value, fallback) => Number(value) || fallback,
    isCodexSupportPending: (request, status, state) => request > status || ["PENDING", "RECEIVED", "VALIDATING", "QUEUEING", "RETRYING"].includes(state),
    codexSupportCooldownRemaining: (at) => at ? Math.max(0, at + 300_000 - now) : 0,
  });
  const documentFor = (data) => ({ fields: Object.fromEntries(Object.entries(data).map(([key, value]) => [key,
    typeof value === "number" ? { integerValue: String(value) } : { stringValue: value }])) });
  const result = context.normalizedCodexSupportStatus(documentFor(completedCompany));
  assert.equal(result.responseState, "COMPLETED");
  assert.equal(result.responseText, "完成了");
  assert.equal(result.cooldownRemainingMs, 0);
  const pending = context.normalizedCodexSupportStatus(documentFor({ ...completedCompany, codexResponseState: "IN_PROGRESS" }));
  assert.equal(pending.pending, true);
  assert.equal(pending.responsePending, true);
});
