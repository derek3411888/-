import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const publicDirectory = new URL("../public/", import.meta.url);
const companyControlDirectory = new URL("../../remote-control-web/", import.meta.url);

test("recording status uses an isolated responsive layout", async () => {
  const [html, css] = await Promise.all([
    readFile(new URL("index.html", publicDirectory), "utf8"),
    readFile(new URL("styles.css", publicDirectory), "utf8"),
  ]);

  assert.match(html, /id="recordingStatus" class="recording-status"/);
  assert.doesNotMatch(html, /id="recordingStatus" class="key-values"/);
  assert.match(css, /\.key-values\s*>\s*div\s*\{/);
  assert.doesNotMatch(css, /\.key-values\s+div\s*\{/);
  assert.match(css, /\.recording-paths\s*>\s*span\s*\{[^}]*overflow-wrap:\s*anywhere/s);
  assert.match(css, /\.progress-summary\s+span\s*\{[^}]*white-space:\s*nowrap/s);
  assert.match(css, /\.card\s*\{[^}]*min-width:\s*0/s);
  assert.match(css, /\.tab-panel\.active\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)/s);
  assert.match(css, /\.table-wrap\s*\{[^}]*min-width:\s*0[^}]*overflow:\s*auto/s);
  assert.match(css, /\.device-bar,\s*\.grid\.two,\s*\.video-grid\s*\{\s*grid-template-columns:\s*minmax\(0,\s*1fr\)/s);
});

test("GitHub Pages company mode sends a fixed support action to the local Codex bridge", async () => {
  const [html, script, css, bridge] = await Promise.all([
    readFile(new URL("index.html", companyControlDirectory), "utf8"),
    readFile(new URL("app.js", companyControlDirectory), "utf8"),
    readFile(new URL("styles.css", companyControlDirectory), "utf8"),
    readFile(new URL("../windows/CodexSupportBridge.ps1", import.meta.url), "utf8"),
  ]);

  assert.doesNotMatch(html, /location\.(?:replace|href)/);
  assert.doesNotMatch(script, /SELF_HOSTED_CONTROL_URL|redirectToSelfHostedControl/);
  assert.match(html, /id="btnAskCodex"/);
  assert.doesNotMatch(html, /chatgpt\.com/i);
  assert.match(script, /CODEX_SUPPORT_ACTION\s*=\s*"FIX_SCRIPT"/);
  assert.match(script, /CODEX_SUPPORT_DOC_ID\s*=\s*"__codex_support"/);
  assert.match(script, /transaction\.set\(supportRef,[\s\S]*supportRequestAction:\s*CODEX_SUPPORT_ACTION/);
  assert.match(bridge, /\$ExpectedAction\s*=\s*'FIX_SCRIPT'/);
  assert.match(bridge, /\$FixedPrompt\s*=\s*'現在腳本有問題，請你找出問題並修正'/);
  assert.match(bridge, /queue --thread \(\[string\]\$config\.ThreadId\) --message \$FixedPrompt/);
  assert.doesNotMatch(script, /supportRequestPrompt|SUPPORT_PROMPT/);
  assert.match(script, /startClientListener\(\)/);
  assert.match(script, /startCodexSupportListener\(\)/);
  assert.match(css, /@media\s*\(max-width:\s*700px\)/);
  assert.match(css, /\.support-button\s*\{[^}]*white-space:\s*normal/s);
});
