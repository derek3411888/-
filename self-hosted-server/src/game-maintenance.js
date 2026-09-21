import { HttpError } from "./utils.js";

const phases = new Set(["NORMAL", "CHECKING_NOTICE", "WAIT_NOTICE", "WAIT_OPEN", "CHECKING_INSTALL", "CHECKING_UPDATE",
  "UPDATING", "CHECKING_LOGIN", "WAIT_SERVER", "READY", "NEEDS_ATTENTION", "STOPPED"]);
export const MAINTENANCE_SETTINGS = Object.freeze({ maintenanceEnabled: "boolean", maintenanceOverrideEventId: "string",
  maintenanceDelayUntilUtc: "integer", maintenanceSkipEventId: "string", maintenanceRefreshRequestId: "string" });
const text = (value, max) => typeof value === "string" ? value.replace(/[\x00-\x1f\x7f]/g, " ").slice(0, max) : "";
const time = (value) => Number.isSafeInteger(value) && value > 0 && value <= 9999999999999 ? value : 0;

export function normalizeGameMaintenance(value, nowMs = Date.now()) {
  if (typeof value === "string") {
    if (Buffer.byteLength(value) > 4096) return null;
    try { value = JSON.parse(value); } catch { return null; }
  }
  if (!value || typeof value !== "object" || Array.isArray(value) || value.schemaVersion !== 1 || value.capabilityVersion !== 1
    || !phases.has(value.phase) || !time(value.observedAt) || value.observedAt > nowMs + 5000) return null;
  const sourceUrl = /^https:\/\/wutheringwaves\.kurogames\.com\/tw\/main\/news\/detail\/\d+$/.test(value.sourceUrl ?? "")
    ? value.sourceUrl : "";
  return { schemaVersion: 1, capabilityVersion: 1, phase: value.phase,
    overlay: ["PAUSE", "WAIT_DESKTOP"].includes(value.overlay) ? value.overlay : "",
    provider: ["steam", "kuro", "ambiguous"].includes(value.provider) ? value.provider : "unknown",
    gameVersion: text(value.gameVersion, 32), eventId: text(value.eventId, 180), sourceUrl,
    sourceState: ["valid", "pending", "unavailable", "invalid", "disabled"].includes(value.sourceState) ? value.sourceState : "unavailable",
    expectedOpenAt: time(value.expectedOpenAt), checkedAt: time(value.checkedAt) <= nowMs + 5000 ? time(value.checkedAt) : 0,
    observedAt: value.observedAt, observedUtcNow: time(value.observedUtcNow) <= nowMs + 5000 ? time(value.observedUtcNow) : 0,
    progressPercent: typeof value.progressPercent === "number" && Number.isFinite(value.progressPercent)
      && value.progressPercent >= 0 && value.progressPercent <= 100 ? value.progressPercent : null,
    progressStage: text(value.progressStage, 40), errorCode: text(value.errorCode, 100),
    detail: text(value.detail, 400).replace(/(?:[A-Za-z]:\\|\\\\)[^\s|]*/g, "[本機路徑]"), targetServer: text(value.targetServer, 80) };
}

export function normalizeMaintenanceSettings(value = {}, { previous = {}, status = null, nowMs = Date.now() } = {}) {
  const result = {};
  const changed = [];
  for (const [key, type] of Object.entries(MAINTENANCE_SETTINGS)) {
    if (Object.hasOwn(previous, key)) result[key] = previous[key];
    if (!Object.hasOwn(value, key)) continue;
    const item = value[key];
    if (type === "boolean" ? typeof item !== "boolean" : type === "integer" ? !Number.isSafeInteger(item) || item < 0
      : typeof item !== "string" || item.length > 180 || (item !== "" && !/^[A-Za-z0-9._:@-]+$/.test(item))) {
      throw new HttpError(400, "版本維護設定格式錯誤", "INVALID_MAINTENANCE_SETTINGS");
    }
    result[key] = item;
    if (item !== previous[key]) changed.push(key);
  }
  if (!changed.length) return result;
  const normalized = normalizeGameMaintenance(status, nowMs);
  if (!normalized || nowMs - normalized.observedAt > 180000) {
    throw new HttpError(409, "裝置版本未支援或維護狀態已過期，請等候新心跳", "MAINTENANCE_CAPABILITY_UNAVAILABLE");
  }
  if (changed.some((key) => ["maintenanceOverrideEventId", "maintenanceDelayUntilUtc"].includes(key))
    && (result.maintenanceDelayUntilUtc || result.maintenanceOverrideEventId)) {
    if (!normalized.eventId || result.maintenanceOverrideEventId !== normalized.eventId
      || result.maintenanceDelayUntilUtc <= nowMs || result.maintenanceDelayUntilUtc > nowMs + 172800000) {
      throw new HttpError(400, "延後時間必須綁定目前事件，晚於現在且不超過 48 小時", "INVALID_MAINTENANCE_DELAY");
    }
  }
  if (changed.includes("maintenanceSkipEventId") && result.maintenanceSkipEventId && result.maintenanceSkipEventId !== normalized.eventId) {
    throw new HttpError(409, "維護事件已變更，不能略過舊事件", "MAINTENANCE_EVENT_CHANGED");
  }
  return result;
}
