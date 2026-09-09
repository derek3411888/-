import assert from "node:assert/strict";
import test from "node:test";
import {
  firestoreCommandState,
  forwardCommandWithFirestoreCas,
} from "../src/firestore-command.js";

function value(input) {
  if (typeof input === "string") return { stringValue: input };
  if (typeof input === "boolean") return { booleanValue: input };
  if (typeof input === "number") return { integerValue: String(input) };
  if (Array.isArray(input)) return { arrayValue: { values: input.map(value) } };
  return { mapValue: { fields: Object.fromEntries(Object.entries(input).map(([key, item]) => [key, value(item)])) } };
}

function document(updateTime, fields) {
  return { updateTime, fields: Object.fromEntries(Object.entries(fields).map(([key, item]) => [key, value(item)])) };
}

test("forwards an atomic Firestore command with history", async () => {
  let patched = null;
  const result = await forwardCommandWithFirestoreCas({
    uid: "DEVICE_1",
    command: "RUN",
    idempotencyKey: "request-1",
    readDocument: async () => document("stamp-1", { nonce: 7, lastAckNonce: 7, desiredState: "PAUSE", commandHistory: [] }),
    patchDocument: async (uid, fields, stamp) => { patched = { uid, fields, stamp }; },
    isConcurrencyConflict: () => false,
    now: () => 123456,
  });
  assert.equal(result.nonce, 8);
  assert.equal(result.transport, "firestore");
  assert.equal(patched.uid, "DEVICE_1");
  assert.equal(patched.stamp, "stamp-1");
  const written = firestoreCommandState({ fields: patched.fields.fields });
  assert.equal(written.nonce, 8);
  assert.equal(written.command, "RUN");
  assert.equal(written.requestId, "request-1");
  assert.equal(written.history[0].commandNonce, 8);
  assert.equal(written.history[0].status, "WAITING_ACK");
});

test("rejects a second non-STOP command while ACK is pending", async () => {
  await assert.rejects(
    forwardCommandWithFirestoreCas({
      uid: "DEVICE_1",
      command: "PAUSE",
      readDocument: async () => document("stamp-1", { nonce: 9, lastAckNonce: 8, desiredState: "RUN" }),
      patchDocument: async () => assert.fail("pending command must not be overwritten"),
      isConcurrencyConflict: () => false,
    }),
    (error) => error.code === "COMMAND_PENDING",
  );
});

test("STOP supersedes a pending command and a repeated STOP reuses it", async () => {
  let writtenDocument = null;
  const oldHistory = [{
    commandId: "9", commandNonce: 9, requestedState: "RUN", targetServerIndex: 0,
    targetServerName: "", sentAt: 100, status: "WAITING_ACK", ackAt: 0,
    ackResult: "", ackDetail: "", statusUpdatedAt: 100, statusReason: "",
  }];
  const first = await forwardCommandWithFirestoreCas({
    uid: "DEVICE_1",
    command: "STOP",
    idempotencyKey: "stop-1",
    readDocument: async () => document("stamp-1", {
      nonce: 9, lastAckNonce: 8, desiredState: "RUN", commandHistory: oldHistory,
    }),
    patchDocument: async (uid, fields) => { writtenDocument = { fields: fields.fields, updateTime: "stamp-2" }; },
    isConcurrencyConflict: () => false,
    now: () => 200,
  });
  assert.equal(first.nonce, 10);
  const written = firestoreCommandState(writtenDocument);
  assert.equal(written.history[1].status, "SUPERSEDED");
  assert.equal(written.history[1].statusReason, "STOP_PRIORITY");

  const repeated = await forwardCommandWithFirestoreCas({
    uid: "DEVICE_1",
    command: "STOP",
    idempotencyKey: "stop-2",
    readDocument: async () => writtenDocument,
    patchDocument: async () => assert.fail("repeated STOP must be idempotent"),
    isConcurrencyConflict: () => false,
  });
  assert.equal(repeated.nonce, 10);
  assert.equal(repeated.reused, true);
});

test("retries a Firestore compare-and-swap conflict", async () => {
  let reads = 0;
  let writes = 0;
  const result = await forwardCommandWithFirestoreCas({
    uid: "DEVICE_1",
    command: "RUN",
    readDocument: async () => document(`stamp-${++reads}`, { nonce: 3, lastAckNonce: 3, desiredState: "RUN" }),
    patchDocument: async () => {
      writes += 1;
      if (writes === 1) throw Object.assign(new Error("conflict"), { status: 412 });
    },
    isConcurrencyConflict: (error) => error.status === 412,
  });
  assert.equal(result.nonce, 4);
  assert.equal(reads, 2);
  assert.equal(writes, 2);
});
