import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import test from "node:test";
const source = readFileSync(new URL("../public/app.js", import.meta.url), "utf8");
const company = readFileSync(new URL("../../remote-control-web/app.js", import.meta.url), "utf8");
function functionText(text, name) {
  return text.match(new RegExp(`(?:async )?function ${name}\\([^]*?\\n\\}`))?.[0] || "";
}
function setup(authorized = false) {
  const calls = []; const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, { hidden: false, textContent: "", disabled: false, close() {}, showModal() { calls.push("dialog"); } });
    return elements.get(id);
  };
  const context = vm.createContext({
    state: { me: { codexAccess: { authorized, loginUrl: "https://codex.sckang.cc/#codex" } }, codexSupportData: null },
    $: element, codexDetails: { message: element("detail-message") },
    setText: (id, text) => { element(id).textContent = text; }, setCodexSupportMessage() {}, toast() {},
    URL, document: { hidden: false }, window: { location: { assign: (url) => calls.push(url), reload: () => calls.push("reload") } },
    clearTimeout() {}, setTimeout() { calls.push("timer"); return 1; },
    api: async () => { calls.push("api"); return { responseText: "private" }; },
    syncCodexLogDeviceOptions() {}, updateCodexMessageControls() {},
    selectedCodexSupportMessage: () => ({ message: "test" }),
  });
  vm.runInContext(["isCodexAuthorized", "requireCodexLogin", "clearCodexAccess", "stopCodexSupportPolling", "scheduleCodexSupportRefresh", "refreshCodexSupport", "requestCodexSupport", "recoverCodexSupport", "openCodexSupportDialog", "refreshAdmin"].map((name) => functionText(source, name)).join("\n"), context);
  context.renderCodexSupportStatus = () => {};
  return { context, calls, element };
}
test("anonymous page never polls or fetches Codex or admin APIs", async () => {
  const { context, calls } = setup();
  await context.refreshCodexSupport(); context.scheduleCodexSupportRefresh(); await context.refreshAdmin();
  assert.deepEqual(calls, []);
});
test("anonymous Codex actions navigate only to fixed login entrance without sending a message", async () => {
  const { context, calls } = setup();
  context.openCodexSupportDialog(); await context.requestCodexSupport(); await context.recoverCodexSupport("retry");
  assert.deepEqual(calls, Array(3).fill("https://codex.sckang.cc/#codex"));
});
test("authorized page can fetch Codex status and schedule refresh", async () => {
  const { context, calls } = setup(true);
  await context.refreshCodexSupport();
  assert.deepEqual(calls, ["api", "timer"]);
});
test("expired session clears private data and stops polling", async () => {
  const { context, calls, element } = setup(true);
  context.state.codexSupportData = { responseText: "old private reply" };
  element("codexResponseText").textContent = "old private reply";
  element("detail-message").textContent = "old private request";
  context.api = async () => { throw Object.assign(new Error("expired"), { status: 401 }); };
  await context.refreshCodexSupport();
  assert.equal(context.state.me.codexAccess.authorized, false);
  assert.equal(context.state.codexSupportData, null);
  assert.equal(element("codexResponseText").textContent, "");
  assert.equal(element("detail-message").textContent, "");
  assert.deepEqual(calls, []);
});
test("legacy company Codex subscription and mutations are retired", async () => {
  const calls = [];
  const ctx = vm.createContext({ CODEX_LOGIN_URL: "https://codex.sckang.cc/#codex", window: { location: { assign: (url) => calls.push(url) } }, setCodexSupportMessage() {} });
  vm.runInContext(["startCodexSupportListener", "requestCodexSupport", "cancelCodexSupport", "retryCodexSupport", "openCodexSupportDialog"].map((name) => functionText(company, name)).join("\n"), ctx);
  ctx.startCodexSupportListener();
  assert.equal(calls.length, 0);
  for (const name of ["requestCodexSupport", "cancelCodexSupport", "retryCodexSupport", "openCodexSupportDialog"]) await ctx[name]();
  assert.deepEqual(calls, Array(4).fill("https://codex.sckang.cc/#codex"));
});

test("Access login HTML and redirected API responses expire the UI session", async () => {
  for (const response of [
    { ok: true, status: 200, redirected: true, headers: new Headers({ "content-type": "text/html" }) },
    { ok: true, status: 200, redirected: false, headers: new Headers({ "content-type": "text/html" }) },
    { ok: false, status: 403, redirected: false, headers: new Headers({ "content-type": "application/json" }), json: async () => ({error:{message:"expired"}}) },
  ]) {
    const { context, calls, element } = setup(true);
    context.Blob = Blob;
    context.fetch = async () => response;
    vm.runInContext(functionText(source, "api"), context);
    element("codexResponseText").textContent = "private";
    await context.refreshCodexSupport();
    assert.equal(context.state.me.codexAccess.authorized, false);
    assert.equal(element("codexResponseText").textContent, "");
    assert.deepEqual(calls, []);
  }
});

test("expired protected page performs a real reload to re-enter Access login", () => {
  const { context, calls } = setup(true);
  Object.assign(context.window.location, { origin: "https://codex.sckang.cc", pathname: "/", search: "", hash: "#codex" });
  context.clearCodexAccess();
  context.openCodexSupportDialog();
  assert.deepEqual(calls, ["reload"]);
});
