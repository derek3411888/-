import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

function integer(name, fallback, min, max) {
  const parsed = Number.parseInt(process.env[name] ?? "", 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

function requiredSecret(name) {
  const value = String(process.env[name] ?? "").trim();
  if (value.length < 32) {
    throw new Error(`${name} 必須至少 32 個字元`);
  }
  return value;
}

function srtHost(name, fallback = "") {
  const value = String(process.env[name] ?? fallback).trim();
  if (!value) return "";
  if (!/^[A-Za-z0-9.-]+$/.test(value)) throw new Error(`${name} 必須是主機名稱或 IPv4 位址`);
  return value;
}

function publicUrl() {
  const raw = String(process.env.PUBLIC_URL ?? "http://localhost:8080").replace(/\/+$/, "");
  const parsed = new URL(raw);
  if (!["http:", "https:"].includes(parsed.protocol)) throw new Error("PUBLIC_URL 必須是 HTTP(S) 網址");
  return parsed;
}

const publicBase = publicUrl();
const serverRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const localDevelopmentRoot = path.resolve(serverRoot, "..", ".dev-runtime", "self-hosted-runtime");
const staticRoot = path.resolve(process.env.STATIC_ROOT ?? fileURLToPath(new URL("../public", import.meta.url)));
const packageInfo = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8"));

function sha256Text(value) {
  return crypto.createHash("sha256").update(value).digest("hex").toUpperCase();
}

function webAssetSha256(root) {
  const names = ["app.js", "index.html", "styles.css"].sort();
  const inventory = names.map((name) => {
    const digest = crypto.createHash("sha256").update(fs.readFileSync(path.join(root, name))).digest("hex").toUpperCase();
    return `${name}:${digest}`;
  }).join("\n");
  return sha256Text(inventory);
}

export const config = Object.freeze({
  port: integer("PORT", 3000, 1, 65535),
  databaseUrl: process.env.DATABASE_URL ?? "postgres://wuthering:wuthering@postgres:5432/wuthering_control",
  publicUrl: publicBase.origin,
  serverVersion: String(packageInfo.version ?? "0.0.0"),
  webSha256: webAssetSha256(staticRoot),
  publicSrtHost: srtHost("PUBLIC_SRT_HOST", publicBase.hostname),
  localSrtHost: srtHost("LOCAL_SRT_HOST"),
  publicSrtPort: integer("PUBLIC_SRT_PORT", 8890, 1, 65535),
  sessionSecret: requiredSecret("SESSION_SECRET"),
  codexBridgeToken: requiredSecret("CODEX_BRIDGE_TOKEN"),
  liveSecret: requiredSecret("LIVE_TOKEN_SECRET"),
  liveSrtPassphrase: requiredSecret("LIVE_SRT_PASSPHRASE"),
  // Compose always supplies /data mounts. These repository-local fallbacks are
  // only for direct Node development, so a local `npm start` cannot write to a
  // drive root or the user's profile by accident.
  mediaRoot: path.resolve(process.env.MEDIA_ROOT ?? path.join(localDevelopmentRoot, "media")),
  snapshotRoot: path.resolve(process.env.SNAPSHOT_ROOT ?? path.join(localDevelopmentRoot, "snapshots")),
  serverLogRoot: path.resolve(process.env.SERVER_LOG_ROOT ?? path.join(localDevelopmentRoot, "logs")),
  staticRoot,
  migrationDir: path.resolve(process.env.MIGRATION_DIR ?? fileURLToPath(new URL("../migrations", import.meta.url))),
  minFreeBytes: BigInt(integer("MIN_FREE_GB", 20, 1, 10_000)) * 1024n * 1024n * 1024n,
  sessionsPerDevice: integer("SESSIONS_PER_DEVICE", 5, 1, 100),
  browserSessionDays: integer("BROWSER_SESSION_DAYS", 180, 1, 730),
  liveLeaseSeconds: integer("LIVE_LEASE_SECONDS", 90, 30, 300),
  livePublisherGraceSeconds: integer("LIVE_PUBLISHER_GRACE_SECONDS", 600, 30, 3600),
  liveTokenSeconds: integer("LIVE_TOKEN_SECONDS", 900, 120, 3600),
  maxJsonBytes: integer("MAX_JSON_BYTES", 2 * 1024 * 1024, 64 * 1024, 8 * 1024 * 1024),
  maxUploadChunkBytes: integer("MAX_UPLOAD_CHUNK_BYTES", 8 * 1024 * 1024, 256 * 1024, 32 * 1024 * 1024),
  cookieName: "wu_owner_session",
  firestore: Object.freeze({
    enabled: String(process.env.FIRESTORE_IMPORT_ENABLED ?? "false").toLowerCase() === "true",
    projectId: String(process.env.FIRESTORE_PROJECT_ID ?? "").trim(),
    apiKey: String(process.env.FIRESTORE_API_KEY ?? "").trim(),
    collection: String(process.env.FIRESTORE_COLLECTION ?? "ahk_clients").trim() || "ahk_clients",
  }),
});

export function assertChildPath(root, candidate) {
  const resolvedRoot = path.resolve(root);
  const resolved = path.resolve(candidate);
  if (resolved !== resolvedRoot && !resolved.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new Error(`拒絕存取資料根目錄以外的路徑: ${resolved}`);
  }
  return resolved;
}
