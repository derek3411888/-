import { createLocalJWKSet, createRemoteJWKSet, jwtVerify } from "jose";
import { HttpError } from "./utils.js";

// Browser sessions are anonymous device-control sessions, not Codex identities.
// Verify at the origin too: DNS-only and legacy-IP ingress never bypass Access.
export function createAccessVerifier({ issuer, audience, allowedEmails = [], jwks } = {}) {
  const trustedIssuer = String(issuer ?? "").replace(/\/+$/, "");
  const trustedAudience = String(audience ?? "").trim();
  const owners = new Set(allowedEmails.map((email) => String(email).trim().toLowerCase()).filter(Boolean));
  const configured = /^https:\/\/[a-z0-9-]+\.cloudflareaccess\.com$/.test(trustedIssuer) && trustedAudience && owners.size;
  const keySet = configured
    ? (typeof jwks === "function" ? jwks : jwks ? createLocalJWKSet(jwks) : createRemoteJWKSet(
      new URL(`${trustedIssuer}/cdn-cgi/access/certs`),
      { timeoutDuration: 3_000, cooldownDuration: 30_000, cacheMaxAge: 600_000 },
    )) : null;
  return async function verify(token) {
    if (!configured) throw new HttpError(503, "Codex 登入保護尚未設定完成", "CODEX_ACCESS_UNCONFIGURED");
    if (typeof token !== "string" || !token || token.length > 16_384) {
      throw new HttpError(401, "請先登入 Codex 功能", "CODEX_ACCESS_REQUIRED");
    }
    let payload;
    try {
      ({ payload } = await jwtVerify(token, keySet, {
        issuer: trustedIssuer, audience: trustedAudience, algorithms: ["RS256"],
        requiredClaims: ["iss", "aud", "exp", "iat", "sub", "email", "type"],
      }));
    } catch {
      // Never echo a token, a claim or the upstream/JWKS error into public logs.
      throw new HttpError(401, "登入已失效或無法驗證，請重新登入", "CODEX_ACCESS_REQUIRED");
    }
    if (payload.type !== "app" || typeof payload.sub !== "string" || !payload.sub ||
        typeof payload.email !== "string" || !owners.has(payload.email.toLowerCase())) {
      throw new HttpError(403, "此帳號不可使用 Codex 功能", "CODEX_ACCESS_DENIED");
    }
    return { subject: payload.sub, email: payload.email.toLowerCase(), expiresAt: payload.exp };
  };
}

export function isPrivilegedPath(pathname) {
  let decoded = String(pathname);
  // Guard encoded variants even though the router currently matches literal paths.
  for (let pass = 0; pass < 4 && decoded.includes("%"); pass += 1) {
    try { decoded = decodeURIComponent(decoded); } catch { break; }
  }
  return /^\/api\/v1\/(?:codex-support|admin)(?:\/|$)/.test(decoded);
}

export function requireAllowedOrigin(req, allowedOrigins) {
  const origin = String(req.headers.origin ?? "");
  if (origin && !allowedOrigins.includes(origin)) throw new HttpError(403, "來源驗證失敗", "ORIGIN_REJECTED");
  if (String(req.headers["x-wuthering-csrf"] ?? "") !== "1") {
    throw new HttpError(403, "缺少操作確認標頭", "CSRF_REJECTED");
  }
}
