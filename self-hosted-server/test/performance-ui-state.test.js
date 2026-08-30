import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";

function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `missing function ${name}`);
  const signatureEnd = source.indexOf(") {", start);
  assert.notEqual(signatureEnd, -1, `missing function body ${name}`);
  const opening = signatureEnd + 2;
  let depth = 0;
  for (let index = opening; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    if (source[index] === "}") depth -= 1;
    if (depth === 0) return source.slice(start, index + 1);
  }
  throw new Error(`unterminated function ${name}`);
}

for (const [label, url] of [
  ["self-hosted", new URL("../public/app.js", import.meta.url)],
  ["company", new URL("../../remote-control-web/app.js", import.meta.url)],
]) {
  test(`${label} performance UI trusts a fresh healthy state over an old error`, async () => {
    const source = await readFile(url, "utf8");
    const health = vm.runInNewContext(`(${extractFunction(source, "performanceCollectorHealth")})`);
    const recovered = health({
      state: "running", presentMon: "capturing", fpsAvailable: true,
      error: "old error from the previous worker",
    });
    assert.equal(recovered.recovered, true);
    assert.equal(recovered.activeError, "");
    assert.equal(recovered.problem, false);

    const waiting = health({ state: "running", presentMon: "waiting_game", error: "stale" });
    assert.equal(waiting.activeError, "");
    assert.equal(waiting.problem, false);

    const failed = health({ state: "degraded", presentMon: "retry_wait", error: "active failure" });
    assert.equal(failed.activeError, "active failure");
    assert.equal(failed.problem, true);
  });
}

test("self-hosted diagnostics prefers a newer recovered heartbeat over an older API snapshot", async () => {
  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const freshest = vm.runInNewContext(`(${extractFunction(source, "freshestPerformanceSnapshot")})`);
  const oldError = { collector: { updatedAt: 1000, state: "degraded", error: "old" }, current: { at: 1000 } };
  const recovered = { collector: { updatedAt: 2000, state: "running", error: "" }, current: { at: 2000 } };
  assert.equal(freshest(oldError, recovered).collector.state, "running");
  assert.equal(freshest(recovered, oldError).collector.state, "running");
});

test("both diagnostic layouts contain long text on narrow screens", async () => {
  const [selfCss, companyCss] = await Promise.all([
    readFile(new URL("../public/styles.css", import.meta.url), "utf8"),
    readFile(new URL("../../remote-control-web/styles.css", import.meta.url), "utf8"),
  ]);
  assert.match(selfCss, /\.transport-status\s*\{[^}]*min-width:\s*0[^}]*overflow-wrap:\s*anywhere[^}]*word-break:\s*break-word/s);
  assert.match(selfCss, /\.recording-paths\s*>\s*span\s*\{[^}]*white-space:\s*pre-wrap[^}]*overflow-wrap:\s*anywhere[^}]*word-break:\s*break-word/s);
  assert.match(companyCss, /\.performance-notice\s*\{[^}]*min-width:\s*0[^}]*overflow-wrap:\s*anywhere[^}]*word-break:\s*break-word/s);
  assert.match(companyCss, /\.recording-path-row\s+code\s*\{[^}]*white-space:\s*pre-wrap[^}]*overflow-wrap:\s*anywhere[^}]*word-break:\s*break-word/s);
  assert.match(companyCss, /@media\s*\(max-width:\s*700px\)[\s\S]*\.recording-path-row\s*\{\s*grid-template-columns:\s*1fr/);
});
