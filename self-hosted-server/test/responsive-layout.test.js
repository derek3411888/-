import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const publicDirectory = new URL("../public/", import.meta.url);

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
