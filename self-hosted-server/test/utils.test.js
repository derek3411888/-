import assert from "node:assert/strict";
import path from "node:path";
import { Readable } from "node:stream";
import test from "node:test";
import {
  HttpError,
  RateLimiter,
  bearerToken,
  boundedText,
  integer,
  normalizeUid,
  parseCookies,
  readJson,
  sha256,
  timingSafeTextEqual,
} from "../src/utils.js";

test("credential helpers do not accept prefixes or length mismatches", () => {
  assert.equal(timingSafeTextEqual("token", "token"), true);
  assert.equal(timingSafeTextEqual("token", "token2"), false);
  assert.equal(bearerToken({ headers: { authorization: "Bearer abc_def-123" } }), "abc_def-123");
  assert.equal(bearerToken({ headers: { authorization: "Basic abc" } }), "");
  assert.equal(sha256("test").length, 64);
});

test("cookie and UID parsing are bounded", () => {
  const cookies = parseCookies("a=1; encoded=%E6%B8%AC%E8%A9%A6; malformed=%ZZ");
  assert.equal(cookies.a, "1");
  assert.equal(cookies.encoded, "測試");
  assert.equal(cookies.malformed, undefined);
  assert.equal(normalizeUid(" machine-01 "), "machine-01");
  assert.throws(() => normalizeUid("../escape"), (error) => error instanceof HttpError && error.code === "INVALID_UID");
  assert.equal(boundedText("  abcdef  ", 3), "abc");
  assert.equal(integer("99", 0, 1, 10), 10);
});

test("JSON reader rejects malformed and oversized request bodies", async () => {
  const valid = Readable.from([Buffer.from('{"ok":true}')]); valid.headers = {};
  assert.deepEqual(await readJson(valid, 100), { ok: true });
  const malformed = Readable.from([Buffer.from("{")]); malformed.headers = {};
  await assert.rejects(readJson(malformed, 100), (error) => error.code === "INVALID_JSON");
  const oversized = Readable.from([Buffer.alloc(11)]); oversized.headers = { "content-length": "11" };
  await assert.rejects(readJson(oversized, 10), (error) => error.code === "BODY_TOO_LARGE");
});

test("rate limiter resets by time window", async () => {
  const limiter = new RateLimiter();
  assert.equal(limiter.check("ip", 2, 10), true);
  assert.equal(limiter.check("ip", 2, 10), true);
  assert.equal(limiter.check("ip", 2, 10), false);
  await new Promise((resolve) => setTimeout(resolve, 15));
  assert.equal(limiter.check("ip", 2, 10), true);
});

test("path guard rejects siblings sharing a prefix", async () => {
  process.env.SESSION_SECRET = "test-session-secret-abcdefghijklmnopqrstuvwxyz";
  process.env.CODEX_BRIDGE_TOKEN = "test-codex-bridge-token-abcdefghijklmnopqrstuvwxyz";
  process.env.LIVE_TOKEN_SECRET = "test-live-token-secret-abcdefghijklmnopqrstuvwxyz";
  process.env.LIVE_SRT_PASSPHRASE = "test-live-srt-passphrase-abcdefghijklm";
  const { assertChildPath } = await import("../src/config.js");
  const root = path.resolve("test-root");
  assert.equal(assertChildPath(root, path.join(root, "device", "file")), path.join(root, "device", "file"));
  assert.throws(() => assertChildPath(root, path.resolve("test-root-evil", "file")));
});
