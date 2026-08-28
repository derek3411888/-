import assert from "node:assert/strict";
import test from "node:test";
import {
  CODEX_SUPPORT_ACTION,
  CODEX_SUPPORT_COOLDOWN_MS,
  codexSupportCooldownRemaining,
  isCodexSupportPending,
  normalizeCodexSupportMessage,
  resolveCodexSupportMessage,
} from "../src/codex-support.js";

test("Codex support presets match the Windows bridge contract", () => {
  assert.equal(CODEX_SUPPORT_ACTION, "QUEUE_MESSAGE_V1");
  assert.deepEqual(resolveCodexSupportMessage({ mode: "FIX_SCRIPT" }), {
    mode: "FIX_SCRIPT",
    label: "找出問題並修正",
    message: "現在腳本有問題，請你找出問題並修正",
  });
  assert.match(resolveCodexSupportMessage({ mode: "DIAGNOSE_ONLY" }).message, /先不要修改任何檔案/);
  assert.match(resolveCodexSupportMessage({ mode: "CHECK_CURRENT_STATUS" }).message, /最新 Log/);
});

test("custom Codex support messages normalize line endings and reject unsafe bounds", () => {
  assert.equal(normalizeCodexSupportMessage("  第一行\r\n第二\u0000行  "), "第一行\n第二行");
  assert.deepEqual(resolveCodexSupportMessage({ mode: "custom", message: "  自訂內容  " }), {
    mode: "CUSTOM",
    label: "自訂訊息",
    message: "自訂內容",
  });
  assert.throws(
    () => resolveCodexSupportMessage({ mode: "CUSTOM", message: " \u0000 " }),
    (error) => error.code === "CODEX_SUPPORT_EMPTY_MESSAGE",
  );
  assert.throws(
    () => resolveCodexSupportMessage({ mode: "CUSTOM", message: "字".repeat(1001) }),
    (error) => error.code === "CODEX_SUPPORT_MESSAGE_TOO_LONG",
  );
  assert.throws(
    () => resolveCodexSupportMessage({ mode: "UNKNOWN" }),
    (error) => error.code === "CODEX_SUPPORT_INVALID_MODE",
  );
});

test("pending and cooldown guards survive either website racing", () => {
  assert.equal(isCodexSupportPending(8, 7, "QUEUED"), true);
  assert.equal(isCodexSupportPending(8, 8, "RETRYING"), true);
  assert.equal(isCodexSupportPending(8, 8, "QUEUED"), false);
  const now = 1_000_000;
  assert.equal(codexSupportCooldownRemaining(now - 1_000, now), CODEX_SUPPORT_COOLDOWN_MS - 1_000);
  assert.equal(codexSupportCooldownRemaining(now - CODEX_SUPPORT_COOLDOWN_MS, now), 0);
});
