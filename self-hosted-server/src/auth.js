import { config } from "./config.js";
import { query, withTransaction } from "./db.js";
import {
  HttpError,
  bearerToken,
  boundedText,
  clientIp,
  normalizeUid,
  parseCookies,
  randomToken,
  sha256,
} from "./utils.js";

export async function createActivationLink(hours = 24) {
  const token = randomToken(32);
  await query(
    "INSERT INTO activation_tokens(token_hash, expires_at) VALUES ($1, now() + ($2 || ' hours')::interval)",
    [sha256(token), Math.max(1, Math.min(168, Number(hours) || 24))],
  );
  return `${config.publicUrl}/#activate=${token}`;
}

export async function activateBrowser(req, token, label = "") {
  const tokenHash = sha256(String(token ?? ""));
  const sessionToken = randomToken(40);
  const sessionHash = sha256(sessionToken);
  const expiresAt = new Date(Date.now() + config.browserSessionDays * 86_400_000);
  const row = await withTransaction(async (client) => {
    const activation = await client.query(
      "SELECT token_hash FROM activation_tokens WHERE token_hash=$1 AND used_at IS NULL AND expires_at > now() FOR UPDATE",
      [tokenHash],
    );
    if (!activation.rowCount) throw new HttpError(401, "啟用連結無效、已使用或已過期", "ACTIVATION_INVALID");
    const inserted = await client.query(
      `INSERT INTO browser_sessions(token_hash,label,user_agent,ip_address,expires_at)
       VALUES($1,$2,$3,$4,$5) RETURNING id,created_at,expires_at`,
      [sessionHash, boundedText(label, 80), boundedText(req.headers["user-agent"], 300), clientIp(req), expiresAt],
    );
    await client.query("UPDATE activation_tokens SET used_at=now() WHERE token_hash=$1", [tokenHash]);
    return inserted.rows[0];
  });
  return { token: sessionToken, session: row };
}

export function browserCookie(token, expiresAt) {
  const secure = config.publicUrl.startsWith("https://") ? "; Secure" : "";
  return `${config.cookieName}=${encodeURIComponent(token)}; Path=/; HttpOnly; SameSite=Strict${secure}; Expires=${new Date(expiresAt).toUTCString()}`;
}

export function clearBrowserCookie() {
  const secure = config.publicUrl.startsWith("https://") ? "; Secure" : "";
  return `${config.cookieName}=; Path=/; HttpOnly; SameSite=Strict${secure}; Max-Age=0`;
}

export async function requireBrowser(req) {
  const token = parseCookies(req.headers.cookie)[config.cookieName] ?? "";
  if (!token) throw new HttpError(401, "需要私人啟用連結", "BROWSER_UNAUTHORIZED");
  const tokenHash = sha256(token);
  const result = await query(
    `SELECT id,label,user_agent,ip_address,created_at,last_seen_at,expires_at
     FROM browser_sessions WHERE token_hash=$1 AND revoked_at IS NULL AND expires_at>now()`,
    [tokenHash],
  );
  if (!result.rowCount) throw new HttpError(401, "瀏覽器授權已失效", "BROWSER_SESSION_EXPIRED");
  if (Date.now() - result.rows[0].last_seen_at.valueOf() >= 60_000) {
    await query(
      "UPDATE browser_sessions SET last_seen_at=now() WHERE token_hash=$1 AND last_seen_at<now()-interval '1 minute'",
      [tokenHash],
    );
    result.rows[0].last_seen_at = new Date();
  }
  return result.rows[0];
}

export function requireSameOrigin(req) {
  const origin = String(req.headers.origin ?? "");
  if (origin && origin !== config.publicUrl) throw new HttpError(403, "來源驗證失敗", "ORIGIN_REJECTED");
  if (String(req.headers["x-wuthering-csrf"] ?? "") !== "1") {
    throw new HttpError(403, "缺少操作確認標頭", "CSRF_REJECTED");
  }
}

export async function requireDevice(req) {
  const token = bearerToken(req);
  if (!token) throw new HttpError(401, "缺少裝置憑證", "DEVICE_UNAUTHORIZED");
  const tokenHash = sha256(token);
  const result = await query(
    "SELECT uid,id,last_used_at FROM device_credentials WHERE token_hash=$1 AND revoked_at IS NULL",
    [tokenHash],
  );
  if (!result.rowCount) throw new HttpError(401, "裝置憑證無效或已撤銷", "DEVICE_UNAUTHORIZED");
  if (!result.rows[0].last_used_at || Date.now() - result.rows[0].last_used_at.valueOf() >= 5 * 60_000) {
    await query(
      "UPDATE device_credentials SET last_used_at=now() WHERE token_hash=$1 AND (last_used_at IS NULL OR last_used_at<now()-interval '5 minutes')",
      [tokenHash],
    );
  }
  return result.rows[0];
}

export async function enrollDevice(body) {
  const uid = normalizeUid(body.uid);
  const token = String(body.deviceToken ?? "");
  if (!/^[A-Za-z0-9_-]{40,180}$/.test(token)) throw new HttpError(400, "裝置憑證格式無效", "INVALID_DEVICE_TOKEN");
  const displayName = boundedText(body.displayName, 160);
  const deviceAlias = boundedText(body.deviceAlias, 120);
  const lastNonce = Math.max(0, Number(body.lastNonce) || 0);
  const settingsRevision = Math.max(0, Number(body.settingsRevision) || 0);
  const tokenHash = sha256(token);

  return withTransaction(async (client) => {
    const existing = await client.query(
      "SELECT uid FROM device_credentials WHERE token_hash=$1 AND revoked_at IS NULL",
      [tokenHash],
    );
    if (existing.rowCount) {
      if (existing.rows[0].uid !== uid) throw new HttpError(409, "裝置憑證與 UID 不一致", "DEVICE_TOKEN_UID_MISMATCH");
      return { uid, enrolled: true, existing: true };
    }

    const device = await client.query("SELECT uid FROM devices WHERE uid=$1 FOR UPDATE", [uid]);
    const enrollment = await client.query(
      "SELECT value->>'openUntil' AS open_until FROM system_settings WHERE key='enrollment'",
    );
    const openUntil = enrollment.rows[0]?.open_until ? new Date(enrollment.rows[0].open_until) : null;
    const allow = await client.query(
      `SELECT uid FROM enrollment_allowlist
       WHERE uid=$1 AND claimed_at IS NULL AND (expires_at IS NULL OR expires_at>now()) FOR UPDATE`,
      [uid],
    );
    if (!allow.rowCount && !(openUntil && openUntil > new Date())) {
      throw new HttpError(403, "目前未開放此裝置自動註冊", "ENROLLMENT_CLOSED");
    }
    if (!device.rowCount) {
      await client.query(
        `INSERT INTO devices(uid,display_name,device_alias,last_nonce,command_nonce,settings_revision)
         VALUES($1,$2,$3,$4,$4,$5)`,
        [uid, displayName, deviceAlias, lastNonce, settingsRevision],
      );
    } else {
      await client.query(
        `UPDATE devices SET display_name=COALESCE(NULLIF($2,''),display_name),
          device_alias=COALESCE(NULLIF($3,''),device_alias),last_nonce=GREATEST(last_nonce,$4),
          command_nonce=GREATEST(command_nonce,$4),settings_revision=GREATEST(settings_revision,$5),updated_at=now()
         WHERE uid=$1`,
        [uid, displayName, deviceAlias, lastNonce, settingsRevision],
      );
    }
    await client.query(
      "INSERT INTO device_credentials(uid,token_hash,label) VALUES($1,$2,$3)",
      [uid, tokenHash, displayName || uid],
    );
    await client.query("UPDATE devices SET credential_issued_at=now() WHERE uid=$1", [uid]);
    await client.query("UPDATE enrollment_allowlist SET claimed_at=now() WHERE uid=$1", [uid]);
    return { uid, enrolled: true, existing: false };
  });
}
