import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const publicDirectory = new URL("../public/", import.meta.url);
const companyControlDirectory = new URL("../../remote-control-web/", import.meta.url);

test("recording status uses an isolated responsive layout", async () => {
  const [html, css, script, server, bridge] = await Promise.all([
    readFile(new URL("index.html", publicDirectory), "utf8"),
    readFile(new URL("styles.css", publicDirectory), "utf8"),
    readFile(new URL("app.js", publicDirectory), "utf8"),
    readFile(new URL("../src/app.js", import.meta.url), "utf8"),
    readFile(new URL("../src/firestore-bridge.js", import.meta.url), "utf8"),
  ]);

  assert.match(html, /id="recordingStatus" class="recording-status"/);
  assert.match(html, /<details class="card recording-details">/);
  assert.doesNotMatch(html, /<details class="card recording-details"\s+open/);
  assert.match(html, /id="performanceRange"/);
  assert.match(html, /id="perfFpsChart"/);
  assert.match(html, /id="perfUsageChart"/);
  assert.doesNotMatch(html, /id="recordingStatus" class="key-values"/);
  assert.match(css, /\.key-values\s*>\s*div\s*\{/);
  assert.doesNotMatch(css, /\.key-values\s+div\s*\{/);
  assert.match(css, /\.recording-paths\s*>\s*span\s*\{[^}]*overflow-wrap:\s*anywhere/s);
  assert.match(css, /\.performance-kpis\s*\{[^}]*grid-template-columns:\s*repeat\(4,/s);
  assert.match(css, /\.performance-chart-grid\s*\{[^}]*grid-template-columns:\s*repeat\(2,/s);
  assert.match(css, /\.progress-summary\s+span\s*\{[^}]*white-space:\s*nowrap/s);
  assert.match(css, /\.card\s*\{[^}]*min-width:\s*0/s);
  assert.match(css, /\.tab-panel\.active\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)/s);
  assert.match(css, /\.table-wrap\s*\{[^}]*min-width:\s*0[^}]*overflow:\s*auto/s);
  assert.match(css, /\.device-bar,\s*\.grid\.two,\s*\.video-grid\s*\{\s*grid-template-columns:\s*minmax\(0,\s*1fr\)/s);
  assert.match(html, /id="btnOpenCodexSupport"/);
  assert.match(html, /id="codexSupportDialog"/);
  assert.match(html, /id="codexCustomMessage"[^>]*maxlength="1000"/);
  assert.match(html, /id="codexStageQueued"/);
  assert.match(html, /data-panel="videos"/);
  assert.match(html, /id="liveVideo"/);
  assert.match(html, /id="recordingList"/);
  assert.match(css, /\.codex-field\[hidden\]\s*\{\s*display:\s*none/);
  assert.match(css, /\.codex-progress-list\s*\{/);
  assert.match(css, /@media\s*\(max-width:\s*820px\)[\s\S]*\.codex-progress-list\s*\{\s*grid-template-columns:\s*1fr/);
  assert.match(script, /api\("\/api\/v1\/codex-support"/);
  assert.match(script, /CODEX_SUPPORT_PRESETS\s*=\s*Object\.freeze/);
  assert.match(script, /stopCodexSupportPolling/);
  assert.match(script, /\/api\/v1\/devices\/\$\{encoded\}\/performance\?range=/);
  assert.match(script, /function renderPerformance/);
  assert.match(server, /pathname === "\/api\/v1\/codex-support" && req\.method === "GET"/);
  assert.match(server, /pathname === "\/api\/v1\/codex-support" && req\.method === "POST"/);
  assert.match(bridge, /currentDocument\.updateTime/);
  assert.match(bridge, /CODEX_SUPPORT_DOCUMENT_ID\s*=\s*"__codex_support"/);
});

test("GitHub Pages company mode supports preset or custom Codex messages with detailed status", async () => {
  const [html, script, css, bridge] = await Promise.all([
    readFile(new URL("index.html", companyControlDirectory), "utf8"),
    readFile(new URL("app.js", companyControlDirectory), "utf8"),
    readFile(new URL("styles.css", companyControlDirectory), "utf8"),
    readFile(new URL("../windows/CodexSupportBridge.ps1", import.meta.url), "utf8"),
  ]);

  assert.doesNotMatch(html, /location\.(?:replace|href)/);
  assert.doesNotMatch(script, /SELF_HOSTED_CONTROL_URL|redirectToSelfHostedControl/);
  assert.match(html, /id="btnOpenCodexSupport"/);
  assert.match(html, /id="codexSupportDialog"/);
  assert.match(html, /id="codexMessagePreset"/);
  assert.match(html, /option value="CUSTOM"/);
  assert.match(html, /id="codexCustomMessage"[^>]*maxlength="1000"/);
  assert.match(html, /id="btnAskCodex"/);
  assert.match(html, /id="codexStageQueued"/);
  assert.match(html, /id="codexDetailAttemptCount"/);
  assert.match(html, /id="codexDetailError"/);
  assert.doesNotMatch(html, /chatgpt\.com/i);
  assert.match(script, /CODEX_SUPPORT_ACTION\s*=\s*"QUEUE_MESSAGE_V1"/);
  assert.match(script, /CODEX_SUPPORT_MAX_MESSAGE_LENGTH\s*=\s*1000/);
  assert.match(script, /FIX_SCRIPT:\s*Object\.freeze/);
  assert.match(script, /DIAGNOSE_ONLY:\s*Object\.freeze/);
  assert.match(script, /CHECK_CURRENT_STATUS:\s*Object\.freeze/);
  assert.match(script, /CODEX_SUPPORT_DOC_ID\s*=\s*"__codex_support"/);
  assert.match(script, /transaction\.set\(supportRef,[\s\S]*supportRequestAction:\s*CODEX_SUPPORT_ACTION[\s\S]*supportRequestMessage:\s*selection\.message/);
  assert.match(script, /bridgeAttemptCount:\s*0/);
  assert.match(script, /bridgeNextRetryAt:\s*0/);
  assert.match(bridge, /\$ExpectedAction\s*=\s*'QUEUE_MESSAGE_V1'/);
  assert.match(bridge, /\$LegacyAction\s*=\s*'FIX_SCRIPT'/);
  assert.match(bridge, /\$FixedPrompt\s*=\s*'現在腳本有問題，請你找出問題並修正'/);
  assert.match(bridge, /\$MaxMessageLength\s*=\s*1000/);
  assert.match(bridge, /queue --thread \(\[string\]\$config\.ThreadId\) --message \$message/);
  assert.match(bridge, /bridgeState = \$State/);
  assert.match(bridge, /bridgeMessageSha256/);
  assert.match(bridge, /bridgeAttemptCount/);
  assert.match(bridge, /Queued support message nonce=\$nonce length=\$\(\$message\.Length\) sha256=\$messageHash/);
  assert.doesNotMatch(bridge, /\[[^\]]+\]\(if\s*\(/);
  assert.match(script, /startClientListener\(\)/);
  assert.match(script, /startCodexSupportListener\(\)/);
  assert.match(css, /@media\s*\(max-width:\s*700px\)/);
  assert.match(css, /\.support-button\s*\{[^}]*white-space:\s*normal/s);
  assert.match(css, /\.codex-support-dialog\s*\{/);
  assert.match(css, /\.codex-progress-list\s*\{/);
  assert.match(css, /\.codex-request-details\s+dl\s*\{/);
});
