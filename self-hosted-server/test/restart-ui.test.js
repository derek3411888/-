import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import test from "node:test";

const companySource = readFileSync(new URL("../../remote-control-web/app.js", import.meta.url), "utf8");
const centralSource = readFileSync(new URL("../public/app.js", import.meta.url), "utf8");
function functions(source, names) {
  return names.map((name) => {
    const match = new RegExp(`^(?:async )?function ${name}\\(`, "m").exec(source);
    assert.ok(match, `production function ${name} exists`);
    const rest = source.slice(match.index);
    const end = /\n(?:async )?function |\nbtnPause\.addEventListener|\nfunction refreshAdmin/.exec(rest);
    return end ? rest.slice(0, end.index) : rest;
  }).join("\n");
}

function companyHarness(overrides = {}) {
  let stored = { nonce: 7, lastAckNonce: 7, status: "RUN", lastHeartbeat: Date.now(), remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.33", ...overrides };
  const writes = [];
  const messages = [];
  let release = null;
  const context = vm.createContext({ Date, Map, Math, Set, String, Number, Boolean, Error,
    pcDropdown: { value: "PC" }, statusMsg: {}, db: {}, COLLECTION: "clients", cache: new Map(),
    COMMAND_HISTORY_LIMIT: 30, OFFLINE_THRESHOLD_MS: 300000, crypto: { randomUUID: () => "company-request-1" },
    sending: false, sendingState: "", commandError: null,
    selectedClientData: () => stored,
    readField: (data, field, fallback) => data?.[field] ?? fallback,
    toInteger: (value, fallback = 0) => Number.isFinite(Number(value)) ? Math.trunc(Number(value)) : fallback,
    toMillis: (input) => Number(input) || 0,
    deriveCommandHistory: (data) => data.commandHistory || [],
    renderSelectedClient: () => {}, assertFirestoreControlWritable: () => {},
    setCommandStatus: (...args) => messages.push(args), doc: () => ({}),
    runTransaction: async (_db, callback) => {
      if (release) await new Promise((resolve) => { release = resolve; });
      return callback({ get: async () => ({ exists: () => true, data: () => stored }),
        update: (_ref, patch) => { writes.push(patch); stored = { ...stored, ...patch }; } });
    }, window: { setTimeout: () => {} },
  });
  vm.runInContext(functions(companySource, ["normalizeStatus", "normalizeCommandState", "isServerTargetCommand", "isClientOnline", "supportsRemoteRestart", "commandValidationError", "sendCommand"]), context);
  return { context, writes, messages, send: (command) => context.sendCommand(command),
    hold: () => { release = true; }, release: () => { const resolve = release; release = null; resolve(); },
    setStored: (patch) => { stored = { ...stored, ...patch }; } };
}

test("company real sender emits restart once, blocks pending and lets STOP replace it", async () => {
  const harness = companyHarness();
  await harness.send("RESTART_UPDATE");
  assert.equal(harness.writes.length, 1);
  assert.equal(harness.writes[0].desiredState, "RESTART_UPDATE");
  assert.equal(harness.writes[0].nonce, 8);
  await harness.send("RESTART_UPDATE");
  assert.equal(harness.writes.length, 1);
  await harness.send("STOP");
  assert.equal(harness.writes.length, 2);
  assert.equal(harness.writes[1].nonce, 9);
  assert.equal(harness.writes[1].commandHistory[1].statusReason, "STOP_PRIORITY");
  await harness.send("STOP");
  assert.equal(harness.writes.length, 2);
});

test("company sender checks fresh transaction capability and blocks duplicate in-flight submit", async () => {
  for (const fields of [{ remoteRestartSupported: false }, { remoteRestartSupported: "true" }, { payloadVersion: "5.28" },
    { payloadVersion: "5.28", runtime: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.33" } },
    { status: "STOP" }, { lastHeartbeat: Date.now() - 301000 }]) {
    const harness = companyHarness(fields);
    await harness.send("RESTART_UPDATE");
    assert.equal(harness.writes.length, 0);
  }
  const harness = companyHarness();
  harness.hold();
  const first = harness.send("RESTART_UPDATE");
  await harness.send("RESTART_UPDATE");
  harness.setStored({ remoteRestartSupported: false });
  harness.release();
  await first;
  assert.equal(harness.writes.length, 0, "capability must be checked inside transaction, not only cached UI");
});

test("both real click handlers confirm only managed app restart, not Windows reboot", async () => {
  for (const [source, start, end, buttonName] of [
    [companySource, "btnPause.addEventListener", "btnSwitchServer.addEventListener", "btnRestart"],
    [centralSource, '$("pauseButton").addEventListener', '$("switchButton").addEventListener', "restartButton"],
  ]) {
    const buttons = new Map();
    const button = (name) => buttons.get(name) || (buttons.set(name, { addEventListener: (_event, fn) => buttons.get(name).click = fn }), buttons.get(name));
    const sent = [];
    const confirmations = [];
    let approved = false;
    const context = { $: button, btnPause: button("pause"), btnRun: button("run"), btnStop: button("stop"), btnRestart: button("btnRestart"),
      confirm: (text) => { confirmations.push(text); return approved; }, sendCommand: async (command) => sent.push(command), toast: () => {} };
    vm.runInNewContext(source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start))), context);
    assert.equal(typeof button(buttonName).click, "function");
    button(buttonName).click();
    assert.equal(sent.length, 0);
    approved = true;
    button(buttonName).click();
    await Promise.resolve();
    assert.deepEqual(sent, ["RESTART_UPDATE"]);
    assert.match(confirmations[0], /Windows/);
    assert.match(confirmations[0], /更新/);
    assert.match(confirmations[0], /完整關閉/);
  }
});

function centralHarness(devicePatch = {}) {
  const sent = [];
  const releases = [];
  let held = false;
  let requestNonce = 0;
  const device = { uid: "PC", online: true, status: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.33" }, ...devicePatch };
  const context = vm.createContext({ state: { selectedUid: "PC", devices: [device], details: { device }, migration: { mode: "primary" } },
    crypto: { randomUUID: () => `central-request-${++requestNonce}` }, Date, Error, String, Set,
    selectedDevice: () => device, toast: () => {}, refresh: async () => {},
    api: async (path, input) => { sent.push({ path, ...input }); if (held) await new Promise((resolve) => { releases.push(resolve); }); return { nonce: 8 }; } });
  vm.runInContext(functions(centralSource, ["supportsRemoteRestart", "sendCommand"]), context);
  return { context, sent, hold: () => { held = true; }, release: () => { held = false; releases.shift()(); }, send: (command) => context.sendCommand(command) };
}

test("central real sender rejects legacy/offline and duplicate submit without disabling STOP", async () => {
  for (const patch of [{ status: {} }, { online: false }, { status: { remoteRestartSupported: "true" } },
    { status: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.28" } },
    { status: { payloadVersion: "5.28", runtime: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.33" } } }]) {
    const harness = centralHarness(patch);
    await assert.rejects(harness.send("RESTART_UPDATE"));
    assert.equal(harness.sent.length, 0);
  }
  const harness = centralHarness();
  harness.hold();
  const first = harness.send("RESTART_UPDATE");
  await harness.send("RESTART_UPDATE").catch(() => {});
  assert.equal(harness.sent.length, 1);
  const stop = harness.send("STOP");
  assert.equal(harness.sent[1].body.command, "STOP");
  harness.release(); await first;
  assert.equal(harness.context.state.commandSending, "central-request-2", "finishing older request must not clear active STOP");
  harness.release(); await stop;
});

test("central sender rejects an already pending command locally but STOP still reaches transport", async () => {
  for (const patch of [{ pending_nonce: 7 }, { firestore_command: { pending: true, nonce: 7 } }]) {
    const harness = centralHarness(patch);
    await assert.rejects(harness.send("RESTART_UPDATE"), /ACK|命令/);
    assert.equal(harness.sent.length, 0);
    await harness.send("STOP");
    assert.equal(harness.sent[0].body.command, "STOP");
  }
});

test("company real control renderer gates restart and never offers offline RUN; STOP remains available", () => {
  for (const [patch, disabled] of [[{}, false], [{ payloadVersion: "5.28" }, true], [{ remoteRestartSupported: false }, true],
    [{ lastHeartbeat: Date.now() - 301000 }, true], [{ nonce: 8 }, true]]) {
    const harness = companyHarness(patch);
    const button = () => ({ disabled: false, title: "" });
    Object.assign(harness.context, { btnPause: button(), btnRun: button(), btnRestart: button(), btnStop: button(),
      btnSwitchServer: button(), serverTargetSelect: { options: [], value: "" },
      readServerSchedule: () => ({ enabled: false, list: [] }) });
    harness.context.cache.set("PC", {});
    vm.runInContext(functions(companySource, ["setButtonsDisabled"]), harness.context);
    harness.context.setButtonsDisabled(false);
    assert.equal(harness.context.btnRestart.disabled, disabled);
    assert.equal(harness.context.btnStop.disabled, false);
    if (patch.lastHeartbeat) assert.equal(harness.context.btnRun.disabled, true);
  }
});

test("central real control renderer gates restart on same-build capability and preserves priority STOP", () => {
  const start = centralSource.indexOf('  const migrationMode = state.migration?.mode ?? "shadow";', centralSource.indexOf("function renderDetails("));
  const block = centralSource.slice(start, centralSource.indexOf("  const serverList =", start));
  for (const [patch, disabled] of [[{}, false], [{ online: false }, true], [{ pending_nonce: 8 }, true],
    [{ status: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.28" } }, true]]) {
    const device = { online: true, status: { remoteRestartSupported: true, remoteRestartVersion: "5.33", payloadVersion: "5.33" }, ...patch };
    const elements = new Map();
    const context = vm.createContext({ device, status: device.status, state: { migration: { mode: "primary" } },
      $: (id) => elements.get(id) || (elements.set(id, {}), elements.get(id)) });
    vm.runInContext(functions(centralSource, ["supportsRemoteRestart"]) + block, context);
    assert.equal(elements.get("restartButton").disabled, disabled);
    assert.equal(elements.get("stopButton").disabled, false);
    if (!device.online) assert.equal(elements.get("runButton").disabled, true);
  }
});

test("central real status renderer labels accepted restart as waiting for fresh evidence", () => {
  const start = centralSource.indexOf("  if (pendingNonce) {", centralSource.indexOf("function renderDetails("));
  const block = centralSource.slice(start, centralSource.indexOf("  const healing =", start));
  for (const firestoreControl of [false, true]) {
    const output = {};
    const command = { command: "RESTART_UPDATE", nonce: 8, status: "ACKED", ack_result: "ACCEPTED" };
    const context = vm.createContext({ Date, String, Number, device: { last_command: command }, controlEnabled: true,
      firestoreControl, pendingNonce: 0, forwardedCommand: { ...command, lastAckNonce: 8, lastAckState: "RESTART_UPDATE", lastAckResult: "ACCEPTED" },
      reloadSnapshot: false, $: () => output, setText: (_id, text) => { output.textContent = text; } });
    vm.runInContext(functions(centralSource, ["commandLabel", "restartScheduledText"]) + block, context);
    assert.match(output.textContent, /尚未完成/);
    assert.match(output.textContent, /心跳.*版本/);
    assert.match(output.className, /warning/);
  }
});

test("restart ACCEPTED history is scheduled, never completed by ACK alone", () => {
  const context = vm.createContext({ fmtTs: () => "time", readField: (_data, _key, fallback) => fallback, toInteger: Number, ACK_TIMEOUT_MS: 30000 });
  vm.runInContext(functions(companySource, ["historyStatusLabel", "historyStatusClass", "historyStatusDetail", "commandHistoryLabel"]), context);
  const entry = { requestedState: "RESTART_UPDATE", status: "ACKED", ackResult: "ACCEPTED", ackDetail: "scheduled", commandNonce: 8 };
  assert.match(context.commandHistoryLabel(entry), /重新啟動/);
  assert.match(context.historyStatusLabel(entry), /排程|受理/);
  assert.equal(context.historyStatusClass(entry), "waiting");
  assert.match(context.historyStatusDetail(entry, {}), /心跳/);
  assert.match(context.historyStatusDetail(entry, {}), /進度|版本/);
});

test("company reconciliation preserves explicit priority STOP supersession before any later ACK", () => {
  const context = vm.createContext({ Date, Set, Math, String, Number, ACK_TIMEOUT_MS: 30000,
    readField: (data, key, fallback) => data[key] ?? fallback, toInteger: (input) => Number(input) || 0,
    toMillis: (input) => Number(input) || 0 });
  vm.runInContext(functions(companySource, ["normalizeCommandState", "isServerTargetCommand", "normalizeHistoryEntry", "deriveHistoryEntry", "historyStatusLabel", "historyStatusDetail"]), context);
  const entry = { commandNonce: 8, requestedState: "RESTART_UPDATE", status: "SUPERSEDED", statusReason: "STOP_PRIORITY", sentAt: 1000 };
  for (const lastAckNonce of [7, 8, 9]) {
    const actual = context.deriveHistoryEntry(entry, { lastAckNonce, lastAckState: "RESTART_UPDATE", lastAckResult: "ACCEPTED" }, 2000);
    assert.equal(actual.status, "SUPERSEDED");
    assert.equal(actual.statusReason, "STOP_PRIORITY");
    assert.match(context.historyStatusLabel(actual), /關閉|STOP/);
    assert.match(context.historyStatusDetail(actual, {}), /優先/);
    assert.doesNotMatch(context.historyStatusDetail(actual, {}), /ACK 已前進/);
  }
});
