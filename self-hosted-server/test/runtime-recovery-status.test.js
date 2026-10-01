import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import test from "node:test";

const source = readFileSync(new URL("../public/app.js", import.meta.url), "utf8");
function render(healing) {
  const block = source.match(/  const healing = status\.selfHealing \|\| \{\};[^]*?(?=\n  const recording =)/)?.[0];
  assert.ok(block, "production recovery rendering block exists");
  const element = { textContent: "", className: "" };
  vm.runInNewContext(block, {
    status: { selfHealing: healing }, Date: class extends Date { static now() { return 1000; } },
    $: () => element, setText: (_id, text) => { element.textContent = text; },
  });
  return element;
}
test("verified gameplay recovery labels retained errors as history, not active retries", () => {
  const view = render({ state: "recovered", code: "GAME_STARTUP_NO_WINDOW_TIMEOUT", consecutive: 6,
    action: "previous repair", detail: "original failure", nextRetryAt: 50_000,
    recoveryDetail: "到达终点了", recoveredAt: 900 });
  assert.match(view.textContent, /已恢復/);
  assert.match(view.textContent, /歷史錯誤.*GAME_STARTUP_NO_WINDOW_TIMEOUT/);
  assert.match(view.textContent, /保留計數 6/);
  assert.match(view.textContent, /到达终点了/);
  assert.doesNotMatch(view.textContent, /秒後再試|正在重試/);
  assert.equal(view.className, "notice ok");
});
test("a new active incident still renders retry/circuit severity and countdown", () => {
  for (const [state, severity] of [["retrying", "warning"], ["circuit_open", "danger"]]) {
    const view = render({ state, code: "NEW_ERROR", consecutive: 7, nextRetryAt: 5000,
      recoveryDetail: "stale recovery evidence" });
    assert.match(view.textContent, /NEW_ERROR/);
    assert.match(view.textContent, /4 秒後再試/);
    assert.doesNotMatch(view.textContent, /stale recovery evidence|歷史錯誤/);
    assert.equal(view.className, `notice ${severity}`);
  }
});
