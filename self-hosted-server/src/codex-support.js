import { HttpError } from "./utils.js";

export const CODEX_SUPPORT_ACTION = "QUEUE_MESSAGE_V1";
export const CODEX_SUPPORT_MAX_MESSAGE_LENGTH = 1000;
export const CODEX_SUPPORT_COOLDOWN_MS = 5 * 60_000;
export const CODEX_SUPPORT_PENDING_STATES = Object.freeze([
  "PENDING",
  "RECEIVED",
  "VALIDATING",
  "QUEUEING",
  "RETRYING",
]);

export const CODEX_SUPPORT_PRESETS = Object.freeze({
  FIX_SCRIPT: Object.freeze({
    label: "找出問題並修正",
    message: "現在腳本有問題，請你找出問題並修正",
  }),
  DIAGNOSE_ONLY: Object.freeze({
    label: "只分析原因",
    message: "現在腳本有問題，請找出原因並回報，先不要修改任何檔案。",
  }),
  CHECK_CURRENT_STATUS: Object.freeze({
    label: "檢查目前狀態",
    message: "請檢查目前腳本執行狀態與最新 Log，告訴我現在發生什麼事；先不要修改。",
  }),
});

export function normalizeCodexSupportMessage(value) {
  return String(value ?? "")
    .replace(/\r\n?/g, "\n")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "")
    .trim();
}

export function resolveCodexSupportMessage(input = {}) {
  const mode = String(input.mode ?? "FIX_SCRIPT").trim().toUpperCase();
  if (mode === "CUSTOM") {
    const message = normalizeCodexSupportMessage(input.message);
    if (!message) throw new HttpError(400, "請先輸入要送出的自訂訊息", "CODEX_SUPPORT_EMPTY_MESSAGE");
    if (message.length > CODEX_SUPPORT_MAX_MESSAGE_LENGTH) {
      throw new HttpError(400, `自訂訊息不可超過 ${CODEX_SUPPORT_MAX_MESSAGE_LENGTH} 個字元`, "CODEX_SUPPORT_MESSAGE_TOO_LONG");
    }
    return { mode, label: "自訂訊息", message };
  }

  const preset = CODEX_SUPPORT_PRESETS[mode];
  if (!preset) throw new HttpError(400, "不支援的 Codex 訊息類型", "CODEX_SUPPORT_INVALID_MODE");
  return { mode, label: preset.label, message: preset.message };
}

export function isCodexSupportPending(requestNonce, statusNonce, state) {
  const request = Math.max(0, Number(requestNonce) || 0);
  const status = Math.max(0, Number(statusNonce) || 0);
  const normalizedState = String(state ?? "").trim().toUpperCase();
  return request > status || (request === status && CODEX_SUPPORT_PENDING_STATES.includes(normalizedState));
}

export function codexSupportCooldownRemaining(queuedAt, now = Date.now()) {
  const queued = Math.max(0, Number(queuedAt) || 0);
  return queued > 0 ? Math.max(0, queued + CODEX_SUPPORT_COOLDOWN_MS - now) : 0;
}
