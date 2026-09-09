import { HttpError, boundedText, integer } from "./utils.js";

export const FIRESTORE_COMMAND_READ_FIELDS = Object.freeze([
  "desiredState",
  "nonce",
  "lastAckNonce",
  "lastAckState",
  "lastAckResult",
  "lastAckDetail",
  "lastAckServerIndex",
  "lastAckServerName",
  "lastAckAt",
  "requestedServerIndex",
  "requestedServerName",
  "commandUpdatedAt",
  "commandRequestId",
  "commandHistory",
]);

const COMMANDS = new Set(["RUN", "PAUSE", "STOP", "SWITCH_SERVER", "COMPLETE_SERVER"]);
const HISTORY_LIMIT = 30;

function firestoreValue(value) {
  if (!value || typeof value !== "object") return undefined;
  if ("nullValue" in value) return null;
  if ("stringValue" in value) return String(value.stringValue ?? "");
  if ("integerValue" in value) return Number(value.integerValue);
  if ("doubleValue" in value) return Number(value.doubleValue);
  if ("booleanValue" in value) return Boolean(value.booleanValue);
  if ("timestampValue" in value) return String(value.timestampValue ?? "");
  if (value.arrayValue) return (value.arrayValue.values ?? []).map(firestoreValue);
  if (value.mapValue) {
    return Object.fromEntries(Object.entries(value.mapValue.fields ?? {})
      .map(([key, item]) => [key, firestoreValue(item)]));
  }
  return undefined;
}

function firestoreField(document, name, fallback = undefined) {
  const value = firestoreValue(document?.fields?.[name]);
  return value === undefined ? fallback : value;
}

function toFirestoreValue(value) {
  if (value === null || value === undefined) return { nullValue: null };
  if (typeof value === "boolean") return { booleanValue: value };
  if (typeof value === "number") {
    return Number.isSafeInteger(value)
      ? { integerValue: String(value) }
      : { doubleValue: value };
  }
  if (typeof value === "string") return { stringValue: value };
  if (Array.isArray(value)) return { arrayValue: { values: value.map(toFirestoreValue) } };
  if (typeof value === "object") {
    return {
      mapValue: {
        fields: Object.fromEntries(Object.entries(value)
          .filter(([, item]) => item !== undefined)
          .map(([key, item]) => [key, toFirestoreValue(item)])),
      },
    };
  }
  return { stringValue: String(value) };
}

function normalizeHistoryEntry(value = {}) {
  const commandNonce = integer(value.commandNonce, 0, 0, Number.MAX_SAFE_INTEGER);
  const requestedState = String(value.requestedState ?? "").trim().toUpperCase();
  if (!commandNonce || !COMMANDS.has(requestedState)) return null;
  return {
    commandId: boundedText(value.commandId || String(commandNonce), 100),
    commandNonce,
    requestedState,
    targetServerIndex: integer(value.targetServerIndex, 0, 0, 100),
    targetServerName: boundedText(value.targetServerName, 160),
    sentAt: integer(value.sentAt, 0, 0, Number.MAX_SAFE_INTEGER),
    status: boundedText(value.status || "WAITING_ACK", 40),
    ackAt: integer(value.ackAt, 0, 0, Number.MAX_SAFE_INTEGER),
    ackResult: boundedText(value.ackResult, 120),
    ackDetail: boundedText(value.ackDetail, 2000),
    statusUpdatedAt: integer(value.statusUpdatedAt, 0, 0, Number.MAX_SAFE_INTEGER),
    statusReason: boundedText(value.statusReason, 160),
  };
}

export function firestoreCommandState(document = null) {
  const nonce = integer(firestoreField(document, "nonce", 0), 0, 0, Number.MAX_SAFE_INTEGER);
  const lastAckNonce = integer(firestoreField(document, "lastAckNonce", 0), 0, 0, Number.MAX_SAFE_INTEGER);
  const command = String(firestoreField(document, "desiredState", "RUN") ?? "RUN").trim().toUpperCase();
  const history = (Array.isArray(firestoreField(document, "commandHistory", []))
    ? firestoreField(document, "commandHistory", []) : [])
    .map(normalizeHistoryEntry).filter(Boolean).sort((a, b) => b.commandNonce - a.commandNonce)
    .slice(0, HISTORY_LIMIT);
  return {
    nonce,
    command: COMMANDS.has(command) ? command : "RUN",
    serverIndex: integer(firestoreField(document, "requestedServerIndex", 0), 0, 0, 100),
    serverName: boundedText(firestoreField(document, "requestedServerName", ""), 160),
    updatedAt: integer(firestoreField(document, "commandUpdatedAt", 0), 0, 0, Number.MAX_SAFE_INTEGER),
    requestId: boundedText(firestoreField(document, "commandRequestId", ""), 100),
    lastAckNonce,
    lastAckState: boundedText(firestoreField(document, "lastAckState", ""), 40).toUpperCase(),
    lastAckResult: boundedText(firestoreField(document, "lastAckResult", ""), 120),
    lastAckDetail: boundedText(firestoreField(document, "lastAckDetail", ""), 2000),
    lastAckServerIndex: integer(firestoreField(document, "lastAckServerIndex", 0), 0, 0, 100),
    lastAckServerName: boundedText(firestoreField(document, "lastAckServerName", ""), 160),
    lastAckAt: integer(firestoreField(document, "lastAckAt", 0), 0, 0, Number.MAX_SAFE_INTEGER),
    pending: nonce > lastAckNonce,
    history,
  };
}

function commandFields(command, payload, idempotencyKey, nonce, sentAt, history) {
  const serverIndex = integer(payload?.serverIndex, 0, 0, 100);
  const serverName = boundedText(payload?.serverName, 160);
  return {
    fields: {
      desiredState: toFirestoreValue(command),
      nonce: toFirestoreValue(nonce),
      requestedServerIndex: toFirestoreValue(serverIndex),
      requestedServerName: toFirestoreValue(serverName),
      commandUpdatedAt: toFirestoreValue(sentAt),
      commandRequestId: toFirestoreValue(idempotencyKey),
      commandHistory: toFirestoreValue(history),
    },
  };
}

export async function forwardCommandWithFirestoreCas({
  uid,
  command,
  payload = {},
  idempotencyKey = "",
  readDocument,
  patchDocument,
  isConcurrencyConflict,
  now = Date.now,
  maxAttempts = 5,
}) {
  const normalizedCommand = String(command ?? "").trim().toUpperCase();
  if (!COMMANDS.has(normalizedCommand)) {
    throw new HttpError(400, "命令不在允許清單", "INVALID_COMMAND");
  }
  const requestId = boundedText(idempotencyKey, 100);
  const serverIndex = integer(payload?.serverIndex, 0, 0, 100);
  const serverName = boundedText(payload?.serverName, 160);

  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const document = await readDocument(uid, FIRESTORE_COMMAND_READ_FIELDS);
    const updateTime = String(document?.updateTime ?? "").trim();
    if (!updateTime) {
      throw new HttpError(409, "Firestore 裝置文件缺少版本時間，無法安全送出命令", "COMMAND_CAS_UNAVAILABLE");
    }
    const current = firestoreCommandState(document);
    if (requestId && current.requestId === requestId && current.command === normalizedCommand) {
      return { uid, ...current, status: current.pending ? "PENDING" : "ACKED", transport: "firestore", reused: true };
    }
    if (current.pending && normalizedCommand !== "STOP") {
      throw new HttpError(409, "上一筆命令尚未 ACK，不能覆蓋", "COMMAND_PENDING", current);
    }
    if (current.pending && normalizedCommand === "STOP" && current.command === "STOP") {
      return { uid, ...current, status: "PENDING", transport: "firestore", reused: true };
    }

    const sentAt = now();
    const nonce = Math.max(current.nonce, current.lastAckNonce) + 1;
    const superseded = current.pending
      ? current.history.map((entry) => entry.commandNonce === current.nonce
        ? { ...entry, status: "SUPERSEDED", statusUpdatedAt: sentAt, statusReason: "STOP_PRIORITY" }
        : entry)
      : current.history;
    const entry = {
      commandId: String(nonce),
      commandNonce: nonce,
      requestedState: normalizedCommand,
      targetServerIndex: serverIndex,
      targetServerName: serverName,
      sentAt,
      status: "WAITING_ACK",
      ackAt: 0,
      ackResult: "",
      ackDetail: "",
      statusUpdatedAt: sentAt,
      statusReason: "",
    };
    const history = [entry, ...superseded]
      .filter((item, index, all) => all.findIndex((other) => other.commandNonce === item.commandNonce) === index)
      .sort((a, b) => b.commandNonce - a.commandNonce)
      .slice(0, HISTORY_LIMIT);
    const fields = commandFields(normalizedCommand, { serverIndex, serverName }, requestId, nonce, sentAt, history);
    try {
      await patchDocument(uid, fields, updateTime);
      return {
        uid,
        nonce,
        command: normalizedCommand,
        serverIndex,
        serverName,
        updatedAt: sentAt,
        requestId,
        lastAckNonce: current.lastAckNonce,
        pending: true,
        status: "PENDING",
        transport: "firestore",
        reused: false,
        history,
      };
    } catch (error) {
      if (isConcurrencyConflict(error) && attempt + 1 < maxAttempts) continue;
      if (isConcurrencyConflict(error)) {
        throw new HttpError(409, "命令同時被其他控制台更新，請再試一次", "COMMAND_CONFLICT");
      }
      throw error;
    }
  }
  throw new HttpError(409, "命令同時被其他控制台更新，請再試一次", "COMMAND_CONFLICT");
}
