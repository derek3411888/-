import crypto from "node:crypto";

export class HttpError extends Error {
  constructor(status, message, code = "REQUEST_FAILED", details = undefined) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

export function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

export function hmac(secret, value) {
  return crypto.createHmac("sha256", secret).update(value).digest("base64url");
}

export function randomToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString("base64url");
}

export function timingSafeTextEqual(left, right) {
  const a = Buffer.from(String(left));
  const b = Buffer.from(String(right));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

export function sendJson(res, status, body, extraHeaders = {}) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": data.length,
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    ...extraHeaders,
  });
  res.end(data);
}

export function sendEmpty(res, status = 204, extraHeaders = {}) {
  res.writeHead(status, { "Cache-Control": "no-store", ...extraHeaders });
  res.end();
}

export async function readBuffer(req, maxBytes) {
  const length = Number.parseInt(req.headers["content-length"] ?? "0", 10);
  if (Number.isFinite(length) && length > maxBytes) throw new HttpError(413, "請求內容過大", "BODY_TOO_LARGE");
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > maxBytes) throw new HttpError(413, "請求內容過大", "BODY_TOO_LARGE");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, total);
}

export async function readJson(req, maxBytes) {
  const raw = await readBuffer(req, maxBytes);
  if (!raw.length) return {};
  try {
    return JSON.parse(raw.toString("utf8"));
  } catch {
    throw new HttpError(400, "JSON 格式錯誤", "INVALID_JSON");
  }
}

export function parseCookies(header = "") {
  const result = Object.create(null);
  for (const part of String(header).split(";")) {
    const index = part.indexOf("=");
    if (index <= 0) continue;
    const key = part.slice(0, index).trim();
    try { result[key] = decodeURIComponent(part.slice(index + 1).trim()); } catch {}
  }
  return result;
}

export function bearerToken(req) {
  const match = /^Bearer\s+(.+)$/i.exec(String(req.headers.authorization ?? ""));
  return match ? match[1].trim() : "";
}

export function clientIp(req) {
  const forwarded = String(req.headers["x-forwarded-for"] ?? "").split(",").map((item) => item.trim()).filter(Boolean).at(-1) ?? "";
  return forwarded || req.socket.remoteAddress || "";
}

export function normalizeUid(value) {
  const uid = String(value ?? "").trim();
  if (!/^[A-Za-z0-9._@-]{3,160}$/.test(uid)) throw new HttpError(400, "裝置 UID 格式無效", "INVALID_UID");
  return uid;
}

export function boundedText(value, max = 1000) {
  return String(value ?? "").trim().slice(0, max);
}

export function integer(value, fallback = 0, min = 0, max = Number.MAX_SAFE_INTEGER) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

export function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export class EventHub {
  #listeners = new Set();

  add(res) {
    this.#listeners.add(res);
    return () => this.#listeners.delete(res);
  }

  emit(type, payload) {
    const data = `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;
    for (const res of [...this.#listeners]) {
      try { res.write(data); } catch { this.#listeners.delete(res); }
    }
  }

  heartbeat() {
    for (const res of [...this.#listeners]) {
      try { res.write(": keepalive\n\n"); } catch { this.#listeners.delete(res); }
    }
  }
}

export class RateLimiter {
  #entries = new Map();

  check(key, maxAttempts, windowMs) {
    const now = Date.now();
    const entry = this.#entries.get(key);
    if (!entry || entry.resetAt <= now) {
      this.#entries.set(key, { count: 1, resetAt: now + windowMs });
      return true;
    }
    entry.count += 1;
    return entry.count <= maxAttempts;
  }

  prune() {
    const now = Date.now();
    for (const [key, value] of this.#entries) if (value.resetAt <= now) this.#entries.delete(key);
  }
}
