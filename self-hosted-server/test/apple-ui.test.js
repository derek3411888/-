import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const baseline = JSON.parse(readFileSync(new URL("./fixtures/apple-ui-dom-baseline.json", import.meta.url), "utf8"));
const files = [
  { name: "company", base: "../../remote-control-web/", selector: "pcDropdown", nav: "view-tabs" },
  { name: "central", base: "../public/", selector: "deviceSelect", nav: "tabs" },
];
function parse(html) {
  const root = { tag: "root", attrs: {}, children: [] };
  const stack = [root];
  for (const match of html.matchAll(/<\/?([a-z][\w-]*)\b([^>]*?)>/gi)) {
    const tag = match[1].toLowerCase();
    if (match[0].startsWith("</")) {
      const index = stack.findLastIndex((node) => node.tag === tag);
      if (index > 0) stack.splice(index);
      continue;
    }
    const attrs = Object.fromEntries([...match[2].matchAll(/([\w-]+)(?:="([^"]*)")?/g)].map((item) => [item[1], item[2] ?? true]));
    const node = { tag, attrs, children: [], parent: stack.at(-1) };
    node.parent.children.push(node);
    if (!["meta", "link", "img", "input", "br", "hr", "source"].includes(tag) && !match[0].endsWith("/>")) stack.push(node);
  }
  const all = [];
  function visit(node) { all.push(node); node.children.forEach(visit); }
  visit(root);
  return { all, byId: (id) => all.find((node) => node.attrs.id === id) };
}
function inside(node, ancestor) { for (let item = node; item; item = item.parent) if (item === ancestor) return true; return false; }

for (const entry of files) {
  const html = readFileSync(new URL(`${entry.base}index.html`, import.meta.url), "utf8");
  const css = readFileSync(new URL(`${entry.base}styles.css`, import.meta.url), "utf8");
  const tree = parse(html);
  test(`${entry.name}: redesign preserves every functional DOM ID, hidden panel and native form control`, () => {
    const ids = tree.all.map((node) => node.attrs.id).filter(Boolean);
    assert.equal(new Set(ids).size, ids.length, "IDs must remain unique");
    for (const id of baseline[entry.name]) assert.ok(tree.byId(id), `missing existing feature element ${id}`);
    for (const node of tree.all.filter((item) => item.attrs.role === "tab")) {
      const panel = tree.byId(node.attrs["aria-controls"]);
      assert.equal(panel.attrs.role, "tabpanel");
      assert.equal(panel.attrs["aria-labelledby"], node.attrs.id);
      assert.equal("hidden" in panel.attrs, node.attrs["aria-selected"] !== "true");
    }
    assert.equal(tree.byId("codexCustomMessage").tag, "textarea");
    assert.equal(tree.byId("codexSupportDialog").tag, "dialog");
    assert.ok("hidden" in tree.byId("codexResponseText").attrs);
    assert.ok("hidden" in tree.byId("gameMaintenanceCard").attrs);
  });
  test(`${entry.name}: desktop information architecture groups device and navigation in a real sidebar`, () => {
    const sidebar = tree.all.find((node) => node.tag === "aside" && String(node.attrs.class).split(" ").includes("app-sidebar"));
    const navigation = tree.all.find((node) => node.attrs.role === "tablist");
    assert.ok(sidebar, "device/navigation must have a shared sidebar container");
    assert.ok(inside(tree.byId(entry.selector), sidebar));
    assert.ok(inside(navigation, sidebar));
    assert.ok(!inside(tree.byId("commandStatus"), sidebar));
    assert.ok(!inside(tree.byId("codexProgressBanner"), sidebar));
    assert.match(css, /\.app-shell\s*\{[^}]*grid-template-columns:\s*248px\s+minmax\(0,\s*1fr\)/s);
  });
  test(`${entry.name}: compact layout, focus visibility and reduced-motion safeguards are explicit`, () => {
    assert.match(css, /@media\s*\(max-width:\s*820px\)[\s\S]*\.app-shell\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)/);
    assert.match(css, /:focus-visible[^}]*outline:\s*3px\s+solid/s);
    assert.match(css, /\[hidden\]\s*\{\s*display:\s*none\s*!important/);
    assert.match(css, /min-height:\s*44px/);
    assert.match(css, /prefers-reduced-motion:\s*reduce/);
    assert.doesNotMatch(css, /animation:[^;]*infinite|backdrop-filter|@import\s|fonts\.googleapis/i);
    assert.ok(css.length < 36000, "replace the old override stack, do not append another theme");
  });
  test(`${entry.name}: core text, blue actions and semantic status colors meet 4.5:1 contrast`, () => {
    const tokens = Object.fromEntries([...css.matchAll(/--([\w-]+):\s*(#[0-9a-f]{6})\s*;/gi)].map((match) => [match[1], match[2]]));
    const luminance = (hex) => {
      const rgb = [1, 3, 5].map((offset) => parseInt(hex.slice(offset, offset + 2), 16) / 255)
        .map((channel) => channel <= .04045 ? channel / 12.92 : ((channel + .055) / 1.055) ** 2.4);
      return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
    };
    for (const [foreground, background] of [["ink", "panel"], ["muted", "panel"], ["accent", "panel"],
      ["ok", "ok-tint"], ["warn", "warn-tint"], ["danger", "danger-tint"]]) {
      assert.ok(tokens[foreground] && tokens[background], `missing semantic tokens ${foreground}/${background}`);
      const values = [luminance(tokens[foreground]), luminance(tokens[background])].sort((a, b) => b - a);
      assert.ok((values[0] + .05) / (values[1] + .05) >= 4.5, `${foreground}/${background} must be readable`);
    }
  });
}

function fakeTab(name, key) {
  return { dataset: { [key]: name }, handlers: {}, classList: { toggle() {} }, setAttribute(name, value) { this[name] = value; },
    addEventListener(name, fn) { this.handlers[name] = fn; }, focus() { this.focused = true; } };
}
test("company real tab keyboard handler supports vertical sidebar arrows and retains roving focus", () => {
  const source = readFileSync(new URL("../../remote-control-web/app.js", import.meta.url), "utf8");
  const tabs = ["overview", "diagnostics", "settings"].map((name) => fakeTab(name, "view"));
  const panels = Object.fromEntries(tabs.map((tab) => [tab.dataset.view, { hidden: tab.dataset.view !== "overview" }]));
  const activate = source.slice(source.indexOf("function setActiveView("), source.indexOf("\nfunction startSelectedMediaSubscription("));
  const start = source.indexOf("for (const tab of viewTabs) {", source.indexOf('pcDropdown.addEventListener("change"'));
  const listeners = source.slice(start, source.indexOf('window.addEventListener("hashchange"', start));
  const context = vm.createContext({ viewTabs: tabs, viewOverview: panels.overview, viewDiagnostics: panels.diagnostics, viewSettings: panels.settings,
    activeView: "overview", location: { hash: "" }, history: { replaceState() {} }, startSelectedMediaSubscription() {}, renderSelectedClient() {} });
  vm.runInContext(activate + listeners, context);
  const event = (key) => ({ key, preventDefault() {} });
  tabs[0].handlers.keydown(event("ArrowDown"));
  assert.equal(context.activeView, "diagnostics");
  assert.equal(tabs[1].tabIndex, 0);
  assert.equal(tabs[1].focused, true);
  assert.equal(panels.overview.hidden, true);
  tabs[1].handlers.keydown(event("ArrowUp"));
  assert.equal(context.activeView, "overview");
});
test("central real tab keyboard handler supports vertical navigation without activating hidden panels", () => {
  const source = readFileSync(new URL("../public/app.js", import.meta.url), "utf8");
  const tabs = ["overview", "diagnostics", "videos", "settings"].map((name) => fakeTab(name, "tab"));
  const panels = tabs.map((tab) => ({ dataset: { panel: tab.dataset.tab }, classList: { toggle() {} }, hidden: tab.dataset.tab !== "overview" }));
  const start = source.indexOf('  const tabButtons = [...document.querySelectorAll("[data-tab]")]');
  const block = source.slice(start, source.indexOf('  $("performanceRange").addEventListener', start));
  const state = { activeTab: "overview" };
  vm.runInNewContext(block, { state, document: { querySelectorAll: (selector) => selector === "[data-tab]" ? tabs : panels },
    refresh: async () => {}, toast() {} });
  tabs[0].handlers.keydown({ key: "ArrowDown", preventDefault() {} });
  assert.equal(state.activeTab, "diagnostics");
  assert.equal(tabs[1].tabIndex, 0);
  assert.equal(tabs[1].focused, true);
  assert.equal(panels.filter((panel) => !panel.hidden).length, 1);
});

test("theme preserves semantic colors for actual recording and performance runtime classes", () => {
  const source = readFileSync(new URL("../../remote-control-web/app.js", import.meta.url), "utf8");
  const start = source.indexOf("function recordingStateClass(");
  const fn = source.slice(start, source.indexOf("\nasync function copyPathToClipboard", start));
  const context = vm.createContext({ isLegacyRecordingState: () => false });
  vm.runInContext(fn, context);
  for (const entry of files) {
    const css = readFileSync(new URL(`${entry.base}styles.css`, import.meta.url), "utf8");
    for (const [state, token] of [["complete", "ok"], ["recording", "accent"], ["start_failed", "danger"], ["waiting_game", "warn"]]) {
      const runtimeClass = context.recordingStateClass(state, false);
      const rule = new RegExp(`\\.recording-status-badge\\.${runtimeClass}[^{}]*\\{[^}]*color:\\s*var\\(--${token}\\)`, "s");
      assert.match(css, rule, `${entry.name} must style ${state}/${runtimeClass}`);
    }
    assert.match(css, /\.performance-notice\.error[^{}]*\{[^}]*color:\s*var\(--danger\)/s);
    assert.match(css, /\.performance-notice\.warning[^{}]*\{[^}]*color:\s*var\(--warn\)/s);
  }
});

test("mobile top chrome removes duplicate branding and keeps refresh next to the device selector", () => {
  const styles = files.map((entry) => readFileSync(new URL(`${entry.base}styles.css`, import.meta.url), "utf8"));
  assert.equal(styles[0], styles[1], "both control surfaces must use the same responsive rules");
  const mobile = styles[0].slice(styles[0].indexOf("@media (max-width: 700px)"));
  assert.match(mobile, /\.sidebar-brand\s*\{\s*display:\s*none/);
  assert.match(mobile, /\.brand-kicker,\s*\.brand-copy\s*>\s*p\s*\{\s*display:\s*none/);
  assert.match(mobile, /#refreshButton\s*\{[^}]*grid-column:\s*2[^}]*grid-row:\s*1[^}]*min-height:\s*44px/s);
  assert.match(mobile, /\.device-bar\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)\s+auto/s);
  assert.match(mobile, /\.device-summary\s+strong,\s*#deviceTitle\s*\{[^}]*font-size:\s*12px/s);
  assert.match(mobile, /\.device-summary\s+span,\s*#deviceSummary\s*\{[^}]*font-size:\s*12px/s);
  assert.doesNotMatch(mobile, /(?:#deviceSummary|#deviceTitle|#codexSupportStatus|#commandStatus)[^{}]*\{[^}]*display:\s*none/s);
});
