import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import test from "node:test";

for (const relative of ["../public/app.js", "../../remote-control-web/app.js"]) {
  const source = readFileSync(new URL(relative, import.meta.url), "utf8");
  const renderer = source.match(/function renderCodexProgressOverview\(view\) \{[\s\S]*?\n\}/)?.[0];
  assert.ok(renderer, `progress renderer missing: ${relative}`);
  function render(responseState, turnId = responseState === "WAITING" ? "" : "turn-9") {
    const elements = new Map();
    const element = (id) => {
      if (!elements.has(id)) elements.set(id, { textContent: "", className: "", setAttribute() {} });
      return elements.get(id);
    };
    const context = vm.createContext({
      document: { getElementById: element },
      $: element,
      setText: (id, text) => { element(id).textContent = text; },
      formatTime: String, formatAge: String, fmtTs: String, fmtAge: String,
      formatCodexElapsed: String,
    });
    vm.runInContext(renderer, context);
    context.renderCodexProgressOverview({
      requestNonce: 9, supportState: "QUEUED", responseState, turnId,
      requestedAt: 100, receivedAt: 200, validatedAt: 300, lastAttemptAt: 400,
      queuedAt: 500, responseAt: 0, replyCheckedAt: 0, heartbeatAt: 600,
      bridgeOnline: true, bridgeVersion: "test", detail: "", replyError: "", sending: false, uiError: "",
    });
    return elements;
  }
  test(`${relative}: a stored queue item must not claim conversation delivery`, () => {
    const elements = render("WAITING");
    assert.match(elements.get("codexProgressDeliveryBadge").className, /warning/);
    assert.doesNotMatch(elements.get("codexProgressDeliveryBadge").textContent, /已送進/);
    assert.match(elements.get("codexProgressHeadline").textContent, /等待/);
  });
  test(`${relative}: actual turn evidence advances to processing`, () => {
    const elements = render("IN_PROGRESS");
    assert.match(elements.get("codexProgressDeliveryBadge").className, /ok/);
    assert.match(elements.get("codexProgressHeadline").textContent, /正在處理/);
  });
  test(`${relative}: a removed queue item without a Turn cannot claim Codex received it`, () => {
    const elements = render("FAILED", "");
    assert.doesNotMatch(elements.get("codexProgressDeliveryBadge").className, /\bok\b/);
    assert.doesNotMatch(elements.get("codexProgressDeliveryBadge").textContent, /已送進|已接收/);
    assert.doesNotMatch(elements.get("codexProgressSummary").textContent, /確實已送進/);
  });
  test(`${relative}: stale Turn IDs without a current response are not delivery evidence`, () => {
    const turnEvidence = source.match(/  const responseTurnId = [^\n]+\n  const hasResponseTurn = [^\n]+/)?.[0];
    assert.ok(turnEvidence, "turn evidence validation missing");
    for (const responseState of ["NONE", "WAITING"]) {
      const valid = vm.runInNewContext(`${turnEvidence}; hasResponseTurn`, {
        data: { codexTurnId: "old-turn" }, readField: () => "old-turn",
        responseState, invalidResponseChronology: false,
      });
      assert.equal(valid, false, `${responseState} cannot use an unrelated Turn ID`);
    }
  });
  test(`${relative}: queued input does not complete the actual Turn milestone`, () => {
    const branch = source.match(/if \((?:supportState|state) === "QUEUED"\) \{\r?\n\s+setCodexStage[\s\S]*?\r?\n  \} else if/)?.[0].replace(/ else if$/, "");
    assert.ok(branch, "queued stage renderer missing");
    const stages = {};
    const context = vm.createContext({
      state: "QUEUED", supportState: "QUEUED", responseState: "WAITING", hasResponseTurn: false,
      queuedAt: 500, attemptCount: 1, data: {}, storedResponseAt: 0, responseError: "",
      formatTime: String, fmtTs: String,
      codexStages: { attempted: "attempted", queued: "queued", response: "response" },
      setCodexStage: (id, state, detail) => { stages[id] = { state, detail }; },
    });
    vm.runInContext(branch, context);
    assert.equal(stages.queued.state, "active", "Actual Turn creation is still pending");
    assert.equal(stages.response.state, "waiting", "There is not yet a response-generating turn");
  });
}
