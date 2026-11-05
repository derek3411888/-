import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import http from "node:http";
import test from "node:test";
import { verifyAnonymousPrivilegedAccess } from "./integration-access-smoke.mjs";

const access = await import("../src/access-auth.js").catch((error) => {
  if (error.code === "ERR_MODULE_NOT_FOUND" && error.url?.endsWith("/src/access-auth.js")) return {};
  throw error;
});
const issuer = "https://unit-test.cloudflareaccess.com";
const audience = "test-application-audience";
const email = "owner@example.test";
const keys = generateKeyPairSync("rsa", { modulusLength: 2048 });
const otherKeys = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...keys.publicKey.export({ format: "jwk" }), kid: "unit-key", alg: "RS256", use: "sig" };
const now = Math.floor(Date.now() / 1000);
const claims = { iss: issuer, aud: [audience], sub: "test-user", email, type: "app", iat: now, nbf: now - 1, exp: now + 300 };
function jwt(changes = {}, options = {}) {
  const body = { ...claims, ...changes };
  for (const key of options.omit ?? []) delete body[key];
  const header = { alg: options.alg ?? "RS256", kid: "unit-key", ...options.header };
  const data = [header, body].map((value) => Buffer.from(JSON.stringify(value)).toString("base64url")).join(".");
  return `${data}.${sign("sha256", Buffer.from(data), options.privateKey ?? keys.privateKey).toString("base64url")}`;
}
function verifier(options = {}) {
  assert.equal(typeof access.createAccessVerifier, "function", "origin Access verifier must exist");
  return access.createAccessVerifier({ issuer, audience, allowedEmails: [email], jwks: { keys: [jwk] }, ...options });
}

test("valid signed Access app identity is accepted", async () => {
  assert.equal((await verifier()(jwt())).email, email);
});
for (const [name, token] of [
  ["missing", ""], ["malformed", "not.a.jwt"],
  ["invalid signature", jwt({}, { privateKey: otherKeys.privateKey })],
  ["wrong algorithm", jwt({}, { alg: "HS256" })],
  ["none algorithm", jwt({}, { alg: "none" })],
  ["wrong issuer", jwt({ iss: "https://attacker.cloudflareaccess.com" })],
  ["wrong audience", jwt({ aud: ["another-app"] })],
  ["expired", jwt({ exp: now - 10 })],
  ["not yet valid", jwt({ nbf: now + 600 })],
  ["non-owner", jwt({ email: "other@example.test" })],
  ["service identity", jwt({ type: "service" })],
  ...["iss", "aud", "exp", "iat", "sub", "email", "type"].map((key) => [`missing ${key}`, jwt({}, { omit: [key] })]),
]) {
  test(`Access rejects ${name}`, async () => {
    await assert.rejects(() => verifier()(token), (error) => [401, 403].includes(error.status));
  });
}
test("missing or unsafe configuration fails closed without making requests", async () => {
  for (const options of [{ issuer: "" }, { audience: "" }, { allowedEmails: [] }, { issuer: "http://unit-test.cloudflareaccess.com" }, { issuer: "https://example.test" }]) {
    await assert.rejects(() => verifier(options)(jwt()), { code: "CODEX_ACCESS_UNCONFIGURED" });
  }
});
test("JWKS failure is fail closed", async () => {
  const verify = verifier({ jwks: async () => { throw new Error("JWKS unavailable"); } });
  await assert.rejects(() => verify(jwt()), { code: "CODEX_ACCESS_REQUIRED" });
});
test("JWKS key rotation accepts a current trusted key, never an unknown key", async () => {
  const rotated = { ...otherKeys.publicKey.export({ format: "jwk" }), kid: "rotated", alg: "RS256", use: "sig" };
  const verify = verifier({ jwks: { keys: [jwk, rotated] } });
  assert.equal((await verify(jwt({}, { privateKey: otherKeys.privateKey, header: { kid: "rotated" } }))).email, email);
  await assert.rejects(() => verify(jwt({}, { header: { kid: "unknown" } })), { code: "CODEX_ACCESS_REQUIRED" });
});
test("all Codex and admin path variants are privileged, device routes are separate", () => {
  assert.equal(typeof access.isPrivilegedPath, "function");
  for (const name of ["/api/v1/codex-support", "/api/v1/codex-support/retry", "/api/v1/admin/migration", "/api/v1/%63odex-support", "/api/v1/codex-support%2fcancel", "/api/v1/%2563odex-support"]) {
    assert.equal(access.isPrivilegedPath(name), true, name);
  }
  for (const name of ["/api/v1/device/control", "/api/v1/devices", "/internal/codex-support/next", "/api/v1/events"]) {
    assert.equal(access.isPrivilegedPath(name), false, name);
  }
});
test("exact configured origins only; preserve existing CSRF requirement", () => {
  assert.equal(typeof access.requireAllowedOrigin, "function");
  const origins = ["https://ww.sckang.cc", "https://direct.sckang.cc", "https://codex.sckang.cc"];
  for (const origin of [...origins, undefined]) access.requireAllowedOrigin({ headers: { origin, "x-wuthering-csrf": "1" } }, origins);
  for (const origin of ["null", "https://ww.sckang.cc.attacker.test", "http://ww.sckang.cc", "https://other.sckang.cc"]) {
    assert.throws(() => access.requireAllowedOrigin({ headers: { origin, "x-wuthering-csrf": "1" } }, origins), { code: "ORIGIN_REJECTED" });
  }
  assert.throws(() => access.requireAllowedOrigin({ headers: { origin: origins[0] } }, origins), { code: "CSRF_REJECTED" });
});
test("real application handler denies direct, old-IP, forged-Host and encoded anonymous Codex before database access", async (t) => {
  for (const name of ["SESSION_SECRET", "CODEX_BRIDGE_TOKEN", "LIVE_TOKEN_SECRET", "LIVE_SRT_PASSPHRASE"]) process.env[name] = "isolated-test-secret-longer-than-32-characters";
  process.env.DATABASE_URL = "postgres://invalid:invalid@127.0.0.1:1/no_database";
  process.env.CLOUDFLARE_ACCESS_ISSUER = issuer;
  process.env.CLOUDFLARE_ACCESS_AUDIENCE = audience;
  process.env.CODEX_ALLOWED_EMAILS = email;
  const app = await import("../src/app.js");
  assert.equal(typeof app.handleRequest, "function");
  const server = http.createServer((req, res) => app.handleRequest(req, res).catch((error) => {
    res.writeHead(error.status ?? 500); res.end(error.code ?? "UNKNOWN");
  }));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  for (const host of ["direct.sckang.cc", "220.135.218.98", "codex.sckang.cc", "attacker.test"]) {
    for (const pathname of ["/api/v1/codex-support", "/api/v1/admin/migration", "/api/v1/%63odex-support"]) {
      const response = await fetch(base + pathname, { method: "POST", headers: { host, "x-wuthering-csrf": "1", "cf-access-authenticated-user-email": email } });
      assert.equal(response.status, 401, `${host}${pathname}`);
      assert.equal(await response.text(), "CODEX_ACCESS_REQUIRED");
    }
  }
  const response = await fetch(base + "/api/v1/device/control");
  assert.equal(response.status, 401);
  assert.equal(await response.text(), "DEVICE_UNAUTHORIZED", "device auth must not depend on Access");
  await verifyAnonymousPrivilegedAccess({ base, cookie: "anonymous=fixture", origin: "https://ww.sckang.cc" });

  // Validate the authenticated branches through the real handler and RS256
  // verifier. Only the external JWKS/DB boundaries use isolated fixtures.
  const realFetch = globalThis.fetch;
  let jwksRequests = 0;
  t.mock.method(globalThis, "fetch", async (url, options) => {
    if (String(url) === `${issuer}/cdn-cgi/access/certs`) {
      jwksRequests++;
      return Response.json({ keys: [jwk] });
    }
    assert.ok(String(url).startsWith(base + "/"), "no external network allowed");
    return realFetch(url, options);
  });
  const { pool } = await import("../src/db.js");
  const { config } = await import("../src/config.js");
  t.mock.method(pool, "query", async (sql) => {
    assert.match(sql, /^SELECT id,label,user_agent,ip_address,created_at,last_seen_at,expires_at\s+FROM browser_sessions/);
    return { rowCount: 1, rows: [{ id: 1, last_seen_at: new Date(), expires_at: new Date(Date.now() + 60000) }] };
  });
  const signedHeaders = { Cookie: `${config.cookieName}=fixture-session`, "cf-access-jwt-assertion": jwt(), "Content-Type": "application/json" };
  const invalidMode = await fetch(base + "/api/v1/codex-support", {
    method: "POST", headers: { ...signedHeaders, Origin: config.publicUrl, "X-Wuthering-CSRF": "1" },
    body: JSON.stringify({ mode: "UNKNOWN", message: "must not be sent" }),
  });
  assert.equal(invalidMode.status, 400, await invalidMode.text());
  const missingCsrf = await fetch(base + "/api/v1/admin/migration/mode", {
    method: "PUT", headers: signedHeaders, body: JSON.stringify({ mode: "primary" }),
  });
  assert.equal(missingCsrf.status, 403);
  assert.equal(await missingCsrf.text(), "CSRF_REJECTED");
  assert.equal(jwksRequests, 1, "signed requests passed real JWT validation with cached test JWKS");
});
