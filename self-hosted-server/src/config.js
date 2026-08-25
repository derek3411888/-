import path from "node:path";

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

function publicUrl() {
  const raw = String(process.env.PUBLIC_URL ?? "http://localhost:8080").replace(/\/+$/, "");
  const parsed = new URL(raw);
  if (!["http:", "https:"].includes(parsed.protocol)) throw new Error("PUBLIC_URL 必須是 HTTP(S) 網址");
  return parsed;
}

const publicBase = publicUrl();

export const config = Object.freeze({
  port: integer("PORT", 3000, 1, 65535),
  databaseUrl: process.env.DATABASE_URL ?? "postgres://wuthering:wuthering@postgres:5432/wuthering_control",
  publicUrl: publicBase.origin,
  publicSrtHost: String(process.env.PUBLIC_SRT_HOST ?? publicBase.hostname).trim(),
  publicSrtPort: integer("PUBLIC_SRT_PORT", 8890, 1, 65535),
  sessionSecret: requiredSecret("SESSION_SECRET"),
  liveSecret: requiredSecret("LIVE_TOKEN_SECRET"),
  liveSrtPassphrase: requiredSecret("LIVE_SRT_PASSPHRASE"),
  mediaRoot: path.resolve(process.env.MEDIA_ROOT ?? "/data/media"),
  snapshotRoot: path.resolve(process.env.SNAPSHOT_ROOT ?? "/data/snapshots"),
  serverLogRoot: path.resolve(process.env.SERVER_LOG_ROOT ?? "/data/logs"),
  staticRoot: path.resolve(process.env.STATIC_ROOT ?? new URL("../public", import.meta.url).pathname),
  migrationDir: path.resolve(process.env.MIGRATION_DIR ?? new URL("../migrations", import.meta.url).pathname),
  minFreeBytes: BigInt(integer("MIN_FREE_GB", 20, 1, 10_000)) * 1024n * 1024n * 1024n,
  sessionsPerDevice: integer("SESSIONS_PER_DEVICE", 5, 1, 100),
  browserSessionDays: integer("BROWSER_SESSION_DAYS", 180, 1, 730),
  liveLeaseSeconds: integer("LIVE_LEASE_SECONDS", 90, 30, 300),
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
