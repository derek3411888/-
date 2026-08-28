import assert from "node:assert/strict";
import test from "node:test";
import { buildFallbackCommandBaseline } from "../src/migration-baseline.js";

test("fallback baseline lifts stale Firestore cursors to the device floor", () => {
  assert.deepEqual(buildFallbackCommandBaseline({
    state: "RUN",
    lastNonce: 106,
    commandNonce: 106,
    remoteNonce: 104,
    remoteAckNonce: 103,
    nowMs: 123456,
  }), { nonce: 106, desiredState: "RUN", at: 123456 });
});

test("fallback baseline preserves a newer Firestore command", () => {
  assert.equal(buildFallbackCommandBaseline({
    state: "RUN",
    lastNonce: 106,
    commandNonce: 106,
    remoteNonce: 107,
    remoteAckNonce: 106,
  }), null);
});

test("fallback baseline does not rewrite an aligned cursor and keeps PAUSE when needed", () => {
  assert.equal(buildFallbackCommandBaseline({
    state: "RUN",
    lastNonce: 96,
    commandNonce: 96,
    remoteNonce: 96,
    remoteAckNonce: 96,
  }), null);
  assert.equal(buildFallbackCommandBaseline({
    state: "PAUSE",
    lastNonce: 8,
    commandNonce: 8,
    remoteNonce: 7,
    remoteAckNonce: 7,
    nowMs: 99,
  })?.desiredState, "PAUSE");
});
