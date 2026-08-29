import assert from "node:assert/strict";
import test from "node:test";
import { allowInternalSmokeMutation } from "../src/internal-smoke.js";

function request(address, header = "1") {
  return {
    socket: { remoteAddress: address },
    headers: { "x-wuthering-integration-smoke": header },
  };
}

test("integration mutation bypass is limited to loopback smoke devices", () => {
  assert.equal(allowInternalSmokeMutation(request("127.0.0.1"), "smoke-device-1"), true);
  assert.equal(allowInternalSmokeMutation(request("::1"), "smoke-device-2"), true);
  assert.equal(allowInternalSmokeMutation(request("::ffff:127.0.0.1"), "smoke-device-3"), true);
  assert.equal(allowInternalSmokeMutation(request("172.20.0.4"), "smoke-device-4"), false);
  assert.equal(allowInternalSmokeMutation(request("127.0.0.1", ""), "smoke-device-5"), false);
  assert.equal(allowInternalSmokeMutation(request("127.0.0.1"), "MYDESKPC_60cf84ad1ea2"), false);
});
