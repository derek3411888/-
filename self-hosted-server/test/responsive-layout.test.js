import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const publicDirectory = new URL("../public/", import.meta.url);
const companyControlDirectory = new URL("../../remote-control-web/", import.meta.url);

test("recording status uses an isolated responsive layout", async () => {
  const [html, css, script, server, bridge, supportQueue, supportResponseMigration, codexBridge,
    codexBridgeInstaller, codexBridgeWatchdog] = await Promise.all([
    readFile(new URL("index.html", publicDirectory), "utf8"),
    readFile(new URL("styles.css", publicDirectory), "utf8"),
    readFile(new URL("app.js", publicDirectory), "utf8"),
    readFile(new URL("../src/app.js", import.meta.url), "utf8"),
    readFile(new URL("../src/firestore-bridge.js", import.meta.url), "utf8"),
    readFile(new URL("../src/codex-support-queue.js", import.meta.url), "utf8"),
    readFile(new URL("../migrations/008_codex_support_responses.sql", import.meta.url), "utf8"),
    readFile(new URL("../windows/CodexSupportBridge.ps1", import.meta.url), "utf8"),
    readFile(new URL("../windows/Install-CodexSupportBridge.ps1", import.meta.url), "utf8"),
    readFile(new URL("../windows/CodexSupportWatchdog.ps1", import.meta.url), "utf8"),
  ]);

  assert.match(html, /id="recordingStatus" class="recording-status"/);
  assert.match(html, /styles\.css\?v=__SERVER_VERSION__-diagnostics-recovery-20260831/);
  assert.match(html, /app\.js\?v=__SERVER_VERSION__-diagnostics-recovery-20260831/);
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
  assert.match(html, /id="codexLogDeviceSelect"/);
  assert.match(html, /id="btnCancelCodexSupport"/);
  assert.match(html, /id="btnRetryCodexSupport"/);
  assert.match(html, /id="codexSupportDialog"/);
  assert.match(html, /id="codexCustomMessage"[^>]*maxlength="1000"/);
  assert.match(html, /id="codexStageQueued"/);
  assert.match(html, /id="codexStageResponse"/);
  assert.match(html, /id="codexResponseText"/);
  assert.match(html, /data-panel="videos"/);
  assert.match(html, /id="liveVideo"/);
  assert.match(html, /id="recordingList"/);
  assert.match(css, /\.codex-field\[hidden\]\s*\{\s*display:\s*none/);
  assert.match(css, /\.codex-progress-list\s*\{/);
  assert.match(css, /@media\s*\(max-width:\s*820px\)[\s\S]*\.codex-progress-list\s*\{\s*grid-template-columns:\s*1fr/);
  assert.match(script, /api\("\/api\/v1\/codex-support"/);
  assert.match(script, /\/api\/v1\/codex-support\/\$\{action\}/);
  assert.match(script, /CODEX_SUPPORT_PRESETS\s*=\s*Object\.freeze/);
  assert.match(script, /stopCodexSupportPolling/);
  assert.match(script, /\/api\/v1\/devices\/\$\{encoded\}\/performance\?range=/);
  assert.match(script, /function renderPerformance/);
  assert.match(script, /效能資料部分可用；遊戲 FPS 採集異常/);
  assert.doesNotMatch(script, /基礎效能監測正常；遊戲 FPS 採集異常/);
  assert.match(server, /pathname === "\/api\/v1\/codex-support" && req\.method === "GET"/);
  assert.match(server, /pathname === "\/api\/v1\/codex-support" && req\.method === "POST"/);
  assert.match(server, /pathname === "\/api\/v1\/codex-support\/cancel"/);
  assert.match(server, /pathname === "\/api\/v1\/codex-support\/retry"/);
  assert.match(server, /\/internal\/codex-support\/next/);
  assert.match(server, /\/internal\/codex-support\/responses\/pending/);
  assert.match(server, /\/internal\/codex-support\/:nonce\/response/);
  assert.match(bridge, /currentDocument\.updateTime/);
  assert.match(bridge, /CODEX_SUPPORT_DOCUMENT_ID\s*=\s*"__codex_support"/);
  assert.match(supportQueue, /FOR UPDATE SKIP LOCKED/);
  assert.match(supportQueue, /WHERE id=\$1 AND state=\$14 AND claim_generation=\$15 AND claimed_by=\$16 RETURNING/);
  assert.match(supportQueue, /retry_of_id/);
  assert.match(supportQueue, /responseText:\s*String\(row\.codex_response/);
  assert.match(supportQueue, /updateCodexResponse/);
  assert.match(supportResponseMigration, /response_state text NOT NULL DEFAULT 'WAITING'/);
  assert.match(supportResponseMigration, /codex_response text NOT NULL DEFAULT ''/);
  assert.match(codexBridge, /thread\/turns\/list/);
  assert.match(codexBridge, /phase' ''\) -eq 'final_answer'/);
  assert.match(codexBridge, /Find-CodexResponseByMessageHash/);
  assert.match(codexBridge, /Find-CodexResponseFromSessionLog \$Config \$target/);
  assert.match(codexBridge, /rollout-\*-\$\(\[string\]\$Config\.ThreadId\)\.jsonl/);
  assert.match(codexBridge, /\$script:CodexResponseCursors/);
  assert.match(codexBridge, /Get-CodexDisplayResponseText/);
  assert.match(codexBridge, /<oai-mem-citation>/);
  assert.match(codexBridgeInstaller, /BridgePowerShellPath = \$bridgePowerShellPath/);
  assert.match(codexBridgeWatchdog, /PSObject\.Properties\['BridgePowerShellPath'\]/);
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
  assert.match(html, /id="codexLogDeviceSelect"/);
  assert.match(html, /id="btnCancelCodexSupport"/);
  assert.match(html, /id="btnRetryCodexSupport"/);
  assert.match(html, /id="codexStageQueued"/);
  assert.match(html, /id="codexStageResponse"/);
  assert.match(html, /id="codexResponseText"/);
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
  assert.match(script, /codexResponseState:\s*"WAITING"/);
  assert.match(script, /codexResponseText:\s*""/);
  assert.match(script, /async function cancelCodexSupport/);
  assert.match(script, /async function retryCodexSupport/);
  assert.match(script, /supportRetryOfNonce:\s*currentNonce/);
  assert.match(script, /DISPATCH_RESULT_UNKNOWN/);
  assert.match(script, /為避免重複執行，禁止直接重送/);
  assert.match(bridge, /\$ExpectedAction\s*=\s*'QUEUE_MESSAGE_V1'/);
  assert.match(bridge, /\$LegacyAction\s*=\s*'FIX_SCRIPT'/);
  assert.match(bridge, /\$FixedPrompt\s*=\s*'現在腳本有問題，請你找出問題並修正'/);
  assert.match(bridge, /\$MaxMessageLength\s*=\s*1000/);
  assert.match(bridge, /queue --thread \(\[string\]\$(?:config|Config)\.ThreadId\) --message \$queuedMessage/);
  assert.match(bridge, /bridgeState = \$State/);
  assert.match(bridge, /bridgeMessageSha256/);
  assert.match(bridge, /bridgeAttemptCount/);
  assert.match(bridge, /supportRequestContext/);
  assert.match(bridge, /currentDocument\.updateTime/);
  assert.match(bridge, /Invoke-SelfHostedQueue/);
  assert.match(bridge, /Sync-CodexResponses/);
  assert.match(bridge, /Publish-FirestoreCodexResponse/);
  assert.match(bridge, /Queued Firestore support message nonce=\$nonce length=\$\(\$queuedMessage\.Length\) sha256=\$messageHash/);
  assert.doesNotMatch(bridge, /\[[^\]]+\]\(if\s*\(/);
  assert.match(script, /startClientListener\(\)/);
  assert.match(script, /startCodexSupportListener\(\)/);
  assert.match(css, /@media\s*\(max-width:\s*700px\)/);
  assert.match(css, /\.support-button\s*\{[^}]*white-space:\s*normal/s);
  assert.match(css, /\.codex-support-dialog\s*\{/);
  assert.match(css, /\.codex-progress-list\s*\{/);
  assert.match(css, /\.codex-request-details\s+dl\s*\{/);
});
